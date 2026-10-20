#!/usr/bin/env bash

# IkaMode's switcher changes Android's mode, and the console follows Android: in
# TV mode it opens fullscreen, at 1.5 times the automatic density unless
# tv_dpi sets one, with the gamepad passed through as the remote, and keeps
# its own window state.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export HOME="${T}/home" CVD_HOME_DIR="${T}/ika" CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"
unset IKADPI IKA_TV_DPI IKA_SCRCPY IKA_APP_INPUT IKA_TOUCH
source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  [[ "$2" == "$1" ]] || fail "$3: expected '$1', got '$2'"
}

# The mode Android booted in: TV mode adds the leanback feature.
host_adb() { printf 'true\r\n'; }
assert_equal "tv" "$(guest_ui_mode serial)" "TV guest"
host_adb() { printf 'false\r\n'; }
assert_equal "desktop" "$(guest_ui_mode serial)" "desktop guest"
host_adb() { return 1; }
assert_equal "" "$(guest_ui_mode serial)" "guest not answering"

# TV density: 1.5 times the automatic density, unless tv_dpi sets one.
host_display_size() { printf '1920x1080\n'; }
assert_equal "168" "$(resolve_scrcpy_dpi "")" "desktop density"
assert_equal "248" "$(resolve_tv_dpi)" "1080p TV density"
host_display_size() { printf '3456x2160\n'; }
assert_equal "480" "$(resolve_tv_dpi)" "MacBook Pro TV density"
assert_equal "480" "$(IKADPI=200 resolve_tv_dpi)" "TV density ignores the desktop's dpi"
assert_equal "240" "$(IKA_TV_DPI=240 resolve_tv_dpi)" "tv_dpi"
host_display_size() { return 1; }
assert_equal "216" "$(resolve_tv_dpi 2>/dev/null)" "TV density without a display size"

# The TV console passes the gamepad through as the remote and keeps the SDK
# keyboard; an app's start options do not reach it.
input_args=()
IKA_APP_INPUT="keyboard mouse gamekb" append_scrcpy_input_args input_args tv console 2>/dev/null
assert_equal "--gamepad=uhid --keyboard=sdk --prefer-text" "${input_args[*]}" "TV console input"

# The console launch, with the supervisor stubbed: prints its fullscreen flag
# and the console command.
default_scrcpy_window_size() { printf '1280x720\n'; }
resolve_cuttlefish_frames_socket() { printf '%s\n' "${T}/frames"; }
ensure_chromium() { :; }
has_packaged_scrcpy() { return 0; }
sleep() { :; }
# setsid --fork IKA __console_supervisor SERIAL FULLSCREEN -- COMMAND...
setsid() {
  shift 4
  printf 'fullscreen=%s %s \n' "$1" "${*:3}"
}
console_of() {
  local mode="$1"
  shift
  host_adb() { [[ "${mode}" == "tv" ]] && printf 'true\n' || printf 'false\n'; }
  start_scrcpy_with_retries serial "$@" 2>/dev/null
  # The supervisor starts in the background.
  for _ in {1..100}; do
    [[ -s "${SCRCPY_LOG_FILE}" ]] && break
    env sleep 0.05
  done
  cat "${SCRCPY_LOG_FILE}"
}
host_display_size() { printf '1920x1080\n'; }
SCRCPY_DPI="168"
SCRCPY_DPI_GIVEN="false"

tv_console="$(console_of tv false)"
[[ "${tv_console}" == fullscreen=true* ]] || fail "TV console is not fullscreen: ${tv_console}"
[[ "${tv_console}" == *" --dpi=248 "* ]] || fail "TV console density: ${tv_console}"
[[ "${tv_console}" == *" --gamepad=uhid --keyboard=sdk "* ]] || fail "TV console input: ${tv_console}"
[[ "${tv_console}" == *" --window-state-file=${TV_CONSOLE_WINDOW_STATE_FILE} "* ]] \
  || fail "TV console window state: ${tv_console}"

