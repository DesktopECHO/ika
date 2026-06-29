#!/usr/bin/env bash
# All distro packages required by the ika build pipeline, combined in one
# place so ./ika-build can install them with a single sudo escalation.
# No other script may call apt/dnf: a package install mid-build would stall
# a multi-hour unattended build at a sudo password prompt.
#
# Source only — defines functions. Requires lib/common.sh (run_as_root,
# can_run_as_root) with init_root_cmd already called.

case ":$PATH:" in
  *:/usr/sbin:*) ;;
  *) export PATH="$PATH:/usr/sbin:/sbin" ;;
esac

# Accept both the distro-agnostic name and the legacy RPM-specific name.
readonly SKIP_BUILD_DEPENDENCIES="${SKIP_BUILD_DEPENDENCIES:-${SKIP_RPM_BUILD_DEPENDENCIES:-false}}"
readonly REPO_TOOL_URL="${REPO_TOOL_URL:-https://storage.googleapis.com/git-repo-downloads/repo}"
readonly REPO_INSTALL_PATH="${REPO_INSTALL_PATH:-/usr/local/bin/repo}"
LINEAGEOS_PRIVILEGED_HELPERS_LOADED=0

function install_rpm_build_dependencies() {
  echo "Installing RPM build dependencies"
  run_as_root dnf -y upgrade --refresh

  # Every build dependency for all ika RPMs plus the ROM host tools, installed
  # in a single dnf transaction: one sudo call, one dependency resolution.
  local -a packages=(
    # Core RPM build tooling
    rpm-build rpmdevtools systemd-rpm-macros

    # cuttlefish-base BuildRequires (Bazel C++ build)
    libaom-devel libavdevice-free-devel libswscale-free-devel clang-devel
    cmake fmt-devel gcc-c++ gflags-devel git glog-devel gtest-devel
    jsoncpp-devel libX11-devel libXext-devel libcurl-devel libcap-devel
    libdrm-devel libxcrypt-compat libuuid-devel libxml2-devel libsrtp-devel
    opus-devel openssl openssl-devel perl-FindBin pkgconf-pkg-config
    protobuf-c-devel protobuf-compiler protobuf-devel python3
    mesa-libgbm-devel virglrenderer-devel wayland-devel which xxd xz-devel
    z3-devel

    # cuttlefish-frontend BuildRequires (Go + Node.js)
    curl golang npm

    # ika-base scrcpy viewer BuildRequires (Meson C build + scrcpy-server Java build)
    meson ninja-build java-25-openjdk-devel SDL3-devel libavcodec-free-devel
    libavformat-free-devel libavutil-free-devel libswresample-free-devel
    libusb1-devel vulkan-headers libicu-devel

    # Runtime tools needed during rpmbuild
    rsync pigz

    # LineageOS Desktop ROM host tools + Bazelisk prerequisites — previously
    # installed on demand by lineageos/scripts/lib/host_env.sh and
    # installbazel.sh.
    7zip android-tools binutils ccache coreutils dwarves e2fsprogs
    erofs-utils file findutils gawk git-lfs ImageMagick kmod lz4
    policycoreutils policycoreutils-python-utils tar unzip util-linux zip
  )

  run_as_root dnf -y install --setopt=install_weak_deps=False "${packages[@]}"
}

function ensure_trixie_backports_repository() {
  if grep -qrE "^[^#]*trixie-backports" \
       /etc/apt/sources.list \
       /etc/apt/sources.list.d/ 2>/dev/null; then
    return 0
  fi

  echo "Debian 13 (trixie) requires the trixie-backports repository."
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
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
}

function install_trixie_testing_vulkan_loader() {
  local buildutils_dir builder version
  version="$(dpkg-query -W -f='${Version}' libvulkan1 2>/dev/null || true)"
  if [[ -n "${version}" ]] && dpkg --compare-versions "${version}" ge 1.4.341; then
    echo "libvulkan1 ${version} is already 1.4.341 or newer; skipping Debian testing Vulkan build."
    return 0
  fi

  buildutils_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  builder="${buildutils_dir}/vulkan-build-trixie"

  [[ -x "${builder}" ]] || {
    >&2 echo "Missing executable Vulkan testing build helper: ${builder}"
    exit 1
  }

  echo "Build libvulkan from Debian testing..."
  "${builder}" --yes --install --no-stage
}

