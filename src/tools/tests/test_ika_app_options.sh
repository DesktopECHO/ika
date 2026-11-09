#!/usr/bin/bash

# App start options ("Startup options" on a launcher, ika app --options):
# the window ticks the saved options and saves the ticked ones (tested in
# test_ika_app_settings_window.sh),
# ~/ika/app-options.ini keeps one section per app, and
# 'ika app' adds the saved options to those it is given.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
export XDG_DATA_HOME="${T}/data"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"

export PATH="${T}/bin:${PATH}"

source "${ROOT}/tools/ika"
# App IDs and launcher names as on a Linux desktop, also when run on WSLg.
IKA_ON_WSLG=false
log() { printf '%s\n' "$*" >>"${T}/log"; }
notify_user() { :; }

# The device is never reached. On a host where Ika runs, 127.0.0.1:6520 (the
# serial stubbed below) is the live one, and an app window's title lookup asked
# it for its apps, which replaced the app list cached here. adb and scrcpy
# fail, as with no device.
cat >"${T}/bin/no-device" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "${T}/bin/no-device"
resolve_adb_bin() { printf '%s\n' "${T}/bin/no-device"; }
SCRCPY_BIN="${T}/bin/no-device"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

expect_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in: $1"
}

mkdir -p "${IKA_APPS_DIR}"
printf 'com.example.game\n' > "${APP_GAMES_FILE}"
printf 'Some Game\tcom.example.game\nSome App\tcom.example.app\n' > "${APP_LIST_CACHE}"

# Saving and reading back, one section per app.
expect_equal "$(saved_app_options com.example.game)" "" "no file, no options"
save_app_options com.example.game fullscreen touch
save_app_options com.example.app fullscreen
expect_equal "$(saved_app_options com.example.game)" "fullscreen touch" "a game's options"
expect_equal "$(saved_app_options com.example.app)" "fullscreen" "an app's options"
expect_equal "$(saved_app_options com.example)" "" "a package that is a prefix of another"
expect_equal "$(head -n1 "${APP_OPTIONS_FILE}")" \
  "# Start options of Android apps, one section per app, named by its package." \
  "the file starts with its explanation"
save_app_options com.example.game keyboard
expect_equal "$(saved_app_options com.example.game)" "keyboard" "options replaced"
expect_equal "$(saved_app_options com.example.app)" "fullscreen" "other apps kept"
expect_equal "$(grep -c '^\[com.example.game\]$' "${APP_OPTIONS_FILE}")" "1" "one section per app"
for _ in 1 2 3; do
  save_app_options com.example.game touch
done
grep -q '^# Start options of Android apps' "${APP_OPTIONS_FILE}" || fail "the explanation was dropped"
[[ "$(cat -s "${APP_OPTIONS_FILE}")" == "$(<"${APP_OPTIONS_FILE}")" ]] \
  || fail "saving again left blank lines behind: $(<"${APP_OPTIONS_FILE}")"
save_app_options com.example.game
expect_equal "$(saved_app_options com.example.game)" "" "options removed"
app_options_saved com.example.game || fail "an app without options lost its section"
if app_options_saved com.example; then
  fail "a package that is a prefix of another has a section"
fi
expect_equal "$(saved_app_options com.example.app)" "fullscreen" "other apps kept after a removal"
# Edited by hand: spaces around =, a Windows line end, another key.
printf '\n[com.example.edited]\nnote = mine\n  options   =  fullscreen   touch \r\n' >> "${APP_OPTIONS_FILE}"
expect_equal "$(saved_app_options com.example.edited)" "fullscreen   touch" "a hand-edited section"
echo "ok: options saved and read back per app, others and comments kept"

# The display density: auto (empty, 0 or auto), 96 for 1 to 95, up to 999.
for case in ":" "0:" "auto:" "AUTO:" "50:96" "96:96" "160.000000:160" "999:999"; do
  expect_equal "$(app_dpi_value "${case%%:*}")" "${case#*:}" "density ${case%%:*}"
done
for bad in 1000 big -5 12x; do
  if app_dpi_value "${bad}" >/dev/null; then
    fail "density ${bad} was taken"
  fi
