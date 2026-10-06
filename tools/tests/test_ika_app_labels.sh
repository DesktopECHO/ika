#!/usr/bin/bash

# App labels with unusual characters: every app stays in the app list, and its
# launcher is written once, validates, and is then recognised as current.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
export XDG_DATA_HOME="${T}/data"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"

source "${ROOT}/tools/ika"
log() { :; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

labels=(
  'Plain'
  'Tom & Jerry'
  '<b>Bold</b>'
  '50% Off'
  'Semi;colon'
  "Quote \"dq\" 'sq'"
  'Dollar $HOME `x`'
  'Back\slash'
  'C:\new\path'
  'Trailing space '
  'Hash # mid'
  '=Equals='
  '[Brackets]'
  'Émoji 🍉 日本語'
  'عربي'
  'Multi   spaces'
  $'Tab\there'
  'A label long enough to wrap the package'
)

# scrcpy's app list: " - LABEL  PACKAGE", with the package on an indented
# continuation line when the label is 30 characters or longer.
SCRCPY_BIN="${T}/scrcpy"
{
  printf '[server] INFO: List of apps:\n'
  for i in "${!labels[@]}"; do
    if (( ${#labels[i]} >= 30 )); then
      printf ' - %s\n          com.example.app%d\n' "${labels[i]}" "${i}"
    else
      printf ' - %-30s com.example.app%d\n' "${labels[i]}" "${i}"
    fi
  done
} > "${T}/list.txt"
printf '#!/bin/bash\ncat %q\n' "${T}/list.txt" > "${SCRCPY_BIN}"
chmod +x "${SCRCPY_BIN}"
append_scrcpy_env() { :; }

list="$(query_guest_apps 127.0.0.1:6520)"
[[ "$(wc -l <<<"${list}")" -eq "${#labels[@]}" ]] || \
  fail "expected ${#labels[@]} apps, got: ${list}"
i=0
while IFS=$'\t' read -r label package; do
  expected="${labels[i]//$'\t'/ }"
  expected="${expected%"${expected##*[! ]}"}"
  [[ "${package}" == "com.example.app${i}" ]] || fail "app ${i}: package '${package}'"
  [[ "${label}" == "${expected}" ]] || fail "app ${i}: label '${label}', expected '${expected}'"
  i=$((i + 1))
done <<<"${list}"
echo "ok: every app kept in the app list, tabs turned into spaces"

# Writes every launcher twice in APPS_DIR and checks it is current the second
# time, valid, and named exactly.
check_launchers() {
  local apps_dir="$1"
  local mode="$2"
  local label
  local package
  local file
  local name

  mkdir -p "${apps_dir}"
  while IFS=$'\t' read -r label package; do
    file="${apps_dir}/ika-${package}.desktop"
    write_app_launcher "${apps_dir}" "${label}" "${package}" /icons/app.png || \
      fail "${mode}: '${label}' was not written"
    if write_app_launcher "${apps_dir}" "${label}" "${package}" /icons/app.png; then
      fail "${mode}: '${label}' was rewritten although it was current"
    fi
    if command -v desktop-file-validate >/dev/null 2>&1; then
      desktop-file-validate "${file}" >/dev/null || fail "${mode}: '${label}' launcher is invalid"
    fi
    if python3 -c 'from gi.repository import GLib' 2>/dev/null; then
      name="$(python3 -c 'import sys
from gi.repository import GLib
k = GLib.KeyFile()
k.load_from_file(sys.argv[1], GLib.KeyFileFlags.NONE)
print(k.get_string("Desktop Entry", "Name"))' "${file}")"
      [[ "${name}" == "$(app_launcher_name "${label}" "${package}")" ]] || \
        fail "${mode}: '${label}' reads back as '${name}'"
    fi
  done <<<"${list}"
  echo "ok: ${mode}: launchers written once, valid, names read back exactly"
}

if command -v desktop-file-edit >/dev/null 2>&1; then
  check_launchers "${T}/apps-edit" "desktop-file-edit"
fi

# Without desktop-file-edit, launchers are written directly.
command() {
  [[ "$*" != "-v desktop-file-edit" ]] || return 1
  builtin command "$@"
}
check_launchers "${T}/apps-plain" "plain writer"
unset -f command

# GNOME Shell's rename handling must leave launchers with unchanged names alone.
pgrep() { return 0; }
sleep() { :; }
refresh_app_menu_caches() { :; }
for apps_dir in "${T}"/apps-*; do
  parked="$(refresh_renamed_launchers "${apps_dir}" "${list}")"
  [[ "${parked}" == "0" ]] || fail "$(basename "${apps_dir}"): ${parked} unchanged launchers re-added"
done
echo "ok: unchanged launchers are not re-added for GNOME Shell"

# Messages and notifications name an app as its launcher does, not by package.
assert_name() {
  [[ "$(app_display_name "$1")" == "$2" ]] || \
    fail "app_display_name $1: '$(app_display_name "$1")', expected '$2'"
}
apps_dir="$(app_menu_data_dir)/applications"
mkdir -p "${apps_dir}" "${IKA_APPS_DIR}/com.example.titled"
printf 'com.example.game\n' > "${APP_GAMES_FILE}"
write_app_launcher "${apps_dir}" 'Back\slash Game' com.example.game /icons/app.png
write_app_launcher "${apps_dir}" 'Tom & Jerry' com.example.app /icons/app.png
printf 'Listed App\tcom.example.listed\n' > "${APP_LIST_CACHE}"
printf 'Titled App\n' > "${IKA_APPS_DIR}/com.example.titled/title"
assert_name com.example.game 'Back\slash Game'
assert_name com.example.app 'Tom & Jerry'
assert_name com.example.listed 'Listed App'
assert_name com.example.titled 'Titled App'
assert_name com.example.unknown com.example.unknown
echo "ok: app names come from the launcher, the app list, the window title, or the package"

# A menu launcher passes the package: a game session starts with the app name.
require_executable() { :; }
ensure_guest_ready() { :; }
resolve_adb_serial() { printf '127.0.0.1:6520\n'; }
app_is_installed() { return 0; }
start_game_session() { printf 'session %s|%s\n' "$1" "$2"; }
session="$(open_app_window com.example.game false false "" "" false)"
[[ "${session}" == 'session com.example.game|Back\slash Game' ]] || \
  fail "game session started as '${session}'"

# The launcher of an app removed since: the error notification names the app.
notify_user() { printf 'notify %s\n' "$1"; }
message="$( (resolve_app_name com.example.app "" app) 2>/dev/null || true)"
[[ "${message}" == "notify Tom & Jerry is not installed in Android; see '"*" app'" ]] || \
  fail "removed app notified as '${message}'"
echo "ok: game sessions and errors started from a launcher use the app name"

printf 'PASS: app labels with unusual characters\n'
