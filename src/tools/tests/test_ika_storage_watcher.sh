#!/usr/bin/env bash

# Android's files stay mounted only while the VM runs: the storage watcher,
# started with the mount (or by a start that finds it mounted), unmounts them
# once the VM stops by itself, as when Android is turned off from its power
# menu. ika stop, restart and reset end the watcher before they unmount. A
# mount that fails, or finds Android has not mounted /sdcard yet on a busy
# host, leaves the watcher to mount Android's files once it can.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export HOME="${T}/home" CVD_HOME_DIR="${T}/ika" CVD_PRODUCT_OUT="${T}/product"
export XDG_RUNTIME_DIR="${T}/run"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${XDG_RUNTIME_DIR}"
source "${ROOT}/tools/ika"
mkdir -p "${CVD_HOME_DIR}" "${CVD_TMP_DIR}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

calls() { cat "${T}/calls" 2>/dev/null || true; }

# The VM runs for two checks, then stops by itself. (The watcher runs in a
# subshell, so the checks are counted in a file.)
STORAGE_WATCHER_POLL_SEC=0
STORAGE_REMOUNT_SEC=1000
resolve_adb_serial() { printf 'serial\n'; }
has_live_cvd_processes() {
  echo >>"${T}/checks"
  (( $(wc -l <"${T}/checks") <= 2 ))
}
unmount_android_storage_at() { printf 'unmount %s\n' "$1" >>"${T}/calls"; }

( run_storage_watcher 2>"${T}/watcher.log" )
[[ "$(calls)" == "unmount ${ANDROID_STORAGE_DIR}" ]] || fail "the watcher did: $(calls)"
(( $(wc -l <"${T}/checks") == 3 )) ||
  fail "the watcher unmounted after $(wc -l <"${T}/checks") checks, not once the VM stopped"
grep -q "unmounting Android's files" "${T}/watcher.log" || fail "not logged: $(<"${T}/watcher.log")"
[[ ! -e "${STORAGE_WATCHER_PID_FILE}" ]] || fail "the watcher left its pid file"
echo "ok: the watcher unmounts once the VM stops"

# One watcher at a time: another finds the lock taken and leaves
: >"${T}/calls"
: >"${T}/checks"
exec {held}>"${STORAGE_WATCHER_LOCK_FILE}"
flock -n "${held}"
( run_storage_watcher 2>/dev/null )
exec {held}>&-
[[ -z "$(calls)" ]] || fail "a second watcher ran: $(calls)"
echo "ok: one watcher at a time"

# The mount starts the watcher, as does a start that finds Android's files
# already mounted
start_storage_watcher() { printf 'watcher\n' >>"${T}/calls"; }
edit_windows_android_storage_shortcut() { :; }
edit_android_storage_place() { :; }
guest_is_rooted() { return 1; }
guest_adb() { return 0; }
printf '#!/bin/sh\nexit 0\n' >"${T}/madbfs"
chmod +x "${T}/madbfs"
PACKAGED_MADBFS_BIN="${T}/madbfs"

: >"${T}/calls"
android_storage_mounted() { return 1; }
mount_android_storage serial 2>/dev/null
grep -qx watcher "${T}/calls" || fail "a mount did not start the watcher: $(calls)"
: >"${T}/calls"
android_storage_mounted() { return 0; }
mount_android_storage serial 2>/dev/null
[[ "$(calls)" == "watcher" ]] || fail "a start that found the mount did not start the watcher: $(calls)"
echo "ok: the mount starts the watcher"

# On a busy host Android has not mounted /sdcard when the start stops waiting
# for it: the mount leaves it to the watcher, without running madbfs.
SECONDS=100
guest_adb() { [[ "$*" != *"test -d /sdcard/"* ]]; }
printf '#!/bin/sh\necho ran >>"%s/madbfs-runs"\nexit 1\n' "${T}" >"${T}/madbfs"
: >"${T}/calls"
android_storage_mounted() { return 1; }
mount_android_storage serial 2>"${T}/mount.log"
grep -qx watcher "${T}/calls" || fail "a mount before /sdcard did not start the watcher: $(calls)"
[[ ! -e "${T}/madbfs-runs" ]] || fail "madbfs ran before Android mounted /sdcard"
grep -q "has not mounted /sdcard yet" "${T}/mount.log" || fail "not logged: $(<"${T}/mount.log")"
echo "ok: a mount before Android has /sdcard is left to the watcher"

# madbfs fails: the warning says it is tried again, and the watcher starts.
guest_adb() { return 0; }
: >"${T}/calls"
mount_android_storage serial 2>"${T}/mount.log"
[[ -e "${T}/madbfs-runs" ]] || fail "madbfs did not run"
grep -qx watcher "${T}/calls" || fail "a failed mount did not start the watcher: $(calls)"
grep -q "trying again in ${STORAGE_REMOUNT_SEC} seconds" "${T}/mount.log" ||
  fail "not logged: $(<"${T}/mount.log")"
echo "ok: a failed mount starts the watcher"

# The watcher mounts again while the VM runs and the files are not mounted,
# no sooner than STORAGE_REMOUNT_SEC after the mount that started it, and not
# while they are mounted.
# A second passes at each check.
mount_android_storage() {
  printf 'mount %s at check %s\n' "$1" "$(wc -l <"${T}/checks")" >>"${T}/calls"
  touch "${T}/mounted"
}
android_storage_mounted() { [[ -e "${T}/mounted" ]]; }
has_live_cvd_processes() {
  SECONDS=$((SECONDS + 1))
  echo >>"${T}/checks"
  (( $(wc -l <"${T}/checks") <= 4 ))
}
STORAGE_REMOUNT_SEC=2
: >"${T}/calls"
: >"${T}/checks"
( SECONDS=0; run_storage_watcher 2>/dev/null )
[[ "$(grep '^mount' "${T}/calls")" == "mount serial at check 2" ]] ||
  fail "the watcher did not mount once, ${STORAGE_REMOUNT_SEC} seconds in: $(calls)"
echo "ok: the watcher mounts Android's files once it can"
rm -f "${T}/mounted"

# stop, restart and reset end the watcher before they unmount
: >"${T}/calls"
stop_supervisor_from_file() { printf 'stop %s %s\n' "${1##*/}" "$2" >>"${T}/calls"; }
unmount_android_storage
[[ "$(head -n 1 "${T}/calls")" == "stop storage-watcher.pid __storage_watcher" ]] ||
  fail "the watcher was not ended first: $(calls)"
grep -qxF "unmount ${ANDROID_STORAGE_DIR}" "${T}/calls" || fail "nothing unmounted: $(calls)"
echo "ok: unmounting ends the watcher first"

echo PASS
