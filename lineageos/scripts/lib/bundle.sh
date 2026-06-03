#!/usr/bin/env bash
# Cuttlefish bundle assembly for the LineageOS Desktop build engine: zip/tar and
# host-package validation, AVB testkey repair, fetcher-config + release-metadata
# emission, and package_cvd_bundle. Source only (defines functions). Relies on
# engine globals + core primitives at call time.

desktop_launcher_target_files_exclusive() {
  local target_files_zip="$1"
  [[ -f "$target_files_zip" && -s "$target_files_zip" ]] || return 1

  python3 - "$target_files_zip" <<'PY'
import sys
import zipfile

target_files = sys.argv[1]
required = "SYSTEM_EXT/priv-app/Launcher3QuickStep/Launcher3QuickStep.apk"
stale_prefixes = (
    "SYSTEM_EXT/priv-app/Launcher3/",
    "SYSTEM_EXT/priv-app/Launcher3Go/",
    "SYSTEM_EXT/priv-app/Launcher3QuickStepGo/",
    "SYSTEM_OTHER/system_ext/priv-app/Launcher3/",
    "SYSTEM_OTHER/system_ext/priv-app/Launcher3Go/",
    "SYSTEM_OTHER/system_ext/priv-app/Launcher3QuickStepGo/",
)
stale_product_overlays = (
    "PRODUCT/overlay/Launcher3__",
    "PRODUCT/overlay/Launcher3Go__",
    "PRODUCT/overlay/Launcher3QuickStepGo__",
)

try:
    with zipfile.ZipFile(target_files) as archive:
        names = set(archive.namelist())
except zipfile.BadZipFile:
    raise SystemExit(1)

if required not in names:
    raise SystemExit(1)

for name in names:
    if any(name.startswith(prefix) for prefix in stale_prefixes):
        raise SystemExit(1)
    if any(name.startswith(prefix) for prefix in stale_product_overlays):
        raise SystemExit(1)
PY
}

valid_targz_archive() {
  local path="$1"
  [[ -f "$path" && -s "$path" ]] || return 1
  tar -tzf "$path" >/dev/null 2>&1
}