desktop_console="$(console_of desktop false)"
[[ "${desktop_console}" == fullscreen=false* ]] || fail "desktop console went fullscreen"
[[ "${desktop_console}" == *" --dpi=168 "* ]] || fail "desktop console density: ${desktop_console}"
[[ "${desktop_console}" != *"--gamepad"* ]] || fail "desktop console passes the gamepad"
[[ "${desktop_console}" == *" --window-state-file=${SCRCPY_WINDOW_STATE_FILE} "* ]] \
  || fail "desktop console window state: ${desktop_console}"

# tv_dpi sets the TV console's density only.
IKA_TV_DPI="240"
[[ "$(console_of tv false)" == *" --dpi=240 "* ]] || fail "tv_dpi in TV mode"
[[ "$(console_of desktop false)" == *" --dpi=168 "* ]] \
  || fail "tv_dpi changed the desktop console"

# --dpi wins over tv_dpi in TV mode.
SCRCPY_DPI="200"
SCRCPY_DPI_GIVEN="true"
[[ "$(console_of tv false)" == *" --dpi=200 "* ]] || fail "--dpi in TV mode"

# The mode switch opens in the console on the primary display, not in a window.
scrcpy_supervisor_pid() { printf '123\n'; }
guest_adb() {
  printf '%s\n' "$*" >>"${T}/adb.log"
  case "$*" in
    *resolve-activity*) printf 'org.lineageos.desktop.mode/.SwitcherActivity\n' ;;
  esac
}
open_in_console "${IKA_MODE_PACKAGE}" "Desktop/TV" >/dev/null 2>&1
grep -q -- "am start --display 0 .* -n org.lineageos.desktop.mode/.SwitcherActivity" "${T}/adb.log" \
  || fail "Desktop/TV did not open on the primary display: $(cat "${T}/adb.log")"

# A mode switch brings each console back as it was last used in its mode:
# the console that opens after Android restarted in the other mode takes
# --fullscreen from that mode's own saved window state.
rm -f "${DESKTOP_CONSOLE_WINDOW_STATE_FILE}" "${TV_CONSOLE_WINDOW_STATE_FILE}"
write_window_state() {
  printf 'version=1\nwidth=%s\nheight=%s\nfullscreen=%s\n' "$2" "$3" "$4" >"$1"
}
switch_options=()
console_switch_start_options switch_options desktop
assert_equal "" "${switch_options[*]}" "desktop console without saved state"
console_switch_start_options switch_options tv
assert_equal "" "${switch_options[*]}" "TV console without saved state"
write_window_state "${DESKTOP_CONSOLE_WINDOW_STATE_FILE}" 1280 720 true
console_switch_start_options switch_options desktop
assert_equal "--fullscreen" "${switch_options[*]}" "desktop console last fullscreen"
console_switch_start_options switch_options tv
assert_equal "" "${switch_options[*]}" "TV state is not the desktop's"
write_window_state "${DESKTOP_CONSOLE_WINDOW_STATE_FILE}" 1600 900 false
write_window_state "${TV_CONSOLE_WINDOW_STATE_FILE}" 1280 720 true
console_switch_start_options switch_options desktop
assert_equal "" "${switch_options[*]}" "desktop console last windowed"
console_switch_start_options switch_options tv
assert_equal "--fullscreen" "${switch_options[*]}" "TV console last fullscreen"
printf 'version=2\nfullscreen=true\n' >"${DESKTOP_CONSOLE_WINDOW_STATE_FILE}"
console_switch_start_options switch_options desktop
assert_equal "" "${switch_options[*]}" "unreadable saved state"

# The supervisor's round trip through TV mode, with scrcpy stubbed: it saves
# its window state as the real one does on exit, and exits as disconnected
# by Android's restart. The supervisor then hands over to 'ika start' for the
# new mode, whose options the setsid stub records.
mkdir -p "${CVD_TMP_DIR}"
scrcpy_stub="${T}/scrcpy"
cat >"${scrcpy_stub}" <<'EOF'
#!/usr/bin/env bash
state_file="" width="" height="" fullscreen=false
for arg in "$@"; do
  case "${arg}" in
    --window-state-file=*) state_file="${arg#*=}" ;;
    --window-width=*) width="${arg#*=}" ;;
    --window-height=*) height="${arg#*=}" ;;
    --fullscreen) fullscreen=true ;;
  esac