function install_deb_build_dependencies() {
  local codename
  codename=$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")

  if [[ "${codename}" == "trixie" ]]; then
    ensure_trixie_backports_repository
  fi

  echo "Installing Debian build dependencies"
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq

  # All static build dependencies for every ika deb plus the ROM host tools, in
  # a single apt-get transaction: one sudo call, one dependency resolution.
  # (The conditional libgcc-<ver>-dev and trixie-backports steps below can't
  # join it — they depend on runtime detection / a different apt source.)
  local -a packages=(
    # Core deb build tooling
    config-package-dev debhelper dh-exec dpkg-dev

    # cuttlefish-base Build-Depends (Bazel C++ build)
    cmake git libaom-dev libavdevice-dev libclang-dev libfmt-dev libgflags-dev
    libgoogle-glog-dev libgtest-dev libjsoncpp-dev liblzma-dev libopus-dev
    openssl libprotobuf-c-dev libprotobuf-dev libsrtp2-dev libssl-dev
    libswscale-dev libvirglrenderer-dev libxml2-dev libz3-dev libicu-dev
    libvulkan-dev libgl-dev libgles-dev libegl-dev libcap-dev libdrm-dev
    libgbm-dev libwayland-dev libva-dev libzstd-dev pkgconf protobuf-compiler
    uuid-dev xxd

    # cuttlefish-frontend Build-Depends (Go + Node.js)
    curl golang-go npm

    # ika-base scrcpy viewer Build-Depends (Meson C build + scrcpy-server Java build)
    default-jdk meson ninja-build libavcodec-dev libavformat-dev libavutil-dev
    libswresample-dev libsdl3-dev libusb-1.0-0-dev

    # LineageOS Desktop ROM host tools + Bazelisk prerequisites — previously
    # installed on demand by lineageos/scripts/lib/host_env.sh and
    # installbazel.sh.
    7zip adb android-sdk-libsparse-utils binutils ccache coreutils dwarves
    e2fsprogs erofs-utils file findutils gawk git-lfs imagemagick kmod lz4
    python3 rsync tar unzip util-linux zip
  )

  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"

  # crtbeginS.o is split from gcc into libgcc-<ver>-dev on Debian trixie+;
  # the ROM build links host tools against it.
  if ! compgen -G '/usr/lib/gcc/*/*/crtbeginS.o' >/dev/null 2>&1; then
    local gcc_ver
    gcc_ver="$(apt-cache pkgnames 2>/dev/null | grep -E '^libgcc-[0-9]+-dev$' | \
      grep -oE '[0-9]+' | sort -n | tail -1)"
    if [[ -n "${gcc_ver}" ]]; then
      run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "libgcc-${gcc_ver}-dev"
    fi
  fi

  # Debian 13: upgrade Mesa from backports, then install Vulkan loader/dev
  # packages built from testing source. Trixie base has vulkan_raii.hpp v1.4.309
  # which is ABI-incompatible with the v1.4.338 headers the Bazel build fetches
  # from KhronosGroup/Vulkan-Headers.
  if [[ "${codename}" == "trixie" ]]; then
    echo "Upgrading Mesa stack from trixie-backports..."
    run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -t trixie-backports -y --no-install-recommends \
      libegl1 \
      libegl-mesa0 \
      libgl1-mesa-dri \
      libgles2 \
      libglx-mesa0 \
      mesa-common-dev \
      mesa-vulkan-drivers \
      mesa-drm-shim \
      mesa-utils-bin
    install_trixie_testing_vulkan_loader
  fi
}

function install_arch_build_dependencies() {
  echo "Installing Arch Linux build dependencies"

  run_as_root pacman -Syu --needed --noconfirm \
    base-devel \
    aom \
    android-tools \
    7zip \
    binutils \
    ccache \
    clang \
    cmake \
    coreutils \
    curl \
    e2fsprogs \
    erofs-utils \
    file \
    ffmpeg \
    findutils \
    fmt \
    gawk \
    gcc \
    gflags \
    git \
    git-lfs \
    google-glog \
    gtest \
    icu \
    imagemagick \
    inetutils \
    jdk-openjdk \
    jsoncpp \
    kmod \
    libcap \
    libdrm \
    libusb \
    libsrtp \
    libx11 \
    libxext \
    libxml2 \
    lz4 \
    mesa \
    meson \
    ninja \
    npm \
    openssl \
    opus \
    pahole \
    perl \
    pigz \
    pkgconf \
    protobuf \
    protobuf-c \
    python \
    go \
    rsync \
    sdl3 \
    tar \
    unzip \
    util-linux \
    util-linux-libs \
    virglrenderer \
    vulkan-headers \
    wayland \
    which \
    xz \
    z3 \
    zstd \
    zip

  if ! pacman -T xxd >/dev/null 2>&1; then
    run_as_root pacman -S --needed --noconfirm tinyxxd
  fi
}

