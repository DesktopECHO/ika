#!/usr/bin/env bash

set -e

# Shared distro detection + sudo-escalation helpers. Kept in lib/common.sh so
# build_package.sh reuses the exact same implementations.
_buildutils_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_buildutils_dir}/lib/common.sh"

# Accept both the distro-agnostic name and the legacy RPM-specific name.
readonly SKIP_BUILD_DEPENDENCIES="${SKIP_BUILD_DEPENDENCIES:-${SKIP_RPM_BUILD_DEPENDENCIES:-false}}"

function install_rpm_build_dependencies() {
  echo "Installing RPM build dependencies"
  run_as_root dnf -y upgrade --refresh

  # Core RPM build tooling
  run_as_root dnf -y install \
    rpm-build \
    rpmdevtools \
    systemd-rpm-macros

  # cuttlefish-base BuildRequires (Bazel C++ build)
  run_as_root dnf -y install \
    libaom-devel \
    libavdevice-free-devel \
    libswscale-free-devel \
    clang-devel \
    cmake \
    fmt-devel \
    gcc-c++ \
    gflags-devel \
    git \
    glog-devel \
    gtest-devel \
    jsoncpp-devel \
    libX11-devel \
    libXext-devel \
    libcurl-devel \
    libcap-devel \
    libdrm-devel \
    libxcrypt-compat \
    libuuid-devel \
    libxml2-devel \
    libsrtp-devel \
    opus-devel \
    openssl-devel \
    perl-FindBin \
    pkgconf-pkg-config \
    protobuf-c-devel \
    protobuf-compiler \
    protobuf-devel \
    python3 \
    mesa-libgbm-devel \
    virglrenderer-devel \
    wayland-devel \
    which \
    xxd \
    xz-devel \
    z3-devel

  # cuttlefish-frontend BuildRequires (Go + Node.js)
  run_as_root dnf -y install \
    curl \
    golang \
    npm

  # cuttlefish-scrcpy BuildRequires (Meson C build)
  run_as_root dnf -y install \
    meson \
    ninja-build \
    java-25-openjdk-devel \
    SDL3-devel \
    libavcodec-free-devel \
    libavformat-free-devel \
    libavutil-free-devel \
    libswresample-free-devel \
    libusb1-devel \
    vulkan-headers \
    libicu-devel

  # Runtime tools needed during rpmbuild
  run_as_root dnf -y install \
    rsync \
    pigz
}

function install_deb_build_dependencies() {
  local codename
  codename=$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")

  if [[ "${codename}" == "trixie" ]]; then
    if ! grep -qrE "^[^#]*trixie-backports" \
         /etc/apt/sources.list \
         /etc/apt/sources.list.d/ 2>/dev/null; then
      echo "Debian 13 (trixie) requires the trixie-backports repository, which is not configured."
      printf "Add it now? [Y/n] "
      read -r _reply
      case "${_reply}" in
        [nN]*)
          >&2 echo "Aborted. Add the repository manually and re-run."
          exit 1
          ;;
      esac
      run_as_root tee /etc/apt/sources.list.d/trixie-backports.list \
        <<<"deb http://deb.debian.org/debian trixie-backports main contrib non-free" >/dev/null
      run_as_root apt-get update -qq
    fi
  fi

  echo "Installing Debian build dependencies"
  run_as_root apt-get update -qq

  # Core deb build tooling
  run_as_root apt-get install -y --no-install-recommends \
    config-package-dev \
    debhelper \
    dh-exec \
    dpkg-dev

  # cuttlefish-base Build-Depends (Bazel C++ build)
  run_as_root apt-get install -y --no-install-recommends \
    cmake \
    git \
    libaom-dev \
    libavdevice-dev \
    libclang-dev \
    libcurl4-openssl-dev \
    libfmt-dev \
    libgflags-dev \
    libgoogle-glog-dev \
    libgtest-dev \
    libjsoncpp-dev \
    liblzma-dev \
    libopus-dev \
    libprotobuf-c-dev \
    libprotobuf-dev \
    libsrtp2-dev \
    libssl-dev \
    libswscale-dev \
    libvirglrenderer-dev \
    libxml2-dev \
    libz3-dev \
    libicu-dev \
    libvulkan-dev \
    libgl-dev \
    libgles-dev \
    libegl-dev \
    libcap-dev \
    libdrm-dev \
    libgbm-dev \
    libwayland-dev \
    libva-dev \
    libzstd-dev \
    pkgconf \
    protobuf-compiler \
    uuid-dev \
    xxd

  # cuttlefish-frontend Build-Depends (Go + Node.js)
  run_as_root apt-get install -y --no-install-recommends \
    curl \
    golang-go \
    npm

  # ika-scrcpy Build-Depends (Meson C build + scrcpy-server Java build)
  run_as_root apt-get install -y --no-install-recommends \
    default-jdk \
    meson \
    ninja-build \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswresample-dev \
    libsdl3-dev \
    libusb-1.0-0-dev

  # Debian 13: upgrade Mesa/Vulkan stack from backports — base repo has
  # vulkan_raii.hpp v1.4.309 which is ABI-incompatible with the v1.4.338
  # headers the Bazel build fetches from KhronosGroup/Vulkan-Headers.
  if [[ "${codename}" == "trixie" ]]; then
    echo "Upgrading Mesa/Vulkan stack from trixie-backports..."
    run_as_root apt-get install -t trixie-backports -y --no-install-recommends \
      libegl1 \
      libegl-mesa0 \
      libgl1-mesa-dri \
      libgles2 \
      libglx-mesa0 \
      libvulkan1 \
      libvulkan-dev \
      mesa-common-dev \
      mesa-vulkan-drivers \
      mesa-drm-shim \
      mesa-utils-bin      
  fi
}