done
# Saved beside the options, kept when only the options change, gone for auto.
save_app_options_with_dpi com.example.game 240 fullscreen
expect_equal "$(saved_app_dpi com.example.game):$(saved_app_options com.example.game)" "240:fullscreen" "a density saved"
save_app_options com.example.game touch
expect_equal "$(saved_app_dpi com.example.game):$(saved_app_options com.example.game)" "240:touch" "the density is kept"
expect_contains "$(<"${APP_OPTIONS_FILE}")" $'[com.example.game]\noptions = touch\ndpi = 240' "one line in the app's section"
save_app_options_with_dpi com.example.game "" touch
expect_equal "$(saved_app_dpi com.example.game)" "" "auto removes the density"
if grep -q '^dpi' "${APP_OPTIONS_FILE}"; then
  fail "auto left a dpi line"
fi
# Edited by hand: too low is 96, not a number is reported and left out.
printf '\n[com.example.lowdpi]\noptions =\ndpi = 50\n[com.example.baddpi]\ndpi = big\n' >> "${APP_OPTIONS_FILE}"
expect_equal "$(saved_app_dpi com.example.lowdpi)" "96" "a hand-edited density under 96"
: >"${T}/log"
expect_equal "$(saved_app_dpi com.example.baddpi)" "" "a hand-edited density that is not one"
expect_contains "$(<"${T}/log")" "dpi 'big' of com.example.baddpi is not auto or 96 to 999; ignored" "it is reported"
save_app_options com.example.game
echo "ok: the display density is saved per app, 96 to 999"

# 'ika app' adds the saved options to those it is given, and the HID devices
# go to the app's input, replacing any inherited.
fullscreen="false"
unset IKA_TOUCH IKA_APP_INPUT
: >"${T}/log"
printf '\n[com.example.odd]\noptions = window --game gamekb touch fullscreen mouse keyboard gamepad\n' >> "${APP_OPTIONS_FILE}"
apply_saved_app_options com.example.odd fullscreen
expect_equal "${fullscreen}:${IKA_TOUCH:-}" "true:1" "saved options applied"
expect_equal "${IKA_APP_INPUT}" "gamekb mouse keyboard gamepad" "the HID devices"
expect_equal "$(bash -c 'printf %s "${IKA_APP_INPUT:-}"')" "gamekb mouse keyboard gamepad" \
  "the HID devices reach the app window's console client"
export IKA_APP_INPUT="inherited"
apply_saved_app_options com.example.odd fullscreen
expect_equal "${IKA_APP_INPUT}" "gamekb mouse keyboard gamepad" "inherited HID devices are replaced"
expect_contains "$(<"${T}/log")" "'--game' is not a start option; ignored" "an unknown option is reported"
expect_contains "$(<"${T}/log")" "'window' is not a start option; ignored" "the former window option is reported"
fullscreen="false"
unset IKA_TOUCH
apply_saved_app_options com.example.none fullscreen
expect_equal "${fullscreen}:${IKA_TOUCH:-}:${IKA_APP_INPUT}" "false::" "nothing saved, nothing applied"

require_executable() { :; }
ensure_guest_ready() { :; }
resolve_adb_serial() { printf '127.0.0.1:6520\n'; }
app_is_installed() { return 0; }
# Stops open_app_window once it opens a window, showing what it opens it with.
use_app_window_paths() {
  printf 'window %s fullscreen=%s input=%s touch=%s\n' "$1" "${fullscreen_mode}" \
    "${IKA_APP_INPUT}" "${IKA_TOUCH:-}"
  exit 0
}
save_app_options com.example.game keyboard gamepad touch
output="$(open_app_window com.example.game false "" "")"
expect_equal "${output}" "window com.example.game fullscreen=false input=keyboard gamepad touch=1" \
  "a game opens in a window with the saved input"
save_app_options com.example.game fullscreen mouse
output="$(open_app_window com.example.game false "" "")"
expect_equal "${output}" "window com.example.game fullscreen=true input=mouse touch=" \
  "a saved fullscreen makes the window fullscreen"
