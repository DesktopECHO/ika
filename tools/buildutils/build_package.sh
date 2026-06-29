#!/usr/bin/env bash

# Copyright (C) 2025 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit -o nounset -o pipefail

# Shared distro detection + sudo-escalation helpers, also used by
# build_packages.sh.
_buildutils_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_buildutils_dir}/lib/common.sh"

function print_usage() {
  >&2 echo "usage: $0 [--exclude-spec NAME[.spec]]... /path/to/pkgdir"
  >&2 echo "   or: $0 [--exclude-spec NAME[.spec]]... /path/to/specfile.spec"
}

declare -a excluded_specs=()
input_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude-spec)
      [[ $# -ge 2 ]] || {
        >&2 echo "missing value for --exclude-spec"
        print_usage
        exit 1
      }
      excluded_specs+=("$2")
      shift 2
      ;;
    --exclude-spec=*)
      excluded_specs+=("${1#--exclude-spec=}")
      shift
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    --*)
      >&2 echo "unknown option: $1"
      print_usage
      exit 1
      ;;
    *)
      if [[ -n "${input_path}" ]]; then
        >&2 echo "unexpected extra argument: $1"
        print_usage
        exit 1
      fi
      input_path="$1"
      shift
      ;;
  esac
done

[[ -n "${input_path}" ]] || {
  >&2 echo "missing path to package directory"
  print_usage
  exit 1
}

readonly INPUT_PATH="${input_path}"
readonly INPUT_PATH_ABS="$(realpath "${INPUT_PATH}")"

readonly REPO_DIR="$(realpath "$(dirname "$0")/../..")"
readonly VERSION_FILE="${REPO_DIR}/packaging/VERSION"
readonly VERSION="$(tr -d '\n' < "${VERSION_FILE}")"
declare -a build_workdirs=()

function normalize_spec_name() {
  local spec_name="$1"
  spec_name="$(basename "${spec_name}")"
  spec_name="${spec_name%.spec}"
  printf '%s\n' "${spec_name}"
}

function should_exclude_spec() {
  local normalized_spec
  local excluded_spec

  normalized_spec="$(normalize_spec_name "$1")"
  for excluded_spec in "${excluded_specs[@]}"; do
    if [[ "${normalized_spec}" == "$(normalize_spec_name "${excluded_spec}")" ]]; then
      return 0
    fi
  done
  return 1
}

function spec_supports_host_arch() {
  local spec_path="$1"
  local exclusive_arches
  local excluded_arches
  local arch
  local matched

  exclusive_arches="$(rpmspec --srpm --query --qf '[%{EXCLUSIVEARCH} ]' "${spec_path}" 2>/dev/null || true)"
  excluded_arches="$(rpmspec --srpm --query --qf '[%{EXCLUDEARCH} ]' "${spec_path}" 2>/dev/null || true)"

  if [[ -n "${exclusive_arches}" && "${exclusive_arches}" != "(none)" ]]; then
    matched=false
    for arch in ${exclusive_arches}; do
      if [[ "${arch}" == "${HOST_RPM_ARCH}" ]]; then
        matched=true
        break
      fi
    done
    [[ "${matched}" == "true" ]] || return 1
  fi

  if [[ -n "${excluded_arches}" && "${excluded_arches}" != "(none)" ]]; then
    for arch in ${excluded_arches}; do
      if [[ "${arch}" == "${HOST_RPM_ARCH}" ]]; then
        return 1
      fi
    done
  fi

  return 0
}

