#!/bin/bash
# Builds Mesa's Dozen Vulkan driver (libvulkan_dzn.so) from the Mesa release
# below, with the patches in series, for Ika on WSL2. Only the driver is
# built: no OpenGL, no window systems, no LLVM. With DirectX-Headers older
# than Mesa wants (Debian 13's), meson fetches the version it pins.
#
# Usage: build-dozen.sh BUILD_DIR DOWNLOAD_DIR INSTALL_DIR
#   BUILD_DIR     gets the patched source and the meson build; the driver and
#                 its ICD manifest are BUILD_DIR/build/src/microsoft/vulkan/
#                 libvulkan_dzn.so and dzn_icd.*.json
#   DOWNLOAD_DIR  keeps the release tarball between builds
#   INSTALL_DIR   where the package installs the driver, for the manifest
set -euo pipefail

MESA_VERSION=26.3.0-rc2
MESA_SHA256=6b9154bc46ec73901555dbcb61600eb69607dc1da718a87e7a1c09a755bb1b6d
MESA_URL="https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$(mkdir -p "$1" && cd "$1" && pwd)"
download_dir="$(mkdir -p "$2" && cd "$2" && pwd)"
install_dir="$3"
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
done < "${here}/series"

meson setup "${src}" "${build_dir}/build" \
  --prefix="$(dirname "${install_dir}")" \
  --libdir="$(basename "${install_dir}")" \
  --buildtype=release \
  -Db_ndebug=true \
  -Dvulkan-drivers=microsoft-experimental \
  -Dgallium-drivers= \
  -Dplatforms= \
  -Dopengl=false \
  -Dgles1=disabled \
  -Dgles2=disabled \
  -Dglx=disabled \
  -Degl=disabled \
  -Dgbm=disabled \
  -Dglvnd=disabled \
  -Dllvm=disabled \
  -Dvalgrind=disabled \
  -Dlibunwind=disabled \
  -Dlmsensors=disabled \
  -Dzstd=disabled \
  -Ddisplay-info=disabled \
  -Dxmlconfig=disabled \
  -Dexpat=disabled \
  -Dvulkan-layers= \
  -Dtools= \
  -Dvideo-codecs= \
  -Dspirv-to-dxil=false \
  -Dmicrosoft-clc=disabled \
  -Dbuild-tests=false \
  -Dperfetto=false
meson compile -C "${build_dir}/build"
