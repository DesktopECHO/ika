#!/bin/bash
# Builds Mesa's D3D12 OpenGL driver, with EGL for libglvnd (libEGL_mesa.so.0
# and libgallium), from the Mesa release build-dozen.sh builds Dozen from,
# with the patches in series-gl, for the console and app windows on WSL2.
# Debian 13's Mesa stages every texture upload in write-combined memory, which
# WSL2 maps uncached: a 1080p frame took scrcpy 25 ms to upload (see
# d3d12-uma-cached-upload.patch). Only the d3d12 Gallium driver is built: no
# LLVM, no Vulkan, no GLX, and of the window systems Wayland and X11.
#
# Usage: build-d3d12-gl.sh BUILD_DIR DOWNLOAD_DIR
#   BUILD_DIR     gets the patched source and the meson build; the libraries
#                 are BUILD_DIR/build/src/egl/libEGL_mesa.so.0 and
#                 BUILD_DIR/build/src/gallium/targets/dri/libgallium-*.so,
#                 libEGL_mesa finding libgallium beside itself ($ORIGIN)
#   DOWNLOAD_DIR  keeps the release tarball between builds
set -euo pipefail

MESA_VERSION=26.3.0-rc2
MESA_SHA256=6b9154bc46ec73901555dbcb61600eb69607dc1da718a87e7a1c09a755bb1b6d
MESA_URL="https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$(mkdir -p "$1" && cd "$1" && pwd)"
download_dir="$(mkdir -p "$2" && cd "$2" && pwd)"
tarball="${download_dir}/mesa-${MESA_VERSION}.tar.xz"

if ! echo "${MESA_SHA256}  ${tarball}" | sha256sum --check --status 2>/dev/null; then
  wget --tries=3 -O "${tarball}.part" "${MESA_URL}"
  echo "${MESA_SHA256}  ${tarball}.part" | sha256sum --check --quiet
  mv "${tarball}.part" "${tarball}"
fi

src="${build_dir}/mesa-${MESA_VERSION}"
rm -rf "${src}" "${build_dir}/build"
tar -xf "${tarball}" -C "${build_dir}"
while read -r patch; do
  [[ -n "${patch}" && "${patch}" != \#* ]] || continue
  patch -d "${src}" -p1 --forward --quiet < "${here}/${patch}"
done < "${here}/series-gl"

meson setup "${src}" "${build_dir}/build" \
  --buildtype=release \
  -Db_ndebug=true \
  '-Dc_link_args=-Wl,-rpath,$ORIGIN' \
  '-Dcpp_link_args=-Wl,-rpath,$ORIGIN' \
  -Dgallium-drivers=d3d12 \
  -Dvulkan-drivers= \
  -Dplatforms=wayland,x11 \
  -Dopengl=true \
  -Dgles1=disabled \
  -Dgles2=enabled \
  -Dglx=disabled \
  -Degl=enabled \
  -Dgbm=enabled \
  -Dglvnd=enabled \
  -Dllvm=disabled \
  -Dvalgrind=disabled \
  -Dlibunwind=disabled \
  -Dlmsensors=disabled \
  -Dxmlconfig=disabled \
  -Dtools= \
  -Dvideo-codecs= \
  -Dgallium-va=disabled \
  -Dspirv-to-dxil=false \
  -Dmicrosoft-clc=disabled \
  -Dbuild-tests=false \
  -Dperfetto=false
meson compile -C "${build_dir}/build"
