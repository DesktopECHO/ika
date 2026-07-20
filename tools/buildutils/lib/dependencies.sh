#!/usr/bin/env bash
# All distro packages required by the ika build pipeline, combined in one
# place so ./ika-build can install them with a single sudo escalation.
# No other script may call apt/dnf: a package install mid-build would stall
# a multi-hour unattended build at a sudo password prompt.
#
# Source only — defines functions. Requires lib/common.sh. Read-only query
# helpers do not need root; installer functions expect init_root_cmd to have
# been called when elevation is required.

case ":$PATH:" in
  *:/usr/sbin:*) ;;
  *) export PATH="$PATH:/usr/sbin:/sbin" ;;
esac

# Accept both the distro-agnostic name and the legacy RPM-specific name.
readonly SKIP_BUILD_DEPENDENCIES="${SKIP_BUILD_DEPENDENCIES:-${SKIP_RPM_BUILD_DEPENDENCIES:-false}}"
readonly REPO_TOOL_URL="${REPO_TOOL_URL:-https://storage.googleapis.com/git-repo-downloads/repo}"
readonly REPO_INSTALL_PATH="${REPO_INSTALL_PATH:-${HOME}/.local/bin/repo}"
readonly BAZEL_INSTALL_PATH="${BAZEL_INSTALL_PATH:-${HOME}/.local/bin/bazel}"
readonly DEBIAN_MESA_BACKPORTS_SUITE="${DEBIAN_MESA_BACKPORTS_SUITE:-trixie-backports}"
readonly DEBIAN_MESA_MIN_VERSION="${DEBIAN_MESA_MIN_VERSION:-${TRIXIE_MESA_BACKPORT_MIN_VERSION:-26.1}}"
readonly DEBIAN_VULKAN_LOADER_COMMIT="${DEBIAN_VULKAN_LOADER_COMMIT:-${TRIXIE_VULKAN_LOADER_COMMIT:-e3a3df62e0b7e9b12dacb626a8d554a47ad9ed2d}}"
readonly DEBIAN_VULKAN_LOADER_MIN_VERSION="${DEBIAN_VULKAN_LOADER_MIN_VERSION:-${TRIXIE_VULKAN_LOADER_MIN_VERSION:-1.4.341}}"
readonly UBUNTU_KISAK_MESA_PPA="${UBUNTU_KISAK_MESA_PPA:-ppa:kisak/kisak-mesa}"
readonly UBUNTU_ENABLE_KISAK_MESA="${UBUNTU_ENABLE_KISAK_MESA:-ask}"
LINEAGEOS_PRIVILEGED_HELPERS_LOADED=0

function rpm_build_dependency_packages() {
  local -a packages=(
    # Core RPM build tooling
    rpm-build rpmdevtools systemd-rpm-macros

    # cuttlefish-base BuildRequires (Bazel C++ build). FFmpeg pkg-config
    # capabilities accept either the Fedora or RPM Fusion development stack.
    libaom-devel "pkgconfig(libavdevice)" "pkgconfig(libswscale)" clang-devel
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
    meson ninja-build java-25-openjdk-devel SDL3-devel pipewire-devel
    "pkgconfig(libavcodec)" "pkgconfig(libavformat)" "pkgconfig(libavutil)"
    "pkgconfig(libswresample)" libusb1-devel vulkan-headers libicu-devel

    # Runtime tools needed during rpmbuild
    rsync pigz

    # LineageOS Desktop ROM host tools + Bazelisk prerequisites — previously
    # installed on demand by lineageos/scripts/lib/host_env.sh and
    # installbazel.sh.
    7zip android-tools binutils ccache coreutils dwarves e2fsprogs
    erofs-utils file findutils gawk git-lfs ImageMagick kmod lz4
    policycoreutils policycoreutils-python-utils tar unzip util-linux zip
  )

  printf '%s\n' "${packages[@]}"
}