save_app_options com.example.game
output="$(open_app_window com.example.game false "" "")"
expect_equal "${output}" "window com.example.game fullscreen=false input= touch=" "without saved options"
output="$(open_app_window com.example.game true "" "")"
expect_equal "${output}" "window com.example.game fullscreen=true input= touch=" "options given are kept"
echo "ok: 'ika app' adds the saved options, from the menu or a terminal"

# The app a window starts: the app itself, force-stopped first, or the start
# given (App info opens with "+info:PACKAGE").
start_app_of() (
  use_app_window_paths() { SCRCPY_SUPERVISOR_PID_FILE="${T}/none.pid"; SCRCPY_LOG_FILE="${T}/window.log"; }
  # The supervisor is registered once setsid has run it.
  supervisor_pid_from_file() { [[ -e "${T}/start-app" ]]; }
  read_scrcpy_window_state() { return 1; }
  default_app_window_size() { printf '1280x720\n'; }
  guest_ui_mode() { printf 'desktop\n'; }
  guest_display_density() { printf '160\n'; }
  add_cuttlefish_display() { printf '2\n'; }
  resolve_cuttlefish_frames_socket() { printf '%s\n' "${T}/frames"; }
  setsid() {
    local arg
    for arg in "$@"; do
      [[ "${arg}" != --start-app=* ]] || printf '%s\n' "${arg#--start-app=}" >"${T}/start-app"
    done
  }
  rm -f "${T}/start-app"
  open_app_window "$@" >/dev/null
  cat "${T}/start-app"
)
expect_equal "$(start_app_of com.example.game false "" "")" "+com.example.game" "an app window starts its app"
expect_equal "$(start_app_of com.android.settings false "" "" "+info:com.example.game")" \
  "+info:com.example.game" "a window starts what it is given to start"
echo "ok: an app window starts its app, or what it is given"

# The window's display density: the console's, else the app's saved one, else
# the one given to 'ika app' (auto keeps the console's).
density_of() (
  use_app_window_paths() { SCRCPY_SUPERVISOR_PID_FILE="${T}/none.pid"; SCRCPY_LOG_FILE="${T}/window.log"; }
  supervisor_pid_from_file() { [[ -e "${T}/dpi" ]]; }
  read_scrcpy_window_state() { return 1; }
  default_app_window_size() { printf '1280x720\n'; }
  guest_ui_mode() { printf 'desktop\n'; }
  guest_display_density() { printf '160\n'; }
  add_cuttlefish_display() { printf '%s\n' "$2" >"${T}/display-dpi"; printf '2\n'; }
  resolve_cuttlefish_frames_socket() { printf '%s\n' "${T}/frames"; }
  setsid() {
    local arg
    for arg in "$@"; do
      [[ "${arg}" != --dpi=* ]] || printf '%s\n' "${arg#--dpi=}" >"${T}/dpi"
    done
  }
  rm -f "${T}/dpi" "${T}/display-dpi"
  open_app_window "$@" >/dev/null
  printf '%s/%s\n' "$(<"${T}/display-dpi")" "$(<"${T}/dpi")"
)
expect_equal "$(density_of com.example.app false "" "")" "160/160" "the console's density"
save_app_options_with_dpi com.example.app 240 fullscreen
expect_equal "$(density_of com.example.app false "" "")" "240/240" "the app's saved density"
expect_equal "$(density_of com.example.app false "" "" "" 320)" "320/320" "a density given to 'ika app'"
expect_equal "$(density_of com.example.app false "" "" "" auto)" "160/160" "--dpi=auto keeps the console's"
save_app_options_with_dpi com.example.app "" fullscreen
echo "ok: an app window has the app's own display density"

# ika app --dpi: auto or 0, 96 to 999, 1 to 95 as 96
dpi_given_by() (
  open_app_window() { printf '%s\n' "${6:-}"; }
  run_app_command com.example.app "$@"
)
expect_equal "$(dpi_given_by --dpi=200)" "200" "--dpi=N"
expect_equal "$(dpi_given_by --dpi 50)" "96" "--dpi N under 96"
expect_equal "$(dpi_given_by --dpi=0):$(dpi_given_by --dpi=auto)" "auto:auto" "--dpi=0 and --dpi=auto"
expect_equal "$(dpi_given_by)" "" "without --dpi"
if (dpi_given_by --dpi=1000) >/dev/null 2>&1; then
  fail "--dpi=1000 was taken"