function install_build_dependencies() {
  if [[ "${SKIP_BUILD_DEPENDENCIES}" == "true" ]]; then
    echo "Skipping build dependency installation (SKIP_BUILD_DEPENDENCIES=true)"
    return
  fi

  if ! can_run_as_root; then
    >&2 echo "Cannot install build dependencies without root privileges."
    >&2 echo "Run in an interactive terminal with sudo access, or set SKIP_BUILD_DEPENDENCIES=true if dependencies are already installed."
    exit 1
  fi

  case "${DISTRO_FAMILY}" in
    rpm)    install_rpm_build_dependencies ;;
    debian) install_deb_build_dependencies ;;
  esac
}

REPO_DIR="$(realpath "$(dirname "$0")/../..")"
INSTALL_BAZEL="$(dirname "$0")/installbazel.sh"
BUILD_PACKAGE="$(dirname "$0")/build_package.sh"
BUILD_SCRCPY_SERVER="$(dirname "$0")/build_scrcpy_server.sh"

# Primary ika packages kept at the top level of the output tree; everything
# else a spec emits (debug, devel, sub-packages, the cuttlefish-* shims) is
# moved into an extras/ subdirectory.
readonly PRIMARY_PACKAGES=(ika-base ika-lineageos ika-scrcpy)

function is_primary_package() {
  local candidate="$1"
  local name
  for name in "${PRIMARY_PACKAGES[@]}"; do
    [[ "${candidate}" == "${name}" ]] && return 0
  done
  return 1
}