function deb_build_dependency_packages() {
  local -a packages=(
    # Core deb build tooling
    binutils build-essential config-package-dev debhelper dh-exec dpkg-dev

    # cuttlefish-base Build-Depends (Bazel C++ build)
    cmake git libaom-dev libclang-dev libfmt-dev libgflags-dev
    libgoogle-glog-dev libgtest-dev libjsoncpp-dev liblzma-dev libopus-dev
    openssl libprotobuf-c-dev libprotobuf-dev libsrtp2-dev libssl-dev
    libvirglrenderer-dev libxml2-dev libz3-dev libicu-dev
    libvulkan-dev libgl-dev libgles-dev libegl-dev libcap-dev libdrm-dev
    libgbm-dev libwayland-dev libva-dev libxtst-dev libzstd-dev pkgconf protobuf-compiler
    uuid-dev xxd

    # cuttlefish-frontend Build-Depends (Go + Node.js)
    curl golang-go npm

    # ika-base pinned static multimedia dependencies (crosvm + scrcpy), plus
    # the scrcpy-server Java build
    autoconf automake ca-certificates default-jdk libtool meson nasm ninja-build
    libpipewire-0.3-dev libsdl3-dev libusb-1.0-0-dev libv4l-dev wget xz-utils
    zlib1g-dev

    # LineageOS Desktop ROM host tools + Bazelisk prerequisites — previously
    # installed on demand by lineageos/scripts/lib/host_env.sh and
    # installbazel.sh.
    7zip adb android-sdk-libsparse-utils binutils ccache coreutils dwarves
    e2fsprogs erofs-utils file findutils gawk git-lfs imagemagick kmod lz4
    python3 rsync tar unzip util-linux zip
  )

  printf '%s\n' "${packages[@]}"
}

function deb_mesa_version_packages() {
  local -a packages=(
    libegl-mesa0
    libgbm-dev
    libgbm1
    libgl1-mesa-dri
    libglx-mesa0
    mesa-common-dev
    mesa-vulkan-drivers
    mesa-drm-shim
  )

  printf '%s\n' "${packages[@]}"
}

function arch_build_dependency_packages() {
  local -a packages=(
    base-devel
    aom
    android-tools
    7zip
    binutils
    ccache
    clang
    cmake
    coreutils
    curl
    e2fsprogs
    erofs-utils
    file
    ffmpeg
    findutils
    fmt
    gawk
    gcc
    gflags
    git
    git-lfs
    google-glog
    gtest
    icu
    imagemagick
    inetutils
    jdk-openjdk
    jsoncpp
    kmod
    libcap
    libdrm
    libusb
    libsrtp
    libx11
    libxext
    libxml2
    lz4
    mesa
    meson
    ninja
    npm
    openssl
    opus
    pahole
    perl
    pigz
    pkgconf
    protobuf
    protobuf-c
    python
    go
    rsync
    sdl3
    tar
    unzip
    util-linux
    util-linux-libs
    virglrenderer
    vulkan-headers
    wayland
    which
    xz
    z3
    zstd
    zip
  )

  printf '%s\n' "${packages[@]}"
}

function deb_package_installed() {
  local pkg="$1"
  dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q 'install ok installed'
}

function deb_package_version_at_least() {
  local pkg="$1"
  local min_version="$2"
  local version

  version="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
  [[ -n "${version}" ]] && dpkg --compare-versions "${version}" ge "${min_version}"
}

function debian_codename() {
  . /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}"
}

function debian_distribution_kind() {
  local ID="" ID_LIKE="" UBUNTU_CODENAME="" distro_words

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi

  distro_words=" ${ID:-} ${ID_LIKE:-} "
  if [[ -n "${UBUNTU_CODENAME:-}" || "${distro_words}" == *" ubuntu "* ]]; then
    printf 'ubuntu'
  elif [[ "${distro_words}" == *" debian "* ]]; then
    printf 'debian'
  else
    printf 'unknown'
  fi
}

function debian_is_trixie() {
  [[ "$(debian_distribution_kind)" == "debian" && "$(debian_codename)" == "trixie" ]]
}

function rpm_package_installed() {
  local pkg="$1"
  rpm -q --quiet "$pkg" >/dev/null 2>&1 || \
    rpm -q --quiet --whatprovides "$pkg" >/dev/null 2>&1
}

function arch_package_installed() {
  local pkg="$1"
  pacman -Q --quiet "$pkg" >/dev/null 2>&1
}

function missing_rpm_build_dependencies() {
  local pkg

  while read -r pkg; do
    [[ -n "$pkg" ]] || continue
    rpm_package_installed "$pkg" || printf '%s\n' "$pkg"
  done < <(rpm_build_dependency_packages)
}