fi
echo "ok: ika app --dpi"

# On WSLg, an app launched from a menu (no terminal) with Shift held down opens
# its Startup Options; without Shift, or outside WSLg, its window. A PowerShell
# stub prints the Windows modifier keys, SHIFT_KEYS (Keys.Shift is 65536).
cat >"${T}/bin/powershell.exe" <<STUB
#!/usr/bin/env bash
printf '%s\r\n' "\${SHIFT_KEYS:-0}"
printf 'asked\n' >>"${T}/powershell.calls"
STUB
chmod +x "${T}/bin/powershell.exe"
# main asks Windows in the background, and open_app_window reads the answer:
# before the guest queries when Ika does not run yet (VM_RUNNING false), else
# after them, so that Shift opens the Startup Options without starting Ika
# first ("Ika started" is ensure_guest_ready starting it). The real
# open_app_window runs, up to where it would start the app
# (apply_saved_app_options).
launched_with() (
  IKA_ON_WSLG="$1"
  export SHIFT_KEYS="$2"
  export IKA_WSL_GPU_FIX=0
  edit_app_settings() { printf 'options %s %s\n' "$1" "$2"; }
  release_app_settings_lock() { :; }
  require_executable() { :; }
  has_live_cvd_processes() { [[ "${VM_RUNNING:-false}" == true ]]; }
  wayland_info_output() { :; }
  ensure_guest_ready() { [[ "${VM_RUNNING:-false}" == true ]] || printf 'Ika started\n'; }
  resolve_adb_serial() { printf '127.0.0.1:6520\n'; }
  app_is_installed() { return 0; }
  app_display_name() { printf 'Some App\n'; }
  validate_app_package() { :; }
  apply_saved_app_options() { printf 'window %s\n' "${package}"; exit 0; }
  main app com.example.app </dev/null 2>/dev/null
)
expect_equal "$(launched_with true 65536)" "options com.example.app 1" "Shift held at a launch from Windows"
expect_equal "$(VM_RUNNING=true launched_with true 65536)" "options com.example.app 1" \
  "Shift held at a launch from Windows while Ika runs"
expect_equal "$(launched_with true 0)" $'Ika started\nwindow com.example.app' "a launch from Windows without Shift"
expect_equal "$(VM_RUNNING=true launched_with true 0)" "window com.example.app" \
  "a launch from Windows without Shift while Ika runs"
expect_equal "$(VM_RUNNING=true launched_with true 131072)" "window com.example.app" "Ctrl held at a launch from Windows"
rm -f "${T}/powershell.calls"
expect_equal "$(VM_RUNNING=true launched_with false 65536)" "window com.example.app" "Shift held outside WSLg"
[[ ! -e "${T}/powershell.calls" ]] || fail "PowerShell was asked outside WSLg"
# The same for Ika itself: 'ika start' from the Start menu opens Ika's
started_with() (
  IKA_ON_WSLG="$1"
  export SHIFT_KEYS="$2" IKA_WSL_GPU_FIX=0
  edit_ika_settings() { printf 'ika options\n'; }
  run_timed_operation() { printf 'ika started\n'; }
  stop_startup_packaged_scrcpy() { :; }
  redirect_start_logs() { :; }
  repair_wslg_taskbar_pins() { :; }
  main start </dev/null 2>/dev/null
)
expect_equal "$(started_with true 65536)" "ika options" "Shift held at Ika's start from Windows"
expect_equal "$(started_with true 0)" "ika started" "Ika's start from Windows without Shift"
expect_equal "$(started_with false 65536)" "ika started" "Shift held at Ika's start outside WSLg"
rm -f "${T}/bin/powershell.exe"
echo "ok: Shift at a launch from Windows opens the Startup Options"


