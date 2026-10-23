#!/usr/bin/bash

# The tabbed window ("Startup options" on an app's launcher, ika app
# --options and --controller): a yad notebook, "Startup Options · LABEL", with
# a Startup Options tab and a Gamepad Emulation tab, the same for games and
# other apps. It saves the start options and the display density, and the
# controller mapping only when it was edited or the app has one of its own;
# an edited mapping ticks the keyboard as a gamepad unless the window
# unticked it. "Reset to default" brings the window back on the Startup
# Options tab. Without an X display, the windows of their own open instead.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"
unset GTK_THEME

# A yad stub, which has --css unless YAD_HELP says otherwise. A tab (--plug)
# records its arguments, and GTK_THEME and XDG_DATA_DIRS, in yad.tabN.args
# and prints DIALOG_TABN; the notebook records its arguments, and
# GDK_BACKEND, GDK_SCALE, GDK_DPI_SCALE and GTK_THEME, in yad.notebook.args,
# a form of its own in yad.form.args (printing DIALOG_FORM), and the
# confirmation in yad.confirm.args. The notebook, a form of its own and the
# confirmation exit with the next of DIALOG_STATUS, counted in yad.calls; the
# last one stays.
cat >"${T}/bin/yad" <<STUB
#!/usr/bin/bash
if [[ "\$1" == "--help-all" ]]; then
  printf '%s\n' "\${YAD_HELP:-  --css=STRING}"
  exit 0
fi
args=" \$* "
if [[ "\${args}" == *" --plug="* ]]; then
  for arg in "\$@"; do
    [[ "\${arg}" != --tabnum=* ]] || tab="\${arg#--tabnum=}"
  done
  { printf '%s\n' "\$@"; printf 'GTK_THEME=%s\nXDG_DATA_DIRS=%s\n' "\${GTK_THEME:-}" "\${XDG_DATA_DIRS:-}"; } > "${T}/yad.tab\${tab}.args"
  name="DIALOG_TAB\${tab}"
  printf '%s' "\${!name:-}"
  exit 0