# Canonical set of repo-relative paths excluded from the packaged source tree,
# one per line. Rendered two ways below — as find(1) -prune predicates for the
# manifest fingerprint and as rsync(1) --exclude patterns for staging — so the
# fingerprint and the staged tree can never disagree. Everything is anchored at
# the repo root; a trailing '*' globs the final path component (build symlinks
# like base/cvd/bazel-bin). Bump manifest-cache-version when this changes.
function source_tree_exclude_paths() {
  printf '%s\n' \
    .git .jj .cache .ccache out rpmbuild archbuild \
    build-scrcpy-server android-sdk-cache \
    lineageos/src toolchain \
    base/cvd/bazel-out 'base/cvd/bazel-*' 'bazel-*'

  if [[ "${DISTRO_FAMILY:-}" == "rpm" ]]; then
    # RPM ships the ROM through cuttlefish-lineageos.spec's own Source1 tarball
    # (see refresh_rom_tarball_if_needed), so both bundles stay out of the
    # shared host-source tarball. That keeps it tiny: base/frontend/scrcpy then
    # unpack a few MB instead of 2+ GB they never use, and editing host source
    # no longer re-tars the multi-GB ROM.
    printf '%s\n' lineageos-arm64 lineageos-x86_64
  else
    # Other families bundle this host's lineageos-<arch> ROM into the shared
    # tarball; drop only the other arch's so a one-arch ROM rebuild does not
    # invalidate the cached tarball used by the other specs.
    local other_arch
    if other_arch="$(other_ika_arch)"; then
      printf 'lineageos-%s\n' "${other_arch}"
    else
      printf '%s\n' lineageos-arm64 lineageos-x86_64
    fi
  fi
}

# Populate the named array with a find(1) prune expression built from
# source_tree_exclude_paths (-path ./A -o -path ./B ...).
function source_tree_find_prune_args() {
  local -n prune_ref="$1"
  local path
  local first=1

  prune_ref=()
  while IFS= read -r path; do
    if (( first )); then
      first=0
    else
      prune_ref+=(-o)
    fi
    prune_ref+=(-path "./${path}")
  done < <(source_tree_exclude_paths)
}

# Populate the named array with rsync(1) --exclude args built from
# source_tree_exclude_paths (--exclude=/A/ --exclude=/B/ ...).
function source_tree_rsync_exclude_args() {
  local -n exclude_ref="$1"
  local path

  exclude_ref=()
  while IFS= read -r path; do
    exclude_ref+=("--exclude=/${path}/")
  done < <(source_tree_exclude_paths)
}

function should_skip_spec_for_missing_sources() {
  local spec_path="$1"
  local spec_name
  spec_name="$(normalize_spec_name "${spec_path}")"
  if [[ "${spec_name}" == "cuttlefish-lineageos" ]]; then
    local host_arch
    host_arch="$(ika_arch_for_host)" || return 0
    [[ -d "${REPO_DIR}/lineageos-${host_arch}" ]] || return 0
  fi
  return 1
}

function thin_provision_images_tool() {
  local tool="${REPO_DIR}/tools/lineageos/thin-provision-images.sh"
  [[ -x "${tool}" ]] || {
    >&2 echo "missing executable image thin-provisioning helper: ${tool}"
    exit 1
  }
  printf '%s\n' "${tool}"
}

function thin_provision_rom_bundle_if_present() {
  local arch="$1"
  local rom_dir="${REPO_DIR}/lineageos-${arch}"
  [[ -d "${rom_dir}" ]] || return 0

  "$(thin_provision_images_tool)" "${rom_dir}"
}

function thin_provision_source_rom_bundle_if_needed() {
  [[ "${DISTRO_FAMILY:-}" != "rpm" ]] || return 0

  local host_arch
  host_arch="$(ika_arch_for_host)" || return 0
  thin_provision_rom_bundle_if_present "${host_arch}"
}