function install_build_dependencies() {
  local family="$1"

  if [[ "${SKIP_BUILD_DEPENDENCIES}" == "true" ]]; then
    echo "Skipping build dependency installation (SKIP_BUILD_DEPENDENCIES=true)"
    return
  fi

  if ! can_run_as_root; then
    >&2 echo "Cannot install build dependencies without root privileges."
    >&2 echo "Run in an interactive terminal with sudo access, or set SKIP_BUILD_DEPENDENCIES=true if dependencies are already installed."
    exit 1
  fi

  case "${family}" in
    rpm)    install_rpm_build_dependencies ;;
    debian) install_deb_build_dependencies ;;
    arch)   install_arch_build_dependencies ;;
  esac

  install_repo_if_missing
}

# Bazel is not packaged by the distros we support; install it via Bazelisk
# when missing. Runs as root because the installer writes /usr/local/bin.
function install_bazel_if_missing() {
  local installer="$1"

  if command -v bazel >/dev/null 2>&1; then
    return 0
  fi

  if ! can_run_as_root; then
    >&2 echo "Bazel is not installed and cannot be installed without root privileges."
    >&2 echo "Install bazel manually or run in an interactive terminal with sudo access."
    exit 1
  fi
  run_as_root "${installer}"
}

function load_lineageos_privileged_helpers() {
  local repo_root="$1"

  if [[ "${LINEAGEOS_PRIVILEGED_HELPERS_LOADED}" == "1" ]]; then
    return 0
  fi

  log() {
    printf '[ika-build] %s\n' "$*"
  }

  die() {
    printf '[ika-build] error: %s\n' "$*" >&2
    exit 1
  }

  # shellcheck source=/dev/null
  source "$repo_root/lineageos/scripts/lib/common.sh"
  # shellcheck source=/dev/null
  source "$repo_root/lineageos/scripts/build_jobs.sh"
  # shellcheck source=/dev/null
  source "$repo_root/lineageos/scripts/lib/host_env.sh"
  # shellcheck source=/dev/null
  source "$repo_root/lineageos/scripts/lib/build_exec.sh"

  run_privileged() {
    if (( EUID == 0 )); then
      "$@"
    elif can_run_as_root; then
      run_as_root "$@"
    else
      return 1
    fi
  }

  LINEAGEOS_PRIVILEGED_HELPERS_LOADED=1
}

function prepare_lineageos_privileged_host() {
  local repo_root="$1"
  local workspace_path="$2"

  load_lineageos_privileged_helpers "$repo_root"

  ika_root="$repo_root"
  workspace="$workspace_path"
  if [[ -n "${NOFILE_LIMIT+x}" ]]; then
    host_nofile_limit="$NOFILE_LIMIT"
  else
    host_nofile_limit=4194304
  fi
  temp_zram_device="${temp_zram_device:-}"

  raise_host_open_file_limit
  install_repo_if_missing
  mkdir -p "$workspace"
  ensure_workspace_selinux_contexts
  setup_temp_zram_if_needed

  export IKA_PRIVILEGED_PREFLIGHT_DONE=1
}

function cleanup_lineageos_privileged_host() {
  if [[ "${LINEAGEOS_PRIVILEGED_HELPERS_LOADED}" != "1" ]]; then
    return 0
  fi

  cleanup_temp_zram
}

# repo is distributed as a standalone script. Install it during dependency
# setup so the ROM build never has to sudo in the middle of source sync setup.
function install_repo_if_missing() {
  local tmp_repo

  if command -v repo >/dev/null 2>&1 || [[ -x "$REPO_INSTALL_PATH" ]]; then
    return 0
  fi

  if ! can_run_as_root; then
    >&2 echo "repo is not installed and cannot be installed without root privileges."
    >&2 echo "Install repo manually or run in an interactive terminal with sudo access."
    exit 1
  fi

  command -v curl >/dev/null 2>&1 || {
    >&2 echo "repo is not installed and curl is missing; cannot download ${REPO_TOOL_URL}."
    exit 1
  }

  tmp_repo="$(mktemp)"
  if ! curl -L --fail -o "$tmp_repo" "$REPO_TOOL_URL"; then
    rm -f "$tmp_repo"
    exit 1
  fi
  if ! run_as_root install -m 0755 "$tmp_repo" "$REPO_INSTALL_PATH"; then
    rm -f "$tmp_repo"
    exit 1
  fi
  rm -f "$tmp_repo"
}
