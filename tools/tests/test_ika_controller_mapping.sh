#!/usr/bin/bash

# The controller mapping window ("Controller mapping..." on a game's launcher,
# ika app --controller): it shows the keyboard gamepad's keys and settings
# for the game, from its mapping else from ika.ini, "Apply settings" saves
# them in ~/ika/apps/PACKAGE/controller.ini and ticks the keyboard as a
# gamepad in the game's start options, "Apply and start" starts the game too,
# and "Reset to ika.ini" removes the mapping.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"
unset GTK_THEME

# A yad stub: it records its arguments, one per line, prints DIALOG_OUTPUT
# and exits with DIALOG_STATUS: 2 for "Apply settings", 0 for "Apply and
# start", 3 for "Reset to ika.ini", 1 for Cancel.
cat >"${T}/bin/yad" <<STUB
#!/usr/bin/bash
printf '%s\n' "\$@" > "${T}/yad.args"
printf '%s' "\${DIALOG_OUTPUT:-}"
exit "\${DIALOG_STATUS:-2}"
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

# yad's form output: the label's empty value, then a value per control in
# their order, the three settings, then the blank label's.
form_output() {
  local control output="|"
  local -A given=()
  while [[ $# -gt 0 && "$1" == *=* ]]; do
    given["${1%%=*}"]="${1#*=}"
    shift
  done
  for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
    if [[ -n "${given[${control}]+set}" ]]; then
      output+="${given[${control}]}|"
    else
      output+="${KEYBOARD_GAMEPAD_KEYS[${control}]}|"
    fi
  done
  output+="${1:-100}|${2:-50}|${3:-last}|${4:-right stick}|${5:-100}|"
  printf '%s\n' "${output}|"
}

# The window shows ika.ini's keys and settings for a game without a mapping,
# in two columns, with the buttons in order
: >"${T}/log"
DIALOG_OUTPUT="$(form_output a=J walk=)" edit_controller_mapping com.example.game
dialog_args="$(<"${T}/yad.args")"
expect_contains "${dialog_args}" $'--form\n--title=Controller Mapping\n' "a form titled Controller Mapping"
expect_contains "${dialog_args}" "<span font_size='15pt' weight='bold'>Some Game</span>" "the heading names the game"
expect_contains "${dialog_args}" $'--columns=2\n' "two columns"
expect_contains "${dialog_args}" $'--field=Left stick up:\nW\n--field=Left stick down:\nS\n' "the keys, with their labels"
expect_contains "${dialog_args}" $'--field=Start:\nReturn Keypad_Enter\n' "a control with two keys"
expect_contains "${dialog_args}" $'--field=Guide:\n\n' "a control without a key"
expect_contains "${dialog_args}" $'--field=Walk (held: slower):\nTab\n' "the walk key"
expect_contains "${dialog_args}" $'--field=Stick ramp, ms (0: at once):NUM\n100!0..5000!10\n--field=Walk speed, %:NUM\n50!1..100!5\n--field=Opposite keys held together:CB\n^last!neutral\n--field=Mouse moves the:CB\noff!^right stick!left stick\n--field=Mouse sensitivity, %:NUM\n100!1..1000!10\n' \
  "the settings, from ika.ini"
expect_contains "${dialog_args}" $'--button=Reset to ika.ini:3\n--button=Apply settings:2\n--button=        Apply and start        :0\n--button=Cancel:1' \
  "the buttons, in order"

# "Apply settings" saves every control and setting in the game's mapping,
# and ticks the keyboard as a gamepad in its start options
file="$(app_controller_mapping_file com.example.game)"
[[ -f "${file}" ]] || fail "the mapping was not saved"
expect_contains "$(<"${file}")" $'[keyboard_gamepad]\nleft_stick_up = W\n' "the mapping starts with the keys"
expect_contains "$(<"${file}")" $'\na = J\n' "the edited key"
expect_contains "$(<"${file}")" $'\nwalk = \n' "an emptied control"
expect_contains "$(<"${file}")" $'\nstick_ramp_ms = 100\nwalk_percent = 50\nsocd = last\nsocd_dpad = \n' "the settings"
expect_contains "$(<"${file}")" $'\nmouse_stick = right\nmouse_sensitivity = 100' "the mouse settings"
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
DIALOG_OUTPUT="$(form_output a=J "0.000000" "35" neutral "left stick" "150.000000")" DIALOG_STATUS=0 edit_controller_mapping com.example.game
dialog_args="$(<"${T}/yad.args")"
expect_contains "${dialog_args}" $'--field=A:\nJ\n' "the game's key is shown"
expect_contains "$(<"${file}")" $'\nstick_ramp_ms = 0\nwalk_percent = 35\nsocd = neutral\n' "the settings as entered"
expect_contains "$(<"${file}")" $'\nmouse_stick = left\nmouse_sensitivity = 150' "the mouse settings as entered"
expect_equal "$(<"${T}/started")" "started com.example.game" "Apply and start starts the game"
expect_equal "$(saved_app_options com.example.game)" "fullscreen gamekb" "ticked options are kept"
expect_contains "$(<"${T}/respond")" "Controller mapping of Some Game saved" "and said so"
spec="$(keyboard_gamepad_spec com.example.game)"
expect_contains ",${spec}," ",ramp_ms=0,walk_percent=35,socd=neutral,mouse_stick=left,mouse_sensitivity=150" "the settings reach the spec"
DIALOG_OUTPUT="$(form_output)" edit_controller_mapping com.example.game
dialog_args="$(<"${T}/yad.args")"
expect_contains "${dialog_args}" $'--field=Opposite keys held together:CB\nlast!^neutral\n' "neutral is shown as chosen"
expect_contains "${dialog_args}" $'--field=Mouse moves the:CB\noff!right stick!^left stick\n' "the left stick is shown as the mouse's"
echo "ok: Apply and start saves the game's mapping and starts it"

# Cancel leaves the mapping; "Reset to ika.ini" removes it
cp "${file}" "${T}/before"
DIALOG_STATUS=1 edit_controller_mapping com.example.game
cmp -s "${file}" "${T}/before" || fail "Cancel changed the mapping"
DIALOG_STATUS=3 edit_controller_mapping com.example.game
[[ ! -e "${file}" ]] || fail "Reset to ika.ini kept the mapping"
expect_contains "$(<"${T}/respond")" "uses the controller mapping of ika.ini again" "the reset is reported"
echo "ok: Cancel and Reset to ika.ini"

# A host without yad is told so
command() { [[ "$2" != "yad" ]] && builtin command "$@"; }
die() { printf 'die: %s\n' "$*" >>"${T}/log"; exit 7; }
( edit_controller_mapping com.example.game ) || true
expect_contains "$(<"${T}/log")" "the controller mapping window needs yad" "a missing yad is reported"
unset -f command die

printf 'PASS: controller mapping window tests\n'
