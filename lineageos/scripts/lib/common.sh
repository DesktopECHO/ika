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
