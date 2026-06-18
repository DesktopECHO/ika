#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s LINEAGEOS_IMAGE_DIR [LINEAGEOS_IMAGE_DIR...]\n' "$(basename "$0")" >&2
}

log() {
  printf '[lineage-desktop] %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

is_android_sparse_image() {
  local path="$1"
  local magic

  magic="$(od -An -N4 -tx1 "$path" 2>/dev/null | tr -d ' \n')"
  [[ "$magic" == "3aff26ed" ]]
}

thin_provisionable_partition_image() {
  case "$(basename "$1")" in
    super.img|userdata.img|system.img|system_ext.img|product.img|vendor.img|\
    odm.img|odm_dlkm.img|system_dlkm.img|vendor_dlkm.img)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

thin_provision_android_sparse_image() {
  local image="$1"
  local tmp original_size sparse_size

  thin_provisionable_partition_image "$image" || return 0
  [[ -f "$image" && -s "$image" ]] || return 0
  is_android_sparse_image "$image" && return 0

  command -v img2simg >/dev/null 2>&1 || \
    die "img2simg is required to thin-provision $(basename "$image")"

  tmp="${image}.sparse.$$"
  rm -f "$tmp"
  if ! img2simg "$image" "$tmp" >/dev/null; then
    rm -f "$tmp"
    die "img2simg failed for $image"
  fi

  original_size="$(stat -c '%s' "$image" 2>/dev/null || echo 0)"
  sparse_size="$(stat -c '%s' "$tmp" 2>/dev/null || echo 0)"
  if (( sparse_size > 0 && sparse_size < original_size )); then
    chmod --reference="$image" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    touch -r "$image" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$image"
    log "thin-provisioned $(basename "$image"): raw ${original_size} bytes -> Android sparse ${sparse_size} bytes"
  else
    rm -f "$tmp"
  fi
}

enforce_vbmeta_minimum_size() {
  local root="$1"
  local image size

  for image in "$root"/vbmeta*.img; do
    [[ -f "$image" ]] || continue
    size="$(stat -c '%s' "$image" 2>/dev/null || echo 0)"
    if (( size > 0 && size < 65536 )); then
      truncate -s 65536 "$image"
    fi
  done
}

thin_provision_dir() {
  local root="$1"
  local image

  [[ -d "$root" ]] || die "missing image directory: $root"

  for image in \
    "$root"/super.img \
    "$root"/userdata.img \
    "$root"/system.img \
    "$root"/system_ext.img \
    "$root"/product.img \
    "$root"/vendor.img \
    "$root"/odm.img \
    "$root"/odm_dlkm.img \
    "$root"/system_dlkm.img \
    "$root"/vendor_dlkm.img; do
    [[ -f "$image" ]] || continue
    thin_provision_android_sparse_image "$image"
  done

  enforce_vbmeta_minimum_size "$root"
}

if (( $# == 0 )); then
  usage
  exit 2
fi

for root in "$@"; do
  thin_provision_dir "$root"
done
