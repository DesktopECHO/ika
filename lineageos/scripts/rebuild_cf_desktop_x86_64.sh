#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$script_dir/../src/build/envsetup.sh" ]]; then
  repo_root="$(cd "$script_dir/../src" && pwd)"
elif [[ -f "$script_dir/../../../build/envsetup.sh" ]]; then
  repo_root="$(cd "$script_dir/../../.." && pwd)"
else
  printf '[lineage-desktop] error: missing Android source tree; expected %s or an in-tree vendor/lineage_desktop checkout\n' \
    "$script_dir/../src" >&2
  exit 1
fi
source "$script_dir/build_jobs.sh"
source "$script_dir/signing_common.sh"
ensure_signing_keys

# --- Arch-specific configuration ------------------------------------------
arch="x86_64"
product="lineage_desktop_cf_x86_64"
product_out_subdir="vsoc_x86_64_sandybridge"
host_out_subdir="linux-x86"

bundle_files=(
  android-info.txt
  boot.img
  init_boot.img
  kernel
  ramdisk.img
  super.img
  userdata.img
  vbmeta.img
  vbmeta_system.img
  vbmeta_system_dlkm.img
  vbmeta_vendor_dlkm.img
  vendor-bootconfig.img
  vendor_boot.img
)

thin_files=(
  android-info.txt
  misc_info.txt
  super.img
  boot.img
  init_boot.img
  vendor_boot.img
  vbmeta.img
  vbmeta_system.img
  vbmeta_vendor_dlkm.img
  vbmeta_system_dlkm.img
  userdata.img
  kernel
  ramdisk.img
  vendor-bootconfig.img
)
# --- End arch-specific configuration --------------------------------------

# Output staging directory. Defaults to a per-user temp under the workspace so
# the script works without /home/zero hardcoding; override with OUTPUT_DIR.
output_dir="${OUTPUT_DIR:-$repo_root/out/lineage_desktop_bundles}"
bundle_dir="$output_dir/cvd-desktop-$arch"
thin_dir="$output_dir/cvd-desktop-$arch-slim"
product_out="$repo_root/out/target/product/$product_out_subdir"
host_package="$repo_root/out/host/$host_out_subdir/cvd-host_package.tar.gz"

mkdir -p "$output_dir"
cd "$repo_root"

repair_soong_zero_byte_objects() {
  local intermediates="$repo_root/out/soong/.intermediates"
  [[ -d "$intermediates" ]] || return 0

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
    rm -rf "$dir"
  done
}

repair_soong_zero_byte_objects

# x86 ARM native bridge: enabled by default; opt out with
# INCLUDE_X86_ARM_NATIVE_BRIDGE=0 to disable arm64 binary translation.
if [[ "${INCLUDE_X86_ARM_NATIVE_BRIDGE:-1}" == "1" ]]; then
  vendor/lineage_desktop/scripts/update_native_bridge_prebuilts.py "$repo_root"
  export LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE=true
  export USE_NDK_TRANSLATION_BINARY=true
else
  export LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE=false
  unset USE_NDK_TRANSLATION_BINARY || true
fi

vendor/lineage_desktop/scripts/sync_webview_lfs_prebuilts.sh "$repo_root" "$arch"
vendor/lineage_desktop/scripts/validate_build_inputs.sh "$repo_root" "$arch"

set +u
source build/envsetup.sh
lunch "$product" trunk_staging userdebug
set -eo pipefail
set -u

set_build_jobs
printf '[lineage-desktop] using %s parallel build jobs (%s high-memory jobs)\n' \
  "$jobs" "$highmem_jobs"

m hosttar \
  bootimage \
  vendorbootimage \
  initbootimage \
  systemimage \
  systemextimage \
  productimage \
  vendorimage \
  userdataimage \
  superimage \
  vbmetaimage \
  vbmetasystemimage \
  target-files-package \
  otatools \
  -j"$jobs"

target_files_zip="$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip"
signed_target_files_zip="${target_files_zip%.zip}-signed.zip"
signed_images_dir="$product_out/obj/PACKAGING/signed_images"

"$script_dir/sign_target_files.sh" \
  "$target_files_zip" \
  "$signed_target_files_zip" \
  "$signed_images_dir"

# image_src: signed image (from signed_images_dir) takes precedence over the
# test-key one in $product_out. Files only emitted by `m bootimage` etc. and
# not present in IMAGES/ (kernel binaries, dtb, etc.) fall back to product_out.
image_src() {
  local name="$1"
  if [[ -f "$signed_images_dir/$name" ]]; then
    printf '%s\n' "$signed_images_dir/$name"
  else
    printf '%s\n' "$product_out/$name"
  fi
}

rm -rf "$bundle_dir"
mkdir -p "$bundle_dir"

for f in "${bundle_files[@]}"; do
  src="$(image_src "$f")"
  [[ -f "$src" ]] && install -m 0644 "$src" "$bundle_dir/$f"
done

install -m 0644 "$host_package" "$bundle_dir/cvd-host_package.tar.gz"
tar -xzf "$host_package" -C "$bundle_dir" --exclude='bin' --exclude='lib64'

rm -rf "$thin_dir"
mkdir -p "$thin_dir"

for f in "${thin_files[@]}"; do
  src="$(image_src "$f")"
  [[ -f "$src" ]] && install -m 0644 "$src" "$thin_dir/$f"
done

tar -xzf "$host_package" -C "$thin_dir" --exclude='bin' --exclude='lib64'

entries=""
first=1
for f in "${thin_files[@]}"; do
  [[ -f "$thin_dir/$f" ]] || continue
  [[ "$first" -eq 0 ]] && entries="$entries,"
  entries="$entries
    \"$f\": { \"source\": \"local_file\", \"build_id\": \"\", \"build_target\": \"\" }"
  first=0
done
cat > "$thin_dir/fetcher_config.json" <<EOF
{
  "cvd_files": {${entries}
  }
}
EOF

metadata_args=(
  --android-root "$repo_root"
  --overlay-dir "$repo_root/vendor/lineage_desktop"
  --product-out "$product_out"
  --bundle-dir "$thin_dir"
  --arch "$arch"
  --product "$product"
  --lineage-branch "${LINEAGE_BRANCH:-lineage-23.2}"
)
for f in "${thin_files[@]}"; do
  metadata_args+=(--image "$f")
done
vendor/lineage_desktop/scripts/write_release_metadata.py "${metadata_args[@]}"

du -sh "$thin_dir"
