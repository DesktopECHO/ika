#!/usr/bin/env bash

set -euo pipefail

readonly CROSVM_REMOTE_PRIMARY="https://chromium.googlesource.com/crosvm/crosvm"
readonly CROSVM_REMOTE_FALLBACK="https://github.com/google/crosvm.git"
readonly MINIJAIL_REMOTE_PRIMARY="https://chromium.googlesource.com/chromiumos/platform/minijail"
readonly MINIJAIL_REV="d2e47c2e9aaaa2b175162c31b6bb8976cc762e1a"
readonly MINIJAIL_REF="refs/heads/main"
readonly ANDROID_SYSTEM_CORE_REMOTE="https://android.googlesource.com/platform/system/core"
readonly ANDROID_SYSTEM_EXTRAS_REMOTE="https://android.googlesource.com/platform/system/extras"
readonly DEPOT_TOOLS_REMOTE_PRIMARY="https://chromium.googlesource.com/chromium/tools/depot_tools.git"
readonly DEPOT_TOOLS_REMOTE_ALIAS="https://chromium.googlesource.com/chromium/tools/depot_tools"

readonly DEFAULT_BAZEL_CACHE_ROOT="$HOME/ika-build/cuttlefish-bazel"
readonly MIRROR_ROOT="${CUTTLEFISH_BAZEL_GIT_MIRROR_ROOT:-${CUTTLEFISH_BAZEL_CACHE_ROOT:-$DEFAULT_BAZEL_CACHE_ROOT}/git-mirrors}"
readonly GIT_CONFIG_PATH="${CUTTLEFISH_BAZEL_GIT_CONFIG:-${CUTTLEFISH_BAZEL_CACHE_ROOT:-$DEFAULT_BAZEL_CACHE_ROOT}/gitconfig}"
readonly MAX_RETRIES="${CUTTLEFISH_BAZEL_GIT_MIRROR_RETRIES:-3}"
readonly RETRY_DELAY="${CUTTLEFISH_BAZEL_GIT_MIRROR_RETRY_DELAY:-10}"

git_clean() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c safe.bareRepository=all "$@"
}

