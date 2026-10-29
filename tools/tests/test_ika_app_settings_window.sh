#!/usr/bin/bash

# The tabbed window ("Startup options" on an app's launcher, ika app
# --options and --controller): ika's GTK 3 window, "Startup Options · LABEL",
# native on Wayland as on X11, with a Startup Options tab and a Gamepad
# Emulation tab, the same for games and other apps. It saves the start options
# and the display density, and the controller mapping only when it was edited
# or the app has one of its own; an edited mapping ticks the keyboard as a
# gamepad unless the window unticked it. "Reset to default" brings the window
# back on the Startup Options tab. Without python3's GTK bindings, yad's
# windows of their own open instead.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"
unset GTK_THEME

# A yad stub, which has --css unless YAD_HELP says otherwise. A form of its
# own records its arguments, and GTK_THEME and XDG_DATA_DIRS, in
# yad.form.args and prints DIALOG_FORM; the confirmation records its
# arguments in yad.confirm.args. Both exit with the next of DIALOG_STATUS,
# counted in yad.calls with ika's windows; the last one stays.
cat >"${T}/bin/yad" <<STUB
#!/usr/bin/bash
if [[ "\$1" == "--help-all" ]]; then
  printf '%s\n' "\${YAD_HELP:-  --css=STRING}"
  exit 0