critical_host_package_zero_entries() {
  local host_package="$1"

  tar -tzvf "$host_package" 2>/dev/null | awk '
    $1 ~ /^-/ && $3 == 0 {
      name = $6
      sub(/^\.\//, "", name)
      if (name == "bin/crosvm" ||
          name == "bin/extract-ikconfig" ||
          name == "bin/extract-vmlinux") {
        print name
      }
    }
  '
}

cvd_host_package_critical_tools_complete() {
  local host_package="$1"
  [[ -f "$host_package" && -s "$host_package" ]] || return 1

  local bad_entries
  bad_entries="$(critical_host_package_zero_entries "$host_package")" || return 1
  [[ -z "$bad_entries" ]]
}

repair_zero_size_cvd_host_package() {
  local host_package="$1"
  [[ -f "$host_package" ]] || return 0

  local bad_entries
  bad_entries="$(critical_host_package_zero_entries "$host_package")" || return 0
  [[ -n "$bad_entries" ]] || return 0

  log "removing Cuttlefish host package with zero-size critical tool(s): ${bad_entries//$'\n'/, }"
  rm -f "$host_package" "${host_package%.tar.gz}.stamp"
  rm -rf "${host_package%.tar.gz}"
}

valid_pem_private_key() {
  local path="$1"
  [[ -s "$path" ]] && grep -q 'BEGIN RSA PRIVATE KEY' "$path"
}

rom_avb_private_key() {
  local bits="$1"
  local key="$workspace/external/avb/test/data/testkey_rsa${bits}.pem"

  [[ -f "$key" ]] || die "missing ROM AVB test private key: $key"
  valid_pem_private_key "$key" || die "invalid ROM AVB test private key: $key"
  printf '%s\n' "$key"
}

repair_cvd_host_package_avb_keys() {
  local host_package="$1"
  local tmp_dir tmp_package bits src dest repaired=0

  valid_targz_archive "$host_package" || \
    die "invalid Cuttlefish host package: $host_package"

  tmp_dir="$(mktemp -d)"
  if ! tar -xzf "$host_package" -C "$tmp_dir"; then
    rm -rf "$tmp_dir"
    die "failed to extract Cuttlefish host package: $host_package"
  fi

  mkdir -p "$tmp_dir/etc"
  for bits in 2048 4096; do
    src="$(rom_avb_private_key "$bits")"
    dest="$tmp_dir/etc/cvd_avb_testkey_rsa${bits}.pem"
    if valid_pem_private_key "$dest"; then
      continue
    fi
    log "repairing $(basename "$host_package"): etc/cvd_avb_testkey_rsa${bits}.pem"
    install -m 0644 "$src" "$dest"
    repaired=1
  done

  if (( repaired )); then
    tmp_package="${host_package}.tmp"
    if ! tar -czf "$tmp_package" -C "$tmp_dir" .; then
      rm -rf "$tmp_dir"
      rm -f "$tmp_package"
      die "failed to rewrite Cuttlefish host package: $host_package"
    fi
    mv "$tmp_package" "$host_package"
  fi

  for bits in 2048 4096; do
    dest="$tmp_dir/etc/cvd_avb_testkey_rsa${bits}.pem"
    valid_pem_private_key "$dest" || {
      rm -rf "$tmp_dir"
      die "Cuttlefish host package still has an invalid AVB key: $host_package:etc/cvd_avb_testkey_rsa${bits}.pem"
    }
  done
  rm -rf "$tmp_dir"
}

valid_zip_container() {
  local path="$1"
  [[ -f "$path" && -s "$path" ]] || return 1
  python3 - "$path" <<'PY'
from pathlib import Path
import sys
import zipfile

path = Path(sys.argv[1])
try:
    with zipfile.ZipFile(path) as archive:
        if not archive.namelist():
            raise SystemExit(1)
except zipfile.BadZipFile:
    raise SystemExit(1)
PY
}

bundle_dir_complete() {
  local bundle_dir="$1"
  shift

  [[ -d "$bundle_dir" ]] || return 1

  local member
  for member in "build-info.json" "build-info.txt" "$@"; do
    [[ -e "$bundle_dir/$member" ]] || return 1
  done

  desktop_android_info_selects_tablet "$bundle_dir/android-info.txt"
}

built_target_outputs_complete() {
  local product="$1"
  local product_out="$2"
  local host_package="$3"
  shift 3

  [[ -d "$product_out" ]] || return 1
  valid_targz_archive "$host_package" || return 1
  cvd_host_package_critical_tools_complete "$host_package" || return 1

  local target_files="$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip"
  valid_zip_container "$target_files" || return 1
  desktop_launcher_outputs_exclusive "$product_out" "$target_files" || return 1
  desktop_android_info_selects_tablet "$product_out/android-info.txt" || return 1

  local f
  for f in "$@"; do
    [[ -f "$product_out/$f" && -s "$product_out/$f" ]] || return 1
  done
}

remove_packaged_target_outputs() {
  local product="$1"
  local product_out="$2"
  local host_package="$3"
  shift 3

  local target_files_dir="$product_out/obj/PACKAGING/target_files_intermediates"
  rm -f \
    "$host_package" \
    "$target_files_dir/${product}-target_files.zip" \
    "$target_files_dir/${product}-target_files.zip.list" \
    "$target_files_dir/${product}-target_files.zip.list.list" \
    "$target_files_dir/${product}-target_files-signed.zip"
  rm -rf "$target_files_dir/${product}-target_files"
  rm -rf "$product_out/obj/PACKAGING/signed_images"

  local f
  for f in "$@"; do
    rm -f "$product_out/$f"
  done
}

write_fetcher_config() {
  local bundle_dir="$1"
  shift

  local f first=1
  {
    printf '{\n  "cvd_files": {'
    for f in "$@"; do
      [[ -f "$bundle_dir/$f" ]] || continue
      if [[ "$first" -eq 0 ]]; then
        printf ','
      fi
      printf '\n    "%s": { "source": "local_file", "build_id": "", "build_target": "" }' "$f"
      first=0
    done
    printf '\n  }\n}\n'
  } > "$bundle_dir/fetcher_config.json"
}

write_release_metadata() {
  local bundle_dir="$1"
  local arch="$2"
  local product="$3"
  local product_out="$4"
  shift 4

  local metadata_script="$workspace/vendor/lineage_desktop/scripts/write_release_metadata.py"
  [[ -x "$metadata_script" ]] || die "missing release metadata writer: $metadata_script"

  local -a metadata_args=(
    --android-root "$workspace"
    --overlay-dir "$workspace/vendor/lineage_desktop"
    --product-out "$product_out"
    --bundle-dir "$bundle_dir"
    --arch "$arch"
    --product "$product"
    --lineage-branch "$lineage_branch"
  )

  local image
  for image in "$@"; do
    metadata_args+=(--image "$image")
  done

  "$metadata_script" "${metadata_args[@]}"
}

package_cvd_bundle() {
  local arch="$1"
  local product="$2"
  local product_out="$3"
  local host_package="$4"
  local signed_images_dir="$5"
  local bundle_name="$6"
  shift 6

  local bundle_dir="$output_dir/$bundle_name"
  local -a thin_files=("$@")

  [[ -d "$product_out" ]] || die "missing product output: $product_out"
  [[ -f "$host_package" ]] || die "missing Cuttlefish host package: $host_package"

  log "packaging $bundle_name"
  rm -rf "$bundle_dir"
  mkdir -p "$bundle_dir"

  # For each bundle file prefer the release-key-signed image emitted into
  # $signed_images_dir by sign_target_files.sh. Files that aren't shipped
  # inside the target-files.zip IMAGES/ tree (kernel binaries, dtb.img,
  # vendor-bootconfig.img, android-info.txt, misc_info.txt, ...) fall back
  # to the original $product_out path so the bundle still includes them.
  local f src copied=0
  for f in "${thin_files[@]}"; do
    src="$signed_images_dir/$f"
    if [[ "$f" == "super.img" && -f "$signed_images_dir/vbmeta.img" && ! -f "$src" ]]; then
      die "signed vbmeta exists but signed super.img is missing in $signed_images_dir"
    fi
    [[ -f "$src" ]] || src="$product_out/$f"
    if [[ -f "$src" ]]; then
      install -m 0644 "$src" "$bundle_dir/$f"
      copied=$((copied + 1))
    fi
  done

  (( copied > 0 )) || die "no image files were copied from $product_out"
  desktop_android_info_selects_tablet "$bundle_dir/android-info.txt" || \
    die "$bundle_name/android-info.txt does not select config=tablet"

  tar -xzf "$host_package" -C "$bundle_dir" --exclude='bin' --exclude='lib64'

  # assemble_cvd requires every etc/cvd_config/*.json preset it might select
  # (via --config=... or via android-info.txt) to be a JSON object; it aborts
  # on the first preset that is empty, unparseable, or non-object. Upstream's
  # cvd-host_package.tar.gz ships several of these as zero-byte stubs.
  # Normalize anything that is not a valid object to {} so the launcher
  # treats it as "no overrides", and log each replacement so future bundle
  # issues surface in the build log instead of going silently.
  if [[ -d "$bundle_dir/etc/cvd_config" ]]; then
    local normalize_status=0
    STRICT_BUNDLE_VALIDATION="$strict_bundle_validation" \
      python3 - "$bundle_dir/etc/cvd_config" <<'PY' || normalize_status=$?
import json, os, pathlib, sys
cfg_dir = pathlib.Path(sys.argv[1])
strict = os.environ.get("STRICT_BUNDLE_VALIDATION", "0") == "1"
rewritten = []
for p in sorted(cfg_dir.glob("*.json")):
    try:
        ok = isinstance(json.loads(p.read_text(encoding="utf-8")), dict)
    except (json.JSONDecodeError, OSError, UnicodeDecodeError):
        ok = False
    if ok:
        continue
    p.write_text("{}\n", encoding="utf-8")
    rewritten.append(p.name)
    print(f"[lineage-desktop] normalized cvd_config preset to {{}}: {p.name}",
          file=sys.stderr)
if rewritten and strict:
    print(
        "[lineage-desktop] STRICT_BUNDLE_VALIDATION=1: refusing to ship a bundle "
        f"with {len(rewritten)} corrupt cvd_config preset(s): "
        + ", ".join(rewritten),
        file=sys.stderr,
    )
    sys.exit(1)
PY
    if (( normalize_status != 0 )); then
      die "etc/cvd_config normalization failed in strict mode for $bundle_name"
    fi
  fi
  write_fetcher_config "$bundle_dir" "${thin_files[@]}"
  write_release_metadata "$bundle_dir" "$arch" "$product" "$product_out" "${thin_files[@]}"

  du -sh "$bundle_dir"
}

