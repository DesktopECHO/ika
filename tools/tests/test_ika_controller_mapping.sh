#!/usr/bin/bash

# The controller mapping window of its own ("Gamepad Emulation", ika app
# --controller without the tabbed window): it shows the keyboard gamepad's
# keys and settings for the game, from its mapping else from ika.ini, "Apply settings" saves
# them in ~/ika/apps/PACKAGE/controller.ini and ticks the keyboard as a
# gamepad in the game's start options, "Apply and start" starts the game too,
# and "Reset to default", once confirmed, removes the mapping and shows
# ika.ini's.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"
unset GTK_THEME

# A yad stub: it records the window's arguments, one per line, in yad.args
# (the confirmation's in yad.confirm.args), prints DIALOG_OUTPUT for the
# window and exits with DIALOG_STATUS: 2 for "Apply settings", 0 for "Apply
# and start", 4 for "Reset to default", 1 for Cancel; in the confirmation, 0
# for "Use default mapping", 1 for Cancel. DIALOG_STATUS can list one per
# call, counted in yad.calls; the last one stays.
cat >"${T}/bin/yad" <<STUB
#!/usr/bin/bash
if [[ "\$1" == "--help-all" ]]; then
  printf '%s\n' "\${YAD_HELP:-  --css=STRING}"
  exit 0