fi
args=" \$* "
echo >>"${T}/yad.calls"
read -r -a statuses <<<"\${DIALOG_STATUS:-2}"
n="\$(wc -l <"${T}/yad.calls")"
if (( n > \${#statuses[@]} )); then
  n=\${#statuses[@]}
fi
if [[ "\${args}" == *" --form "* ]]; then
  { printf '%s\n' "\$@"; printf 'GTK_THEME=%s\nXDG_DATA_DIRS=%s\n' "\${GTK_THEME:-}" "\${XDG_DATA_DIRS:-}"; } > "${T}/yad.form.args"
  printf '%s' "\${DIALOG_FORM:-}"
else
  printf '%s\n' "\$@" > "${T}/yad.confirm.args"
fi
exit "\${statuses[n - 1]}"
STUB
chmod +x "${T}/bin/yad"
export PATH="${T}/bin:${PATH}"

source "${ROOT}/tools/ika"

# ika's window, stubbed: it records its own arguments, and its environment,
# in window.args and each tab's (from its --tab on) in window.tabN.args,
# writes DIALOG_TABN to that tab's --output and exits with the next of
# DIALOG_STATUS, counted in yad.calls. With WINDOW_DEFAULTS set, the real
# program writes the outputs instead, as the window shows them untouched.
eval "real_$(declare -f ika_window)"
ika_window() {
  local -n stub_env_ref="$1"
  shift
  local arg name n
  local tab=0
  local -a statuses=()

  : >"${T}/window.args"
  for arg in "$@"; do
    if [[ "${arg}" == --tab=* ]]; then
      tab=$((tab + 1))
      : >"${T}/window.tab${tab}.args"
    fi
    if (( tab == 0 )); then
      printf '%s\n' "${arg}" >>"${T}/window.args"
    else
      printf '%s\n' "${arg}" >>"${T}/window.tab${tab}.args"
    fi
    if [[ "${arg}" == --output=* ]]; then
      name="DIALOG_TAB${tab}"
      printf '%s' "${!name:-}" >"${arg#--output=}"
    fi
  done
  printf 'ENV=%s\n' "${stub_env_ref[*]}" >>"${T}/window.args"
  echo >>"${T}/yad.calls"
  read -r -a statuses <<<"${DIALOG_STATUS:-2}"
  n="$(wc -l <"${T}/yad.calls")"
  (( n <= ${#statuses[@]} )) || n=${#statuses[@]}
  if [[ -n "${WINDOW_DEFAULTS:-}" ]]; then
    real_ika_window stub_env_ref --print-defaults --test-status="${statuses[n - 1]}" "$@"
    return
  fi
  return "${statuses[n - 1]}"
}
IKA_WINDOW_AVAILABLE=yes

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

log() { printf '%s\n' "$*" >>"${T}/log"; }
respond() { printf '%s\n' "$*" >>"${T}/respond"; }
open_app_window() { printf 'started %s\n' "$1" >>"${T}/started"; }
host_color_scheme() { :; }
app_display_name() { printf 'Some Game\n'; }

mkdir -p "${IKA_APPS_DIR}"
printf 'com.example.game\n' > "${APP_GAMES_FILE}"
mapping="$(app_controller_mapping_file com.example.game)"

# The Startup Options tab's output, after dpi=N when given: the density, the
# two labels' empty values, TRUE or FALSE for each option, the blank label's.
options_output() {
  local option
  local dpi="0.000000"
  if [[ "${1:-}" == dpi=* ]]; then
    dpi="${1#dpi=}"
    shift
  fi
  local output="${dpi}|||"
  for option in "${APP_START_OPTIONS[@]}"; do
    if [[ " $* " == *" ${option} "* ]]; then
      output+="TRUE|"
    else
      output+="FALSE|"
    fi
  done
  printf '%s\n' "${output}|"
}

# The Gamepad Emulation tab's output: a value per field of
# CONTROLLER_MAPPING_FORM_LAYOUT, ika.ini's keys unless given as
# control=keys, and the settings as yad prints them; the shorter column ends
# with the blank rows' empty values that make it as high as the other, and
# each column with one more, the tab's small blank row.
mapping_output() {
  local entry column=1 value i rows output=""
  local -a first=()
  local -a second=()
  local -A given=()
  local -A settings=([stick_ramp_ms]="100.000000" [walk_percent]="50.000000"
    [socd]="Last pressed wins" [mouse_stick]="Off" [mouse_sensitivity]="100.000000")
  while [[ $# -gt 0 && "$1" == *=* ]]; do
    given["${1%%=*}"]="${1#*=}"
    shift
  done
  for entry in "${CONTROLLER_MAPPING_FORM_LAYOUT[@]}"; do
    if [[ "${entry}" == "|" ]]; then
      column=2
      continue
    fi
    if [[ -n "${settings[${entry}]+set}" ]]; then
      value="${settings[${entry}]}"
    elif [[ -n "${given[${entry}]+set}" ]]; then
      value="${given[${entry}]}"
    else
      value="${KEYBOARD_GAMEPAD_KEYS[${entry}]}"
    fi
    if (( column == 1 )); then
      first+=("${value}")
    else
      second+=("${value}")
    fi
  done
  rows=$(( (${#first[@]} > ${#second[@]} ? ${#first[@]} : ${#second[@]}) + 1 ))
  for (( i = 0; i < rows; i++ )); do
    output+="${first[i]:-}|"
  done
  for (( i = 0; i < rows; i++ )); do
    output+="${second[i]:-}|"
  done
  printf '%s\n' "${output}"
}

reset_calls() {
  : >"${T}/yad.calls"
  : >"${T}/respond"
  : >"${T}/started"
  rm -f "${T}"/yad.*.args "${T}"/window*.args
}

# A game's window: the two tabs, on the first, under "Startup Options · Some
# Game", native (no GDK_BACKEND); the start options with the density, the
# controls in two columns, and the four buttons
reset_calls
save_app_options com.example.game fullscreen
DIALOG_TAB1="$(options_output fullscreen touch)" DIALOG_TAB2="$(mapping_output)" \
  edit_app_settings com.example.game 1
window="$(<"${T}/window.args")"
expect_contains "${window}" $'--title=Startup Options · Some Game\n' "its title"
expect_contains "${window}" $'\n--active-tab=1\n' "on the first tab"
expect_contains "${window}" $'--button=Reset to default:4\n--button=Apply settings:2\n--button=Apply and start:0\n--button=Cancel:1\n' \
  "the buttons, in order"
[[ "${window}" != *"GDK_BACKEND"* ]] || fail "a GDK backend set, not the session's own: ${window}"
expect_contains "${window}" $'\n--icon='"${IKA_MENU_ICON}"$'\n--app-id='"${APP_SETTINGS_WINDOW_CLASS}"$'\n' "an app ID of its own, for the Ika icon"
# ika-startup-options.desktop names that class, with the Ika icon, hidden
desktop_file="${ROOT}/tools/ika-startup-options.desktop"
grep -qxF "StartupWMClass=ika-startup-options" "${desktop_file}" || fail "the desktop entry names another class"
grep -qxF "Icon=${IKA_MENU_ICON}" "${desktop_file}" || fail "the desktop entry has another icon"
grep -qxF "NoDisplay=true" "${desktop_file}" || fail "the desktop entry is in the app menu"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "${desktop_file}" || fail "the desktop entry is invalid"
fi
tab1="$(<"${T}/window.tab1.args")"
tab2="$(<"${T}/window.tab2.args")"
expect_contains "${tab1}" $'--tab=Startup Options\n--output=' "the first tab"
expect_contains "${tab2}" $'--tab=Gamepad Emulation\n--output=' "the second tab"
[[ "${window}${tab1}${tab2}" != *"--css="* ]] || fail "yad's CSS for ika's window"
expect_contains "${tab1}" $'\n--border='"${APP_OPTIONS_TAB_BORDER_PX}"$'\n' "the tab's fields start in from its frame"
expect_contains "${tab1}" $'\n--field=Display density, 0=Auto  :NUM\n0!0..999!8\n' "the density, auto"
expect_contains "${tab1}" $'\n--field=  Fullscreen mode (F11, Cmd+F or Left-Alt+F exits):CHK\nTRUE\n' "the saved options"
expect_contains "${tab2}" $'\n--compact\n--columns=2\n--border='"${CONTROLLER_MAPPING_TAB_BORDER_PX}"$'\n--align=right\n' \
  "the controls in two columns, smaller, labels by their fields"
expect_contains "${tab2}" $'\n--text=One or more keys per control' "the explanation"
expect_equal "$(grep -c -x -- '--field= :LBL' <<<"${tab2}")" 1 "one blank row, at the end of the second column"
expect_equal "$(grep -c -x -- "--field=<span font_size='6pt'> </span>:LBL" <<<"${tab2}")" 2 \
  "and a small one ending each column, above the buttons"
expect_equal "$(saved_app_options com.example.game)" "fullscreen touch" "Apply settings saves the start options"
[[ ! -e "${mapping}" ]] || fail "an untouched mapping became the game's own"
[[ ! -s "${T}/started" ]] || fail "Apply settings started the game"
echo "ok: a game's window, and an untouched mapping stays ika.ini's"

# ika app --controller opens it on the second tab; an edited mapping is saved
# and ticks the keyboard as a gamepad, in the options' usual order
reset_calls
DIALOG_TAB1="$(options_output dpi=240.000000 fullscreen touch)" DIALOG_TAB2="$(mapping_output a=J)" \
  edit_app_settings com.example.game 2
expect_contains "$(<"${T}/window.args")" $'\n--active-tab=2\n' "on the second tab"
[[ -f "${mapping}" ]] || fail "an edited mapping was not saved"
expect_contains "$(<"${mapping}")" $'\na = J\n' "the edited key"
expect_equal "$(saved_app_options com.example.game)" "fullscreen gamekb touch" "an edited mapping ticks the keyboard as a gamepad"
expect_equal "$(saved_app_dpi com.example.game)" "240" "the density is saved"
expect_contains "$(<"${T}/respond")" "Controller mapping of Some Game saved" "and said so"
echo "ok: an edited mapping is saved and ticks the keyboard as a gamepad"

# The game now has a mapping of its own: it is saved again as shown; the
# keyboard as a gamepad unticked in the window stays unticked
reset_calls
DIALOG_TAB1="$(options_output dpi=240.000000 fullscreen)" DIALOG_TAB2="$(mapping_output a=K)" \
  edit_app_settings com.example.game 1
expect_contains "$(<"${T}/window.tab1.args")" $'\n--field=Display density, 0=Auto  :NUM\n240!0..999!8\n' "the saved density is shown"
expect_equal "$(saved_app_options com.example.game)" "fullscreen" "unticked in the window, it stays unticked"
expect_contains "$(<"${mapping}")" $'\na = K\n' "the game's mapping is saved"
reset_calls
DIALOG_TAB1="$(options_output dpi=240.000000 fullscreen)" DIALOG_TAB2="$(mapping_output a=K)" \
  edit_app_settings com.example.game 1
[[ -f "${mapping}" ]] || fail "the game's own mapping was dropped"
echo "ok: a game's own mapping is kept, and an unticked option stays unticked"

# "Reset to default", once confirmed, resets the start options to a game's
# default, at the console's density, removes the game's mapping and brings
# the window back on the first tab with those and ika.ini's mapping, from
# either tab;
# applied untouched, the game keeps ika.ini's. (The stub's tabs print the
# same both times.)
reset_calls
DIALOG_TAB1="$(options_output dpi=0.000000 touch)" DIALOG_TAB2="$(mapping_output)" DIALOG_STATUS="4 0 2" \
  edit_app_settings com.example.game 2
expect_equal "$(wc -l <"${T}/yad.calls")" 3 "the window, the confirmation and the window again"
expect_contains "$(<"${T}/yad.confirm.args")" "Apply defaults to Some Game</span>" "the confirmation names the game"
expect_contains "$(<"${T}/yad.confirm.args")" "--name=${APP_SETTINGS_WINDOW_CLASS}"$'\n'"--class=${APP_SETTINGS_WINDOW_CLASS}"$'\n' "the confirmation's class"
expect_contains "$(<"${T}/window.args")" $'\n--active-tab=1\n' "the window comes back on the Startup Options tab, opened on the other"
expect_contains "$(<"${T}/window.tab1.args")" $'\n--field=Display density, 0=Auto  :NUM\n0!0..999!8\n' "with the console's density"
expect_contains "$(<"${T}/window.tab1.args")" $'\n--field=  Fullscreen mode (F11, Cmd+F or Left-Alt+F exits):CHK\nTRUE\n' "and a game's default start options"
expect_contains "$(<"${T}/window.tab1.args")" $'\n--field=  Mouse as touch: clicks tap, drags swipe:CHK\nFALSE\n' \
  "the edited ones reset"
expect_contains "$(<"${T}/window.tab2.args")" $'\n--field=\xe2\x80\x87\xe2\x80\x87A'$'\xc2\xa0'$':\xc2\xa0\n'"${KEYBOARD_GAMEPAD_KEYS[a]}"$'\n' \
  "and ika.ini's mapping"
[[ ! -e "${mapping}" ]] || fail "the default mapping came back as the game's own"
expect_equal "$(saved_app_options com.example.game):$(saved_app_dpi com.example.game)" "touch:" "the start options and auto density"
expect_contains "$(<"${T}/respond")" "Some Game uses the controller mapping of ika.ini again" "the reset is reported"
echo "ok: Reset to default"

# Cancel and closing the window leave everything; Apply and start starts the
# game; a window that fails is an error
reset_calls
save_app_options com.example.game fullscreen
DIALOG_TAB1="$(options_output touch)" DIALOG_TAB2="$(mapping_output a=K)" DIALOG_STATUS=1 \
  edit_app_settings com.example.game 1
expect_equal "$(saved_app_options com.example.game)" "fullscreen" "Cancel keeps the start options"
[[ ! -e "${mapping}" ]] || fail "Cancel saved the mapping"
expect_contains "$(<"${T}/respond")" "Start options and controller mapping of Some Game left as they were" "and said so"
reset_calls
DIALOG_TAB1="$(options_output fullscreen)" DIALOG_TAB2="$(mapping_output)" DIALOG_STATUS=0 \
  edit_app_settings com.example.game 1
expect_equal "$(<"${T}/started")" "started com.example.game" "Apply and start starts the game"
reset_calls
if (DIALOG_STATUS=70 edit_app_settings com.example.game 1) >/dev/null 2>&1; then
  fail "a window that failed was not an error"
fi
echo "ok: Cancel, Apply and start, a failed window"

# An app that is not a game gets the same window as a game, from its launcher
# and from --controller: the same window, tabs and fields, with the same
# saved options (the stub's app_display_name names both "Some Game")
window_args() {
  sed -e 's/^--output=.*/--output=FILE/' \
    "${T}/window.args" "${T}/window.tab1.args" "${T}/window.tab2.args"
}
save_app_options com.example.game fullscreen
save_app_options com.example.app fullscreen
reset_calls
DIALOG_TAB1="$(options_output fullscreen touch)" DIALOG_TAB2="$(mapping_output)" \
  edit_app_settings com.example.game 1
game_window="$(window_args)"
reset_calls
DIALOG_TAB1="$(options_output fullscreen touch)" DIALOG_TAB2="$(mapping_output)" \
  edit_app_settings com.example.app 1
[[ -e "${T}/window.args" ]] || fail "an app that is not a game did not get the tabbed window"
[[ ! -e "${T}/yad.form.args" ]] || fail "an app that is not a game got a window of its own"
expect_equal "$(window_args)" "${game_window}" "the same window as a game's"
expect_equal "$(saved_app_options com.example.app)" "fullscreen touch" "and it saves"
reset_calls
DIALOG_TAB1="$(options_output touch)" DIALOG_TAB2="$(mapping_output)" edit_app_settings com.example.app 2
expect_contains "$(<"${T}/window.args")" $'\n--active-tab=2\n' "--controller opens it on the second tab"
echo "ok: an app that is not a game"

# ika's own program reads yad's fields, the label up to the last colon, and
# writes each tab's values as yad prints them, each followed by "|": a whole
# number, the chosen item, TRUE or FALSE, a label's empty value, the text;
# its status is the button's. An argument it does not know is an error.
declare -a no_env=()
status=0
real_ika_window no_env --print-defaults --test-status=2 --title=T --button=OK:0 \
  --tab=One --output="${T}/one" --border=4 --field="Size, 0=Auto  :NUM" "240!0..999!8" \
  --field="Mode: x:CB" "a!^b c!d" --field="  Tick:CHK" "TRUE" --field="<b>x</b>:LBL" "" \
  --field="Keys " "Q Wheel_Up" --field="Mouse → Analog stick:CB" "Off!^Right stick" \
  --tab=Two --output="${T}/two" --compact --columns=2 --align=right --text="<i>t</i>" \
  --field="Off:CHK" "false" || status=$?
expect_equal "${status}" 2 "the status given"
expect_equal "$(<"${T}/one")" "240|b c|TRUE||Q Wheel_Up|Right stick|" "the first tab's values"
expect_equal "$(<"${T}/two")" "FALSE|" "the second tab's"
real_ika_window no_env --parse-only --tab=One --field="Mode: x:CB" "a!^b" >"${T}/parsed"
expect_contains "$(tr -d ' \n' <"${T}/parsed")" '"label":"Mode:x","type":"CB","value":"a!^b"' "split at the last colon"
if real_ika_window no_env --print-defaults --tab=One --bogus >/dev/null 2>&1; then
  fail "an unknown argument was taken"
fi
echo "ok: ika's program"

# ika's own program shows what it is given: applied untouched, the window
# changes nothing, the density, the start options and ika.ini's mapping
# included (it prints whole numbers, where yad has decimals)
save_app_options_with_dpi com.example.game 240 fullscreen touch
rm -f "${mapping}"
reset_calls
WINDOW_DEFAULTS=1 edit_app_settings com.example.game 1
expect_equal "$(saved_app_options com.example.game):$(saved_app_dpi com.example.game)" "fullscreen touch:240" \
  "the start options and the density, applied untouched"
[[ ! -e "${mapping}" ]] || fail "an untouched mapping became the game's own, through ika's program"
expect_contains "$(<"${T}/respond")" "Some Game starts with fullscreen touch at 240 DPI" "and said so"
reset_calls
WINDOW_DEFAULTS=1 DIALOG_STATUS=1 edit_app_settings com.example.game 2
expect_equal "$(saved_app_options com.example.game)" "fullscreen touch" "Cancel, through ika's program"
echo "ok: ika's program, applied untouched"

# Without python3's GTK bindings, each tab is a window of its own
reset_calls
IKA_WINDOW_AVAILABLE=no
DIALOG_FORM="$(options_output fullscreen)" edit_app_settings com.example.game 1
[[ ! -e "${T}/window.args" ]] || fail "the tabbed window opened without GTK's bindings"
expect_contains "$(<"${T}/yad.form.args")" $'\n--title=Startup Options · Some Game\n' "the start options window of its own"
reset_calls
DIALOG_FORM="$(printf '%s|' W)" DIALOG_STATUS=1 edit_app_settings com.example.game 2
expect_contains "$(<"${T}/yad.form.args")" $'\n--title=Gamepad Emulation · Some Game\n' "the gamepad window of its own"
expect_contains "$(<"${T}/log")" "python3's GTK 3 bindings are missing" "and why"
echo "ok: without python3's GTK bindings"

# A yad without --css (Debian's 0.40, whose --gtkrc styles the window alone)
# gives such a window its CSS in a theme of its own: Adwaita, dark as the
# desktop is, then the CSS, found ahead of the system's themes. A GTK_THEME
# of the user's stays, with the CSS given to the window alone.
unset YAD_CSS_OPTION
export YAD_HELP="  --gtkrc=FILENAME"
host_color_scheme() { printf 'dark\n'; }
reset_calls
DIALOG_FORM="$(printf '%s|' W)" DIALOG_STATUS=1 edit_app_settings com.example.game 2
form="$(<"${T}/yad.form.args")"
[[ "${form}" != *"--css="* ]] || fail "--css for a yad without it"
expect_contains "${form}" $'\nGTK_THEME=ika-gamepad:dark\n' "the gamepad's theme, dark"
expect_contains "${form}" $'\nXDG_DATA_DIRS='"${CVD_TMP_DIR}/yad-css:" "found first"
theme_dir="${CVD_TMP_DIR}/yad-css/themes/ika-gamepad/gtk-3.0"
expect_equal "$(<"${theme_dir}/gtk-dark.css")" \
  '@import url("resource:///org/gtk/libgtk/theme/Adwaita/gtk-contained-dark.css");'$'\n'"${CONTROLLER_MAPPING_FORM_CSS}" \
  "Adwaita's dark theme, then the CSS"
expect_contains "$(<"${theme_dir}/gtk.css")" '/Adwaita/gtk-contained.css");' "and the light one"
reset_calls
GTK_THEME=Breeze DIALOG_FORM="$(printf '%s|' W)" DIALOG_STATUS=1 edit_app_settings com.example.game 2
expect_contains "$(<"${T}/yad.form.args")" $'\n--gtkrc='"${CVD_TMP_DIR}"$'/yad-css/gamepad.css\n' "the user's theme, with --gtkrc"
expect_contains "$(<"${T}/yad.form.args")" $'\nGTK_THEME=Breeze\n' "the user's theme stays"
unset YAD_HELP YAD_CSS_OPTION
host_color_scheme() { :; }
IKA_WINDOW_AVAILABLE=yes
echo "ok: a yad without --css"

printf 'PASS: tabbed app settings window\n'
