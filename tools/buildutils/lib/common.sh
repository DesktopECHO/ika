#!/usr/bin/env bash
# Shared primitives for the ika package build scripts (build_packages.sh and
# build_package.sh). Source only — defines functions. Mirrors the lib/ pattern
# under lineageos/scripts/ so the two build entry points share one
# implementation of distro detection and sudo escalation.
#
# Building as root is not supported: refuse_root_build aborts when run as root,
# and the helpers below escalate to root only via sudo, and only for dependency
# installation.

# Never allow a graphical sudo/askpass dialog: point SUDO_ASKPASS at a no-op so
# sudo can't launch a GUI password helper, overriding any value the desktop
# session exported. Combined with the tty/-n discipline in init_root_cmd, every
# privilege prompt goes to the controlling terminal or fails cleanly — never a
# popup — keeping the build headless-safe and unattended-friendly.
export SUDO_ASKPASS=/bin/false

# Root command prefix, populated by init_root_cmd. Empty when no sudo
# escalation is available.
declare -a ROOT_CMD=()

detect_distro_family() {
  if command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    printf 'debian'
  elif command -v rpm >/dev/null 2>&1 && command -v dnf >/dev/null 2>&1; then
    printf 'rpm'
  elif command -v pacman >/dev/null 2>&1; then
    printf 'arch'
  else
    >&2 echo "Unsupported distribution: no apt/dpkg, dnf/rpm, or pacman found"
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

  if [[ -t 0 ]]; then
    ROOT_CMD=(sudo)
  elif sudo -n true >/dev/null 2>&1; then
    ROOT_CMD=(sudo -n)
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

# --- sudo timestamp keep-alive ----------------------------------------------
# The privileged setup phase (dependency install + Bazel download + host
# preflight) can run well past sudo's default 5-minute timestamp_timeout.
# Without a refresh, a later sudo call would re-prompt for a password and stall
# an otherwise unattended build. start_sudo_keepalive primes the timestamp once
# (a single, predictable prompt) then refreshes it in the background until
# stop_sudo_keepalive runs or the parent shell exits.
SUDO_KEEPALIVE_PID=""

start_sudo_keepalive() {
  # Only meaningful for interactive sudo escalation (ROOT_CMD=(sudo)). Running
  # as root, non-interactive (sudo -n), or with no sudo needs no keep-alive.
  [[ "${#ROOT_CMD[@]}" -eq 1 && "${ROOT_CMD[0]}" == "sudo" ]] || return 0
  command -v sudo >/dev/null 2>&1 || return 0

  # If priming fails (e.g. the user cancels the prompt), skip the keep-alive and
  # let the first real sudo surface the prompt; never abort the caller.
  sudo -v || return 0

  ( while true; do
      sudo -n true 2>/dev/null || break
      sleep 50
      kill -0 "$$" 2>/dev/null || break
    done ) &
  SUDO_KEEPALIVE_PID=$!
}

stop_sudo_keepalive() {
  [[ -n "${SUDO_KEEPALIVE_PID}" ]] || return 0
  kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
  wait "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
  SUDO_KEEPALIVE_PID=""
}