fi
echo >>"${T}/yad.calls"
read -r -a statuses <<<"\${DIALOG_STATUS:-2}"
n="\$(wc -l <"${T}/yad.calls")"
if (( n > \${#statuses[@]} )); then
  n=\${#statuses[@]}
fi
if [[ "\${args}" == *" --notebook "* ]]; then
  { printf '%s\n' "\$@"; printf 'GDK_BACKEND=%s\nGDK_SCALE=%s\nGDK_DPI_SCALE=%s\nGTK_THEME=%s\n' "\${GDK_BACKEND:-}" "\${GDK_SCALE:-}" "\${GDK_DPI_SCALE:-}" "\${GTK_THEME:-}"; } > "${T}/yad.notebook.args"
elif [[ "\${args}" == *" --form "* ]]; then
  printf '%s\n' "\$@" > "${T}/yad.form.args"
  printf '%s' "\${DIALOG_FORM:-}"
else
  printf '%s\n' "\$@" > "${T}/yad.confirm.args"
fi
exit "\${statuses[n - 1]}"
STUB
chmod +x "${T}/bin/yad"
export PATH="${T}/bin:${PATH}"

source "${ROOT}/tools/ika"

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
export DISPLAY=":0"
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
  rm -f "${T}"/yad.*.args
}

# A game's window: the two tabs, on the first, under "Startup Options · Some
# Game", on XWayland; the start options with the density, the controls in two
# columns, and the four buttons
reset_calls
save_app_options com.example.game fullscreen
DIALOG_TAB1="$(options_output fullscreen touch)" DIALOG_TAB2="$(mapping_output)" \
  edit_app_settings com.example.game 1
notebook="$(<"${T}/yad.notebook.args")"
expect_contains "${notebook}" $'--notebook\n' "a notebook"
expect_contains "${notebook}" $'\n--tab=Startup Options\n--tab=Gamepad Emulation\n--active-tab=1\n' "its tabs, on the first"
expect_contains "${notebook}" $'\n--title=Startup Options · Some Game\n' "its title"
expect_contains "${notebook}" $'--button=Reset to default:4\n--button=Apply settings:2\n--button=        Apply and start        :0\n--button=Cancel:1' \
  "the buttons, in order"
expect_contains "${notebook}" $'\nGDK_BACKEND=x11' "on XWayland, for its tabs"
expect_contains "${notebook}" $'--name=ika-startup-options\n--class=ika-startup-options\n--notebook\n' "a window class of its own, for the Ika icon"
# ika-startup-options.desktop names that class, with the Ika icon, hidden
desktop_file="${ROOT}/tools/ika-startup-options.desktop"
grep -qxF "StartupWMClass=${APP_SETTINGS_WINDOW_CLASS}" "${desktop_file}" || fail "the desktop entry names another class"
grep -qxF "Icon=${IKA_MENU_ICON}" "${desktop_file}" || fail "the desktop entry has another icon"
grep -qxF "NoDisplay=true" "${desktop_file}" || fail "the desktop entry is in the app menu"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "${desktop_file}" || fail "the desktop entry is invalid"
fi
tab1="$(<"${T}/yad.tab1.args")"
tab2="$(<"${T}/yad.tab2.args")"
key="$(grep -o -m1 -- '--key=[0-9]*' <<<"${notebook}")"
expect_contains "${tab1}" $'--plug='"${key#--key=}"$'\n--tabnum=1\n' "the first tab plugs into the notebook"
expect_contains "${tab2}" $'--plug='"${key#--key=}"$'\n--tabnum=2\n' "the second tab plugs into the notebook"
expect_contains "${tab1}" $'\n--css='"${CVD_TMP_DIR}"$'/yad-css/density-tab.css\n' "the density's box is narrow in the tab"
expect_equal "$(<"${CVD_TMP_DIR}/yad-css/density-tab.css")" "spinbutton { margin-right: ${APP_DPI_TAB_MARGIN_PX}px; }" \
  "by a margin"
expect_contains "${tab2}" $'\n--css='"${CVD_TMP_DIR}"$'/yad-css/gamepad.css\n' "the gamepad's fields are smaller"
expect_equal "$(<"${CVD_TMP_DIR}/yad-css/gamepad.css")" "${CONTROLLER_MAPPING_FORM_CSS}" "in a smaller font, in lower rows"
[[ "${notebook}" != *"--css="* ]] || fail "CSS for the notebook, which has no fields"
expect_contains "${tab1}" $'\n--borders='"${APP_OPTIONS_TAB_BORDER_PX}"$'\n' "the tab's fields start in from its frame"
expect_contains "${tab1}" $'\n--field=Display density, 0=Auto  :NUM\n0!0..999!8\n' "the density, auto"
expect_contains "${tab1}" $'\n--field=  Fullscreen mode (F11, Cmd+F or Left-Alt+F exits):CHK\nTRUE\n' "the saved options"
expect_contains "${tab2}" $'\n--columns=2\n' "the controls in two columns"
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
expect_contains "$(<"${T}/yad.notebook.args")" $'\n--active-tab=2\n' "on the second tab"
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
expect_contains "$(<"${T}/yad.tab1.args")" $'\n--field=Display density, 0=Auto  :NUM\n240!0..999!8\n' "the saved density is shown"
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
expect_contains "$(<"${T}/yad.confirm.args")" $'--name=ika-startup-options\n--class=ika-startup-options\n' "the confirmation's class"
expect_contains "$(<"${T}/yad.notebook.args")" $'\n--active-tab=1\n' "the window comes back on the Startup Options tab, opened on the other"
expect_contains "$(<"${T}/yad.tab1.args")" $'\n--field=Display density, 0=Auto  :NUM\n0!0..999!8\n' "with the console's density"
expect_contains "$(<"${T}/yad.tab1.args")" $'\n--field=  Fullscreen mode (F11, Cmd+F or Left-Alt+F exits):CHK\nTRUE\n' "and a game's default start options"
expect_contains "$(<"${T}/yad.tab1.args")" $'\n--field=  Mouse as touch: clicks tap, drags swipe:CHK\nFALSE\n' \
  "the edited ones reset"
expect_contains "$(<"${T}/yad.tab2.args")" $'\n--field=\xe2\x80\x87\xe2\x80\x87A'$'\xc2\xa0'$':\xc2\xa0\n'"${KEYBOARD_GAMEPAD_KEYS[a]}"$'\n' \
  "and ika.ini's mapping"
[[ ! -e "${mapping}" ]] || fail "the default mapping came back as the game's own"
expect_equal "$(saved_app_options com.example.game):$(saved_app_dpi com.example.game)" "touch:" "the start options and auto density"
expect_contains "$(<"${T}/respond")" "Some Game uses the controller mapping of ika.ini again" "the reset is reported"
echo "ok: Reset to default"

# Cancel and closing the window leave everything; Apply and start starts the
# game; a notebook that fails is an error
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
  fail "a notebook that failed was not an error"
fi
echo "ok: Cancel, Apply and start, a failed window"

# An app that is not a game gets the same window as a game, from its launcher
# and from --controller: the same notebook, tabs and fields, with the same
# saved options (the stub's app_display_name names both "Some Game")
window_args() {
  sed -e 's/^--key=.*/--key=KEY/' -e 's/^--plug=.*/--plug=KEY/' \
    "${T}/yad.notebook.args" "${T}/yad.tab1.args" "${T}/yad.tab2.args"
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
[[ -e "${T}/yad.notebook.args" ]] || fail "an app that is not a game did not get the tabbed window"
[[ ! -e "${T}/yad.form.args" ]] || fail "an app that is not a game got a window of its own"
expect_equal "$(window_args)" "${game_window}" "the same window as a game's"
expect_equal "$(saved_app_options com.example.app)" "fullscreen touch" "and it saves"
reset_calls
DIALOG_TAB1="$(options_output touch)" DIALOG_TAB2="$(mapping_output)" edit_app_settings com.example.app 2
expect_contains "$(<"${T}/yad.notebook.args")" $'\n--active-tab=2\n' "--controller opens it on the second tab"
echo "ok: an app that is not a game"

# Without an X display, each tab is a window of its own
reset_calls
unset DISPLAY
DIALOG_FORM="$(options_output fullscreen)" edit_app_settings com.example.game 1
[[ ! -e "${T}/yad.notebook.args" ]] || fail "the tabbed window opened without an X display"
expect_contains "$(<"${T}/yad.form.args")" $'\n--title=Startup Options · Some Game\n' "the start options window of its own"
reset_calls
DIALOG_FORM="$(printf '%s|' W)" DIALOG_STATUS=1 edit_app_settings com.example.game 2
expect_contains "$(<"${T}/yad.form.args")" $'\n--title=Gamepad Emulation · Some Game\n' "the gamepad window of its own"
expect_contains "$(<"${T}/log")" "no X display for yad's tabbed window" "and why"
export DISPLAY=":0"
echo "ok: without an X display"

# On KDE Plasma's Wayland session, with X11 apps applying scaling themselves
# ([Xwayland] Scale in kwinrc), the tabbed window gets that scale: rounded for
# the window, the rest for its text. Not elsewhere, nor over a GDK_SCALE set.
export XDG_CONFIG_HOME="${T}/config"
mkdir -p "${XDG_CONFIG_HOME}"
scale_env_with() (
  printf '[Compositing]\nBackend=OpenGL\n\n[Xwayland]\nScale=%s\n' "$1" > "${XDG_CONFIG_HOME}/kwinrc"
  shift
  export "$@"
  xwayland_gdk_scale_env | paste -sd" " -
)
unset GDK_SCALE GDK_DPI_SCALE
expect_equal "$(scale_env_with 1.7 WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=KDE)" "GDK_SCALE=2 GDK_DPI_SCALE=0.85" "KDE at 1.7"
expect_equal "$(scale_env_with 1.25 WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=KDE)" "GDK_SCALE=1 GDK_DPI_SCALE=1.25" "KDE at 1.25"
expect_equal "$(scale_env_with 2 WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=KDE)" "GDK_SCALE=2 GDK_DPI_SCALE=1" "KDE at 2"
expect_equal "$(scale_env_with 1 WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=KDE)" "" "KDE at 1"
expect_equal "$(scale_env_with 1.7 WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=GNOME)" "" "another desktop"
expect_equal "$(scale_env_with 1.7 WAYLAND_DISPLAY= XDG_CURRENT_DESKTOP=KDE)" "" "an X11 session"
expect_equal "$(scale_env_with 1.7 WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=KDE GDK_SCALE=3)" "" "a GDK_SCALE of the user's"
expect_equal "$(scale_env_with big WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=KDE)" "" "a scale that is not a number"
printf '[Xwayland]\nScale=1.7\n' > "${XDG_CONFIG_HOME}/kwinrc"
reset_calls
WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=KDE DIALOG_TAB1="$(options_output fullscreen)" DIALOG_TAB2="$(mapping_output)" \
  edit_app_settings com.example.game 1
expect_contains "$(<"${T}/yad.notebook.args")" $'\nGDK_SCALE=2\nGDK_DPI_SCALE=0.85' "the tabbed window gets the scale"
reset_calls
WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=GNOME DIALOG_TAB1="$(options_output fullscreen)" DIALOG_TAB2="$(mapping_output)" \
  edit_app_settings com.example.game 1
expect_contains "$(<"${T}/yad.notebook.args")" $'\nGDK_SCALE=\nGDK_DPI_SCALE=' "and only there"
echo "ok: the tabbed window scales with KDE's X11 apps"

# A yad without --css (Debian's 0.40, whose --gtkrc styles the window alone)
# gets each window's CSS in a theme of its own: Adwaita, dark as the desktop
# is, then the CSS, found ahead of the system's themes. The notebook gets one
# too, to look like its tabs. A GTK_THEME of the user's stays, with the CSS
# given to the window alone.
unset YAD_CSS_OPTION
export YAD_HELP="  --gtkrc=FILENAME"
host_color_scheme() { printf 'dark\n'; }
reset_calls
DIALOG_TAB1="$(options_output fullscreen)" DIALOG_TAB2="$(mapping_output)" \
  edit_app_settings com.example.game 1
tab1="$(<"${T}/yad.tab1.args")"
tab2="$(<"${T}/yad.tab2.args")"
notebook="$(<"${T}/yad.notebook.args")"
[[ "${tab1}${tab2}${notebook}" != *"--css="* ]] || fail "--css for a yad without it"
expect_contains "${tab1}" $'\nGTK_THEME=ika-density-tab:dark\n' "the density's theme, dark"
expect_contains "${tab2}" $'\nGTK_THEME=ika-gamepad:dark\n' "the gamepad's"
expect_contains "${notebook}" $'\nGTK_THEME=ika-window:dark' "the notebook's"
expect_contains "${tab2}" $'\nXDG_DATA_DIRS='"${CVD_TMP_DIR}/yad-css:" "found first"
theme_dir="${CVD_TMP_DIR}/yad-css/themes/ika-gamepad/gtk-3.0"
expect_equal "$(<"${theme_dir}/gtk-dark.css")" \
  '@import url("resource:///org/gtk/libgtk/theme/Adwaita/gtk-contained-dark.css");'$'\n'"${CONTROLLER_MAPPING_FORM_CSS}" \
  "Adwaita's dark theme, then the CSS"
expect_contains "$(<"${theme_dir}/gtk.css")" '/Adwaita/gtk-contained.css");' "and the light one"
reset_calls
GTK_THEME=Breeze DIALOG_TAB1="$(options_output fullscreen)" DIALOG_TAB2="$(mapping_output)" \
  edit_app_settings com.example.game 1
expect_contains "$(<"${T}/yad.tab2.args")" $'\n--gtkrc='"${CVD_TMP_DIR}"$'/yad-css/gamepad.css\n' "the user's theme, with --gtkrc"
expect_contains "$(<"${T}/yad.tab2.args")" $'\nGTK_THEME=Breeze\n' "the user's theme stays"
unset YAD_HELP YAD_CSS_OPTION
host_color_scheme() { :; }
echo "ok: a yad without --css"

printf 'PASS: tabbed app settings window\n'
