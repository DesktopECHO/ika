#!/usr/bin/bash

# 'ika install' and 'ika remove' with a stubbed adb: the app an install added
# is found from the guest's update times and named by its label, a failed
# install is reported with its reason, and apps are removed by label or
# package name but not when they come with Android.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
export XDG_DATA_HOME="${T}/data"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${CVD_HOME_DIR}/apps"

source "${ROOT}/tools/ika"
log() { printf '%s\n' "$*" >&2; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in: $1"
}

ensure_guest_ready() { :; }
resolve_adb_serial() { printf 'serial\n'; }
app_window_is_open() { return 1; }
notify_user() { :; }
notify_progress() { :; }
close_progress_notifications() { :; }

INSTALLED="com.example.old"
SYSTEM_APPS="com.android.settings"
APPS=$'Old\tcom.example.old\nSettings\tcom.android.settings'

# list_guest_apps prints "LABEL<TAB>PACKAGE" for the launchable apps.
list_guest_apps() { printf '%s\n' "${APPS}"; }
app_is_installed() { [[ " ${INSTALLED} ${SYSTEM_APPS} " == *" $1 "* ]]; }
app_display_name() { printf '%s\n' "$1"; }

# host_adb TIMEOUT -s SERIAL COMMAND...
host_adb() {
  shift 3
  case "$1" in
    shell)
      case "$2" in
        *lastUpdateTime*)
          printf '  Package [com.example.old] (abc):\r\n'
          printf '    lastUpdateTime=2026-10-14 09:00:00\r\n'
          printf '  Package [com.android.settings] (def):\r\n'
          printf '    lastUpdateTime=2008-12-31 20:00:00\r\n'
          printf '  Package [com.example.fresh] (123):\r\n'
          printf '    lastUpdateTime=2026-10-14 13:05:22\r\n'
          ;;
        pm)
          [[ "$*" == *" -s "* ]] || return 0
          [[ "${@: -1}" == "com.android.settings" ]] && printf 'package:com.android.settings\r\n'
          ;;
      esac
      ;;
    install)
      if [[ "${@: -1}" == *bad.apk ]]; then
        printf 'adb: failed to install bad.apk: Failure [INSTALL_FAILED_OLDER_SDK]\r\n'
        return 1
      fi
      printf 'Performing Streamed Install\r\nSuccess\r\n'
      ;;
    uninstall)
      if [[ "${@: -1}" == "com.android.settings" ]]; then
        printf 'Failure [DELETE_FAILED_INTERNAL_ERROR]\r\n'
        return 1
      fi
      printf 'Success\r\n'
      ;;
  esac
}

# The package updated last is the one just installed.
[[ "$(last_updated_package serial)" == "com.example.fresh" ]] \
  || fail "last_updated_package did not pick the newest package"

: > "${T}/good.apk"
: > "${T}/bad.apk"

APPS+=$'\nFresh App\tcom.example.fresh'
out="$( (run_install_command "${T}/good.apk") 2>&1)" || fail "install of a good apk failed: ${out}"
expect_contains "${out}" "Installed Fresh App" "install names the app by its label"

status=0
out="$( (run_install_command "${T}/bad.apk") 2>&1)" || status=$?
[[ "${status}" -ne 0 ]] || fail "install of a bad apk succeeded"
expect_contains "${out}" "INSTALL_FAILED_OLDER_SDK" "install reports why it failed"

status=0
out="$( (run_install_command "${T}/missing.apk") 2>&1)" || status=$?
[[ "${status}" -ne 0 ]] || fail "install of a missing file succeeded"
expect_contains "${out}" "no such file" "install of a missing file"

status=0
out="$( (run_install_command "${T}/good.apk" "${T}/bad.apk") 2>&1)" || status=$?
[[ "${status}" -ne 0 ]] || fail "install with one bad apk exited 0"
expect_contains "${out}" "Installed Fresh App" "the good apk is still installed"

mkdir -p "${IKA_APPS_DIR}/com.example.old"
out="$( (run_remove_command old) 2>&1)" || fail "remove by label failed: ${out}"
expect_contains "${out}" "Removed Old" "remove by label"
[[ ! -e "${IKA_APPS_DIR}/com.example.old" ]] || fail "remove left the app's cache behind"

out="$( (run_remove_command com.example.old) 2>&1)" || fail "remove by package failed: ${out}"
expect_contains "${out}" "Removed com.example.old" "remove by package"

status=0
out="$( (run_remove_command Settings) 2>&1)" || status=$?
[[ "${status}" -ne 0 ]] || fail "removing a system app succeeded"
expect_contains "${out}" "comes with Android" "remove of a system app"

status=0
out="$( (run_remove_command) 2>&1)" || status=$?
[[ "${status}" -ne 0 ]] || fail "remove without a name succeeded"

printf 'ok\n'