done
printf '%s\n' "$*" >>"${SCRCPY_STUB_LOG}"
printf 'version=1\nwidth=%s\nheight=%s\nfullscreen=%s\n' \
  "${width}" "${height}" "${fullscreen}" >"${state_file}"
exit "${SCRCPY_STUB_STATUS}"
EOF
chmod +x "${scrcpy_stub}"
export SCRCPY_STUB_LOG="${T}/scrcpy.log" SCRCPY_STUB_STATUS="${SCRCPY_EXIT_DISCONNECTED}"
flock() { :; }
lock_scrcpy_forward_port() { return 1; }
has_live_cvd_processes() { return 0; }
remove_app_cuttlefish_display() { :; }
adb_guest_boot_id() { printf 'boot-0\n'; }
wait_for_guest_reboot() { printf 'boot-%s\n' "${RANDOM}"; }
guest_ui_mode() { printf '%s\n' "${GUEST_MODE}"; }
# setsid --fork bash -c SCRIPT ika-console-switch PID IKA OPTIONS...
setsid() {
  local options="${*:8}"
  printf 'start%s\n' "${options:+ ${options}}" >"${T}/switch"
}
# Runs the console of MODE until Android restarts in NEW_MODE; prints the
# 'ika start' the supervisor handed over to.
console_round() {
  local mode="$1"
  local fullscreen="$2"
  local new_mode="$3"
  local state_file

  state_file="$(mode_console_window_state_file "${mode}")"
  rm -f "${T}/switch"
  : >"${SCRCPY_STUB_LOG}"
  ( GUEST_MODE="${new_mode}"
    run_scrcpy_supervisor serial "${fullscreen}" -- "${scrcpy_stub}" \
      --window-width=1280 --window-height=720 \
      --window-state-file="${state_file}" ) 2>/dev/null \
    || fail "console supervisor of ${mode} mode failed"
  cat "${T}/switch" 2>/dev/null || true
}

# Fullscreen in desktop mode, to TV mode and back: fullscreen again.
rm -f "${DESKTOP_CONSOLE_WINDOW_STATE_FILE}" "${TV_CONSOLE_WINDOW_STATE_FILE}"
assert_equal "start" "$(console_round desktop true tv)" "switch to TV mode"
assert_equal "start --fullscreen" "$(console_round tv true desktop)" "switch back to the desktop"
[[ "$(cat "${SCRCPY_STUB_LOG}")" != *"${DESKTOP_CONSOLE_WINDOW_STATE_FILE}"* ]] \
  || fail "the TV console used the desktop console's window state"
assert_equal "fullscreen=true" "$(grep fullscreen "${DESKTOP_CONSOLE_WINDOW_STATE_FILE}")" \
  "desktop state after the round trip"

# Windowed at 1600x900 in desktop mode, to TV mode and back: that size, not
# fullscreen. The TV console, last fullscreen, keeps that from its own state.
write_window_state "${DESKTOP_CONSOLE_WINDOW_STATE_FILE}" 1600 900 false
assert_equal "start --fullscreen" "$(console_round desktop false tv)" "windowed switch to TV mode"
assert_equal "start" "$(console_round tv true desktop)" "switch back to the desktop"
assert_equal "start --fullscreen" "$(console_round desktop false tv)" "desktop console reopened windowed"
[[ "$(cat "${SCRCPY_STUB_LOG}")" == *"--window-width=1600 --window-height=900"* ]] \
  || fail "desktop console size after the round trip: $(cat "${SCRCPY_STUB_LOG}")"
[[ "$(cat "${SCRCPY_STUB_LOG}")" != *"--fullscreen"* ]] \
  || fail "desktop console went fullscreen after the round trip"
assert_equal "fullscreen=true" "$(grep fullscreen "${TV_CONSOLE_WINDOW_STATE_FILE}")" \
  "TV state after the round trip"

printf 'ika TV mode tests passed\n'
