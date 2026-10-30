#!/usr/bin/bash

# On WSLg, an app launched from Windows' Start menu or task bar with Shift held
# down opens its Startup Options instead. "Apply and start" then opens the app
# in the same process, and must start it: Shift's kept answer must not bring
# the window back.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

require_executable() { :; }
wayland_info_output() { :; }
windows_shift_held() { true; }
# "Apply and start", a few times at most: before the fix, each one came back
# to the window.
edit_app_settings() {
  printf 'options %s\n' "$1" >>"${T}/calls"
  (( $(wc -l <"${T}/calls") < 4 )) || return 0
  open_app_window "$1" false "" ""
}
ensure_guest_ready() {
  printf 'started\n' >>"${T}/calls"
  exit 0
}

# Shift at the launch with Ika stopped, then with it running
for live in false true; do
  : >"${T}/calls"
  has_live_cvd_processes() { [[ "${live}" == true ]]; }
  if [[ "${live}" == true ]]; then
    validate_app_package() { :; }
    app_is_installed() { true; }
    app_display_name() { printf 'Some Game\n'; }
    resolve_adb_serial() { printf 'serial\n'; }
    ensure_guest_ready() { :; }
    use_app_window_paths() { printf 'started\n' >>"${T}/calls"; exit 0; }
  fi
  ( APP_SHIFT_CHECK="true"
    open_app_window com.example.game false "" "" ) || true
  expect_equal "$(<"${T}/calls")" $'options com.example.game\nstarted' \
    "Apply and start starts the game (Ika running: ${live})"
done

echo "ok: Shift's Startup Options start the app on Apply and start"