function missing_deb_build_dependencies() {
  local pkg version gcc_ver

  while read -r pkg; do
    [[ -n "$pkg" ]] || continue
    deb_package_installed "$pkg" || printf '%s\n' "$pkg"
  done < <(deb_build_dependency_packages)

  # crtbeginS.o is split from gcc into libgcc-<ver>-dev on Debian trixie+;
  # the ROM build links host tools against it.
  if ! compgen -G '/usr/lib/gcc/*/*/crtbeginS.o' >/dev/null 2>&1; then
    gcc_ver="$(apt-cache pkgnames 2>/dev/null | grep -E '^libgcc-[0-9]+-dev$' | \
      grep -oE '[0-9]+' | sort -n | tail -1)"
    if [[ -n "${gcc_ver}" ]]; then
      printf 'libgcc-%s-dev\n' "$gcc_ver"
    else
      printf '%s\n' 'libgcc-<version>-dev'
    fi
  fi

  if ! debian_mesa_stack_at_min_version; then
    case "$(debian_distribution_kind)" in
      ubuntu)
        printf 'mesa>=%s-from-kisak-mesa-ppa\n' "${DEBIAN_MESA_MIN_VERSION}"
        ;;
      debian)
        printf 'mesa>=%s-from-%s\n' "${DEBIAN_MESA_MIN_VERSION}" "${DEBIAN_MESA_BACKPORTS_SUITE}"
        ;;
      *)
        printf 'mesa>=%s-from-a-supported-binary-repository\n' "${DEBIAN_MESA_MIN_VERSION}"
        ;;
    esac
  fi

  if debian_is_trixie; then
    version="$(dpkg-query -W -f='${Version}' libvulkan-dev 2>/dev/null || true)"
    if [[ -z "${version}" ]] || ! dpkg --compare-versions "${version}" ge "${DEBIAN_VULKAN_LOADER_MIN_VERSION}"; then
      printf 'libvulkan-dev>=%s-from-salsa-%s\n' \
        "${DEBIAN_VULKAN_LOADER_MIN_VERSION}" \
        "${DEBIAN_VULKAN_LOADER_COMMIT:0:12}"
    fi
  fi
}

function missing_arch_build_dependencies() {
  local pkg

  while read -r pkg; do
    [[ -n "$pkg" ]] || continue
    arch_package_installed "$pkg" || printf '%s\n' "$pkg"
  done < <(arch_build_dependency_packages)
}

function missing_build_dependencies() {
  local family="$1"

  case "${family}" in
    rpm)    missing_rpm_build_dependencies ;;
    debian) missing_deb_build_dependencies ;;
    arch)   missing_arch_build_dependencies ;;
  esac
}