retry_command() {
  local description="$1"
  shift

  if (( $# == 0 )); then
    echo "No command provided for ${description}." >&2
    return 1
  fi

  local retry_count="${MAX_RETRIES}"
  local retry_delay="${RETRY_DELAY}"
  local attempt=1
  [[ "${retry_count}" =~ ^[0-9]+$ && "${retry_count}" -gt 0 ]] || retry_count=3
  [[ "${retry_delay}" =~ ^[0-9]+$ && "${retry_delay}" -gt 0 ]] || retry_delay=10

  while true; do
    if "$@"; then
      return 0
    fi

    if [[ "${attempt}" -ge "${retry_count}" ]]; then
      echo "Failed to ${description} after ${attempt} attempts." >&2
      return 1
    fi

    echo "Failed to ${description}, retrying in ${retry_delay}s (${attempt}/${retry_count})..." >&2
    sleep "${retry_delay}"
    attempt=$((attempt + 1))
  done
}

ensure_remote_origin() {
  local repo_path="$1"
  local remote_url="$2"

  if git_clean -C "${repo_path}" remote get-url origin >/dev/null 2>&1; then
    git_clean -C "${repo_path}" remote set-url origin "${remote_url}"
  else
    git_clean -C "${repo_path}" remote add origin "${remote_url}"
  fi
}

fetch_mirror() {
  local repo_path="$1"

  git_clean -C "${repo_path}" fetch --prune origin \
    '+refs/heads/*:refs/heads/*' \
    '+refs/tags/*:refs/tags/*'
}

clone_mirror() {
  local remote_url="$1"
  local tmp_path="$2"

  rm -rf "${tmp_path}"
  git_clean clone --mirror "${remote_url}" "${tmp_path}"
}

configure_rewrite() {
  local mirror_path="$1"
  shift

  local remote_url=
  for remote_url in "$@"; do
    [[ -n "${remote_url}" ]] || continue
    git_clean config -f "${GIT_CONFIG_PATH}" --add "url.file://${mirror_path}.insteadof" "${remote_url}"
  done
}

ensure_mirror() {
  local mirror_name="$1"
  local primary_remote="$2"
  local fallback_remote="${3:-}"
  local mirror_path="${MIRROR_ROOT}/${mirror_name}.git"
  local tmp_path=
  local broken_path=

  mkdir -p "${MIRROR_ROOT}"

  if git_clean -C "${mirror_path}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Refreshing local ${mirror_name} git mirror at ${mirror_path}" >&2
    ensure_remote_origin "${mirror_path}" "${primary_remote}"
    if ! retry_command "refresh ${mirror_name} mirror from ${primary_remote}" fetch_mirror "${mirror_path}"; then
      if [[ -z "${fallback_remote}" ]]; then
        return 1
      fi

      echo "Primary ${mirror_name} remote failed, retrying with ${fallback_remote}" >&2
      ensure_remote_origin "${mirror_path}" "${fallback_remote}"
      if ! retry_command "refresh ${mirror_name} mirror from ${fallback_remote}" fetch_mirror "${mirror_path}"; then
        ensure_remote_origin "${mirror_path}" "${primary_remote}"
        return 1
      fi
      ensure_remote_origin "${mirror_path}" "${primary_remote}"
    fi
  else
    if [[ -e "${mirror_path}" ]]; then
      broken_path="${mirror_path}.broken.$(date +%s)"
      echo "Moving invalid ${mirror_name} mirror aside: ${mirror_path} -> ${broken_path}" >&2
      mv "${mirror_path}" "${broken_path}"
    fi

    tmp_path="${mirror_path}.tmp.$$"
    rm -rf "${tmp_path}"

    echo "Creating local ${mirror_name} git mirror at ${mirror_path}" >&2
    if ! retry_command "clone ${mirror_name} mirror from ${primary_remote}" \
      clone_mirror "${primary_remote}" "${tmp_path}"; then
      if [[ -z "${fallback_remote}" ]]; then
        rm -rf "${tmp_path}"
        return 1
      fi

      rm -rf "${tmp_path}"
      echo "Primary ${mirror_name} remote failed, retrying with ${fallback_remote}" >&2
      if ! retry_command "clone ${mirror_name} mirror from ${fallback_remote}" \
        clone_mirror "${fallback_remote}" "${tmp_path}"; then
        rm -rf "${tmp_path}"
        return 1
      fi
      ensure_remote_origin "${tmp_path}" "${primary_remote}"
    fi

    mv "${tmp_path}" "${mirror_path}"
  fi

  configure_rewrite "${mirror_path}" "${primary_remote}" "${fallback_remote}"
}

ensure_minijail_mirror() {
  local mirror_path="${MIRROR_ROOT}/minijail.git"
  local local_branch="refs/heads/ika-minijail-${MINIJAIL_REV:0:12}"

  mkdir -p "${MIRROR_ROOT}"

  if ! git_clean -C "${mirror_path}" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -e "${mirror_path}" ]]; then
      local broken_path="${mirror_path}.broken.$(date +%s)"
      echo "Moving invalid minijail mirror aside: ${mirror_path} -> ${broken_path}" >&2
      mv "${mirror_path}" "${broken_path}"
    fi

    echo "Creating local minijail git mirror at ${mirror_path}" >&2
    git_clean init --bare "${mirror_path}"
  fi

  ensure_remote_origin "${mirror_path}" "${MINIJAIL_REMOTE_PRIMARY}"

  if ! git_clean -C "${mirror_path}" cat-file -e "${MINIJAIL_REV}^{commit}" >/dev/null 2>&1; then
    echo "Fetching pinned minijail revision ${MINIJAIL_REV} into ${mirror_path}" >&2
    retry_command "fetch pinned minijail revision from ${MINIJAIL_REMOTE_PRIMARY}" \
      git_clean -C "${mirror_path}" fetch origin \
        "${MINIJAIL_REF}:${MINIJAIL_REF}"
  fi

  git_clean -C "${mirror_path}" update-ref "${local_branch}" "${MINIJAIL_REV}"
  configure_rewrite "${mirror_path}" \
    "${MINIJAIL_REMOTE_PRIMARY}" \
    "${MINIJAIL_REMOTE_PRIMARY}/"
}

main() {
  mkdir -p "$(dirname "${GIT_CONFIG_PATH}")"
  rm -f "${GIT_CONFIG_PATH}"

  ensure_mirror "crosvm" "${CROSVM_REMOTE_PRIMARY}" "${CROSVM_REMOTE_FALLBACK}"
  ensure_minijail_mirror
  ensure_mirror "depot_tools" "${DEPOT_TOOLS_REMOTE_PRIMARY}" "${DEPOT_TOOLS_REMOTE_ALIAS}"
  ensure_mirror "android_system_core" "${ANDROID_SYSTEM_CORE_REMOTE}"
  ensure_mirror "android_system_extras" "${ANDROID_SYSTEM_EXTRAS_REMOTE}"
}

main "$@"
