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
readonly RPMBUILD_TOPDIR="${REPO_DIR}/rpmbuild"
readonly RPMBUILD_WORK_ROOT="${RPMBUILD_TOPDIR}/work"
readonly TAR_BASENAME="android-cuttlefish-${VERSION}"
readonly SOURCE_TARBALL="${RPMBUILD_TOPDIR}/SOURCES/${TAR_BASENAME}.tar.gz"
readonly SOURCE_MANIFEST="${RPMBUILD_TOPDIR}/SOURCES/${TAR_BASENAME}.manifest"
readonly SOURCE_STAGING_DIR="${RPMBUILD_TOPDIR}/SOURCES/${TAR_BASENAME}"
declare -a build_workdirs=()
readonly HOST_RPM_ARCH="$(rpm --eval '%{_arch}')"

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

function ika_arch_for_host() {
  case "$(uname -m)" in
    aarch64) printf 'arm64' ;;
    x86_64)  printf 'x86_64' ;;
    *)       return 1 ;;
  esac
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

function build_source_manifest() {
  local manifest_path="$1"

  # The lineageos-<host_arch>/ bundle is an input to the cuttlefish-lineageos
  # RPM; the bundle for the other arch is irrelevant to this host and is
  # excluded so a fresh ROM build for one arch does not invalidate the cached
  # source tarball used by the other specs.
  local host_arch other_arch
  if ! host_arch="$(ika_arch_for_host)"; then
    host_arch=''
  fi
  case "${host_arch}" in
    arm64)  other_arch=x86_64 ;;
    x86_64) other_arch=arm64 ;;
    *)      other_arch='' ;;
  esac

  local -a prunes=(
    -path ./.git
    -o -path ./.jj
    -o -path ./rpmbuild
    -o -path ./build-scrcpy-server
    -o -path ./android-sdk-cache
    -o -path ./toolchain
    -o -path ./base/cvd/bazel-out
    -o -name 'bazel-*'
  )
  if [[ -n "${other_arch}" ]]; then
    prunes+=(-o -path "./lineageos-${other_arch}")
  else
    prunes+=(-o -path ./lineageos-arm64 -o -path ./lineageos-x86_64)
  fi

  (
    # Cache key bumped when the staging-exclude set changes in a way that
    # affects tarball contents (e.g. fixing an unanchored exclude that
    # over-pruned base/cvd/toolchain). Bumping this line invalidates any
    # cached source tarball generated by an older buggy run.
    printf 'manifest-cache-version\t2\n'

    cd "${REPO_DIR}"
    find . \
      \( "${prunes[@]}" \) -prune -o \
      -print0 | sort -z | while IFS= read -r -d '' path; do
        local relpath="${path#./}"
        [[ -n "${relpath}" ]] || continue

        local mode
        mode="$(stat -c '%f' "${path}")"

        if [[ -d "${path}" ]]; then
          printf 'dir\t%s\t%s\n' "${relpath}" "${mode}"
        elif [[ -L "${path}" ]]; then
          printf 'symlink\t%s\t%s\t%s\n' "${relpath}" "${mode}" "$(readlink "${path}")"
        elif [[ -f "${path}" ]]; then
          printf 'file\t%s\t%s\t%s\n' "${relpath}" "${mode}" "$(sha256sum "${path}" | cut -d' ' -f1)"
        fi
      done
  ) > "${manifest_path}"
}

