#!/usr/bin/bash

# App start options ("Ika Startup Options..." on a launcher, ika app --options):
# the window ticks the saved options and saves the ticked ones, yad draws it,
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

# A yad stub: it records its arguments, one per line, and GTK_THEME, and
# prints DIALOG_OUTPUT, exiting with DIALOG_STATUS: 2 for "Apply settings", 0
# for "Apply and start", 1 for Cancel.
cat >"${T}/bin/yad" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${T}/yad.args"
printf '%s\n' "\${GTK_THEME:-}" > "${T}/yad.theme"
printf '%s' "\${DIALOG_OUTPUT:-}"
exit "\${DIALOG_STATUS:-2}"
STUB
chmod +x "${T}/bin/yad"
export PATH="${T}/bin:${PATH}"

source "${ROOT}/tools/ika"
log() { printf '%s\n' "$*" >>"${T}/log"; }
notify_user() { :; }

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

# yad's form output for the options given ticked: the label's empty value,
# then TRUE or FALSE for each checkbox, in their order, then the blank label's.
form_output() {
  local option
  local output="|"

  for option in fullscreen keyboard mouse gamepad gamekb touch; do
    if [[ " $* " == *" ${option} "* ]]; then
      output+="TRUE|"
    else
      output+="FALSE|"
    fi
  done
  printf '%s\n' "${output}|"
}

# open_app_window as "Apply and start" calls it.
open_app_window() { printf 'started %s %s\n' "$1" "$2" >>"${T}/started"; }
host_color_scheme() { :; }

# The window: yad lists the options, ticked as saved, under a heading that
# names the app, and "Apply settings" saves the ticked ones in their usual
# order.
save_app_options com.example.game touch
: >"${T}/started"
DIALOG_OUTPUT="$(form_output touch gamekb fullscreen keyboard)" edit_app_options com.example.game >/dev/null
dialog_args="$(<"${T}/yad.args")"
expect_contains "${dialog_args}" $'--form\n--title=\n' "a form without a title, for a blank title bar where KWin draws one"
expect_contains "${dialog_args}" "<span font_size='15pt' weight='bold'>Ika Startup Options</span>" "the heading"
expect_contains "${dialog_args}" "<span font_size='15pt' weight='bold'>Some Game</span>" "the heading names the app"
expect_contains "${dialog_args}" $'\n--field=Start Some Game with:\n<span font_size=\'5pt\'> </span>:LBL\n\n' \
  "the line above the checkboxes, with a half line of space under it"
expect_contains "${dialog_args}" $'--field=  Fullscreen mode:CHK\nFALSE\n--field=  Pass the keyboard through as a HID device:CHK\nFALSE\n--field=  Pass the mouse through as a HID device:CHK\nFALSE\n--field=  Enable gamepads when attached:CHK\nFALSE\n--field=  Use the keyboard to emulate a gamepad:CHK\nFALSE\n--field=  Touch input: Left-click and drag gets interpreted as tap and swipe:CHK\nTRUE\n--field=<span font_size=\'8pt\'> </span>:LBL\n\n' \
  "the options, saved touch ticked, then space above the buttons"
expect_contains "${dialog_args}" $'--button=Apply settings:2\n--button=        Apply and start        :0\n--button=Cancel:1' \
  "Apply settings, Apply and start and Cancel, in that order"
expect_contains "${dialog_args}" $'\n--undecorated\n' "no title bar"
expect_equal "$(saved_app_options com.example.game)" "fullscreen keyboard gamekb touch" "the ticked options are saved in order"
expect_equal "$(<"${T}/started")" "" "Apply settings does not start the app"
DIALOG_OUTPUT="$(form_output)" edit_app_options com.example.game >/dev/null
expect_equal "$(saved_app_options com.example.game)" "" "nothing ticked leaves no options"
app_options_saved com.example.game || fail "an app with nothing ticked lost its section"

