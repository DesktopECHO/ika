#!/usr/bin/env bash
# Pre-build input validation and output-repair helpers for the LineageOS Desktop
# build engine: build-input checks, Soong graph/zero-byte repair, stale Launcher3
# cleanup, and fstab/tablet validation. Source only (defines functions). Relies
# on engine globals + core primitives.
#
# Note: corrupt/zero-size *host-tool* ELF auto-repair was intentionally removed.
# A bad host tool now hard-fails at the post-build built_target_outputs_complete
# /cvd_host_package_critical_tools_complete checks instead of self-healing.

validate_build_inputs_for_targets() {
  enabled "$validate_build_inputs" || return 0

  local validate_script="$workspace/vendor/lineage_desktop/scripts/lib/validate_build_inputs.sh"
  [[ -x "$validate_script" ]] || die "missing build input validator: $validate_script"

  log "validating build inputs"
  "$validate_script" "$workspace" "$@"
}

repair_soong_zero_byte_objects() {
  local intermediates="$workspace/out/soong/.intermediates"
  [[ -d "$intermediates" ]] || return 0

  local -a bad_key_outputs=()
  mapfile -t bad_key_outputs < <(
    find "$intermediates/device/google/cuttlefish/build" \
      -type f \
      -name 'cvd_avb_testkey_rsa*.pem' \
      -size 0 \
      -print 2>/dev/null || true
  )
  if (( ${#bad_key_outputs[@]} > 0 )); then
    log "removing ${#bad_key_outputs[@]} zero-size AVB key intermediate(s)"
    rm -f "${bad_key_outputs[@]}"
  fi

  local -a bad_objects
  mapfile -t bad_objects < <(find "$intermediates" -type f -name '*.o' -size 0 -print)
  (( ${#bad_objects[@]} == 0 )) && return 0

  local -A prune_dirs=()
  local obj module_dir
  for obj in "${bad_objects[@]}"; do
    module_dir="${obj%/obj/*}"
    [[ "$module_dir" == "$obj" || -z "$module_dir" || ! -d "$module_dir" ]] && continue
    prune_dirs["$module_dir"]=1
  done

  local dir
  for dir in "${!prune_dirs[@]}"; do
    log "removing stale Soong module output: $dir"
    rm -rf "$dir"
  done
}

remove_generated_ninja_state() {
  local product="$1"
  local reason="$2"
  local out_dir="$workspace/out"
  local out_soong="$workspace/out/soong"
  local prefix="build.${product}"

  [[ -d "$out_dir" ]] || return 0

  log "removing generated Ninja/Kati state for $product: $reason"
  rm -f "$out_dir/.ninja_deps" "$out_dir/.ninja_log"
  find "$out_dir" -maxdepth 1 -type f \( \
    -name "build-${product}.ninja" -o \
    -name "build-${product}-*.ninja" -o \
    -name ".kati_stamp-${product}" -o \
    -name ".kati_stamp-${product}-*" \
  \) -delete 2>/dev/null || true

  [[ -d "$out_soong" ]] || return 0
  find "$out_soong" -maxdepth 1 -type f \( \
    -name "${prefix}.ninja" -o \
    -name "${prefix}.ninja.*" -o \
    -name "${prefix}.*.ninja" -o \
    -name "Android-${product}.mk" -o \
    -name "late-${product}.mk" \
  \) -delete 2>/dev/null || true
}

remove_soong_graph_state() {
  remove_generated_ninja_state "$1" "$2"
}

repair_stale_soong_graph_state() {
  local product="$1"
  local out_soong="$workspace/out/soong"
  local prefix="build.${product}"
  local final_ninja="$out_soong/${prefix}.ninja"
  local globs="$final_ninja.globs"
  local globs_time="$final_ninja.globs_time"
  local -a graph_parts=()

  [[ -d "$out_soong" ]] || return 0

  mapfile -t graph_parts < <(
    find "$out_soong" -maxdepth 1 -type f \( \
      -name "${prefix}.ninja" -o \
      -name "${prefix}.ninja.*" -o \
      -name "${prefix}.*.ninja" \
    \) -print 2>/dev/null || true
  )

  if [[ -e "$globs" && ! -e "$globs_time" ]]; then
    remove_soong_graph_state "$product" "missing glob timestamp"
  elif [[ -f "$final_ninja" && -f "$globs_time" && "$globs_time" -nt "$final_ninja" ]]; then
    remove_soong_graph_state "$product" "interrupted graph regeneration"
  elif [[ -f "$final_ninja" && ! -s "$final_ninja" ]]; then
    remove_soong_graph_state "$product" "zero-size generated ninja"
  elif [[ ! -f "$final_ninja" && ${#graph_parts[@]} -gt 0 ]]; then
    remove_soong_graph_state "$product" "incomplete generated ninja"
  fi
}

repair_zero_size_fstab_outputs() {
  local product="$1"
  local product_out="$2"
  [[ -d "$product_out" ]] || return 0

  local -a bad_fstabs=()
  mapfile -t bad_fstabs < <(
    find "$product_out" \
      \( -path '*/vendor_ramdisk/first_stage_ramdisk/system/etc/fstab.cf.*' \
         -o -path '*/VENDOR_BOOT/RAMDISK/first_stage_ramdisk/system/etc/fstab.cf.*' \
      \) \
      -type f \
      -size 0 \
      -print 2>/dev/null || true
  )
  (( ${#bad_fstabs[@]} == 0 )) && return 0

  log "removing ${#bad_fstabs[@]} zero-size vendor-ramdisk fstab output(s)"
  rm -f "${bad_fstabs[@]}"
  rm -f "$product_out/vendor_boot.img"
  rm -f \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip" \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip.list" \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip.list.list"
  rm -rf "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files"
}

remove_stale_launcher3_outputs() {
  local product="$1"
  local product_out="$2"
  [[ -d "$product_out" ]] || return 0

  local -a stale_paths=(
    "$product_out/system_ext/priv-app/Launcher3"
    "$product_out/system_ext/priv-app/Launcher3Go"
    "$product_out/system_ext/priv-app/Launcher3QuickStepGo"
    "$product_out/system_other/system_ext/priv-app/Launcher3"
    "$product_out/system_other/system_ext/priv-app/Launcher3Go"
    "$product_out/system_other/system_ext/priv-app/Launcher3QuickStepGo"
    "$product_out/product/overlay/Launcher3__${product}__auto_generated_rro_product.apk"
    "$product_out/product/overlay/Launcher3Go__${product}__auto_generated_rro_product.apk"
    "$product_out/product/overlay/Launcher3QuickStepGo__${product}__auto_generated_rro_product.apk"
    "$product_out/dexpreopt_config/Launcher3_dexpreopt.config"
    "$product_out/dexpreopt_config/Launcher3Go_dexpreopt.config"
    "$product_out/dexpreopt_config/Launcher3QuickStepGo_dexpreopt.config"
  )
  local -a found=()
  local path

  for path in "${stale_paths[@]}"; do
    [[ -e "$path" ]] && found+=("$path")
  done

  (( ${#found[@]} == 0 )) && return 0

  log "removing stale non-QuickStep Launcher3 output(s)"
  rm -rf "${found[@]}"
  rm -f \
    "$product_out/system_ext.img" \
    "$product_out/super.img" \
    "$product_out/vbmeta.img" \
    "$product_out/vbmeta_system.img" \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip" \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip.list" \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip.list.list" \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files-signed.zip"
  rm -rf "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files"
  rm -rf "$product_out/obj/PACKAGING/signed_images"
}

desktop_launcher_outputs_exclusive() {
  local product_out="$1"
  local target_files_zip="$2"

  [[ -f "$product_out/system_ext/priv-app/Launcher3QuickStep/Launcher3QuickStep.apk" ]] || return 1
  [[ ! -e "$product_out/system_ext/priv-app/Launcher3/Launcher3.apk" ]] || return 1
  [[ ! -e "$product_out/system_ext/priv-app/Launcher3Go/Launcher3Go.apk" ]] || return 1
  [[ ! -e "$product_out/system_ext/priv-app/Launcher3QuickStepGo/Launcher3QuickStepGo.apk" ]] || return 1
  desktop_launcher_target_files_exclusive "$target_files_zip"
}

desktop_android_info_selects_tablet() {
  local android_info="$1"

  [[ -f "$android_info" ]] || return 1
  grep -Eq '^[[:space:]]*config=tablet[[:space:]]*$' "$android_info"
}

validate_fstab_file() {
  local path="$1"

  [[ -s "$path" ]] || die "missing or empty fstab: $path"
  grep -q '/data ext4' "$path" || die "fstab does not mount /data as ext4: $path"
  grep -q 'fileencryption=aes-256-xts:aes-256-hctr2' "$path" || \
    die "fstab does not use HCTR2 filename encryption: $path"
}

validate_cvd_target_fstabs() {
  local product_out="$1"

  validate_fstab_file "$product_out/vendor/etc/fstab.cf.ext4.hctr2"
  validate_fstab_file \
    "$product_out/vendor_ramdisk/first_stage_ramdisk/system/etc/fstab.cf.ext4.hctr2"
}