# Emit a content fingerprint for a subtree of the repo, one record per path.
# Files are fingerprinted by mode+size+mtime rather than a content hash so the
# cache check stays cheap even over the multi-GB ROM bundle (sha256 of every
# file made every rebuild stat the whole tree *and* re-read 2+ GB of images).
# $1 manifest path, $2 find(1) root (repo-relative, e.g. "." or "./lineageos-x86_64"),
# $3 (optional) name of an array of find(1) prune predicates.
function build_tree_manifest() {
  local manifest_path="$1"
  local find_root="$2"
  local prune_name="${3:-}"

  # Bind the caller's prune-predicate array via a nameref with an unlikely name.
  # A local also named "prunes" here would shadow the caller's array, making the
  # nameref resolve to the empty local and silently dropping every -prune
  # predicate (find would then walk the entire repo, including lineageos/src).
  if [[ -n "${prune_name}" ]]; then
    local -n _btm_prune_args="${prune_name}"
  fi

  (
    # Cache key embedded as the manifest's first line. Bump it whenever the
    # record format or the exclude set changes in a way that affects tarball
    # contents, to invalidate any tarball cached by an older run.
    printf 'manifest-cache-version\t10\n'

    cd "${REPO_DIR}"
    if [[ -n "${prune_name}" ]]; then
      find "${find_root}" \( "${_btm_prune_args[@]}" \) -prune -o -print0
    else
      find "${find_root}" -print0
    fi | sort -z | while IFS= read -r -d '' path; do
        local relpath="${path#./}"
        [[ -n "${relpath}" ]] || continue

        local meta
        meta="$(stat -c '%f %s %Y' "${path}")"

        if [[ -L "${path}" ]]; then
          printf 'symlink\t%s\t%s\t%s\n' "${relpath}" "${meta}" "$(readlink "${path}")"
        elif [[ -d "${path}" ]]; then
          printf 'dir\t%s\t%s\n' "${relpath}" "${meta}"
        elif [[ -f "${path}" ]]; then
          printf 'file\t%s\t%s\n' "${relpath}" "${meta}"
        fi
      done
  ) > "${manifest_path}"
}

function build_source_manifest() {
  local manifest_path="$1"
  local -a prunes
  source_tree_find_prune_args prunes
  build_tree_manifest "${manifest_path}" "." prunes
}

function source_tarball_has_required_files() {
  local tarball="$1"
  local tar_basename="$2"
  local tar_index
  local required_file

  tar_index="$(mktemp "${PKG_SOURCES_DIR}/${tar_basename}.tar.index.XXXXXX")"
  if ! tar -tzf "${tarball}" >"${tar_index}"; then
    rm -f "${tar_index}"
    return 1
  fi

  for required_file in \
    "base/cvd/adb/BUILD.bazel" \
    "base/cvd/tools/ensure_bazel_git_mirrors.sh" \
    "base/cvd/tools/ensure_crosvm_git_mirror.sh"
  do
    if ! grep -Fxq "${tar_basename}/${required_file}" "${tar_index}"; then
      echo "Discarding incomplete source tarball ${tarball}: missing ${required_file}"
      rm -f "${tar_index}"
      return 1
    fi
  done

  rm -f "${tar_index}"
  return 0
}

