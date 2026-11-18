#!/usr/bin/bash

# One start at a time launches the VM. Two starts at once both found no VM and
# launched it: the second wrote its own scope's cgroup into vcpu-config.json
# before the first one's run_cvd read it, and systemd removed that scope when
# the second cvd found the group running, so the first run_cvd could not move
# itself to the cgroup and the start failed. A start now holds a lock from its
# check for a running VM until the VM has booted or failed; another start says
# a start is in progress and launches nothing, and ika status says Android is
# starting; both say for how long, and the start says it in a notification
# too, as a menu shows no output. ika stop ends the start and stops the VM it
# launched, once that runs. The lock is released however the start
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
# The second start, run from a menu, also says it in a notification, and both
# say how long the first one has been starting Android, from the time it wrote
# into the lock file (125 s ago here).
rm -f "${TEST_ROOT}/locked" "${TEST_ROOT}/launched" "${TEST_ROOT}/release"
flock "${LOCK}" sh -c 'echo "$2" >"$3"; touch "$1/locked"; until [ -e "$1/release" ]; do sleep 0.05; done' \
  sh "${TEST_ROOT}" "$(( $(date +%s) - 125 ))" "${LOCK}" &
HOLDER="$!"
until [[ -e "${TEST_ROOT}/locked" ]]; do sleep 0.05; done
NOTIFIED="${TEST_ROOT}/notified"
notify_user() { printf '%s\n' "$1" >>"${NOTIFIED}"; }
# Its output goes to the start log, so it says it on the terminal too (fd 3),
# where it reports no device online.
TERMINAL="${TEST_ROOT}/terminal"
( START_CONSOLE=false run_timed_operation started start_cvd false ) >"${LOG}" 2>&1 3>"${TERMINAL}" \
  || fail "the second start failed: $(cat "${LOG}")"
grep -qE "Android virtual device start already in progress \(for 2 min [56] s\)" "${LOG}" \
  || fail "the second start did not say a start is in progress, and for how long: $(cat "${LOG}")"
grep -qE "^Android virtual device start already in progress \(for 2 min [56] s\)$" "${TERMINAL}" \
  || fail "the second start said nothing on the terminal: $(cat "${TERMINAL}")"
! grep -q "online" "${TERMINAL}" || fail "the second start reported a device online: $(cat "${TERMINAL}")"
grep -qE "^Android is still starting \(for 2 min [56] s\)\. " "${NOTIFIED}" \
  || fail "the second start did not notify: $(cat "${NOTIFIED}" 2>/dev/null)"
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
[[ "$(expect_ika "Android virtual device starting (for 2 min" status)" == 0 ]] \
  || fail "ika status failed during a start"
# A start whose time is not known (an empty lock file) still says it starts.
: >"${LOCK}"
[[ "$(expect_ika "Android virtual device starting." status)" == 0 ]] \
  || fail "ika status failed during a start of unknown length"
touch "${TEST_ROOT}/release"
wait "${HOLDER}"
! android_start_in_progress || fail "a start in progress seen after it ended"

# ika stop ends a start in progress, which quits without waiting for Android,
# and stops the VM it launched. Nothing of the desktop is touched.
stop_startup_packaged_scrcpy() { :; }
stop_app_menu_watcher() { :; }
unmount_android_storage() { :; }
stop_dnsmasq() { :; }
report_udmabuf_leaks() { :; }
clear_stale_cvd_group() { :; }
CALLS="${TEST_ROOT}/calls"
STARTED_LOG="${TEST_ROOT}/started.log"

# A start that holds the lock, as start_cvd does from the lock to the boot:
# with "launch", it has launched the VM in a scope.
hold_start() {
  rm -f "${TEST_ROOT}/took"
  ( take_start_lock
    [[ "${1:-}" != launch ]] || write_start_lock_state ika-android-42
    touch "${TEST_ROOT}/took"
    while :; do sleep 0.1; done ) >"${STARTED_LOG}" 2>&1 3>&1 &
  STARTED="$!"
  until [[ -e "${TEST_ROOT}/took" ]]; do sleep 0.05; done
}
start_ended_quietly() {
  local status=0

  wait "${STARTED}" || status=$?
  [[ "${status}" == 143 ]] || fail "the start ended with ${status}, not by ika stop: $(cat "${STARTED_LOG}")"
  grep -q "^Android virtual device start stopped$" "${STARTED_LOG}" \
    || fail "the start did not say it was stopped: $(cat "${STARTED_LOG}")"
  ! grep -q "error\|online" "${STARTED_LOG}" || fail "the start reported a failure: $(cat "${STARTED_LOG}")"
  lock_is_free || fail "the lock stayed held after ika stop ended the start"
}

# Before the start has launched the VM, there is nothing more to stop.
has_live_cvd_processes() { return 1; }
hold_start
[[ "$(expect_ika "Android virtual device start stopped" stop)" == 0 ]] \
  || fail "ika stop failed during a start"
start_ended_quietly

# Once it has, ika stop waits while Cuttlefish's launcher sets up the VM's
# disks, until the VM runs, then stops it as any other, and then what is left
# in its scope.
rm -f "${CALLS}" "${TEST_ROOT}/vm_runs" "${TEST_ROOT}/stopped"
vm_scope_active() { [[ "$1" == ika-android-42 && ! -e "${TEST_ROOT}/scope_gone" ]]; }
vm_is_launched() { [[ -e "${TEST_ROOT}/vm_runs" ]]; }
has_live_cvd_processes() { [[ -e "${TEST_ROOT}/vm_runs" && ! -e "${TEST_ROOT}/stopped" ]]; }
stop_cvd_internal() {
  [[ -e "${TEST_ROOT}/vm_runs" ]] || echo "stopped before the VM ran" >>"${CALLS}"
  touch "${TEST_ROOT}/stopped"
  echo "stop the VM" >>"${CALLS}"
}
stop_vm_scope() { echo "stop $1.scope" >>"${CALLS}"; touch "${TEST_ROOT}/scope_gone"; }
hold_start launch
( sleep 1; touch "${TEST_ROOT}/vm_runs" ) &
[[ "$(expect_ika "Android virtual device stopped" stop)" == 0 ]] \
  || fail "ika stop failed during a start that launched the VM"
start_ended_quietly
[[ "$(cat "${CALLS}")" == $'stop the VM\nstop ika-android-42.scope' ]] \
  || fail "ika stop did not stop the launched VM, then its scope: $(cat "${CALLS}")"

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
