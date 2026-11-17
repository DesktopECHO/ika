#!/usr/bin/bash

# One start at a time launches the VM. Two starts at once both found no VM and
# launched it: the second wrote its own scope's cgroup into vcpu-config.json
# before the first one's run_cvd read it, and systemd removed that scope when
# the second cvd found the group running, so the first run_cvd could not move
# itself to the cgroup and the start failed. A start now holds a lock from its
# check for a running VM until the VM has booted or failed; another start says
# a start is in progress and launches nothing, ika status says Android is
# starting and ika stop leaves it. The lock is released however the start
# ends, even when it is killed, and processes it left running, such as adb's
# server, never hold it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
CHILD_PID=""
trap '[[ -z "${CHILD_PID}" ]] || kill "${CHILD_PID}" 2>/dev/null; rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export CVD_HOME_DIR="${TEST_ROOT}/ika"
export CVD_PRODUCT_OUT="${TEST_ROOT}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

LOCK="${CVD_TMP_DIR}/start.lock"
LOG="${TEST_ROOT}/start.log"

lock_is_free() {
  flock -n "${LOCK}" true
}

# Everything start_cvd does before its check for a running VM, and on the way
# for a VM already running, is stubbed: no adb, display, console or mount.
CVD_BIN="${TEST_ROOT}/cvd_internal_start"
printf '#!/bin/sh\n' >"${CVD_BIN}"
chmod +x "${CVD_BIN}"
check_required_groups() { :; }
ensure_open_file_limit() { :; }
resolve_adb_serial() { printf 'vsock:3:5555\n'; }
host_display_size() { :; }
maybe_start_scrcpy() { lock_is_free || echo "console opened under the lock"; }
ensure_chromium() { :; }
mount_android_storage() { :; }
start_app_menu_watcher() { :; }

# The VM runs. The check for it runs under the lock and leaves a process
# behind, as adb's server does; the lock is free when the console opens and
# after the start.
has_live_cvd_processes() {
  lock_is_free && echo "checked for a running VM without the lock"
  sleep 30 >/dev/null 2>&1 &
  echo "$!" >"${TEST_ROOT}/child"
  return 0
}
( START_CONSOLE=true start_cvd false ) >"${LOG}" 2>&1 3>&1 \
  || fail "start with the VM running failed: $(cat "${LOG}")"
CHILD_PID="$(cat "${TEST_ROOT}/child")"
kill -0 "${CHILD_PID}" || fail "the process the start left did not stay"
! grep -q "without the lock\|under the lock" "${LOG}" || fail "$(cat "${LOG}")"
lock_is_free || fail "the lock stayed held after the start"
grep -q "Android virtual device running" "${LOG}" || fail "no running VM reported: $(cat "${LOG}")"
kill "${CHILD_PID}"
CHILD_PID=""

# A second start while the first one's VM boots says so and launches nothing,
# and leaves the first one's lock as it was.
has_live_cvd_processes() { return 1; }
# The first step of a launch, after the lock.
record_gpu_in_use() { touch "${TEST_ROOT}/launched"; return 1; }
rm -f "${TEST_ROOT}/locked" "${TEST_ROOT}/launched" "${TEST_ROOT}/release"
flock "${LOCK}" sh -c 'touch "$1/locked"; until [ -e "$1/release" ]; do sleep 0.05; done' \
  sh "${TEST_ROOT}" &
HOLDER="$!"
until [[ -e "${TEST_ROOT}/locked" ]]; do sleep 0.05; done
( START_CONSOLE=false start_cvd false ) >"${LOG}" 2>&1 3>&1 \
  || fail "the second start failed: $(cat "${LOG}")"
grep -qF "Android virtual device start already in progress" "${LOG}" \
  || fail "the second start did not say a start is in progress: $(cat "${LOG}")"
[[ ! -e "${TEST_ROOT}/launched" ]] || fail "the second start launched the VM"
! lock_is_free || fail "the second start released the first one's lock"
android_start_in_progress || fail "a start in progress not seen"
expect_ika() {
  local expected="$1" status=0
  shift
  ( main "$@" ) >"${LOG}" 2>&1 3>&1 || status=$?
  grep -qF "${expected}" "${LOG}" || fail "ika $*: expected '${expected}', got: $(cat "${LOG}")"
  printf '%s\n' "${status}"
}
[[ "$(expect_ika "Android virtual device starting." status)" == 0 ]] \
  || fail "ika status failed during a start"
[[ "$(expect_ika "start in progress; stop it once it has started" stop)" != 0 ]] \
  || fail "ika stop succeeded during a start"
touch "${TEST_ROOT}/release"
wait "${HOLDER}"
! android_start_in_progress || fail "a start in progress seen after it ended"

# A start that fails after taking the lock releases it on exit, although a
# process it left is still running.
( take_start_lock
  sleep 30 >/dev/null 2>&1 &
  echo "$!" >"${TEST_ROOT}/child"
  die "the VM did not boot" ) >"${LOG}" 2>&1 3>&1 && fail "die did not fail"
CHILD_PID="$(cat "${TEST_ROOT}/child")"
kill -0 "${CHILD_PID}" || fail "the process the start left did not stay"
lock_is_free || fail "the lock stayed held after a failed start"
kill "${CHILD_PID}"
CHILD_PID=""

# A start killed while it holds the lock, so that it cannot release it, lets
# go of it too, although a process it left is still running.
rm -f "${TEST_ROOT}/took"
( take_start_lock
  sleep 30 >/dev/null 2>&1 &
  echo "$!" >"${TEST_ROOT}/child"
  touch "${TEST_ROOT}/took"
  while :; do sleep 0.1; done ) >"${LOG}" 2>&1 3>&1 &
STARTED="$!"
until [[ -e "${TEST_ROOT}/took" ]]; do sleep 0.05; done
CHILD_PID="$(cat "${TEST_ROOT}/child")"
! lock_is_free || fail "the start did not hold the lock"
kill -KILL "${STARTED}"
wait "${STARTED}" 2>/dev/null || true
for _ in $(seq 50); do
  ! lock_is_free || break
  sleep 0.1
done
kill -0 "${CHILD_PID}" || fail "the process the start left did not stay"
lock_is_free || fail "the lock stayed held after the start was killed"

printf 'PASS: one start at a time launches the VM, and the lock is released however it ends\n'
