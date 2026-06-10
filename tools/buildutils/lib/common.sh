#!/usr/bin/env bash
# Shared primitives for the ika package build scripts (build_packages.sh and
# build_package.sh). Source only — defines functions. Mirrors the lib/ pattern
# under lineageos/scripts/ so the two build entry points share one
# implementation of distro detection and sudo escalation.
#
# Building as root is not supported: refuse_root_build aborts when run as root,
# and the helpers below escalate to root only via sudo, and only for dependency
# installation.

# Root command prefix, populated by init_root_cmd. Empty when no sudo
# escalation is available.
declare -a ROOT_CMD=()

detect_distro_family() {
  if command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    printf 'debian'
  elif command -v rpm >/dev/null 2>&1 && command -v dnf >/dev/null 2>&1; then
    printf 'rpm'
  else
    >&2 echo "Unsupported distribution: neither apt/dpkg nor dnf/rpm found"
    return 1
  fi
}

refuse_root_build() {
  if [[ "$(id -u)" -ne 0 ]]; then
    return
  fi

  >&2 echo "Do not run package builds as root."
  >&2 echo "Root-owned Bazel and build outputs are difficult to clean from a normal user shell."
  >&2 echo "Run this script as your normal user; dependency installation uses sudo only when needed."
  exit 1
}

init_root_cmd() {
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

can_run_as_root() {
  [[ "${#ROOT_CMD[@]}" -gt 0 ]]
}

run_as_root() {
  "${ROOT_CMD[@]}" "$@"
}

drop_root_cmd() {
  if [[ "${#ROOT_CMD[@]}" -eq 0 ]]; then
    return
  fi

  if [[ "${ROOT_CMD[0]}" == "sudo" ]]; then
    sudo -k || true
  fi
  ROOT_CMD=()
}