function build_dependency_packages_need_install() {
  local family="$1"
  local -a missing=()

  [[ "${SKIP_BUILD_DEPENDENCIES}" == "true" ]] && return 1

  mapfile -t missing < <(missing_build_dependencies "$family")
  (( ${#missing[@]} > 0 ))
}

function repo_tool_available() {
  command -v repo >/dev/null 2>&1 || [[ -x "$REPO_INSTALL_PATH" ]]
}

function install_rpm_build_dependencies() {
  local -a packages=()

  echo "Installing RPM build dependencies"
  run_as_root dnf -y upgrade --refresh

  # Every build dependency for all ika RPMs plus the ROM host tools, installed
  # in a single dnf transaction: one sudo call, one dependency resolution.
  mapfile -t packages < <(rpm_build_dependency_packages)
  run_as_root dnf -y install --setopt=install_weak_deps=False "${packages[@]}"
}

function install_debian_salsa_vulkan_loader() {
  local buildutils_dir builder version
  version="$(dpkg-query -W -f='${Version}' libvulkan-dev 2>/dev/null || true)"
  if [[ -n "${version}" ]] && dpkg --compare-versions "${version}" ge "${DEBIAN_VULKAN_LOADER_MIN_VERSION}"; then
    echo "libvulkan-dev ${version} is already ${DEBIAN_VULKAN_LOADER_MIN_VERSION} or newer; skipping Vulkan loader build."
    return 0
  fi

  buildutils_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  builder="${buildutils_dir}/vulkan-build-trixie"

  [[ -x "${builder}" ]] || {
    >&2 echo "Missing executable Vulkan Salsa build helper: ${builder}"
    exit 1
  }

  echo "Build libvulkan from Debian Salsa commit ${DEBIAN_VULKAN_LOADER_COMMIT}..."
  "${builder}" --yes --install --no-stage --commit "${DEBIAN_VULKAN_LOADER_COMMIT}"
}

function debian_backports_binary_repository_present() {
  local suite="$1"
  local file

  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    [[ -f "${file}" ]] || continue
    if grep -Eq "^[[:space:]]*deb[[:space:]].*[[:space:]]${suite}([[:space:]]|$)" "${file}" ||
       { grep -Eq "^[[:space:]]*Types:[[:space:]]+([^#]*[[:space:]])?deb([[:space:]]|$)" "${file}" &&
         grep -Eq "^[[:space:]]*Suites:[[:space:]]+([^#]*[[:space:]])?${suite}([[:space:]]|$)" "${file}"; }; then
      return 0
    fi
  done

  return 1
}

function ensure_debian_backports_repository() {
  local suite="$1"
  local sources_file="/etc/apt/sources.list.d/ika-${suite}.sources"

  if debian_backports_binary_repository_present "${suite}"; then
    return 0
  fi

  echo "Adding Debian ${suite} binary repository for Mesa ${DEBIAN_MESA_MIN_VERSION}+..."
  printf '%s\n' \
    'Types: deb' \
    'URIs: http://deb.debian.org/debian' \
    "Suites: ${suite}" \
    'Components: main' \
    'Enabled: yes' \
    'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' | \
    run_as_root tee "${sources_file}" >/dev/null
  if ! run_as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    echo "Unable to use ${suite}; removing ${sources_file}."
    run_as_root rm -f "${sources_file}"
    run_as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    return 1
  fi
}

function ensure_debian_backports_for_mesa() {
  local codename

  codename="$(debian_codename)"
  if ! debian_is_trixie; then
    >&2 echo "Mesa installation from ${DEBIAN_MESA_BACKPORTS_SUITE} is only supported on Debian trixie. Detected VERSION_CODENAME=${codename:-unknown}."
    return 1
  fi

  ensure_debian_backports_repository "${DEBIAN_MESA_BACKPORTS_SUITE}"
}

function ubuntu_kisak_mesa_repository_present() {
  local file

  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    [[ -f "${file}" ]] || continue
    if grep -Eiq '^[[:space:]]*[^#].*(ppa\.launchpadcontent\.net/kisak/kisak-mesa/ubuntu|ppa:kisak/kisak-mesa)' "${file}"; then
      return 0
    fi
  done

  return 1
}

function ensure_ubuntu_kisak_mesa_repository() {
  local reply

  if ubuntu_kisak_mesa_repository_present; then
    return 0
  fi

  case "${UBUNTU_ENABLE_KISAK_MESA}" in
    1|true|yes|always)
      reply="y"
      ;;
    0|false|no|never)
      echo "Skipping ${UBUNTU_KISAK_MESA_PPA}; UBUNTU_ENABLE_KISAK_MESA=${UBUNTU_ENABLE_KISAK_MESA}."
      return 1
      ;;
    ask)
      if [[ ! -t 0 ]]; then
        echo "Skipping ${UBUNTU_KISAK_MESA_PPA}; no interactive terminal is available to ask about adding it."
        return 1
      fi

      echo "Ubuntu requires Mesa ${DEBIAN_MESA_MIN_VERSION}+ from the Kisak Mesa PPA for Ika."
      printf "Add %s? [Y/n] " "${UBUNTU_KISAK_MESA_PPA}"
      read -r reply
      ;;
    *)
      >&2 echo "Unknown UBUNTU_ENABLE_KISAK_MESA=${UBUNTU_ENABLE_KISAK_MESA}; expected ask, true, or false."
      return 1
      ;;
  esac

  case "${reply}" in
    [nN]*)
      echo "Skipping ${UBUNTU_KISAK_MESA_PPA}; cannot install Mesa ${DEBIAN_MESA_MIN_VERSION}+ from Kisak."
      return 1
      ;;
  esac

  if ! command -v add-apt-repository >/dev/null 2>&1; then
    run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends software-properties-common
  fi

  if ! run_as_root add-apt-repository -y "${UBUNTU_KISAK_MESA_PPA}"; then
    >&2 echo "Unable to add ${UBUNTU_KISAK_MESA_PPA}."
    return 1
  fi
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
}

