#!/usr/bin/env bash

set -e -x

readonly SKIP_RPM_BUILD_DEPENDENCIES="${SKIP_RPM_BUILD_DEPENDENCIES:-false}"
readonly ALLOW_ROOT_RPM_BUILD="${ALLOW_ROOT_RPM_BUILD:-false}"
declare -a ROOT_CMD=()

function refuse_root_rpm_build() {
  if [[ "$(id -u)" -ne 0 || "${ALLOW_ROOT_RPM_BUILD}" == "true" ]]; then
    return
  fi

  >&2 echo "Do not run this package build as root."
  >&2 echo "Run it as your normal user; this script will use sudo only for dependency installation."
  >&2 echo "Set ALLOW_ROOT_RPM_BUILD=true only for a disposable build tree."
  exit 1
}

function init_root_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    return
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    return
  fi

  if sudo -n true >/dev/null 2>&1; then
    ROOT_CMD=(sudo -n)
    return
  fi

  if [[ -t 0 ]]; then
    ROOT_CMD=(sudo)
  fi
}

function can_run_as_root() {
  [[ "$(id -u)" -eq 0 || "${#ROOT_CMD[@]}" -gt 0 ]]
}

function run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    "${ROOT_CMD[@]}" "$@"
  fi
}

function drop_root_cmd() {
  if [[ "$(id -u)" -eq 0 || "${#ROOT_CMD[@]}" -eq 0 ]]; then
    return
  fi

  if [[ "${ROOT_CMD[0]}" == "sudo" ]]; then
    sudo -k || true
  fi
  ROOT_CMD=()
}

function install_rpm_build_dependencies() {
  if [[ "${SKIP_RPM_BUILD_DEPENDENCIES}" == "true" ]]; then
    echo "Skipping RPM build dependency installation (SKIP_RPM_BUILD_DEPENDENCIES=true)"
    return
  fi

  if ! can_run_as_root; then
    >&2 echo "Cannot install RPM build dependencies without root privileges."
    >&2 echo "Run in an interactive terminal with sudo access, or set SKIP_RPM_BUILD_DEPENDENCIES=true if dependencies are already installed."
    exit 1
  fi

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

REPO_DIR="$(realpath "$(dirname "$0")/../..")"
INSTALL_BAZEL="$(dirname "$0")/installbazel.sh"
BUILD_PACKAGE="$(dirname "$0")/build_package.sh"

function rpm_package_name() {
  local rpm_path="$1"
  local rpm_name

  if rpm_name="$(rpm -qp --queryformat '%{NAME}' "${rpm_path}" 2>/dev/null)"; then
    echo "${rpm_name}"
    return
  fi

  basename "${rpm_path}" | sed -E 's/-[0-9][^-]*-[^-]+\.([^.]+\.)?rpm$//'
}

function organize_rpms() {
  local rpms_root="${REPO_DIR}/rpmbuild/RPMS"

  shopt -s nullglob
  for arch_dir in "${rpms_root}"/*; do
    [[ -d "${arch_dir}" ]] || continue

    local extras_dir="${arch_dir}/extras"
    mkdir -p "${extras_dir}"

    local rpm_path
    for rpm_path in "${arch_dir}"/*.rpm; do
      case "$(rpm_package_name "${rpm_path}")" in
        ika-base|ika-lineageos|ika-scrcpy)
          ;;
        *)
          mv -f -- "${rpm_path}" "${extras_dir}/"
          ;;
      esac
    done
  done
}

# Two concurrent runs share ${REPO_DIR}/rpmbuild and corrupt each other's
# source extraction mid-build (a second run re-stages SOURCES while the first
# is still building from it). Serialize with a non-blocking advisory lock held
# for the lifetime of this process (released automatically on exit).
readonly BUILD_PACKAGES_LOCK="${REPO_DIR}/rpmbuild/.build_packages.lock"
mkdir -p "$(dirname "${BUILD_PACKAGES_LOCK}")"
exec 9>"${BUILD_PACKAGES_LOCK}"
if ! flock -n 9; then
  >&2 echo "Another build_packages.sh is already running for ${REPO_DIR}"
  >&2 echo "(lock: ${BUILD_PACKAGES_LOCK}). Wait for it to finish or stop it first."
  exit 1
fi

refuse_root_rpm_build
init_root_cmd
trap drop_root_cmd EXIT
install_rpm_build_dependencies
if ! command -v bazel >/dev/null 2>&1; then
  if ! can_run_as_root; then
    >&2 echo "Bazel is not installed and cannot be installed without root privileges."
    >&2 echo "Install bazel manually or run this script with sudo access."
    exit 1
  fi
  run_as_root "${INSTALL_BAZEL}"
fi
drop_root_cmd

# Builds all RPM specs under base/rpm and frontend/rpm unless excluded.
"${BUILD_PACKAGE}" "$@" "${REPO_DIR}/base"
"${BUILD_PACKAGE}" "$@" "${REPO_DIR}/frontend"
organize_rpms
