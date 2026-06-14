#!/usr/bin/env bash

set -euo pipefail

readonly CROSVM_REMOTE_PRIMARY="https://chromium.googlesource.com/crosvm/crosvm"
readonly CROSVM_REMOTE_FALLBACK="https://github.com/google/crosvm.git"
readonly MAX_RETRIES="${CUTTLEFISH_CROSVM_GIT_MIRROR_RETRIES:-3}"
readonly RETRY_DELAY="${CUTTLEFISH_CROSVM_GIT_MIRROR_RETRY_DELAY:-10}"

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

find_crosvm_mirror_path() {
  local config_line=
  local key=
  local value=
  local mirror_url=

  while IFS= read -r config_line; do
    [[ -n "${config_line}" ]] || continue
    key="${config_line%% *}"
    value="${config_line#* }"
    case "${value}" in
      "${CROSVM_REMOTE_PRIMARY}"|"${CROSVM_REMOTE_FALLBACK}")
        mirror_url="${key#url.}"
        mirror_url="${mirror_url%.insteadof}"
        case "${mirror_url}" in
          file://*)
            printf '%s\n' "${mirror_url#file://}"
            return 0
            ;;
        esac
        ;;
    esac
  done < <(git config --global --get-regexp '^url\..*\.insteadof$' 2>/dev/null || true)

  return 1
}

ensure_remote_origin() {
  local repo_path="$1"

  if git_clean -C "${repo_path}" remote get-url origin >/dev/null 2>&1; then
    git_clean -C "${repo_path}" remote set-url origin "${CROSVM_REMOTE_PRIMARY}"
  else
    git_clean -C "${repo_path}" remote add origin "${CROSVM_REMOTE_PRIMARY}"
  fi
}

clone_mirror() {
  local remote="$1"
  local tmp_path="$2"

  rm -rf "${tmp_path}"
  git_clean clone --mirror "${remote}" "${tmp_path}"
}

main() {
  local mirror_path=
  local mirror_parent=
  local tmp_path=
  local broken_path=

  if ! mirror_path="$(find_crosvm_mirror_path)"; then
    exit 0
  fi

  mirror_parent="$(dirname "${mirror_path}")"
  mkdir -p "${mirror_parent}"

  if git_clean -C "${mirror_path}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Refreshing local crosvm git mirror at ${mirror_path}" >&2
    ensure_remote_origin "${mirror_path}"
    retry_command "refresh crosvm mirror from ${CROSVM_REMOTE_PRIMARY}" \
      git_clean -C "${mirror_path}" fetch --prune origin \
      '+refs/heads/*:refs/heads/*' \
      '+refs/tags/*:refs/tags/*' || {
        echo "Primary crosvm remote failed, retrying with ${CROSVM_REMOTE_FALLBACK}" >&2
        git_clean -C "${mirror_path}" remote set-url origin "${CROSVM_REMOTE_FALLBACK}"
        if ! retry_command "refresh crosvm mirror from ${CROSVM_REMOTE_FALLBACK}" \
          git_clean -C "${mirror_path}" fetch --prune origin \
          '+refs/heads/*:refs/heads/*' \
          '+refs/tags/*:refs/tags/*'; then
          ensure_remote_origin "${mirror_path}"
          return 1
        fi
        ensure_remote_origin "${mirror_path}"
      }
    exit 0
  fi

  if [[ -e "${mirror_path}" ]]; then
    broken_path="${mirror_path}.broken.$(date +%s)"
    echo "Moving invalid crosvm mirror aside: ${mirror_path} -> ${broken_path}" >&2
    mv "${mirror_path}" "${broken_path}"
  fi

  tmp_path="${mirror_path}.tmp.$$"
  rm -rf "${tmp_path}"

  echo "Creating local crosvm git mirror at ${mirror_path}" >&2
  retry_command "clone crosvm mirror from ${CROSVM_REMOTE_PRIMARY}" \
    clone_mirror "${CROSVM_REMOTE_PRIMARY}" "${tmp_path}" || {
    rm -rf "${tmp_path}"
    echo "Primary crosvm remote failed, retrying with ${CROSVM_REMOTE_FALLBACK}" >&2
    if ! retry_command "clone crosvm mirror from ${CROSVM_REMOTE_FALLBACK}" \
      clone_mirror "${CROSVM_REMOTE_FALLBACK}" "${tmp_path}"; then
      rm -rf "${tmp_path}"
      return 1
    fi
    ensure_remote_origin "${tmp_path}"
  }

  mv "${tmp_path}" "${mirror_path}"
}

main "$@"
