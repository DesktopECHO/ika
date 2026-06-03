#!/usr/bin/env bash
# Shared per-target (arch) lookups for the LineageOS Desktop build engine and
# the standalone rebuild helpers. Source this; it only defines functions.
#
# Everything here is keyed on the intended deployment bundle / TARGET arch, not
# the build host. The host/target support matrix itself (x86_64 hosts build
# x86_64 + arm64; arm64 hosts build arm64 only) lives in the engine's
# normalize_targets() + main() guard.

# Fallback die so this library is usable when sourced by a script that does not
# define one. The build engine defines its own die() before sourcing, which wins.
if ! declare -F die >/dev/null 2>&1; then
  die() {
    printf '[lineage-desktop] error: %s\n' "$*" >&2
    exit 1
  }
fi

# Cuttlefish host package tuple, keyed on the TARGET arch -- NOT the build host.
# arm64 ships the musl host package (there is no arm64 Rust musl prebuilt, so
# that tree carries the glibc-payload arm64 toolchain); x86_64 ships the glibc
# host package. Host-independent: an arm64 ROM cross-built on x86_64 still
# packages linux_musl-arm64. Keying this on the build host silently packages the
# wrong Cuttlefish host tools into the release bundle, so keep it target-keyed.
target_host_tag() {
  case "$1" in
    arm64) printf '%s\n' linux_musl-arm64 ;;
    x86_64) printf '%s\n' linux-x86 ;;
    *) die "internal error: unsupported target $1" ;;
  esac
}

target_product() {
  case "$1" in
    arm64) printf '%s\n' lineage_desktop_cf_arm64_pgagnostic ;;
    x86_64) printf '%s\n' lineage_desktop_cf_x86_64 ;;
    *) die "internal error: unsupported target $1" ;;
  esac
}

# Requires $workspace to be set by the caller (the build engine).
target_product_out() {
  case "$1" in
    arm64) printf '%s\n' "$workspace/out/target/product/vsoc_arm64_pgagnostic" ;;
    x86_64) printf '%s\n' "$workspace/out/target/product/vsoc_x86_64_sandybridge" ;;
    *) die "internal error: unsupported target $1" ;;
  esac
}

target_bundle_name() {
  case "$1" in
    arm64) printf '%s\n' lineageos-arm64 ;;
    x86_64) printf '%s\n' lineageos-x86_64 ;;
    *) die "internal error: unsupported target $1" ;;
  esac
}

# Image/metadata files packaged into the Cuttlefish bundle for a target. arm64
# carries the 16 KB-page kernel/ramdisk/dtb variants; x86_64 carries the 4 KB
# defaults.
target_thin_files() {
  case "$1" in
    arm64)
      printf '%s\n' \
        android-info.txt \
        misc_info.txt \
        super.img \
        boot.img \
        boot_16k.img \
        init_boot.img \
        vendor_boot.img \
        vbmeta.img \
        vbmeta_system.img \
        vbmeta_vendor_dlkm.img \
        vbmeta_system_dlkm.img \
        userdata.img \
        kernel_16k \
        ramdisk_16k.img \
        dtb.img \
        vendor-bootconfig.img
      ;;
    x86_64)
      printf '%s\n' \
        android-info.txt \
        misc_info.txt \
        super.img \
        boot.img \
        init_boot.img \
        vendor_boot.img \
        vbmeta.img \
        vbmeta_system.img \
        vbmeta_vendor_dlkm.img \
        vbmeta_system_dlkm.img \
        userdata.img \
        kernel \
        ramdisk.img \
        vendor-bootconfig.img
      ;;
    *)
      die "internal error: unsupported target $1"
      ;;
  esac
}
