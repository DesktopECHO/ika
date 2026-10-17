#!/usr/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export CVD_HOME_DIR="${TEST_ROOT}/ika"
export CVD_PRODUCT_OUT="${TEST_ROOT}/product"
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

line_count() {
  wc -l < "$1" | tr -d ' '
}

assert_equal "${CVD_HOME_DIR}/ikastart.log" "${START_LOG_FILE}"
assert_equal "${CVD_HOME_DIR}/madbfs.log" "${MADBFS_LOG_FILE}"
assert_equal 1000 "${LOG_MAX_LINES}"

# A missing log is created with the new run's header.
( redirect_start_logs; printf 'first run\n' )
assert_equal 2 "$(line_count "${START_LOG_FILE}")"
[[ "$(head -n 1 "${START_LOG_FILE}")" == "${START_LOG_RUN_PREFIX}"*" start" ]] || \
  fail "the new run has no header"

# A short log keeps every line, however old its runs are.
{
  printf '%s2020-01-01 00:00:00 ika start\n' "${START_LOG_RUN_PREFIX}"
  printf '[ika] years old\n'
} > "${START_LOG_FILE}"
inode="$(file_inode "${START_LOG_FILE}")"
( redirect_start_logs; printf 'new run\n' )
assert_equal "${inode}" "$(file_inode "${START_LOG_FILE}")"
assert_equal 4 "$(line_count "${START_LOG_FILE}")"
assert_equal "[ika] years old" "$(sed -n '2p' "${START_LOG_FILE}")"
assert_equal "new run" "$(tail -n 1 "${START_LOG_FILE}")"

# A long log keeps its last 1,000 lines in the same file, and the new run
# follows them.
seq 1 1500 > "${START_LOG_FILE}"
inode="$(file_inode "${START_LOG_FILE}")"
( redirect_start_logs; printf 'new run\n' )
assert_equal "${inode}" "$(file_inode "${START_LOG_FILE}")"
assert_equal 1002 "$(line_count "${START_LOG_FILE}")"
assert_equal 501 "$(head -n 1 "${START_LOG_FILE}")"
assert_equal 1500 "$(sed -n '1000p' "${START_LOG_FILE}")"
[[ "$(sed -n '1001p' "${START_LOG_FILE}")" == "${START_LOG_RUN_PREFIX}"*" start" ]] || \
  fail "the new run has no header"
assert_equal "new run" "$(tail -n 1 "${START_LOG_FILE}")"
compgen -G "${START_LOG_FILE}.*" >/dev/null && fail "trim left a temporary file"

# madbfs.log is trimmed the same way, and a log at the limit is left alone.
seq 1 1200 > "${MADBFS_LOG_FILE}"
inode="$(file_inode "${MADBFS_LOG_FILE}")"
trim_log_lines "${MADBFS_LOG_FILE}"
assert_equal "${inode}" "$(file_inode "${MADBFS_LOG_FILE}")"
assert_equal 1000 "$(line_count "${MADBFS_LOG_FILE}")"
assert_equal 201 "$(head -n 1 "${MADBFS_LOG_FILE}")"
trim_log_lines "${MADBFS_LOG_FILE}"
assert_equal 201 "$(head -n 1 "${MADBFS_LOG_FILE}")"
compgen -G "${MADBFS_LOG_FILE}.*" >/dev/null && fail "trim left a temporary file"

# A missing log stays missing.
rm -f "${MADBFS_LOG_FILE}"
trim_log_lines "${MADBFS_LOG_FILE}"
[[ ! -e "${MADBFS_LOG_FILE}" ]] || fail "trim created a missing log"

printf 'PASS: ikastart.log and madbfs.log keep their last 1,000 lines\n'
