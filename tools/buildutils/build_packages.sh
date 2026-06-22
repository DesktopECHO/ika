#!/usr/bin/env bash

set -e

# Shared distro detection helpers. Kept in lib/common.sh so build_package.sh
# reuses the exact same implementations.
_buildutils_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_buildutils_dir}/lib/common.sh"

REPO_DIR="$(realpath "$(dirname "$0")/../..")"
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
    [[ "${pkg_path}" == *.sig ]] && continue
    if ! is_primary_package "$("${name_fn}" "${pkg_path}")"; then
      mv -f -- "${pkg_path}" "${extras_dir}/"
    fi
  done
}

function organize_deb_sidecars() {
  local pkg_dir="$1"
  local extras_dir="${pkg_dir}/extras"
  local sidecar_path

  shopt -s nullglob
  mkdir -p "${extras_dir}"
  for sidecar_path in "${pkg_dir}"/ika*.buildinfo "${pkg_dir}"/ika*.changes; do
    [[ -f "${sidecar_path}" ]] || continue
    mv -f -- "${sidecar_path}" "${extras_dir}/"
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

# name-pkgver-pkgrel-arch.pkg.tar.zst -> name
function archpkg_package_name() {
  local name
  name="$(basename "$1")"
  name="${name%.pkg.tar*}"
  name="${name%-*}"
  name="${name%-*}"
  name="${name%-*}"
  printf '%s\n' "${name}"
}

function organize_archpkgs() {
  organize_package_dir "${REPO_DIR}/archbuild/packages" 'pkg.tar*' archpkg_package_name
}

readonly DISTRO_FAMILY="$(detect_distro_family)"

refuse_root_build

PACKAGE_BUILD_MARKER="$(mktemp "${TMPDIR:-/tmp}/ika-package-build-start.XXXXXX")"
trap 'rm -f "${PACKAGE_BUILD_MARKER}"' EXIT
touch "${PACKAGE_BUILD_MARKER}"

function package_output_dir() {
  case "${DISTRO_FAMILY}" in
    rpm)    printf '%s\n' "${REPO_DIR}/rpmbuild/RPMS" ;;
    debian) printf '%s\n' "${REPO_DIR}/deb" ;;
    arch)   printf '%s\n' "${REPO_DIR}/archbuild/packages" ;;
    *)      printf '%s\n' "${REPO_DIR}" ;;
  esac
}

function print_built_packages() {
  local output_dir="$1"
  local -a packages=()

  case "${DISTRO_FAMILY}" in
    rpm)
      mapfile -t packages < <(find "${output_dir}" -type f -name '*.rpm' -newer "${PACKAGE_BUILD_MARKER}" 2>/dev/null | sort)
      ;;
    debian)
      mapfile -t packages < <(find "${output_dir}" -type f -name '*.deb' -newer "${PACKAGE_BUILD_MARKER}" 2>/dev/null | sort)
      ;;
    arch)
      mapfile -t packages < <(find "${output_dir}" -type f -name '*.pkg.tar*' -newer "${PACKAGE_BUILD_MARKER}" 2>/dev/null | sort)
      ;;
  esac

  if [[ ${#packages[@]} -eq 0 ]]; then
    echo "No package files were created in ${output_dir}"
    return
  fi

  echo "Built package files:"
  printf '  %s\n' "${packages[@]}"
}

# Build dependencies (including Bazel) are installed by ./ika-build via
# tools/buildutils/lib/dependencies.sh. Fail fast when the toolchain is
# absent.
if ! command -v bazel >/dev/null 2>&1; then
  >&2 echo "bazel not found. Run ./ika-build to install all build dependencies first,"
  >&2 echo "or install Bazel manually with: sudo tools/buildutils/installbazel.sh"
  exit 1
fi

PACKAGE_OUTPUT_DIR="$(package_output_dir)"
echo "Building ${DISTRO_FAMILY} packages; output will be written to ${PACKAGE_OUTPUT_DIR}"

# Builds all packages under base/ and frontend/ for the detected distro.
"${BUILD_PACKAGE}" "$@" "${REPO_DIR}/base"
"${BUILD_PACKAGE}" "$@" "${REPO_DIR}/frontend"

# Build ika-scrcpy outside the RPM flow. Refresh the server APK first on
# Debian so the packaged client and device-side server stay in lockstep. On RPM
# this is handled automatically via base/rpm/cuttlefish-scrcpy.spec.
if [[ "${DISTRO_FAMILY}" != "rpm" ]]; then
  if [[ "${DISTRO_FAMILY}" == "debian" ]]; then
    if [[ -x "${BUILD_SCRCPY_SERVER}" ]]; then
      echo "Building scrcpy-server..."
      rm -f "${REPO_DIR}/scrcpy/scrcpy-server"
      BUILD_DIR="${REPO_DIR}/deb/debbuild/build-scrcpy-server" \
      ANDROID_CACHE_DIR="${REPO_DIR}/deb/debbuild/android-sdk-cache" \
        "${BUILD_SCRCPY_SERVER}"
      cp "${REPO_DIR}/deb/debbuild/build-scrcpy-server/scrcpy-server" \
         "${REPO_DIR}/scrcpy/scrcpy-server"
    else
      >&2 echo "Warning: scrcpy/scrcpy-server missing and ${BUILD_SCRCPY_SERVER} not found; skipping ika-scrcpy"
    fi
  fi
  if [[ "${DISTRO_FAMILY}" == "arch" || -f "${REPO_DIR}/scrcpy/scrcpy-server" ]]; then
    echo "Building ika-scrcpy..."
    "${BUILD_PACKAGE}" "$@" "${REPO_DIR}/tools/scrcpy"
  fi
fi

# Build ika-lineageos outside the RPM flow if the prebuilt bundle exists.
# On RPM this is handled automatically: build_package.sh iterates all *.spec
# files in base/rpm/, including cuttlefish-lineageos.spec.
if [[ "${DISTRO_FAMILY}" != "rpm" ]]; then
  _lineageos_arch="$(ika_arch_for_host 2>/dev/null || true)"
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
  arch)   organize_archpkgs ;;
esac

print_built_packages "${PACKAGE_OUTPUT_DIR}"
