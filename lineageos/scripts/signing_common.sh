# Shared helpers for LineageOS Desktop build signing.
# Sourced by generate_signing_keys.sh, sign_target_files.sh, and the build
# scripts. Centralizes ANDROID_CERTS_DIR resolution + the "is the release key
# present" check so every entry point reports the same problem the same way.

ANDROID_CERTS_DIR="${ANDROID_CERTS_DIR:-$HOME/.android-certs}"

# Path to the first-time bootstrap. Computed relative to this file so it
# follows along if the repo gets relocated.
_signing_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_KEYS_SCRIPT="$_signing_common_dir/../../tools/buildutils/setup_keys.sh"
GENERATE_KEYS_SCRIPT="$_signing_common_dir/generate_signing_keys.sh"

# require_signing_keys
# Aborts the caller (exit 1) if the release key isn't present. Used by the
# rebuild scripts to fail fast and point the user at the bootstrap rather
# than recursively launching it from inside an iterative dev loop.
require_signing_keys() {
  if [[ -f "$ANDROID_CERTS_DIR/releasekey.pk8" ]]; then
    return 0
  fi
  printf '[lineage-desktop] error: signing keys not found at %s/releasekey.pk8\n' "$ANDROID_CERTS_DIR" >&2
  printf '[lineage-desktop] first-time setup: tools/buildutils/setup_keys.sh\n' >&2
  printf '[lineage-desktop] (or regenerate manually with lineageos/scripts/generate_signing_keys.sh;\n' >&2
  printf '[lineage-desktop]  override key location by exporting ANDROID_CERTS_DIR before running)\n' >&2
  exit 1
}

# ensure_signing_keys
# Like require_signing_keys, but auto-runs the bootstrap on a miss instead of
# failing. Used by the full pipeline so a fresh clone can get from `git clone`
# to a successful build in one command. Bootstraps interactively (prompts for
# identity if signing.conf doesn't exist).
ensure_signing_keys() {
  if [[ ! -f "$ANDROID_CERTS_DIR/releasekey.pk8" ]]; then
    if [[ ! -x "$SETUP_KEYS_SCRIPT" ]]; then
      printf '[lineage-desktop] error: signing keys missing AND bootstrap not found at %s\n' \
        "$SETUP_KEYS_SCRIPT" >&2
      exit 1
    fi
    printf '[lineage-desktop] signing keys missing; running %s\n' "$SETUP_KEYS_SCRIPT"
    "$SETUP_KEYS_SCRIPT"
    require_signing_keys
    return 0
  fi

  if [[ -x "$GENERATE_KEYS_SCRIPT" ]] && ! "$GENERATE_KEYS_SCRIPT" --check >/dev/null 2>&1; then
    printf '[lineage-desktop] signing key set is incomplete; adding newly required keys\n'
    "$GENERATE_KEYS_SCRIPT"
  elif [[ ! -x "$GENERATE_KEYS_SCRIPT" ]]; then
    printf '[lineage-desktop] error: signing key checker not found at %s\n' \
      "$GENERATE_KEYS_SCRIPT" >&2
    exit 1
  fi

  require_signing_keys
}

host_tool_matches_machine() {
  local candidate="$1"
  local description machine

  command -v file >/dev/null 2>&1 || return 0
  description="$(file -b "$candidate" 2>/dev/null || true)"

  # Shell/Python wrapper tools are architecture-neutral.
  [[ "$description" != *"ELF "* ]] && return 0

  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)
      [[ "$description" == *"x86-64"* ]]
      ;;
    aarch64|arm64)
      [[ "$description" == *"ARM aarch64"* ]]
      ;;
    *)
      return 0
      ;;
  esac
}

# find_signing_tool <name>
# Locates a host-runnable otatools binary (e.g. sign_target_files_apks) under
# out/host/*/bin/ built by `m otatools`. Cuttlefish builds may also produce
# foreign-architecture host-package tools (for example linux_musl-arm64 on an
# x86_64 builder), so prefer the native host output and skip incompatible ELF
# binaries during fallback.
find_signing_tool() {
  local name="$1"
  local repo_root="$2"
  local candidate
  local -a preferred_dirs=()

  if [[ -n "${ANDROID_HOST_OUT:-}" ]]; then
    preferred_dirs+=("$ANDROID_HOST_OUT/bin")
  fi

  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64)
      preferred_dirs+=("$repo_root/out/host/linux-x86/bin")
      ;;
    Linux:aarch64|Linux:arm64)
      preferred_dirs+=("$repo_root/out/host/linux_musl-arm64/bin")
      preferred_dirs+=("$repo_root/out/host/linux-arm64/bin")
      ;;
  esac

  for candidate in "${preferred_dirs[@]/%//$name}"; do
    [[ -x "$candidate" ]] || continue
    host_tool_matches_machine "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done

  for candidate in "$repo_root"/out/host/*/bin/"$name"; do
    [[ -x "$candidate" ]] || continue
    host_tool_matches_machine "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}