function refresh_source_tarball_if_needed() {
  local tmp_manifest
  local tmp_source_tarball
  thin_provision_source_rom_bundle_if_needed

  tmp_manifest="$(mktemp "${PKG_SOURCES_DIR}/${TAR_BASENAME}.manifest.XXXXXX")"
  tmp_source_tarball="$(mktemp "${PKG_SOURCES_DIR}/${TAR_BASENAME}.tar.gz.XXXXXX")"
  trap 'rm -f "${tmp_manifest}" "${tmp_source_tarball}"' RETURN

  local scrcpy_server_dest="${REPO_DIR}/scrcpy/scrcpy-server"
  local scrcpy_server_build_helper="${REPO_DIR}/tools/buildutils/build_scrcpy_server.sh"
  local local_scrcpy_server="${HOME}/ika-build/build-scrcpy-server/scrcpy-server"

  # The scrcpy viewer is folded into ika-base, which compiles it from a prebuilt
  # scrcpy-server APK bundled in the source tarball. Build/refresh the server
  # when packaging the base spec (RPM) or the base/ tree (Arch).
  local building_scrcpy=false
  if [[ "${DISTRO_FAMILY:-}" == "rpm" ]]; then
    local base_spec_path="${INPUT_PATH_ABS}/rpm/cuttlefish-base.spec"
    if [[ -f "${INPUT_PATH_ABS}" && "$(basename "${INPUT_PATH_ABS}" .spec)" == "cuttlefish-base" ]]; then
      if ! should_exclude_spec "${INPUT_PATH_ABS}" && spec_supports_host_arch "${INPUT_PATH_ABS}"; then
        building_scrcpy=true
      fi
    elif [[ -d "${INPUT_PATH_ABS}/rpm" && -f "${base_spec_path}" ]]; then
      if ! should_exclude_spec "${base_spec_path}" && spec_supports_host_arch "${base_spec_path}"; then
        building_scrcpy=true
      fi
    fi
  elif [[ "${DISTRO_FAMILY:-}" == "arch" ]]; then
    if [[ "${INPUT_PATH_ABS}" == "${REPO_DIR}/base" ]]; then
      building_scrcpy=true
    fi
  fi

  if [[ "${building_scrcpy}" == "true" ]]; then
    # Always refresh the packaged scrcpy-server before building the package so the
    # source tarball cannot silently reuse a stale server APK from a prior run.
    rm -f "${scrcpy_server_dest}"

    # Always rebuild scrcpy-server from the checked-in source so the packaged
    # client and device-side server stay in lockstep on every host arch.
    if [[ ! -x "${scrcpy_server_build_helper}" ]]; then
      >&2 echo "Missing scrcpy-server build helper: ${scrcpy_server_build_helper}"
      return 1
    fi

    echo "Building scrcpy-server locally for $(uname -m)"
    if ! BUILD_DIR="${HOME}/ika-build/build-scrcpy-server" \
        ANDROID_CACHE_DIR="${HOME}/ika-build/android-sdk-cache" \
        "${scrcpy_server_build_helper}"; then
      >&2 echo "Local scrcpy-server build failed."
      return 1
    fi

    if [[ ! -f "${local_scrcpy_server}" ]]; then
      >&2 echo "scrcpy-server build completed without producing ${local_scrcpy_server}"
      return 1
    fi

    install -m 0644 "${local_scrcpy_server}" "${scrcpy_server_dest}"
  fi

  echo "Fingerprinting source tree to check the cached tarball..."
  build_source_manifest "${tmp_manifest}"

  if [[ -f "${SOURCE_TARBALL}" && -f "${SOURCE_MANIFEST}" ]] && cmp -s "${tmp_manifest}" "${SOURCE_MANIFEST}"; then
    if source_tarball_has_required_files "${SOURCE_TARBALL}" "${TAR_BASENAME}"; then
      echo "Reusing source tarball ${SOURCE_TARBALL}"
      return
    fi

    echo "Regenerating source tarball ${SOURCE_TARBALL}"
  fi

  echo "Source changed; staging and compressing the source tarball (this can take a few minutes)..."
  rm -rf "${SOURCE_STAGING_DIR}" "${SOURCE_TARBALL}"
  mkdir -p "${SOURCE_STAGING_DIR}"

  local -a rsync_excludes
  source_tree_rsync_exclude_args rsync_excludes

  rsync -a \
    "${rsync_excludes[@]}" \
    "${REPO_DIR}/" \
    "${SOURCE_STAGING_DIR}/"

  tar --sparse -cf - -C "${PKG_SOURCES_DIR}" "${TAR_BASENAME}" | pigz >"${tmp_source_tarball}"
  mv "${tmp_source_tarball}" "${SOURCE_TARBALL}"
  mv "${tmp_manifest}" "${SOURCE_MANIFEST}"
  rm -rf "${SOURCE_STAGING_DIR}"
}

