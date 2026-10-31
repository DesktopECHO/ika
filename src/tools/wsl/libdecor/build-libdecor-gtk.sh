#!/bin/bash
# Builds libdecor's GTK plugin (libdecor-gtk.so), which draws the title bar and
# shadow of Ika's windows, from the libdecor release below with the patches in
# series, for Ika on WSLg. Its plugin interface is the same from libdecor
# 0.2.2 (Debian 13) to 0.2.5, so it loads into the system's libdecor.
#
# Usage: build-libdecor-gtk.sh BUILD_DIR DOWNLOAD_DIR
#   BUILD_DIR     gets the patched source and the meson build; the plugin is
#                 BUILD_DIR/build/src/plugins/gtk/libdecor-gtk.so
#   DOWNLOAD_DIR  keeps the release tarball between builds
set -euo pipefail

LIBDECOR_VERSION=0.2.5
LIBDECOR_SHA256=7fd50f780a4fee90a03f7b2c09055033e488654cbaff4a0c4bbae616bac9cd1c
LIBDECOR_URL="https://gitlab.freedesktop.org/-/project/18349/uploads/eaf9a38b227a6e4997b5cb8fc3b8c830/libdecor-${LIBDECOR_VERSION}.tar.xz"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$(mkdir -p "$1" && cd "$1" && pwd)"
download_dir="$(mkdir -p "$2" && cd "$2" && pwd)"
tarball="${download_dir}/libdecor-${LIBDECOR_VERSION}.tar.xz"

if ! echo "${LIBDECOR_SHA256}  ${tarball}" | sha256sum --check --status 2>/dev/null; then
  wget --tries=3 -O "${tarball}.part" "${LIBDECOR_URL}"
  echo "${LIBDECOR_SHA256}  ${tarball}.part" | sha256sum --check --quiet
  mv "${tarball}.part" "${tarball}"
fi

src="${build_dir}/libdecor-${LIBDECOR_VERSION}"
rm -rf "${src}" "${build_dir}/build"
tar -xf "${tarball}" -C "${build_dir}"
while read -r patch; do
  [[ -n "${patch}" && "${patch}" != \#* ]] || continue
  patch -d "${src}" -p1 --forward --quiet < "${here}/${patch}"
done < "${here}/series"

meson setup "${src}" "${build_dir}/build" \
  --buildtype=release \
  -Db_ndebug=true \
  -Dgtk=enabled \
  -Ddbus=enabled \
  -Ddemo=false \
  -Dinstall_demo=false
meson compile -C "${build_dir}/build" decor-gtk