function deb_mesa_candidate_version() {
  local pkg="$1"
  local target_release="${2:-}"

  if [[ -n "${target_release}" ]]; then
    apt-cache show "${pkg}/${target_release}" 2>/dev/null | \
      awk '$1 == "Version:" { print $2; exit }'
  else
    apt-cache policy "${pkg}" 2>/dev/null | \
      awk '$1 == "Candidate:" { print $2; exit }'
  fi
}

function deb_mesa_candidates_at_min_version() {
  local target_release="${1:-}"
  local source_name="$2"
  local pkg version

  while read -r pkg; do
    [[ -n "${pkg}" ]] || continue
    version="$(deb_mesa_candidate_version "${pkg}" "${target_release}")"
    if [[ -z "${version}" || "${version}" == "(none)" ]] ||
       ! dpkg --compare-versions "${version}" ge "${DEBIAN_MESA_MIN_VERSION}"; then
      >&2 printf '%s offers %s candidate %s; Ika requires Mesa %s or newer.\n' \
        "${source_name}" "${pkg}" "${version:-none}" "${DEBIAN_MESA_MIN_VERSION}"
      return 1
    fi
  done < <(deb_mesa_version_packages)

  return 0
}

function debian_mesa_stack_at_min_version() {
  local pkg

  while read -r pkg; do
    [[ -n "${pkg}" ]] || continue
    deb_package_version_at_least "${pkg}" "${DEBIAN_MESA_MIN_VERSION}" || return 1
  done < <(deb_mesa_version_packages)

  return 0
}

function install_debian_mesa_from_backports() {
  local pkg
  local -a packages=()

  if ! ensure_debian_backports_for_mesa; then
    >&2 echo "Mesa ${DEBIAN_MESA_MIN_VERSION}+ must be installed from ${DEBIAN_MESA_BACKPORTS_SUITE}; source builds are not supported."
    return 1
  fi

  if ! deb_mesa_candidates_at_min_version "${DEBIAN_MESA_BACKPORTS_SUITE}" "Debian ${DEBIAN_MESA_BACKPORTS_SUITE}"; then
    >&2 echo "Wait for Debian backports to publish Mesa ${DEBIAN_MESA_MIN_VERSION}+; Ika will not build Mesa from source."
    return 1
  fi

  while read -r pkg; do
    [[ -n "${pkg}" ]] || continue
    packages+=("${pkg}/${DEBIAN_MESA_BACKPORTS_SUITE}")
  done < <(deb_mesa_version_packages)
  echo "Installing Mesa ${DEBIAN_MESA_MIN_VERSION}+ from ${DEBIAN_MESA_BACKPORTS_SUITE}..."
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
}

function install_ubuntu_mesa_from_kisak() {
  local -a packages=()

  if ! ensure_ubuntu_kisak_mesa_repository; then
    >&2 echo "Mesa ${DEBIAN_MESA_MIN_VERSION}+ must be installed from ${UBUNTU_KISAK_MESA_PPA}; source builds are not supported."
    return 1
  fi

  if ! deb_mesa_candidates_at_min_version "" "Kisak Mesa PPA"; then
    >&2 echo "Wait for Kisak to publish Mesa ${DEBIAN_MESA_MIN_VERSION}+ for this Ubuntu release and architecture; Ika will not build Mesa from source."
    return 1
  fi

  mapfile -t packages < <(deb_mesa_version_packages)
  echo "Installing Mesa ${DEBIAN_MESA_MIN_VERSION}+ from ${UBUNTU_KISAK_MESA_PPA}..."
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
}

