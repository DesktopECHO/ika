#!/usr/bin/env bash
# Shared primitives for the LineageOS Desktop build scripts. Source only
# (defines functions). Kept dependency-free so it is usable both by the build
# engine (which sources it first, alongside the other lib/ modules) and by the
# standalone scripts invoked from vendor/lineage_desktop/scripts/ inside the
# source tree, where lib/ is rsynced alongside them.
#
# Note: log/die/fail are intentionally NOT defined here. Each entry point uses a
# different prefix ([lineage-desktop] vs [lineage-desktop] validate:) and the
# validator's fail() accumulates instead of exiting, so those stay local.

# Never allow a graphical sudo/askpass dialog: point SUDO_ASKPASS at a no-op so
# sudo (run_privileged in host_env.sh) can't launch a GUI password helper,
# overriding any value the desktop session exported. Privilege prompts go to the
# controlling terminal or fail cleanly — never a popup.
export SUDO_ASKPASS=/bin/false

# True when the build host is ARM64. Keyed on the running host's machine type,
# not on any build target.
host_is_arm64() {
  case "$(uname -m)" in
    aarch64|arm64)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Soong host-output tag for the running build host (out/host/<tag>), e.g.
# linux-x86 or linux-arm64. Distinct from target_host_tag in target_common.sh,
# which names the tuple packaged for a *target* and can be a cross tag
# (linux_musl-arm64).
host_out_tag() {
  printf '%s-%s\n' \
    "$(uname -s | tr '[:upper:]' '[:lower:]')" \
    "$(uname -m | sed 's/aarch64/arm64/;s/x86_64/x86/')"
}

# Verify a .zip/.apk is a structurally valid archive with no corrupt members.
# Prints the offending path + reason and returns non-zero on failure.
validate_zip_file() {
  local zip_file="$1"

  python3 - "$zip_file" <<'PY'
from pathlib import Path
import sys
import zipfile

path = Path(sys.argv[1])
try:
    with zipfile.ZipFile(path) as archive:
        bad_member = archive.testzip()
except zipfile.BadZipFile as exc:
    raise SystemExit(f"{path}: {exc}")

if bad_member:
    raise SystemExit(f"{path}: corrupt zip member {bad_member}")
PY
}

# Rust prebuilt version this branch expects, under the given source root.
# Honors RUST_PREBUILTS_VERSION, else reads RustDefaultVersion from Soong.
rust_prebuilt_version() {
  local root="$1"

  if [[ -n "${RUST_PREBUILTS_VERSION:-}" ]]; then
    printf '%s\n' "$RUST_PREBUILTS_VERSION"
    return 0
  fi

  sed -n 's/^[[:space:]]*RustDefaultVersion[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$root/build/soong/rust/config/global.go" | head -n 1
}

retry_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$@"
  else
    printf '[lineage-desktop] %s\n' "$*" >&2
  fi
}

git_network_retry_delay() {
  local attempt="$1"
  local base="${GIT_NETWORK_RETRY_DELAY:-5}"
  local max="${GIT_NETWORK_RETRY_MAX_DELAY:-60}"
  local delay

  [[ "$base" =~ ^[0-9]+$ && "$base" -gt 0 ]] || base=5
  [[ "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]] || max=60

  delay=$(( base * attempt ))
  (( delay > max )) && delay="$max"
  printf '%s\n' "$delay"
}

git_network_attempts() {
  local attempts="${GIT_NETWORK_ATTEMPTS:-5}"
  [[ "$attempts" =~ ^[0-9]+$ && "$attempts" -gt 0 ]] || attempts=5
  printf '%s\n' "$attempts"
}

git_network_retry() {
  local description="$1"
  shift

  if (( $# == 0 )); then
    retry_log "$description has no command to retry"
    return 1
  fi

  local __git_retry_attempts __git_retry_attempt __git_retry_delay
  __git_retry_attempts="$(git_network_attempts)"
  __git_retry_attempt=1

  while :; do
    if "$@"; then
      return 0
    fi

    if (( __git_retry_attempt >= __git_retry_attempts )); then
      retry_log "$description failed after $__git_retry_attempt attempt(s)"
      return 1
    fi

    __git_retry_delay="$(git_network_retry_delay "$__git_retry_attempt")"
    retry_log "$description failed; retrying in ${__git_retry_delay} seconds (attempt $__git_retry_attempt/$__git_retry_attempts)"
    sleep "$__git_retry_delay"
    __git_retry_attempt=$((__git_retry_attempt + 1))
  done
}

git_clone_with_retries() {
  local dest="$1"
  local description="$2"
  shift 2

  local __git_retry_attempts __git_retry_attempt __git_retry_delay
  __git_retry_attempts="$(git_network_attempts)"
  __git_retry_attempt=1

  [[ -n "$dest" && "$dest" != "/" ]] || {
    retry_log "$description has an unsafe clone destination: $dest"
    return 1
  }
  if (( $# == 0 )); then
    retry_log "$description has no clone source"
    return 1
  fi

  while :; do
    rm -rf "$dest"
    if git clone "$@" "$dest"; then
      return 0
    fi

    rm -rf "$dest"
    if (( __git_retry_attempt >= __git_retry_attempts )); then
      retry_log "$description failed after $__git_retry_attempt attempt(s)"
      return 1
    fi

    __git_retry_delay="$(git_network_retry_delay "$__git_retry_attempt")"
    retry_log "$description failed; retrying in ${__git_retry_delay} seconds (attempt $__git_retry_attempt/$__git_retry_attempts)"
    sleep "$__git_retry_delay"
    __git_retry_attempt=$((__git_retry_attempt + 1))
  done
}
