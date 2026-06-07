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

# Cuttlefish host package tuple. x86_64 targets package the local linux-x86
# host tools. arm64 targets package ARM64 host tools, but the output tag differs
# by build host: native ARM64 builds emit linux-arm64, while x86_64 hosts
# cross-building the ARM64 bundle emit linux_musl-arm64.
target_host_tag() {
  case "$1" in
    arm64)
      case "$(uname -m)" in
        aarch64|arm64) printf '%s\n' linux-arm64 ;;
        *) printf '%s\n' linux_musl-arm64 ;;
      esac
      ;;
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