fi
echo >>"${T}/yad.calls"
read -r -a statuses <<<"\${DIALOG_STATUS:-2}"
n="\$(wc -l <"${T}/yad.calls")"
if (( n > \${#statuses[@]} )); then
  n=\${#statuses[@]}
fi
if [[ " \$* " == *" --form "* ]]; then
  printf '%s\n' "\$@" > "${T}/yad.args"
  printf '%s' "\${DIALOG_OUTPUT:-}"
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

# The second column's labels start with two figure spaces (U+2007)
INDENT=$'\xe2\x80\x87\xe2\x80\x87'
# and every label ends with a no-break space, before its type
GAP=$'\xc2\xa0'
# a key field's label has no colon: its spaces go before a no-break space
# as the field's type, which yad shows as a text field
PLAIN="${GAP}:"$'\xc2\xa0'

# yad's form output: a value per field of CONTROLLER_MAPPING_FORM_LAYOUT,
# ika.ini's keys unless given as control=keys, and the settings given in
# order (full tilt, walk speed, opposite directions, mouse stick, mouse
# sensitivity); each column ends with the blank rows' empty values that make
# it as high as the other, and one more, as a window of its own has them.
form_output() {
  local entry column=1 value i rows output=""
  local -a first=()
  local -a second=()
  local -A given=()
  local -A settings=()
  while [[ $# -gt 0 && "$1" == *=* ]]; do
    given["${1%%=*}"]="${1#*=}"
    shift
  done
  settings=([stick_ramp_ms]="${1:-100}" [walk_percent]="${2:-50}" [socd]="${3:-Last pressed wins}"
    [mouse_stick]="${4:-Off}" [mouse_sensitivity]="${5:-100}")
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

# The window shows ika.ini's keys and settings for a game without a mapping,
# in two columns, with the buttons in order
: >"${T}/log"
DIALOG_OUTPUT="$(form_output a=J walk=)" edit_controller_mapping com.example.game
dialog_args="$(<"${T}/yad.args")"
expect_contains "${dialog_args}" $'--form\n--title=Gamepad Emulation · Some Game\n' "the title names the window and the game"
expect_contains "${dialog_args}" "--name=${APP_SETTINGS_WINDOW_CLASS}"$'\n'"--class=${APP_SETTINGS_WINDOW_CLASS}"$'\n--form\n' "a window class of its own, for the Ika icon"
[[ "${dialog_args}" != *"weight='bold'"* ]] || fail "the window has a heading again"
[[ "${dialog_args}" != *$'\n--undecorated\n'* ]] || fail "the window has no title bar"
expect_contains "${dialog_args}" $'--columns=2\n' "two columns"
expect_contains "${dialog_args}" $'\n--align=right\n' "labels right-justified against their fields"
expect_contains "${dialog_args}" $'\n--css='"${CVD_TMP_DIR}"$'/yad-css/gamepad.css\n' "a smaller font, in lower rows"
expect_equal "$(<"${CVD_TMP_DIR}/yad-css/gamepad.css")" "${CONTROLLER_MAPPING_FORM_CSS}" "the gamepad's CSS"
expect_contains "${dialog_args}" $'\n--text=One or more keys per control, separated by spaces: Space, Return, Left_Shift,\nKeypad_Enter, Mouse_Left, Mouse_Right, Mouse_Middle, Wheel_Up, Wheel_Down\n<span font_size=\'4pt\'> </span>\n' \
  "the explanation is the window's text, in two lines, then a small blank line"
[[ "${dialog_args}" != *"--field=One or more keys per control"* ]] \
  || fail "the explanation is a form field again, which widens the window"
expect_contains "${dialog_args}" $'\n--field=Left stick up'"${PLAIN}"$'\nW\n' "the form starts with the first control"
blanks="$(grep -c -x -- '--field= :LBL' <<<"${dialog_args}")"
expect_equal "${blanks}" 3 "blank rows: one ending the first column, two the second"
expect_contains "${dialog_args}" $'--field=Opposite directions'"${GAP}"$':CB\n^Last pressed wins!Cancel out\n--field= :LBL\n\n--field='"${INDENT}"$'A'"${PLAIN}"$'\n' \
  "the first column ends with Opposite directions and a blank row, and the second starts with A"
expect_contains "${dialog_args}" $'--field='"${INDENT}"$'Mouse sensitivity, %'"${GAP}"$':NUM\n100!1..1000!10\n--field= :LBL\n\n--field= :LBL\n\n--' \
  "the second column ends with two blank rows"
expect_contains "${dialog_args}" $'\n--field=Back'"${PLAIN}"$'\n' "the first column's labels are not indented"
expect_contains "${dialog_args}" $'--field=Left stick up'"${PLAIN}"$'\nW\n--field=Left stick down'"${PLAIN}"$'\nS\n' "the keys, with their labels"
expect_contains "${dialog_args}" $'--field='"${INDENT}"$'Start'"${PLAIN}"$'\nReturn Keypad_Enter\n' "a control with two keys"
expect_contains "${dialog_args}" $'--field='"${INDENT}"$'Guide (Home)'"${PLAIN}"$'\n\n' "a control without a key"
expect_contains "${dialog_args}" $'\n--field=Hold to walk'"${PLAIN}"$'\nTab\n' "the walk key"
expect_contains "${dialog_args}" $'\n--field=Hold to walk'"${PLAIN}"$'\nTab\n--field=Walk speed, %'"${GAP}"$':NUM\n50!1..100!5\n--field=Full tilt, ms (0\xe2\x80\xaf=\xe2\x80\xafInstant)'"${GAP}"$':NUM\n100!0..5000!10\n--field=Opposite directions'"${GAP}"$':CB\n^Last pressed wins!Cancel out\n' \
  "the walk key, its speed under it, and the sticks' other settings, from ika.ini"
expect_contains "${dialog_args}" $'--field='"${INDENT}"$'Mouse → Analog stick'"${GAP}"$':CB\n^Off!Right stick!Left stick\n--field='"${INDENT}"$'Mouse sensitivity, %'"${GAP}"$':NUM\n100!1..1000!10\n' \
  "the mouse's settings, from ika.ini"
# The columns follow the hands: the left half of the pad, the walk key and
# the sticks' settings; then the right half, Guide and the mouse's settings
labels="$(grep -o -- '^--field=[^:]*' <<<"${dialog_args}" | sed -e 's/^--field=//' -e "s/^${INDENT}//" -e "s/${GAP}\$//" \
  | grep -v -x ' ' | paste -sd'|' -)"
expect_equal "${labels}" "Left stick up|Left stick down|Left stick left|Left stick right|Left stick click|D-pad up|D-pad down|D-pad left|D-pad right|Left shoulder|Left trigger|Back|Hold to walk|Walk speed, %|Full tilt, ms (0"$'\xe2\x80\xaf'"="$'\xe2\x80\xaf'"Instant)|Opposite directions|A|B|X|Y|Right stick up|Right stick down|Right stick left|Right stick right|Right stick click|Right shoulder|Right trigger|Start|Guide (Home)|Mouse → Analog stick|Mouse sensitivity, %" \
  "the fields, column by column"
for entry in "${KEYBOARD_GAMEPAD_CONTROLS[@]}" "${CONTROLLER_MAPPING_FORM_SETTINGS[@]}"; do
  expect_equal "$(printf '%s\n' "${CONTROLLER_MAPPING_FORM_LAYOUT[@]}" | grep -c -x -- "${entry}")" 1 "${entry} is in the form once"
done
expect_equal "${#CONTROLLER_MAPPING_FORM_LAYOUT[@]}" "$(( ${#KEYBOARD_GAMEPAD_CONTROLS[@]} + ${#CONTROLLER_MAPPING_FORM_SETTINGS[@]} + 1 ))" \
  "and nothing else but the column break"
expect_contains "${dialog_args}" $'--button=Reset to default:4\n--button=Apply settings:2\n--button=        Apply and start        :0\n--button=Cancel:1' \
  "the buttons, in order"

# "Apply settings" saves every control and setting in the game's mapping,
# and ticks the keyboard as a gamepad in its start options
file="$(app_controller_mapping_file com.example.game)"
[[ -f "${file}" ]] || fail "the mapping was not saved"
expect_contains "$(<"${file}")" $'[keyboard_gamepad]\nleft_stick_up = W\n' "the mapping starts with the keys"
expect_contains "$(<"${file}")" $'\na = J\n' "the edited key"
expect_contains "$(<"${file}")" $'\nwalk = \n' "an emptied control"
expect_contains "$(<"${file}")" $'\nstick_ramp_ms = 100\nwalk_percent = 50\nsocd = last\nsocd_dpad = \n' "the settings"
expect_contains "$(<"${file}")" $'\nmouse_stick = off\nmouse_sensitivity = 100' "the mouse settings"
expect_contains "$(<"${file}")" $'\nright_trigger = X Mouse_Left\n' "a mouse button among the keys"
expect_equal "$(saved_app_options com.example.game)" "gamekb" "the keyboard as a gamepad is ticked"
expect_contains "$(<"${T}/respond")" "it starts with the keyboard as a gamepad" "and said so"
[[ ! -e "${T}/started" ]] || fail "Apply settings started the game"
spec="$(keyboard_gamepad_spec com.example.game)"
expect_contains ",${spec}," ",a=J," "the window's keys reach the spec"
[[ ",${spec}," != *",right_stick_left="* ]] || fail "J did not leave the right stick: ${spec}"
expect_contains "$(<"${file}")" $'\nright_stick_left = \n' "the moved key is gone from the saved mapping"
echo "ok: Apply settings saves the game's mapping"

# The window then shows the game's mapping; "Apply and start" saves it, with
# the settings as yad prints them, and starts the game
save_app_options com.example.game fullscreen gamekb
: >"${T}/respond"
DIALOG_OUTPUT="$(form_output a=J "0.000000" "35" "Cancel out" "Left stick" "150.000000")" DIALOG_STATUS=0 edit_controller_mapping com.example.game
dialog_args="$(<"${T}/yad.args")"
expect_contains "${dialog_args}" $'--field='"${INDENT}"$'A'"${PLAIN}"$'\nJ\n' "the game's key is shown"
expect_contains "$(<"${file}")" $'\nstick_ramp_ms = 0\nwalk_percent = 35\nsocd = neutral\n' "the settings as entered"
expect_contains "$(<"${file}")" $'\nmouse_stick = left\nmouse_sensitivity = 150' "the mouse settings as entered"
expect_equal "$(<"${T}/started")" "started com.example.game" "Apply and start starts the game"
expect_equal "$(saved_app_options com.example.game)" "fullscreen gamekb" "ticked options are kept"
expect_contains "$(<"${T}/respond")" "Controller mapping of Some Game saved" "and said so"
spec="$(keyboard_gamepad_spec com.example.game)"
expect_contains ",${spec}," ",ramp_ms=0,walk_percent=35,socd=neutral,mouse_stick=left,mouse_sensitivity=150" "the settings reach the spec"
DIALOG_OUTPUT="$(form_output)" edit_controller_mapping com.example.game
dialog_args="$(<"${T}/yad.args")"
expect_contains "${dialog_args}" $'--field=Opposite directions'"${GAP}"$':CB\nLast pressed wins!^Cancel out\n' "neutral is shown as chosen"
expect_contains "${dialog_args}" $'--field='"${INDENT}"$'Mouse → Analog stick'"${GAP}"$':CB\nOff!Right stick!^Left stick\n' "the left stick is shown as the mouse's"
echo "ok: Apply and start saves the game's mapping and starts it"

# Cancel leaves the mapping
cp "${file}" "${T}/before"
DIALOG_STATUS=1 edit_controller_mapping com.example.game
cmp -s "${file}" "${T}/before" || fail "Cancel changed the mapping"
echo "ok: Cancel"

# "Reset to default" asks first: Cancel there brings the window back with the
# edits as they were, and keeps the mapping and the start options
: >"${T}/yad.calls"
: >"${T}/respond"
save_app_options_with_dpi com.example.game 200 fullscreen gamekb touch
DIALOG_OUTPUT="$(form_output a=K)" DIALOG_STATUS="4 1 1" edit_controller_mapping com.example.game
expect_equal "$(wc -l <"${T}/yad.calls")" 3 "the window, the confirmation and the window again"
confirm_args="$(<"${T}/yad.confirm.args")"
expect_contains "${confirm_args}" "<span font_size='13pt' weight='bold'>Apply defaults to Some Game</span>" "the confirmation names the game"
expect_contains "${confirm_args}" $'\n\nThis will reset your app options and gamepad emulation mappings.\n' "and says what it resets"
expect_contains "${confirm_args}" $'--button=Ok:0\n--button=Cancel:1' "the confirmation's buttons"
expect_contains "$(<"${T}/yad.args")" $'--field='"${INDENT}"$'A'"${PLAIN}"$'\nK\n' "the window comes back with the edit"
cmp -s "${file}" "${T}/before" || fail "a declined Reset to default changed the mapping"
expect_equal "$(saved_app_options com.example.game):$(saved_app_dpi com.example.game)" "fullscreen gamekb touch:200" \
  "a declined Reset to default keeps the start options"
expect_contains "$(<"${T}/respond")" "Controller mapping of Some Game left as it was" "and nothing changed"
echo "ok: Reset to default, declined"

# Once confirmed, the mapping is gone, the start options are a game's default
# (fullscreen, at the console's density), and the window comes back with
# ika.ini's mapping: Cancel then leaves it so
: >"${T}/yad.calls"
: >"${T}/respond"
DIALOG_OUTPUT="$(form_output a=K)" DIALOG_STATUS="4 0 1" edit_controller_mapping com.example.game
expect_equal "$(wc -l <"${T}/yad.calls")" 3 "the window, the confirmation and the window again"
[[ ! -e "${file}" ]] || fail "Reset to default kept the mapping"
dialog_args="$(<"${T}/yad.args")"
expect_contains "${dialog_args}" $'--field='"${INDENT}"$'A'"${PLAIN}"$'\n'"${KEYBOARD_GAMEPAD_KEYS[a]}"$'\n' "the window shows ika.ini's key"
expect_contains "${dialog_args}" $'--field=Opposite directions'"${GAP}"$':CB\n^Last pressed wins!Cancel out\n' "and ika.ini's settings"
expect_equal "$(saved_app_options com.example.game):$(saved_app_dpi com.example.game)" "fullscreen:" "the default start options"
expect_equal "$(<"${T}/respond")" "Some Game has its default start options and ika.ini's controller mapping again" "the reset is reported"

# and "Apply settings" saves the window's mapping as the game's again
: >"${T}/yad.calls"
: >"${T}/respond"
cp "${T}/before" "${file}"
DIALOG_OUTPUT="$(form_output)" DIALOG_STATUS="4 0 2" edit_controller_mapping com.example.game
expect_contains "$(<"${file}")" $'\na = '"${KEYBOARD_GAMEPAD_KEYS[a]}"$'\n' "ika.ini's key is saved"
expect_contains "$(<"${file}")" $'\nsocd = last\n' "with ika.ini's settings"
expect_contains "$(<"${T}/respond")" "Controller mapping of Some Game saved" "and said so"
echo "ok: Reset to default, confirmed"

# A host without yad is told so
command() { [[ "$2" != "yad" ]] && builtin command "$@"; }
die() { printf 'die: %s\n' "$*" >>"${T}/log"; exit 7; }
( edit_controller_mapping com.example.game ) || true
expect_contains "$(<"${T}/log")" "the controller mapping window needs yad" "a missing yad is reported"
unset -f command die

printf 'PASS: controller mapping window tests\n'
