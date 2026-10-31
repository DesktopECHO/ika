#!/usr/bin/bash

# 'ika backup' and 'ika restore' with a stubbed adb: a backup carries the
# static shared libraries its apps use, such as Trichrome's for Chrome, which
# 'pm list packages' leaves out, and a restore installs them before the apps;
# a backup made before libraries were saved, or without some of the folders,
# still restores.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
export XDG_DATA_HOME="${T}/data"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${CVD_HOME_DIR}/tmp"

source "${ROOT}/tools/ika"
log() { printf '%s\n' "$*" >&2; }
respond() { printf '%s\n' "$*"; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in: $1"
}

# Runs COMMAND... answering "Y", with errexit in force as when ika runs it
# ('out="$(...)" || fail' would turn it off), and sets out to what it printed.
run_ika() {
  local what="$1"
  shift

  "$@" <<<Y >"${T}/out" 2>&1 3>&2 &
  wait $! || fail "${what} failed: $(cat "${T}/out")"
  out="$(cat "${T}/out")"
}

ensure_guest_ready() { :; }
resolve_adb_serial() { printf 'serial\n'; }

GUEST="${T}/guest"
CHROME="/data/app/~~c1==/com.android.chrome-c2=="
APP="/data/app/~~a1==/com.example.app-a2=="
LIB="/data/app/~~l1==/com.google.android.trichromelibrary_792216938-l2=="
# A library only an app that is not backed up uses.
OTHER_LIB="/data/app/~~o1==/com.example.otherlib_7-o2=="
for apk in "${CHROME}/base.apk" "${CHROME}/split_chrome.apk" "${APP}/base.apk" \
    "${LIB}/base.apk" "${OTHER_LIB}/base.apk"; do
  mkdir -p "${GUEST}${apk%/*}"
  printf '%s\n' "${apk}" > "${GUEST}${apk}"
done

DUMP="Packages:
  Package [com.android.chrome] (1):
    codePath=${CHROME}
    usesStaticLibraries:
      com.google.android.trichromelibrary version:792216938
    usesOptionalLibraries:
      androidx.window.extensions
  Package [com.google.android.trichromelibrary_792216938] (2):
    codePath=${LIB}
  Package [com.example.app] (3):
    codePath=${APP}
  Package [org.chromium.chrome] (4):
    codePath=/data/app/~~x==/org.chromium.chrome-x==
    usesStaticLibraries:
      com.example.otherlib version:7
  Package [com.example.otherlib_7] (5):
    codePath=${OTHER_LIB}

Hidden system packages:
  Package [com.android.chrome] (6):
    codePath=/system/app/Chrome
    usesStaticLibraries:
      com.google.android.trichromelibrary version:1"

[[ "$(static_libraries_used "${DUMP}" "com.android.chrome com.example.app")" \
    == "com.google.android.trichromelibrary_792216938"$'\t'"${LIB}" ]] \
  || fail "static_libraries_used: $(static_libraries_used "${DUMP}" "com.android.chrome com.example.app")"
[[ -z "$(static_libraries_used "${DUMP}" "com.example.app")" ]] \
  || fail "static_libraries_used listed a library no backed-up app uses"

# The device's tar, run on the fake guest's files.
append_guest_path() {
  local archive="$2"
  local prefix="$3"
  local parent="$4"
  local name="$5"

  [[ -e "${GUEST}${parent}/${name}" ]] || return 1
  tar -cf - -C "${GUEST}${parent}" --transform "s,^,${prefix}/," "${name}" | pigz -1 >>"${archive}"
}

# host_adb TIMEOUT -s SERIAL COMMAND...
host_adb() {
  shift 3
  case "$1" in
    shell)
      shift
      case "$*" in
        "pm list packages -3 -i")
          printf 'package:com.android.chrome  installer=null\r\n'
          printf 'package:com.example.app  installer=null\r\n'
          printf 'package:org.chromium.chrome  installer=null\r\n'
          ;;
        "pm path com.android.chrome")
          printf 'package:%s/base.apk\r\npackage:%s/split_chrome.apk\r\n' "${CHROME}" "${CHROME}"
          ;;
        "pm path com.example.app") printf 'package:%s/base.apk\r\n' "${APP}" ;;
        "dumpsys package packages") printf '%s\r\n' "${DUMP//$'\n'/$'\r\n'}" ;;
        "ls '/data/app/"*)
          eval "set -- ${*#ls }"
          ls -1 "${GUEST}$1" | sed 's/$/\r/'
          ;;
      esac
      ;;
    install-multiple)
      shift
      [[ "$1" == "-r" ]] || return 1
      shift
      printf '%s\n' "$(for apk in "$@"; do basename -- "$(dirname -- "${apk}")"; done | sort -u)" \
        >> "${T}/installs"
      ;;
  esac
}

run_ika backup run_backup_command "${T}/backup.tgz"
expect_contains "${out}" "backing up com.google.android.trichromelibrary_792216938" "backup saves the library"
expect_contains "${out}" "Backed up 2 apps and 0 files" "the library is neither an app nor a file"
[[ "${out}" != *otherlib* ]] || fail "backup saved a library of a skipped app: ${out}"

listing="$(tar -tizf "${T}/backup.tgz" | sort)"
expect_contains "${listing}" "libs/com.google.android.trichromelibrary_792216938/base.apk" "archive holds the library"
expect_contains "${listing}" "apps/com.android.chrome/split_chrome.apk" "archive holds Chrome's splits"

run_ika restore run_restore_command "${T}/backup.tgz"
expect_contains "${out}" "Restored 2 apps" "restore installs both apps"
[[ "$(cat "${T}/installs")" == "com.google.android.trichromelibrary_792216938
com.android.chrome
com.example.app" ]] || fail "restore did not install the library first: $(cat "${T}/installs")"

# A backup made before libraries were saved: just the apps.
mkdir -p "${T}/old/apps/com.example.app"
printf 'created\tthen\n' > "${T}/old/${BACKUP_INFO_FILE}"
cp "${GUEST}${APP}/base.apk" "${T}/old/apps/com.example.app/"
mkdir -p "${T}/old/settings"
(cd "${T}/old/settings" && touch roles.tsv permissions.tsv appops.tsv disabled.txt settings.tsv night-mode)
tar -czf "${T}/old.tgz" -C "${T}/old" "${BACKUP_INFO_FILE}" apps settings
: > "${T}/installs"
run_ika "restore of an old backup" run_restore_command "${T}/old.tgz"
expect_contains "${out}" "Restored 1 app" "an old backup restores"
[[ "$(cat "${T}/installs")" == "com.example.app" ]] \
  || fail "old backup installs: $(cat "${T}/installs")"

printf 'ok\n'
