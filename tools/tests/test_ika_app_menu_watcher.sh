#!/usr/bin/env bash

# The app menu watcher inherits IKA_NOTIFY from the Ika launcher's 'ika start'
# but reports nothing: a sync that fails is logged and retried. After a boot
# (a mode switch restarts Android with other packages) it waits for the guest
# to settle before the first sync, as the app list is not answered at once.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export HOME="${T}/home" CVD_HOME_DIR="${T}/ika" CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"
source "${ROOT}/tools/ika"
mkdir -p "${CVD_HOME_DIR}" "${CVD_TMP_DIR}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# A notify-send that records each call.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "${T}/notifications" > "${T}/bin/notify-send"
chmod +x "${T}/bin/notify-send"
export PATH="${T}/bin:${PATH}"
export IKA_NOTIFY=true

notify_user "control"
grep -q ' Ika control$' "${T}/notifications" || fail "the notify-send stub was not called"
rm -f "${T}/notifications"

# One poll: the guest has booted with new packages, and the app list fails.
APP_MENU_BOOT_GRACE_SEC=0
polls=0
has_live_cvd_processes() { (( polls++ < 1 )); }
resolve_adb_serial() { printf 'serial\n'; }
adb_boot_completed() { return 0; }
guest_package_fingerprint() { printf 'abc\n'; }
sync_app_menu() { die "could not list apps from the Android virtual device"; }
sleep() { :; }

# In a subshell, which releases the watcher lock when it exits.
( run_app_menu_watcher 2>"${T}/watcher.log" )

grep -q "app menu sync failed; retrying" "${T}/watcher.log" || fail "sync failure not logged"
[[ ! -f "${T}/notifications" ]] || fail "the watcher sent a notification: $(<"${T}/notifications")"

# One-second polls and grace period, in real time. The guest is booted at
# polls 1 and 2, restarts at poll 3 and comes back with other packages: the
# sync waits one poll after each boot, then runs once per package change.
unset -f sleep
APP_MENU_BOOT_GRACE_SEC=1
IKA_APP_MENU_POLL_SEC=1
polls=0
has_live_cvd_processes() { (( polls++ < 5 )); }
adb_boot_completed() { (( polls != 3 )); }
guest_package_fingerprint() { (( polls < 3 )) && printf 'abc\n' || printf 'def\n'; }
sync_app_menu() { printf '%s\n' "${polls}" >> "${T}/syncs"; }

( run_app_menu_watcher 2>>"${T}/watcher.log" )

[[ "$(<"${T}/syncs")" == $'2\n5' ]] || fail "synced at polls $(tr '\n' ' ' < "${T}/syncs"), not 2 and 5"

echo PASS