# "Apply and start" saves the ticked options and starts the app with them.
DIALOG_OUTPUT="$(form_output fullscreen mouse)" DIALOG_STATUS=0 edit_app_options com.example.app >/dev/null
expect_equal "$(saved_app_options com.example.app)" "fullscreen mouse" "Apply and start saves the options"
expect_equal "$(<"${T}/started")" "started com.example.app false" "Apply and start starts the app"

# Cancel and closing the window keep the saved options; a window that fails
# to open is an error.
: >"${T}/started"
output="$(DIALOG_STATUS=1 DIALOG_OUTPUT="$(form_output touch)" edit_app_options com.example.app)"
expect_equal "${output}" "Start options of Some App left as they were" "cancel is reported"
expect_equal "$(saved_app_options com.example.app)" "fullscreen mouse" "cancel keeps the options"
DIALOG_STATUS=252 edit_app_options com.example.app >/dev/null
expect_equal "$(saved_app_options com.example.app)" "fullscreen mouse" "closing the window keeps the options"
if (DIALOG_STATUS=70 edit_app_options com.example.app) >/dev/null 2>&1; then
  fail "a window that failed to open was not an error"
fi
expect_equal "$(saved_app_options com.example.app)" "fullscreen mouse" "a failed window keeps the options"
expect_equal "$(<"${T}/started")" "" "no app starts without Apply and start"

# A label is looked up among the apps.
DIALOG_OUTPUT="$(form_output touch)" edit_app_options "some app" >/dev/null
expect_equal "$(saved_app_options com.example.app)" "touch" "the window opened by label"

# yad reads the heading and the labels as markup with backslash escapes, so a
# label is escaped; an app without a known label is named by its package.
printf 'Tom & <b>Jerry</b> C:\\new\tcom.example.tricky\n' >> "${APP_LIST_CACHE}"
DIALOG_OUTPUT="$(form_output)" edit_app_options com.example.tricky >/dev/null
expect_contains "$(<"${T}/yad.args")" "weight='bold'>Tom &amp; &lt;b&gt;Jerry&lt;/b&gt; C:\\\\new</span>" \
  "a heading with markup characters and a backslash"
expect_contains "$(<"${T}/yad.args")" $'\n--field=Start Tom &amp; &lt;b&gt;Jerry&lt;/b&gt; C:\\\\new with:\n' \
  "a label with markup characters and a backslash"
DIALOG_OUTPUT="$(form_output)" edit_app_options com.example.unknown >/dev/null
expect_contains "$(<"${T}/yad.args")" "weight='bold'>com.example.unknown</span>" "an app without a label"

# The window follows a dark desktop, unless GTK_THEME is set.
expect_equal "$(<"${T}/yad.theme")" "" "a light desktop keeps the GTK theme"
host_color_scheme() { echo dark; }
DIALOG_OUTPUT="$(form_output)" edit_app_options com.example.app >/dev/null
expect_equal "$(<"${T}/yad.theme")" "Adwaita:dark" "a dark desktop"
DIALOG_OUTPUT="$(form_output)" GTK_THEME=Breeze edit_app_options com.example.app >/dev/null
expect_equal "$(<"${T}/yad.theme")" "Breeze" "GTK_THEME wins"
host_color_scheme() { :; }
echo "ok: yad draws the window; Apply settings saves, Apply and start also starts the app"

# A host without yad is told so.
command() {
  [[ "$*" != "-v yad" ]] || return 1
  builtin command "$@"
}
: >"${T}/log"
if (edit_app_options com.example.game) >/dev/null 2>&1; then
  fail "the window opened without yad"
fi
expect_contains "$(<"${T}/log")" "the start options window needs yad" "a missing yad is reported"
unset -f command
echo "ok: a host without yad is told so"

