#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Output staging directory. Defaults to a per-user temp under the workspace so
# the script works without /home/zero hardcoding; override with OUTPUT_DIR.
output_dir="${OUTPUT_DIR:-$repo_root/out/lineage_desktop_bundles}"
bundle_dir="$output_dir/cvd-desktop-arm64"
thin_dir="$output_dir/cvd-desktop-arm64-slim"
thin_tar="$output_dir/lineageos-desktop-arm64.tar"
product_out="$repo_root/out/target/product/vsoc_arm64_pgagnostic"
host_package="$repo_root/out/host/linux_musl-arm64/cvd-host_package.tar.gz"

mkdir -p "$output_dir"
cd "$repo_root"

# Clear x86_64-only env that may leak in from a previous rebuild_cf_desktop_x86_64.sh
# run in the same shell, otherwise lunch picks up a confused configuration.
unset LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE || true
unset USE_NDK_TRANSLATION_BINARY || true

vendor/lineage_desktop/scripts/validate_build_inputs.sh "$repo_root" arm64

set +u
source build/envsetup.sh
lunch lineage_desktop_cf_arm64_pgagnostic trunk_staging userdebug
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

mkdir -p "$bundle_dir"

for f in \
  android-info.txt \
  boot.img \
  boot_16k.img \
  dtb.img \
  init_boot.img \
  kernel \
  kernel_16k \
  ramdisk.img \
  ramdisk_16k.img \
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
  boot_16k.img
  init_boot.img
  vendor_boot.img
  vbmeta.img
  vbmeta_system.img
  vbmeta_vendor_dlkm.img
  vbmeta_system_dlkm.img
  userdata.img
  kernel_16k
  ramdisk_16k.img
  dtb.img
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
  --arch arm64
  --product lineage_desktop_cf_arm64_pgagnostic
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
