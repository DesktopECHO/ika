#!/usr/bin/env bash
# Builds ika_tso.ko (src/lineageos/kernel/ika_tso: the TSO memory model for
# chosen apps on Apple CPUs) for the arm64 4K and 16K GKIs, with the kernel and
# toolchain build_virtio_media_module.sh sets up, and writes
# patches/kernel-prebuilts-virtual-device-arm64-ika-tso.patch, which adds the
# modules to kernel/prebuilts/common-modules/virtual-device/6.12/arm64.
#
# Environment: as build_virtio_media_module.sh (WORKSPACE, WORK_DIR, JOBS).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_virtio_media_module.sh"

build_tso() {
  local variant="$1" module="$work_dir/ika-tso-$1"
  prepare_gki "$variant"
  rm -rf "$module"
  cp -r "$overlay_dir/kernel/ika_tso" "$module"
  "${gki_make[@]}" -s M="$module" modules
  "$gki_clang/llvm-strip" --strip-debug "$module/ika_tso.ko"
  check_crcs "$gki_clang/llvm-objcopy" "$gki_stock" "$module/ika_tso.ko" ||
    die "$variant: symbol CRCs differ from the stock module's: wrong toolchain or config?"
  [[ "$(module_release "$module/ika_tso.ko")" == "$gki_release" ]] || die "$variant: vermagic differs"
  log "$variant: $module/ika_tso.ko"
}

mkdir -p "$work_dir"
build_tso arm64
build_tso arm64-16k
write_binary_patch "$modules_dir/arm64" kernel-prebuilts-virtual-device-arm64-ika-tso.patch \
  "Patch summary: adds ika_tso.ko (src/lineageos/kernel/ika_tso), built for the
same GKIs by src/lineageos/scripts/build_ika_tso_module.sh." \
  "ika_tso.ko=$work_dir/ika-tso-arm64/ika_tso.ko" \
  "16k/ika_tso.ko=$work_dir/ika-tso-arm64-16k/ika_tso.ko"