function install_debian_mesa() {
  if debian_mesa_stack_at_min_version; then
    echo "Mesa stack is already ${DEBIAN_MESA_MIN_VERSION} or newer; skipping Mesa installation."
    return 0
  fi

  case "$(debian_distribution_kind)" in
    debian)
      install_debian_mesa_from_backports || exit 1
      ;;
    ubuntu)
      install_ubuntu_mesa_from_kisak || exit 1
      ;;
    *)
      >&2 echo "Unsupported Debian-family distribution; install Mesa ${DEBIAN_MESA_MIN_VERSION}+ from a binary repository."
      exit 1
      ;;
  esac

  if ! debian_mesa_stack_at_min_version; then
    >&2 echo "Mesa installation completed, but one or more required packages are still older than ${DEBIAN_MESA_MIN_VERSION}."
    exit 1
  fi
}

function install_deb_build_dependencies() {
  local -a packages=()

  echo "Installing Debian build dependencies"
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq

  # All static build dependencies for every ika deb plus the ROM host tools, in
  # a single apt-get transaction: one sudo call, one dependency resolution.
  # (The conditional libgcc-<ver>-dev, Mesa repository installation, and
  # Vulkan loader build below can't join it — they depend on runtime detection.)
  mapfile -t packages < <(deb_build_dependency_packages)
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

  # Debian trixie alone needs the Vulkan loader built from the pinned Debian
  # Salsa packaging commit when libvulkan-dev is older than required. Install
  # Mesa binaries only when the installed stack is older than required:
  # trixie-backports on Debian, or the Kisak Mesa PPA on Ubuntu. Mesa is never
  # built from source.
  # Debian trixie has vulkan_raii.hpp v1.4.309 which is ABI-incompatible with the
  # v1.4.341 headers the Bazel build fetches from KhronosGroup/Vulkan-Headers.
  if debian_is_trixie; then
    install_debian_salsa_vulkan_loader
  fi
  install_debian_mesa
}

function install_arch_build_dependencies() {
  local -a packages=()

  echo "Installing Arch Linux build dependencies"

  mapfile -t packages < <(arch_build_dependency_packages)
  run_as_root pacman -Syu --needed --noconfirm "${packages[@]}"

  if ! pacman -T xxd >/dev/null 2>&1; then
    run_as_root pacman -S --needed --noconfirm tinyxxd
  fi
}

function install_build_dependencies() {
  local family="$1"
  local -a missing=()

  if [[ "${SKIP_BUILD_DEPENDENCIES}" == "true" ]]; then
    echo "Skipping build dependency installation (SKIP_BUILD_DEPENDENCIES=true)"
    return
  fi

  mapfile -t missing < <(missing_build_dependencies "$family")
  if (( ${#missing[@]} == 0 )); then
    echo "Build dependency packages are already installed; skipping distro package install."
    install_repo_if_missing
    return
  fi

  if ! can_run_as_root; then
    >&2 echo "Cannot install build dependencies without root privileges."
    >&2 echo "Missing package(s): ${missing[*]}"
    >&2 echo "Run in an interactive terminal with sudo access, or set SKIP_BUILD_DEPENDENCIES=true if dependencies are already installed."
    exit 1
  fi

  case "${family}" in
    rpm)    install_rpm_build_dependencies ;;
    debian) install_deb_build_dependencies ;;
    arch)   install_arch_build_dependencies ;;
  esac

  mapfile -t missing < <(missing_build_dependencies "$family")
  if (( ${#missing[@]} > 0 )); then
    >&2 echo "Build dependency installation completed, but package(s) are still missing: ${missing[*]}"
    exit 1
  fi

  install_repo_if_missing
}

# Bazel is not packaged by the distros we support; install it via Bazelisk
# into the user's local bin directory when missing.
function install_bazel_if_missing() {
  local installer="$1"

  if [[ -x "$BAZEL_INSTALL_PATH" ]]; then
    return 0
  fi

  env BAZEL_INSTALL_PATH="$BAZEL_INSTALL_PATH" "${installer}"
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
# setup so the ROM build can sync sources without requiring a system install.
function install_repo_if_missing() {
  local tmp_repo

  if [[ -x "$REPO_INSTALL_PATH" ]]; then
    return 0
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
  mkdir -p "$(dirname "$REPO_INSTALL_PATH")"
  if ! install -m 0755 "$tmp_repo" "$REPO_INSTALL_PATH"; then
    rm -f "$tmp_repo"
    exit 1
  fi
  rm -f "$tmp_repo"
}
