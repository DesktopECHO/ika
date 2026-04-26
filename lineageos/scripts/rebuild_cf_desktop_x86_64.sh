#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
output_dir="${OUTPUT_DIR:-$repo_root/out/lineage_desktop_bundles}"
bundle_dir="$output_dir/cvd-desktop-x86_64"
thin_dir="$output_dir/cvd-desktop-x86_64-slim"
thin_tar="$output_dir/lineageos-desktop-x86_64.tar"
product_out="$repo_root/out/target/product/vsoc_x86_64_sandybridge"
host_package="$repo_root/out/host/linux-x86/cvd-host_package.tar.gz"

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

if [[ "${INCLUDE_X86_ARM_NATIVE_BRIDGE:-1}" == "1" ]]; then
  vendor/lineage_desktop/scripts/update_native_bridge_prebuilts.py "$repo_root"
  export LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE=true
  export USE_NDK_TRANSLATION_BINARY=true
else
  export LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE=false
  unset USE_NDK_TRANSLATION_BINARY || true
fi

vendor/lineage_desktop/scripts/validate_build_inputs.sh "$repo_root" x86_64

set +u
source build/envsetup.sh
lunch lineage_desktop_cf_x86_64 trunk_staging userdebug
set -eo pipefail
set -u

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
  -j"$(nproc)"

rm -rf "$bundle_dir"
mkdir -p "$bundle_dir"

for f in \
  android-info.txt \
  boot.img \
  init_boot.img \
  kernel \
  ramdisk.img \
  super.img \
  userdata.img \
  vbmeta.img \
  vbmeta_system.img \
  vbmeta_system_dlkm.img \
  vbmeta_vendor_dlkm.img \
  vendor-bootconfig.img \
  vendor_boot.img
do
  [[ -f "$product_out/$f" ]] && install -m 0644 "$product_out/$f" "$bundle_dir/$f"
done

install -m 0644 "$host_package" "$bundle_dir/cvd-host_package.tar.gz"
tar -xzf "$host_package" -C "$bundle_dir" --exclude='bin' --exclude='lib64'

rm -rf "$thin_dir"
mkdir -p "$thin_dir"

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

for f in "${thin_files[@]}"; do
  [[ -f "$product_out/$f" ]] && install -m 0644 "$product_out/$f" "$thin_dir/$f"
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
  --arch x86_64
  --product lineage_desktop_cf_x86_64
  --tar-name "$(basename "$thin_tar")"
  --lineage-branch "${LINEAGE_BRANCH:-lineage-23.2}"
)
for f in "${thin_files[@]}"; do
  metadata_args+=(--image "$f")
done
vendor/lineage_desktop/scripts/write_release_metadata.py "${metadata_args[@]}"

rm -f "$thin_tar"
source_date_epoch="${SOURCE_DATE_EPOCH:-$(git -C "$repo_root/vendor/lineage_desktop" log -1 --format=%ct HEAD 2>/dev/null || date -u +%s)}"
tar -C "$output_dir" \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --mtime="@${source_date_epoch}" \
    -cf "$thin_tar" "$(basename "$thin_dir")"
ls -lh "$thin_tar"
