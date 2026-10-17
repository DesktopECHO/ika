#!/usr/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export CVD_HOME_DIR="${TEST_ROOT}/ika"
export CVD_PRODUCT_OUT="${TEST_ROOT}/product"
export ADB_TEST_LOG="${TEST_ROOT}/adb-calls.log"
unset ANDROID_ADB_LOG_PATH
mkdir -p "${CVD_PRODUCT_OUT}"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  [[ "${actual}" == "${expected}" ]] || \
    fail "expected '${expected}', got '${actual}'"
}

file_inode() {
  if stat -c '%i' "$1" >/dev/null 2>&1; then
    stat -c '%i' "$1"
  else
    stat -f '%i' "$1"
  fi
}

# A line of the adb server log written the given number of seconds ago.
log_line() {
  printf '%s  1  1 W adb     : %s\n' \
    "$(format_epoch "$(( $(date +%s) - $1 ))" '%m-%d %H:%M:%S.000')" "$2"
}

assert_equal "${CVD_TMP_DIR}/adb.${UID}.log" "${ADB_SERVER_LOG}"

# Lines older than 24 hours go; the rest, and untimestamped lines among them,
# stay in the same file.
{
  log_line $(( 3 * 86400 )) "three days old"
  log_line $(( 25 * 3600 )) "25 hours old"
  log_line $(( 23 * 3600 )) "23 hours old"
  printf -- '--- adb starting (pid 42) ---\n'
  log_line 5 "just now"
} > "${ADB_SERVER_LOG}"
inode="$(file_inode "${ADB_SERVER_LOG}")"
expected="$(sed -n '3,$p' "${ADB_SERVER_LOG}")"
trim_adb_server_log
assert_equal "${expected}" "$(<"${ADB_SERVER_LOG}")"
assert_equal "${inode}" "$(file_inode "${ADB_SERVER_LOG}")"
compgen -G "${ADB_SERVER_LOG}.*" >/dev/null && fail "trim left a temporary file"

# A recent log is left alone.
trim_adb_server_log
assert_equal "${expected}" "$(<"${ADB_SERVER_LOG}")"

# A log with nothing from the last 24 hours is emptied, not removed.
log_line $(( 2 * 86400 )) "two days old" > "${ADB_SERVER_LOG}"
trim_adb_server_log
[[ -f "${ADB_SERVER_LOG}" && ! -s "${ADB_SERVER_LOG}" ]] || \
  fail "an old log was not emptied in place"
assert_equal "${inode}" "$(file_inode "${ADB_SERVER_LOG}")"

# A missing log stays missing.
rm "${ADB_SERVER_LOG}"
trim_adb_server_log
[[ ! -e "${ADB_SERVER_LOG}" ]] || fail "trim created a log"

fake_adb="${TEST_ROOT}/adb"
printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "$*" >> "$ADB_TEST_LOG"' > "${fake_adb}"
chmod +x "${fake_adb}"
CVD_ADB_BIN="${fake_adb}"

# With no adb server running, disconnecting starts none.
pgrep() { return 1; }
disconnect_guest_adb "vsock:3:5555"
[[ ! -e "${ADB_TEST_LOG}" ]] || fail "adb ran with no server running"

# With one running, the guest's transport is dropped.
pgrep() { return 0; }
disconnect_guest_adb "vsock:3:5555"
assert_equal "disconnect vsock:3:5555" "$(<"${ADB_TEST_LOG}")"

printf 'PASS: adb server log trim and guest disconnect\n'