# The launcher offers the window, for games and other apps alike.
apps_dir="$(app_menu_data_dir)/applications"
mkdir -p "${apps_dir}"
for package in com.example.game com.example.app; do
  file="${apps_dir}/ika-${package}.desktop"
  write_app_launcher "${apps_dir}" "Some Label" "${package}" /icons/app.png
  expect_contains "$(<"${file}")" \
    $'[Desktop Action options]\nName=Ika Startup Options...\nExec=ika app --options '"${package}" \
    "${package}'s launcher offers the start options"
  if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "${file}" >/dev/null || fail "${package}'s launcher is invalid"
  fi
  if write_app_launcher "${apps_dir}" "Some Label" "${package}" /icons/app.png; then
    fail "${package}'s launcher was rewritten although it was current"
  fi
done
grep -qxF "Actions=options;controller;app-settings;" "${apps_dir}/ika-com.example.game.desktop" \
  || fail "a game's actions"
expect_contains "$(<"${apps_dir}/ika-com.example.game.desktop")" \
  $'[Desktop Action controller]\nName=Controller mapping...\nExec=ika app --controller com.example.game\nIcon=input-gaming' \
  "a game's launcher offers the controller mapping"
grep -qxF "Actions=options;app-settings;" "${apps_dir}/ika-com.example.app.desktop" \
  || fail "an app's actions"
if grep -q "Desktop Action controller" "${apps_dir}/ika-com.example.app.desktop"; then
  fail "an app that is not a game offers the controller mapping"
fi
# A game's launcher without the controller mapping is updated
sed -i -e 's/^Actions=.*/Actions=options;app-settings;/' "${apps_dir}/ika-com.example.game.desktop"
write_app_launcher "${apps_dir}" "Some Label" com.example.game /icons/app.png \
  || fail "a game's launcher without the controller mapping was kept"
grep -qxF "Actions=options;controller;app-settings;" "${apps_dir}/ika-com.example.game.desktop" \
  || fail "the controller mapping was not added to a game's launcher"
sed -i 's/^Name=Ika Startup Options\.\.\.$/Name=Ika start options.../' \
  "${apps_dir}/ika-com.example.app.desktop"
write_app_launcher "${apps_dir}" "Some Label" com.example.app /icons/app.png \
  || fail "a launcher with the start options action's old name was kept"
grep -qxF "Name=Ika Startup Options..." "${apps_dir}/ika-com.example.app.desktop" \
  || fail "the start options action was not renamed"
sed -i 's/^Name=Android App Settings\.\.\.$/Name=App Settings/' "${apps_dir}/ika-com.example.app.desktop"
write_app_launcher "${apps_dir}" "Some Label" com.example.app /icons/app.png \
  || fail "a launcher with the settings action's old name was kept"
grep -qxF "Name=Android App Settings..." "${apps_dir}/ika-com.example.app.desktop" \
  || fail "the settings action was not renamed"
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
expect_equal "$(grep -c '^\[Desktop Action app-settings\]$' "${apps_dir}/ika-com.example.old.desktop")" "1" \
  "an old launcher's settings action is not doubled"
echo "ok: launchers offer \"Ika Startup Options...\""

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
grep -qxF "Actions=options;controller;app-settings;" "${apps_dir}/ika-com.example.game.desktop" \
  || fail "the re-added launcher has no start options"
if grep -q -e 'Desktop Action touch' -e 'Play with Touch Input' "${apps_dir}/ika-com.example.game.desktop"; then
  fail "the re-added launcher kept Play with Touch Input"
fi
: >"${T}/refresh"
updated="$(refresh_changed_launchers "${apps_dir}" $'Some Game\tcom.example.game')"
expect_equal "${updated}:$(<"${T}/refresh")" "0:" "a current launcher stays"
echo "ok: GNOME Shell gets launchers whose actions changed as new apps"

# A game added to the menu starts with Fullscreen mode ticked, unless its options
# were set before; other apps and games already in the menu are left alone.
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
expect_equal "$(saved_app_options com.example.newgame)" "fullscreen" "a new game starts fullscreen"
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
echo "ok: a game added to the menu starts with Fullscreen mode ticked"

# "Android App Settings..." opens the Settings window with App info as its
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
