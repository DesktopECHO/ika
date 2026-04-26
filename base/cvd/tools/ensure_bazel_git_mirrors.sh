#!/usr/bin/env bash

set -euo pipefail

readonly CROSVM_REMOTE_PRIMARY="https://chromium.googlesource.com/crosvm/crosvm"
readonly CROSVM_REMOTE_FALLBACK="https://github.com/google/crosvm.git"
readonly ANDROID_SYSTEM_CORE_REMOTE="https://android.googlesource.com/platform/system/core"
readonly ANDROID_SYSTEM_EXTRAS_REMOTE="https://android.googlesource.com/platform/system/extras"

readonly MIRROR_ROOT="${CUTTLEFISH_BAZEL_GIT_MIRROR_ROOT:-${CUTTLEFISH_BAZEL_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/cuttlefish-bazel}/git-mirrors}"
readonly GIT_CONFIG_PATH="${CUTTLEFISH_BAZEL_GIT_CONFIG:-${CUTTLEFISH_BAZEL_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/cuttlefish-bazel}/gitconfig}"
readonly MAX_RETRIES="${CUTTLEFISH_BAZEL_GIT_MIRROR_RETRIES:-3}"
readonly RETRY_DELAY="${CUTTLEFISH_BAZEL_GIT_MIRROR_RETRY_DELAY:-10}"

git_clean() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"
}

retry_command() {
  local description="$1"
  shift

  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi

    if [[ "${attempt}" -ge "${MAX_RETRIES}" ]]; then
      echo "Failed to ${description} after ${attempt} attempts." >&2
      return 1
    fi

    echo "Failed to ${description}, retrying in ${RETRY_DELAY}s (${attempt}/${MAX_RETRIES})..." >&2
    sleep "${RETRY_DELAY}"
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

  if git -C "${mirror_path}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Refreshing local ${mirror_name} git mirror at ${mirror_path}" >&2
    ensure_remote_origin "${mirror_path}" "${primary_remote}"
    if ! retry_command "refresh ${mirror_name} mirror from ${primary_remote}" fetch_mirror "${mirror_path}"; then
      if [[ -z "${fallback_remote}" ]]; then
        return 1
      fi

      echo "Primary ${mirror_name} remote failed, retrying with ${fallback_remote}" >&2
      ensure_remote_origin "${mirror_path}" "${fallback_remote}"
      retry_command "refresh ${mirror_name} mirror from ${fallback_remote}" fetch_mirror "${mirror_path}"
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
      git_clean clone --mirror "${primary_remote}" "${tmp_path}"; then
      if [[ -z "${fallback_remote}" ]]; then
        rm -rf "${tmp_path}"
        return 1
      fi

      rm -rf "${tmp_path}"
      echo "Primary ${mirror_name} remote failed, retrying with ${fallback_remote}" >&2
      retry_command "clone ${mirror_name} mirror from ${fallback_remote}" \
        git_clean clone --mirror "${fallback_remote}" "${tmp_path}"
      ensure_remote_origin "${tmp_path}" "${primary_remote}"
    fi

    mv "${tmp_path}" "${mirror_path}"
  fi

  configure_rewrite "${mirror_path}" "${primary_remote}" "${fallback_remote}"
}

main() {
  mkdir -p "$(dirname "${GIT_CONFIG_PATH}")"
  rm -f "${GIT_CONFIG_PATH}"

  ensure_mirror "crosvm" "${CROSVM_REMOTE_PRIMARY}" "${CROSVM_REMOTE_FALLBACK}"
  ensure_mirror "android_system_core" "${ANDROID_SYSTEM_CORE_REMOTE}"
  ensure_mirror "android_system_extras" "${ANDROID_SYSTEM_EXTRAS_REMOTE}"
}

main "$@"