function refresh_source_tarball_if_needed() {
  local tmp_manifest
  local tmp_source_tarball
  tmp_manifest="$(mktemp "${RPMBUILD_TOPDIR}/SOURCES/${TAR_BASENAME}.manifest.XXXXXX")"
  tmp_source_tarball="$(mktemp "${RPMBUILD_TOPDIR}/SOURCES/${TAR_BASENAME}.tar.gz.XXXXXX")"
  trap 'rm -f "${tmp_manifest}" "${tmp_source_tarball}"' RETURN

  local scrcpy_server_dest="${REPO_DIR}/scrcpy/scrcpy-server"
  local scrcpy_server_build_helper="${REPO_DIR}/tools/build_scrcpy_server_aarch64.sh"
  local local_scrcpy_server="${REPO_DIR}/build-scrcpy-server/scrcpy-server"

  # Only prepare the scrcpy-server when the scrcpy spec is actually being built.
  local building_scrcpy=false
  local scrcpy_spec_path="${INPUT_PATH_ABS}/rpm/cuttlefish-scrcpy.spec"
  if [[ -f "${INPUT_PATH_ABS}" && "$(basename "${INPUT_PATH_ABS}" .spec)" == "cuttlefish-scrcpy" ]]; then
    if ! should_exclude_spec "${INPUT_PATH_ABS}" && spec_supports_host_arch "${INPUT_PATH_ABS}"; then
      building_scrcpy=true
    fi
  elif [[ -d "${INPUT_PATH_ABS}/rpm" && -f "${scrcpy_spec_path}" ]]; then
    if ! should_exclude_spec "${scrcpy_spec_path}" && spec_supports_host_arch "${scrcpy_spec_path}"; then
      building_scrcpy=true
    fi
  fi

  if [[ "${building_scrcpy}" == "true" ]]; then
    # Always refresh the packaged scrcpy-server before building the RPM so the
    # source tarball cannot silently reuse a stale server APK from a prior run.
    rm -f "${scrcpy_server_dest}"

    # Always rebuild scrcpy-server from the checked-in source so the packaged
    # client and device-side server stay in lockstep on every host arch.
    if [[ ! -x "${scrcpy_server_build_helper}" ]]; then
      >&2 echo "Missing scrcpy-server build helper: ${scrcpy_server_build_helper}"
      return 1
    fi

    echo "Building scrcpy-server locally for $(uname -m)"
    if ! BUILD_DIR="${REPO_DIR}/build-scrcpy-server" "${scrcpy_server_build_helper}"; then
      >&2 echo "Local scrcpy-server build failed."
      return 1
    fi

    if [[ ! -f "${local_scrcpy_server}" ]]; then
      >&2 echo "scrcpy-server build completed without producing ${local_scrcpy_server}"
      return 1
    fi

    install -m 0644 "${local_scrcpy_server}" "${scrcpy_server_dest}"
  fi

  build_source_manifest "${tmp_manifest}"

  if [[ -f "${SOURCE_TARBALL}" && -f "${SOURCE_MANIFEST}" ]] && cmp -s "${tmp_manifest}" "${SOURCE_MANIFEST}"; then
    if tar -tzf "${SOURCE_TARBALL}" >/dev/null 2>&1; then
      echo "Reusing source tarball ${SOURCE_TARBALL}"
      return
    fi

    echo "Discarding corrupt source tarball ${SOURCE_TARBALL}"
  fi

  rm -rf "${SOURCE_STAGING_DIR}" "${SOURCE_TARBALL}"
  mkdir -p "${SOURCE_STAGING_DIR}"

  local host_arch other_arch
  if ! host_arch="$(ika_arch_for_host)"; then
    host_arch=''
  fi
  case "${host_arch}" in
    arm64)  other_arch=x86_64 ;;
    x86_64) other_arch=arm64 ;;
    *)      other_arch='' ;;
  esac

  # Anchored to the source root (leading slash). Unanchored patterns like
  # 'toolchain/' would also strip base/cvd/toolchain/, which Bazel needs for
  # //toolchain:bazel.MODULE.bazel.
  local -a rsync_excludes=(
    --exclude='/.git/'
    --exclude='/.jj/'
    --exclude='/rpmbuild/'
    --exclude='/build-scrcpy-server/'
    --exclude='/android-sdk-cache/'
    --exclude='/toolchain/'
    --exclude='/base/cvd/bazel-out/'
    --exclude='/base/cvd/bazel-*/'
    --exclude='/bazel-*/'
  )
  if [[ -n "${other_arch}" ]]; then
    rsync_excludes+=(--exclude="/lineageos-${other_arch}/")
  else
    rsync_excludes+=(--exclude='/lineageos-arm64/' --exclude='/lineageos-x86_64/')
  fi

  rsync -a \
    "${rsync_excludes[@]}" \
    "${REPO_DIR}/" \
    "${SOURCE_STAGING_DIR}/"

  tar -czf "${tmp_source_tarball}" -C "${RPMBUILD_TOPDIR}/SOURCES" "${TAR_BASENAME}"
  mv "${tmp_source_tarball}" "${SOURCE_TARBALL}"
  mv "${tmp_manifest}" "${SOURCE_MANIFEST}"
  rm -rf "${SOURCE_STAGING_DIR}"
}

function cleanup_build_workdirs() {
  local workdir
  for workdir in "${build_workdirs[@]}"; do
    [[ -d "${workdir}" ]] || continue
    rm -rf "${workdir}" || true
  done
}

trap cleanup_build_workdirs EXIT

mkdir -p \
  "${RPMBUILD_TOPDIR}/BUILD" \
  "${RPMBUILD_TOPDIR}/BUILDROOT" \
  "${RPMBUILD_TOPDIR}/RPMS" \
  "${RPMBUILD_TOPDIR}/SOURCES" \
  "${RPMBUILD_TOPDIR}/SPECS" \
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

pushd "${pushd_args[0]}"
for spec in "${specs[@]}"; do
  if should_skip_spec_for_missing_sources "${spec}"; then
    echo "Skipping RPM build for $(basename "${spec}") because ${REPO_DIR}/lineageos-$(ika_arch_for_host 2>/dev/null || echo '?') is missing"
    continue
  fi
  spec_workdir="$(mktemp -d "${RPMBUILD_WORK_ROOT}/$(normalize_spec_name "${spec}").XXXXXX")"
  build_workdirs+=("${spec_workdir}")
  echo "Building RPM from ${spec}"
  rpmbuild \
    --define "_topdir ${RPMBUILD_TOPDIR}" \
    --define "_sourcedir ${RPMBUILD_TOPDIR}/SOURCES" \
    --define "_rpmdir ${RPMBUILD_TOPDIR}/RPMS" \
    --define "_builddir ${spec_workdir}/BUILD" \
    --define "_buildrootdir ${spec_workdir}/BUILDROOT" \
    -bb "${spec}"
done
popd

# Move *debuginfo* RPMs to debug subfolder after build
for arch_dir in "${RPMBUILD_TOPDIR}/RPMS"/*; do
  if [[ -d "$arch_dir" ]]; then
    mkdir -p "$arch_dir/debug"
    mv "$arch_dir"/*debuginfo*.rpm "$arch_dir/debug/" 2>/dev/null || true
    mv "$arch_dir"/ika-orchestration*.rpm "$arch_dir"/ika-metrics*.rpm "$arch_dir/debug/" 2>/dev/null || true
  fi
done
