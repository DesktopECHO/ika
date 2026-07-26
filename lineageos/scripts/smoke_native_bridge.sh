#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
adb_bin="${ADB:-adb}"
serial="${ANDROID_SERIAL:-}"
remote_dir="/data/local/tmp/ika-native-bridge-tests"
manifest="$script_dir/manifest.json"

usage() {
  printf 'Usage: %s [-s SERIAL] [--gtest_filter=PATTERN]\n' "${0##*/}"
  printf 'Runs the bundled ARM64 static and dynamic NDK suites through the x86-64 native bridge.\n'
}

adb_args=()
gtest_args=()
while (( $# > 0 )); do
  case "$1" in
    -s|--serial)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      serial="$2"
      shift 2
      ;;
    --gtest_*)
      gtest_args+=("$1")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$serial" ]] && adb_args=(-s "$serial")
adb_cmd() { "$adb_bin" "${adb_args[@]}" "$@"; }

[[ -s "$manifest" ]] || {
  printf 'Missing bundled native-bridge manifest: %s\n' "$manifest" >&2
  exit 1
}

manifest_entries() {
  python3 - "$manifest" <<'PY'
import json
from pathlib import Path, PurePosixPath
import re
import sys

path = Path(sys.argv[1])
try:
    manifest = json.loads(path.read_text())
except (OSError, json.JSONDecodeError) as exc:
    print(f"Invalid native-bridge manifest: {exc}", file=sys.stderr)
    raise SystemExit(1)

if manifest.get("format_version") != 1:
    print("Unsupported native-bridge manifest format", file=sys.stderr)
    raise SystemExit(1)

entries = manifest.get("files")
if not isinstance(entries, list) or not entries:
    print("Native-bridge manifest contains no files", file=sys.stderr)
    raise SystemExit(1)

seen = set()
for entry in entries:
    try:
        relpath = entry["path"]
        size = entry["size"]
        digest = entry["sha256"]
    except (KeyError, TypeError):
        print("Malformed native-bridge manifest entry", file=sys.stderr)
        raise SystemExit(1)
    parts = PurePosixPath(relpath).parts if isinstance(relpath, str) else ()
    if (
        not parts
        or relpath.startswith("/")
        or ".." in parts
        or relpath in seen
        or not isinstance(size, int)
        or size < 0
        or not isinstance(digest, str)
        or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        or "\t" in relpath
        or "\n" in relpath
    ):
        print(f"Unsafe native-bridge manifest entry: {relpath!r}", file=sys.stderr)
        raise SystemExit(1)
    seen.add(relpath)
    print(f"{digest}\t{size}\t{relpath}")
PY
}

for binary in ndk_program_tests_static ndk_program_tests; do
  [[ -x "$script_dir/$binary" ]] || {
    printf 'Missing bundled test executable: %s/%s\n' "$script_dir" "$binary" >&2
    exit 1
  }
  # ELF e_machine 183 is AArch64. Refuse a false-positive run of accidentally
  # bundled x86-64 test binaries before touching the guest.
  machine="$(od -An -tu2 -j18 -N2 "$script_dir/$binary" | tr -d '[:space:]')"
  [[ "$machine" == "183" ]] || {
    printf 'Bundled test executable is not AArch64: %s (e_machine=%s)\n' \
      "$script_dir/$binary" "${machine:-unknown}" >&2
    exit 1
  }
done

abi="$(adb_cmd shell getprop ro.product.cpu.abi | tr -d '\r')"
abilist="$(adb_cmd shell getprop ro.product.cpu.abilist | tr -d '\r')"
bridge="$(adb_cmd shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')"
isa="$(adb_cmd shell getprop ro.dalvik.vm.isa.arm64 | tr -d '\r')"
exec_enabled="$(adb_cmd shell getprop ro.enable.native.bridge.exec | tr -d '\r')"

[[ "$abi" == "x86_64" ]] || { printf 'Expected x86_64 host ABI, got %s\n' "$abi" >&2; exit 1; }
[[ ",$abilist," == *,arm64-v8a,* ]] || { printf 'ARM64 is absent from abilist: %s\n' "$abilist" >&2; exit 1; }
[[ "$bridge" == "libndk_translation.so" ]] || { printf 'Unexpected native bridge: %s\n' "$bridge" >&2; exit 1; }
[[ "$isa" == "x86_64" ]] || { printf 'Unexpected ARM64 ISA mapping: %s\n' "$isa" >&2; exit 1; }
[[ "$exec_enabled" == "1" ]] || { printf 'Translated executable support is disabled\n' >&2; exit 1; }

manifest_rows="$(manifest_entries)"
while IFS=$'\t' read -r expected_digest expected_size relpath; do
  remote_path="/system/$relpath"
  actual_size="$(adb_cmd shell stat -c %s "$remote_path" 2>/dev/null | tr -d '\r')"
  [[ "$actual_size" == "$expected_size" ]] || {
    printf 'Native-bridge file size mismatch: %s (expected=%s actual=%s)\n' \
      "$remote_path" "$expected_size" "${actual_size:-missing}" >&2
    exit 1
  }
  actual_digest="$(adb_cmd shell sha256sum "$remote_path" 2>/dev/null | awk '{print $1}' | tr -d '\r')"
  [[ "$actual_digest" == "$expected_digest" ]] || {
    printf 'Native-bridge file digest mismatch: %s\n' "$remote_path" >&2
    exit 1
  }
done <<<"$manifest_rows"

for registration in arm64_exe arm64_dyn; do
  # User builds deny the shell domain read access to binfmt_misc. Validate the
  # registration when readable; direct execution below remains the definitive
  # test on restricted builds.
  registration_state="$(adb_cmd shell cat "/proc/sys/fs/binfmt_misc/$registration" 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "$registration_state" ]]; then
    [[ "$registration_state" == *enabled* ]] || {
      printf 'ARM64 binfmt registration is unavailable: %s\n' "$registration" >&2
      exit 1
    }
    [[ "$registration_state" == *ndk_translation_program_runner_binfmt_misc_arm64* ]] || {
      printf 'ARM64 binfmt registration uses the wrong interpreter: %s\n' "$registration" >&2
      exit 1
    }
  fi
done

adb_cmd shell rm -rf "$remote_dir"
adb_cmd shell mkdir -p "$remote_dir"
trap 'adb_cmd shell rm -rf "$remote_dir" >/dev/null 2>&1 || true' EXIT

for binary in ndk_program_tests_static ndk_program_tests; do
  adb_cmd push "$script_dir/$binary" "$remote_dir/$binary" >/dev/null
  adb_cmd shell chmod 0755 "$remote_dir/$binary"
  printf '\nRunning ARM64 %s through %s\n' "$binary" "$bridge"
  adb_cmd shell "$remote_dir/$binary" "${gtest_args[@]}"
done

printf '\nARM64 native-bridge smoke test passed (host=%s guest=arm64-v8a).\n' "$abi"