# Move every package in $1 that is not a primary ika package into $1/extras/.
# $2 is the file-extension glob (rpm|deb); $3 is the name of a function that
# prints a package file's name given its path.
function organize_package_dir() {
  local pkg_dir="$1"
  local suffix="$2"
  local name_fn="$3"
  local extras_dir="${pkg_dir}/extras"
  local pkg_path

  shopt -s nullglob
  mkdir -p "${extras_dir}"
  for pkg_path in "${pkg_dir}"/*."${suffix}"; do
    if ! is_primary_package "$("${name_fn}" "${pkg_path}")"; then
      mv -f -- "${pkg_path}" "${extras_dir}/"
    fi
  done
}

function organize_deb_sidecars() {
  local pkg_dir="$1"
  local extras_dir="${pkg_dir}/extras"
  local sidecar_path
  local source_name

  shopt -s nullglob
  mkdir -p "${extras_dir}"
  for sidecar_path in "${pkg_dir}"/*.buildinfo "${pkg_dir}"/*.changes; do
    [[ -f "${sidecar_path}" ]] || continue
    source_name="$(basename "${sidecar_path}")"
    source_name="${source_name%%_*}"
    if ! is_primary_package "${source_name}"; then
      mv -f -- "${sidecar_path}" "${extras_dir}/"
    fi
  done
}

function rpm_package_name() {
  rpm -qp --queryformat '%{NAME}' "$1" 2>/dev/null
}

function organize_rpms() {
  local rpms_root="${REPO_DIR}/rpmbuild/RPMS"
  local arch_dir

  shopt -s nullglob
  for arch_dir in "${rpms_root}"/*; do
    [[ -d "${arch_dir}" ]] || continue
    organize_package_dir "${arch_dir}" rpm rpm_package_name
  done
}

function deb_package_name() {
  dpkg-deb --field "$1" Package 2>/dev/null
}

function organize_debs() {
  organize_package_dir "${REPO_DIR}/deb" deb deb_package_name
  organize_deb_sidecars "${REPO_DIR}/deb"
}

readonly DISTRO_FAMILY="$(detect_distro_family)"

refuse_root_build
init_root_cmd
trap drop_root_cmd EXIT
install_build_dependencies
if ! command -v bazel >/dev/null 2>&1; then
  if ! can_run_as_root; then
    >&2 echo "Bazel is not installed and cannot be installed without root privileges."
    >&2 echo "Install bazel manually or run this script with sudo access."
    exit 1
  fi
  run_as_root "${INSTALL_BAZEL}"
fi
drop_root_cmd

# Builds all packages under base/ and frontend/ for the detected distro.
"${BUILD_PACKAGE}" "$@" "${REPO_DIR}/base"
"${BUILD_PACKAGE}" "$@" "${REPO_DIR}/frontend"

# Build ika-scrcpy on Debian. Build the server APK first if not already present.
# On RPM this is handled automatically via base/rpm/cuttlefish-scrcpy.spec.
if [[ "${DISTRO_FAMILY}" == "debian" ]]; then
  if [[ ! -f "${REPO_DIR}/scrcpy/scrcpy-server" ]]; then
    if [[ -x "${BUILD_SCRCPY_SERVER}" ]]; then
      echo "Building scrcpy-server..."
      BUILD_DIR="${REPO_DIR}/deb/debbuild/build-scrcpy-server" \
      ANDROID_CACHE_DIR="${REPO_DIR}/deb/debbuild/android-sdk-cache" \
        "${BUILD_SCRCPY_SERVER}"
      cp "${REPO_DIR}/deb/debbuild/build-scrcpy-server/scrcpy-server" \
         "${REPO_DIR}/scrcpy/scrcpy-server"
    else
      >&2 echo "Warning: scrcpy/scrcpy-server missing and ${BUILD_SCRCPY_SERVER} not found; skipping ika-scrcpy"
    fi
  fi
  if [[ -f "${REPO_DIR}/scrcpy/scrcpy-server" ]]; then
    echo "Building ika-scrcpy..."
    "${BUILD_PACKAGE}" "$@" "${REPO_DIR}/tools/scrcpy"
  fi
fi

# Build ika-lineageos on Debian if the prebuilt bundle exists.
# On RPM this is handled automatically: build_package.sh iterates all *.spec
# files in base/rpm/, including cuttlefish-lineageos.spec.
if [[ "${DISTRO_FAMILY}" == "debian" ]]; then
  case "$(uname -m)" in
    x86_64)  _lineageos_arch="x86_64" ;;
    aarch64) _lineageos_arch="arm64" ;;
    *)       _lineageos_arch="" ;;
  esac
  if [[ -n "${_lineageos_arch}" && -d "${REPO_DIR}/lineageos-${_lineageos_arch}" ]]; then
    echo "Building ika-lineageos for ${_lineageos_arch}..."
    "${BUILD_PACKAGE}" "$@" "${REPO_DIR}/tools/lineageos"
  else
    echo "Skipping ika-lineageos: lineageos-${_lineageos_arch:-?} not found"
  fi
fi

case "${DISTRO_FAMILY}" in
  rpm)    organize_rpms ;;
  debian) organize_debs ;;
esac