# Stage the per-arch LineageOS ROM bundle into its own tarball, consumed only by
# cuttlefish-lineageos.spec (Source1). Kept separate from the shared host-source
# tarball so base/frontend/scrcpy don't unpack 2+ GB they never use. Written
# uncompressed: the ROM is almost entirely already-compressed images (super.img,
# boot images), so gzip costs minutes of CPU for a negligible size reduction.
# Cached on a mode+size+mtime fingerprint, so it is rewritten only when the ROM
# actually changes (a host-source edit no longer touches it).
function refresh_rom_tarball_if_needed() {
  local arch="$1"
  local rom_dir="${REPO_DIR}/lineageos-${arch}"
  [[ -d "${rom_dir}" ]] || return 0
  thin_provision_rom_bundle_if_present "${arch}"

  local rom_basename="android-cuttlefish-rom-${arch}-${VERSION}"
  local rom_tarball="${PKG_SOURCES_DIR}/${rom_basename}.tar"
  local rom_manifest="${PKG_SOURCES_DIR}/${rom_basename}.manifest"

  local tmp_manifest tmp_tarball
  tmp_manifest="$(mktemp "${PKG_SOURCES_DIR}/${rom_basename}.manifest.XXXXXX")"
  tmp_tarball="$(mktemp "${PKG_SOURCES_DIR}/${rom_basename}.tar.XXXXXX")"
  trap 'rm -f "${tmp_manifest}" "${tmp_tarball}"' RETURN

  echo "Fingerprinting the ${arch} ROM bundle to check the cached tarball..."
  build_tree_manifest "${tmp_manifest}" "./lineageos-${arch}"

  if [[ -f "${rom_tarball}" && -f "${rom_manifest}" ]] && cmp -s "${tmp_manifest}" "${rom_manifest}"; then
    if tar -tf "${rom_tarball}" >/dev/null 2>&1; then
      echo "Reusing ${arch} ROM tarball ${rom_tarball}"
      return
    fi
    echo "Discarding corrupt ROM tarball ${rom_tarball}"
  fi

  echo "ROM bundle changed; writing ${arch} ROM tarball (uncompressed, this can take a minute)..."
  rm -f "${rom_tarball}"
  tar --sparse -cf "${tmp_tarball}" -C "${REPO_DIR}" "lineageos-${arch}"
  mv "${tmp_tarball}" "${rom_tarball}"
  mv "${tmp_manifest}" "${rom_manifest}"
}

function cleanup_build_workdirs() {
  local workdir
  for workdir in "${build_workdirs[@]}"; do
    [[ -d "${workdir}" ]] || continue
    rm -rf "${workdir}" || true
  done
}

function rpm_spec_workdir() {
  local spec_path="$1"
  local spec_name
  local workdir

  spec_name="$(normalize_spec_name "${spec_path}")"
  workdir="${RPMBUILD_WORK_ROOT}/${spec_name}"

  # Keep the rpmbuild path stable so Bazel's output_base, which is derived from
  # the workspace path, is reused across RPM package builds. The extracted
  # source/buildroot are still cleaned for each rpmbuild invocation.
  rm -rf "${workdir}/BUILD" "${workdir}/BUILDROOT"
  mkdir -p "${workdir}"
  printf '%s\n' "${workdir}"
}

function arch_pkg_workdir() {
  local pkg_path="$1"
  local pkg_name
  local workdir

  pkg_name="$(basename "${pkg_path}")"
  workdir="${ARCHBUILD_WORK_ROOT}/${pkg_name}"

  # Keep makepkg's workspace path stable for the same reason as RPM: Bazel's
  # output_base is derived from the workspace path. Clean the transient package
  # workspace each invocation while reusing the same absolute path.
  rm -rf "${workdir}"
  mkdir -p "${workdir}"
  printf '%s\n' "${workdir}"
}

trap cleanup_build_workdirs EXIT

readonly DISTRO_FAMILY="$(detect_distro_family)"

refuse_root_build