# The launcher offers the window, for games and other apps alike.
apps_dir="$(app_menu_data_dir)/applications"
mkdir -p "${apps_dir}"
for package in com.example.game com.example.app; do
  file="${apps_dir}/ika-${package}.desktop"
  write_app_launcher "${apps_dir}" "Some Label" "${package}" /icons/app.png
  expect_contains "$(<"${file}")" \
    $'[Desktop Action options]\nName=Startup options\nExec=ika app --options '"${package}" \
    "${package}'s launcher offers the start options"
  # GNOME Shell's "New Window" gives way to "Launch app"; the app has one window
  expect_contains "$(<"${file}")" \
    $'[Desktop Action new-window]\nName=Launch app\nExec=ika app '"${package}" \
    "${package}'s launcher offers Launch app"
  grep -qxF "SingleMainWindow=true" "${file}" || fail "${package}'s launcher allows more than one window"
  # KDE Plasma shows an action's icon: the Ika icon for Launch app and the
  # start options, the Settings app's for App info
  expect_equal "$(launcher_action_value "${file}" new-window Icon)" "${IKA_MENU_ICON}" "${package}'s Launch app icon"
  expect_equal "$(launcher_action_value "${file}" options Icon)" "${IKA_MENU_ICON}" "${package}'s start options icon"
  expect_equal "$(launcher_action_value "${file}" app-settings Icon)" "$(app_menu_icon com.android.settings)" \
    "${package}'s App info icon"
  if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "${file}" >/dev/null || fail "${package}'s launcher is invalid"
  fi
  if write_app_launcher "${apps_dir}" "Some Label" "${package}" /icons/app.png; then
    fail "${package}'s launcher was rewritten although it was current"
  fi
done
# Games and other apps offer the same actions, Launch app first, without a
# controller mapping
for package in com.example.game com.example.app; do
  grep -qxF "Actions=new-window;options;app-settings;" "${apps_dir}/ika-${package}.desktop" \
    || fail "${package}'s actions"
  if grep -q "Desktop Action controller" "${apps_dir}/ika-${package}.desktop"; then
    fail "${package}'s launcher offers the controller mapping"
  fi
done
# A launcher whose Launch app and start options have no icon, as they were
# written before, gets them
sed -i "/^Icon=${IKA_MENU_ICON}\$/d" "${apps_dir}/ika-com.example.app.desktop"
write_app_launcher "${apps_dir}" "Some Label" com.example.app /icons/app.png \
  || fail "a launcher without the actions' icons was kept"
expect_equal "$(launcher_action_value "${apps_dir}/ika-com.example.app.desktop" new-window Icon):$(launcher_action_value "${apps_dir}/ika-com.example.app.desktop" options Icon)" \
  "${IKA_MENU_ICON}:${IKA_MENU_ICON}" "the actions get the Ika icon"
# A game's launcher with the former "Controller mapping..." action loses it
sed -i -e 's/^Actions=.*/Actions=options;controller;app-settings;/' "${apps_dir}/ika-com.example.game.desktop"
printf '\n[Desktop Action controller]\nName=Controller mapping...\nExec=ika app --controller com.example.game\nIcon=input-gaming\n' \
  >> "${apps_dir}/ika-com.example.game.desktop"
write_app_launcher "${apps_dir}" "Some Label" com.example.game /icons/app.png \
  || fail "a game's launcher with the controller mapping was kept"
grep -qxF "Actions=new-window;options;app-settings;" "${apps_dir}/ika-com.example.game.desktop" \
  || fail "the controller mapping stayed in a game's actions"
if grep -q -e "Desktop Action controller" -e "Controller mapping" "${apps_dir}/ika-com.example.game.desktop"; then
  fail "the controller mapping action stayed in a game's launcher"
fi
for old_name in "Ika start options..." "Ika Startup Options..." "Ika Startup Options" "Ika startup options"; do
  sed -i "s/^Name=Startup options$/Name=${old_name}/" "${apps_dir}/ika-com.example.app.desktop"
  write_app_launcher "${apps_dir}" "Some Label" com.example.app /icons/app.png \
    || fail "a launcher with the start options action named ${old_name} was kept"
  grep -qxF "Name=Startup options" "${apps_dir}/ika-com.example.app.desktop" \
    || fail "the start options action named ${old_name} was not renamed"
