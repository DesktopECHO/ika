#!/usr/bin/env bash

set -e -x

readonly SKIP_RPM_BUILD_DEPENDENCIES="${SKIP_RPM_BUILD_DEPENDENCIES:-false}"
declare -a ROOT_CMD=()

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

function install_rpm_build_dependencies() {
  if [[ "${SKIP_RPM_BUILD_DEPENDENCIES}" == "true" ]]; then
    echo "Skipping RPM build dependency installation (SKIP_RPM_BUILD_DEPENDENCIES=true)"
    return
  fi

  if ! can_run_as_root; then
    >&2 echo "Cannot install RPM build dependencies without root privileges."
    >&2 echo "Run in an interactive terminal with sudo, run as root, or set SKIP_RPM_BUILD_DEPENDENCIES=true if dependencies are already installed."
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
    libusb1-devel

  # Runtime tools needed during rpmbuild
  run_as_root dnf -y install \
    rsync
}

REPO_DIR="$(realpath "$(dirname "$0")/../..")"
INSTALL_BAZEL="$(dirname "$0")/installbazel.sh"
BUILD_PACKAGE="$(dirname "$0")/build_package.sh"

init_root_cmd
install_rpm_build_dependencies
if ! command -v bazel >/dev/null 2>&1; then
  if ! can_run_as_root; then
    >&2 echo "Bazel is not installed and cannot be installed without root privileges."
    >&2 echo "Install bazel manually or run this script with sudo access."
    exit 1
  fi
  run_as_root "${INSTALL_BAZEL}"
fi

# Builds all RPM specs under base/rpm and frontend/rpm unless excluded.
"${BUILD_PACKAGE}" "$@" "${REPO_DIR}/base"
"${BUILD_PACKAGE}" "$@" "${REPO_DIR}/frontend"