if [[ "${DISTRO_FAMILY}" == "rpm" ]]; then
  readonly RPMBUILD_TOPDIR="${REPO_DIR}/rpmbuild"
  readonly RPMBUILD_WORK_ROOT="${RPMBUILD_TOPDIR}/work"
  readonly PKG_SOURCES_DIR="${RPMBUILD_TOPDIR}/SOURCES"
  readonly TAR_BASENAME="android-cuttlefish-${VERSION}"
  readonly SOURCE_TARBALL="${PKG_SOURCES_DIR}/${TAR_BASENAME}.tar.gz"
  readonly SOURCE_MANIFEST="${PKG_SOURCES_DIR}/${TAR_BASENAME}.manifest"
  readonly SOURCE_STAGING_DIR="${PKG_SOURCES_DIR}/${TAR_BASENAME}"
  readonly HOST_RPM_ARCH="$(rpm --eval '%{_arch}')"

  # Compress RPM payloads with zstd across all cores. Keeps rpm's default level
  # 19 (same RPM size) but parallelizes the otherwise single-threaded payload
  # compression, which dominates packaging time for the multi-GB ika-lineageos
  # RPM. An explicit thread count is used rather than T0: in libzstd nbWorkers=0
  # means single-threaded, and rpm's handling of T0 is version-dependent.
  readonly RPM_BINARY_PAYLOAD="w19T$(nproc 2>/dev/null || echo 1).zstdio"

  mkdir -p \
    "${RPMBUILD_TOPDIR}/BUILD" \
    "${RPMBUILD_TOPDIR}/BUILDROOT" \
    "${RPMBUILD_TOPDIR}/RPMS" \
    "${RPMBUILD_TOPDIR}/SOURCES" \
    "${RPMBUILD_TOPDIR}/SPECS" \
    "${RPMBUILD_TOPDIR}/SRPMS" \
    "${RPMBUILD_WORK_ROOT}"

  refresh_source_tarball_if_needed

  declare -a specs
  declare -a pushd_args

  if [[ -f "${INPUT_PATH_ABS}" && "${INPUT_PATH_ABS}" == *.spec ]]; then
    if should_exclude_spec "${INPUT_PATH_ABS}"; then
      echo "Skipping excluded spec $(basename "${INPUT_PATH_ABS}")"
      exit 0
    fi
    if ! spec_supports_host_arch "${INPUT_PATH_ABS}"; then
      echo "Skipping spec $(basename "${INPUT_PATH_ABS}") on ${HOST_RPM_ARCH}: unsupported by ExclusiveArch/ExcludeArch"
      exit 0
    fi
    specs=("${INPUT_PATH_ABS}")
    pushd_args=("$(dirname "${specs[0]}")")
  elif [[ -d "${INPUT_PATH_ABS}/rpm" ]]; then
    specs=("${INPUT_PATH_ABS}"/rpm/*.spec)
    if [[ ${#specs[@]} -eq 0 ]]; then
      >&2 echo "no spec files found under ${INPUT_PATH_ABS}/rpm"
      exit 1
    fi
    declare -a filtered_specs=()
    for spec in "${specs[@]}"; do
      if should_exclude_spec "${spec}"; then
        echo "Skipping excluded spec $(basename "${spec}")"
        continue
      fi
      if ! spec_supports_host_arch "${spec}"; then
        echo "Skipping spec $(basename "${spec}") on ${HOST_RPM_ARCH}: unsupported by ExclusiveArch/ExcludeArch"
        continue
      fi
      filtered_specs+=("${spec}")
    done
    specs=("${filtered_specs[@]}")
    if [[ ${#specs[@]} -eq 0 ]]; then
      echo "No RPM specs left to build under ${INPUT_PATH_ABS}/rpm after exclusions"
      exit 0
    fi
    pushd_args=("${INPUT_PATH_ABS}")
  else
    >&2 echo "missing rpm directory under ${INPUT_PATH_ABS}, or input is not a .spec file"
    exit 1
  fi

  # cuttlefish-lineageos.spec pulls the ROM from its own Source1 tarball; build
  # it (host arch only) before rpmbuild parses that spec. refresh_rom_tarball
  # no-ops when the bundle is absent, matching should_skip_spec_for_missing_sources.
  for spec in "${specs[@]}"; do
    if [[ "$(normalize_spec_name "${spec}")" == "cuttlefish-lineageos" ]]; then
      if rom_arch="$(ika_arch_for_host)"; then
        refresh_rom_tarball_if_needed "${rom_arch}"
      fi
      break
    fi
  done

  pushd "${pushd_args[0]}"
  for spec in "${specs[@]}"; do
    if should_skip_spec_for_missing_sources "${spec}"; then
      spec_basename="$(basename "${spec}")"
      host_arch="$(ika_arch_for_host 2>/dev/null || echo '?')"
      echo "Skipping RPM build for ${spec_basename} because ${REPO_DIR}/lineageos-${host_arch} is missing"
      continue
    fi
    spec_workdir="$(rpm_spec_workdir "${spec}")"
    build_workdirs+=("${spec_workdir}")
    echo "Building RPM from ${spec}"
    rpmbuild --quiet \
      --define "_topdir ${RPMBUILD_TOPDIR}" \
      --define "_sourcedir ${RPMBUILD_TOPDIR}/SOURCES" \
      --define "_rpmdir ${RPMBUILD_TOPDIR}/RPMS" \
      --define "_srcrpmdir ${RPMBUILD_TOPDIR}/SRPMS" \
      --define "_builddir ${spec_workdir}/BUILD" \
      --define "_buildrootdir ${spec_workdir}/BUILDROOT" \
      --define "_binary_payload ${RPM_BINARY_PAYLOAD}" \
      -bb "${spec}"
  done
  popd

elif [[ "${DISTRO_FAMILY}" == "debian" ]]; then
  if [[ ! -d "${INPUT_PATH_ABS}/debian" ]]; then
    >&2 echo "missing debian/ directory under ${INPUT_PATH_ABS}"
    exit 1
  fi

  # Prepend /usr/local/bin so Bazelisk installed there is found before any
  # system bazel package.
  export PATH="/usr/local/bin:${PATH}"

  echo "Building Debian packages from ${INPUT_PATH_ABS}"
  (
    cd "${INPUT_PATH_ABS}"
    dpkg-buildpackage -us -uc -b -d
  )

  parent_dir="$(dirname "${INPUT_PATH_ABS}")"
  deb_out="${REPO_DIR}/deb"
  mkdir -p "${deb_out}"
  for f in "${parent_dir}"/*.deb "${parent_dir}"/*.buildinfo "${parent_dir}"/*.changes; do
    [[ -f "${f}" ]] || continue
    mv -f -- "${f}" "${deb_out}/"
  done

elif [[ "${DISTRO_FAMILY}" == "arch" ]]; then
  if [[ ! -f "${INPUT_PATH_ABS}/arch/PKGBUILD" ]]; then
    >&2 echo "missing arch/PKGBUILD under ${INPUT_PATH_ABS}"
    exit 1
  fi

  readonly ARCHBUILD_TOPDIR="${REPO_DIR}/archbuild"
  readonly ARCHBUILD_WORK_ROOT="${ARCHBUILD_TOPDIR}/work"
  readonly ARCHBUILD_PKGDEST="${ARCHBUILD_TOPDIR}/packages"
  readonly PKG_SOURCES_DIR="${ARCHBUILD_TOPDIR}/SOURCES"
  readonly TAR_BASENAME="android-cuttlefish-${VERSION}"
  readonly SOURCE_TARBALL="${PKG_SOURCES_DIR}/${TAR_BASENAME}.tar.gz"
  readonly SOURCE_MANIFEST="${PKG_SOURCES_DIR}/${TAR_BASENAME}.manifest"
  readonly SOURCE_STAGING_DIR="${PKG_SOURCES_DIR}/${TAR_BASENAME}"
  readonly HOST_RPM_ARCH="$(uname -m)"

  mkdir -p \
    "${ARCHBUILD_WORK_ROOT}" \
    "${ARCHBUILD_PKGDEST}" \
    "${PKG_SOURCES_DIR}"

  refresh_source_tarball_if_needed

  # Prepend /usr/local/bin so Bazelisk installed there is found before any
  # system bazel package.
  export PATH="/usr/local/bin:${PATH}"

  pkg_workdir="$(arch_pkg_workdir "${INPUT_PATH_ABS}")"
  build_workdirs+=("${pkg_workdir}")
  cp -a "${INPUT_PATH_ABS}/arch/." "${pkg_workdir}/"
  ln -sfn "${SOURCE_TARBALL}" "${pkg_workdir}/${TAR_BASENAME}.tar.gz"

  echo "Building packages from ${INPUT_PATH_ABS}/arch"
  (
    cd "${pkg_workdir}"
    PKGDEST="${ARCHBUILD_PKGDEST}" makepkg --force
  )

else
  >&2 echo "unsupported distro family: ${DISTRO_FAMILY}"
  exit 1
fi