done
for old_name in "Android App Settings..." "Android App Info..." "App Info"; do
  sed -i "s/^Name=App info$/Name=${old_name}/" "${apps_dir}/ika-com.example.app.desktop"
  write_app_launcher "${apps_dir}" "Some Label" com.example.app /icons/app.png \
    || fail "a launcher with the App info action named ${old_name} was kept"
  grep -qxF "Name=App info" "${apps_dir}/ika-com.example.app.desktop" \
    || fail "the App info action named ${old_name} was not renamed"
done
sed -i 's/^Exec=ika app --options .*/Exec=ika app --options com.example.other/' \
  "${apps_dir}/ika-com.example.app.desktop"
write_app_launcher "${apps_dir}" "Some Label" com.example.app /icons/app.png \
  || fail "a launcher whose start options action runs something else was kept"
grep -qxF "Exec=ika app --options com.example.app" "${apps_dir}/ika-com.example.app.desktop" \
  || fail "the start options action was not restored"
# A launcher written before the window existed gets it.
printf '[Desktop Entry]\nType=Application\nName=old\nExec=ika app com.example.old\nActions=app-settings;\n\n[Desktop Action app-settings]\nName=App Settings\nExec=ika app --info com.example.old\n' \
  > "${apps_dir}/ika-com.example.old.desktop"
write_app_launcher "${apps_dir}" "Old" com.example.old /icons/app.png || fail "an old launcher was not updated"
grep -qxF "Exec=ika app --options com.example.old" "${apps_dir}/ika-com.example.old.desktop" \
  || fail "an old launcher did not get the start options"
grep -qxF "Name=Launch app" "${apps_dir}/ika-com.example.old.desktop" \
  || fail "an old launcher did not get Launch app"
expect_equal "$(grep -c '^\[Desktop Action app-settings\]$' "${apps_dir}/ika-com.example.old.desktop")" "1" \
  "an old launcher's settings action is not doubled"
echo "ok: launchers offer \"Startup options\""

# GNOME Shell does not reload a launcher whose actions change in place, so a
# launcher written before the window existed leaves the applications directory
# while the caches are refreshed and comes back with it; a current one stays.
pgrep() { [[ "$*" == *gnome-shell* ]]; }
sleep() { :; }
refresh_app_menu_caches() {
  if [[ -e "${apps_dir}/ika-com.example.game.desktop" ]]; then
    echo present >>"${T}/refresh"
  else
    echo parked >>"${T}/refresh"
  fi
}
write_app_launcher "${apps_dir}" "Some Game" com.example.game "$(app_menu_icon com.example.game)" || true
sed -i -e 's/^Actions=.*/Actions=touch;app-settings;/' -e 's/^X-Ika-Version=.*/X-Ika-Version=4/' \
  "${apps_dir}/ika-com.example.game.desktop"
printf '\n[Desktop Action touch]\nName=Play with Touch Input\nExec=ika app --touch com.example.game\n' \
  >> "${apps_dir}/ika-com.example.game.desktop"
: >"${T}/refresh"
updated="$(refresh_changed_launchers "${apps_dir}" $'Some Game\tcom.example.game')"
expect_equal "${updated}" "1" "a launcher with old actions is re-added"
expect_equal "$(<"${T}/refresh")" "parked" "it is out of the applications directory while GNOME Shell rescans"
app_launcher_is_current "${apps_dir}" "Some Game" com.example.game "$(app_menu_icon com.example.game)" \
  || fail "the re-added launcher is not current"
grep -qxF "Actions=new-window;options;app-settings;" "${apps_dir}/ika-com.example.game.desktop" \
  || fail "the re-added launcher has no start options"
if grep -q -e 'Desktop Action touch' -e 'Play with Touch Input' "${apps_dir}/ika-com.example.game.desktop"; then
  fail "the re-added launcher kept Play with Touch Input"
fi
: >"${T}/refresh"
updated="$(refresh_changed_launchers "${apps_dir}" $'Some Game\tcom.example.game')"
expect_equal "${updated}:$(<"${T}/refresh")" "0:" "a current launcher stays"
echo "ok: GNOME Shell gets launchers whose actions changed as new apps"

# A game added to the menu starts with Fullscreen mode and the keyboard straight
# to Android ticked, unless its options were set before; other apps and games
# already in the menu are left alone.
require_executable() { :; }
has_live_cvd_processes() { return 0; }
adb_boot_completed() { return 0; }
export_app_icons() { return 0; }
install_xdg_app_menu() { :; }
install_gnome_app_folder() { :; }
list_guest_apps() { printf '%s' "${GUEST_APPS}"; }
printf 'com.example.game\ncom.example.newgame\ncom.example.setgame\n' > "${APP_GAMES_FILE}"
save_app_options com.example.setgame
GUEST_APPS=$'Some Game\tcom.example.game\nNew Game\tcom.example.newgame\nSet Game\tcom.example.setgame\nNew App\tcom.example.newapp\n'
sync_app_menu >/dev/null 2>&1
expect_equal "$(saved_app_options com.example.newgame)" "fullscreen keyboard" "a new game starts fullscreen, the keyboard straight to Android"
expect_equal "$(saved_app_options com.example.setgame)" "" "a new game whose options were set keeps them"
if app_options_saved com.example.newapp; then
  fail "a new app that is not a game got options"
fi
save_app_options com.example.game touch
sync_app_menu >/dev/null 2>&1
expect_equal "$(saved_app_options com.example.game)" "touch" "a game already in the menu keeps its options"
save_app_options com.example.newgame
rm -f "$(app_menu_data_dir)/applications/ika-com.example.newgame.desktop"
sync_app_menu >/dev/null 2>&1
expect_equal "$(saved_app_options com.example.newgame)" "" "a game unticked before comes back without the default"
echo "ok: a game added to the menu starts with Fullscreen mode and the keyboard straight to Android ticked"

# On WSLg, app IDs and launcher names have dashes for dots, as WSLg finds no
# icon for an app ID with dots, and a sync replaces the launchers with dots;
# back on a Linux desktop, the sync puts them back.
apps="$(app_menu_data_dir)/applications"
IKA_ON_WSLG=true
expect_equal "$(app_window_id com.example.game)" "ika-com-example-game" "WSLg: the app ID has dashes"
sync_app_menu >/dev/null 2>&1
[[ -f "${apps}/ika-com-example-game.desktop" ]] || fail "WSLg: no launcher named with dashes"
[[ ! -e "${apps}/ika-com.example.game.desktop" ]] || fail "WSLg: the launcher named with dots stayed"
grep -qxF "StartupWMClass=ika-com-example-game" "${apps}/ika-com-example-game.desktop" \
  || fail "WSLg: the launcher names another window class"
IKA_ON_WSLG=false
sync_app_menu >/dev/null 2>&1
[[ -f "${apps}/ika-com.example.game.desktop" && ! -e "${apps}/ika-com-example-game.desktop" ]] \
  || fail "the launchers named with dashes stayed after WSLg"
echo "ok: WSLg launchers and app IDs have dashes for dots"

# "App info" opens the Settings window with App info as its
# first page, so the Settings home page never shows.
app_window_is_open() { return 1; }
open_app_window() { printf '%s|' "$@" >"${T}/opened"; }
guest_adb() { shift; printf '%s\n' "$*" >"${T}/am-start"; }
rm -f "${T}/am-start"
open_app_info com.example.game >/dev/null
expect_equal "$(<"${T}/opened")" "com.android.settings|false|||+info:com.example.game|" \
  "the Settings window opens with App info"
[[ ! -e "${T}/am-start" ]] || fail "App info was started again in a new Settings window"
echo "ok: App info opens a Settings window of its own"

# In an open Settings window, App info replaces the window's Settings pages,
# as a subpage, so that Settings shows no two-pane list beside it.
app_window_is_open() { [[ "$1" == com.android.settings ]]; }
mkdir -p "${IKA_APPS_DIR}/com.android.settings"
printf 'INFO: Starting app "Settings" on display 7...\n' > "${IKA_APPS_DIR}/com.android.settings/window.log"
guest_adb() { shift; printf '%s\n' "$*" >"${T}/am-start"; }
open_app_info com.example.game >/dev/null
expect_equal "$(<"${T}/am-start")" \
  "shell am start --display 7 -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:com.example.game --ez :settings:show_fragment_as_subsetting true -f 0x10008000" \
  "App info replaces the Settings window's pages, as a subpage"
echo "ok: App info opens alone in the Settings window"

printf 'PASS: app start options\n'
