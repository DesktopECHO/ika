#!/usr/bin/bash

# The input of the consoles and app windows: the desktop console keeps the SDK
# keyboard, the TV console passes the gamepad through as the remote, and an
# app window passes through the HID devices ticked in the app's start options
# (IKA_APP_INPUT): the keyboard, the mouse, gamepads, and the keyboard as a
# gamepad with the [keyboard_gamepad] keys. Touch input wins over the mouse,
# and extra args that set the gamepad are left alone.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"
unset IKA_SCRCPY IKA_APP_INPUT IKA_TOUCH

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

# Prints the input args for MODE and LABEL with the HID devices INPUT, then
# Ika's log.
input_args() {
  local -a args=()

  IKA_APP_INPUT="$3" append_scrcpy_input_args args "$1" "$2" 2>"${T}/log"
  printf '%s\n' "${args[*]}"
  cat "${T}/log"
}

DEFAULT_SPEC="dpad_up=Up/W,dpad_down=Down/S,dpad_left=Left/A,dpad_right=Right/D,a=Space,b=Escape,x=C,y=V,start=Return/Keypad_Enter,back=Backspace,left_shoulder=Q,right_shoulder=E,left_trigger=Z,right_trigger=X"
expect_equal "$(keyboard_gamepad_spec)" "${DEFAULT_SPEC}" "the default keyboard gamepad spec"

# The consoles: an app's start options never reach them.
output="$(input_args desktop console "keyboard mouse gamepad gamekb")"
expect_equal "${output%%$'\n'*}" "--keyboard=sdk --prefer-text" "the desktop console"
output="$(input_args tv console "keyboard mouse gamekb")"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --keyboard=sdk --prefer-text" "the TV console's remote"
expect_contains "${output}" "console TV mode: the gamepad is the remote" "the remote is logged"
output="$(IKA_TOUCH=1 input_args desktop console "")"
expect_equal "${output%%$'\n'*}" "--keyboard=sdk --prefer-text --no-mouse-hover" "the desktop console with touch input"

# An app passes through what its start options tick, and nothing otherwise.
output="$(input_args app "app window" "")"
expect_equal "${output%%$'\n'*}" "--keyboard=sdk --prefer-text" "an app without HID devices"
expect_contains "${output}" "app window HID devices: none" "no HID devices is logged"
output="$(input_args app "app window" "keyboard")"
expect_equal "${output%%$'\n'*}" "--keyboard=uhid" "the keyboard"
output="$(input_args app "app window" "mouse")"
expect_equal "${output%%$'\n'*}" "--keyboard=sdk --prefer-text --mouse=uhid" "the mouse"
output="$(input_args app "app window" "gamepad")"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --keyboard=sdk --prefer-text" "gamepads"
output="$(input_args app console "keyboard mouse gamepad")"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --keyboard=uhid --mouse=uhid" "every HID device"
expect_contains "${output}" "console HID devices: keyboard mouse gamepad" "the HID devices are logged"
output="$(input_args app "app window" "gamekb")"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --gamekb=${DEFAULT_SPEC} --keyboard=sdk --prefer-text" "the keyboard as a gamepad"
expect_contains "${output}" "app window keyboard gamepad: dpad_up=Up/W," "the keyboard gamepad is logged"
output="$(input_args app "app window" "gamepad gamekb")"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --gamekb=${DEFAULT_SPEC} --keyboard=sdk --prefer-text" "gamepads and the keyboard as one"

# Touch input needs the SDK mouse.
output="$(IKA_TOUCH=1 input_args app console "keyboard mouse")"
expect_equal "${output%%$'\n'*}" "--keyboard=uhid --no-mouse-hover" "touch input wins over the mouse"
expect_contains "${output}" "console touch input: the mouse is not a HID device" "the mouse left out is logged"
output="$(IKA_TOUCH=1 input_args app console "")"
expect_equal "${output%%$'\n'*}" "--keyboard=sdk --prefer-text --no-mouse-hover" "touch input alone"

# [keyboard_gamepad] in ika.ini remaps: several keys, none, extra spaces.
KEYBOARD_GAMEPAD_KEYS[a]="H  J"
KEYBOARD_GAMEPAD_KEYS[dpad_up]=""
KEYBOARD_GAMEPAD_KEYS[guide]="F1"
expect_equal "$(keyboard_gamepad_spec)" "dpad_down=Down/S,dpad_left=Left/A,dpad_right=Right/D,a=H/J,b=Escape,x=C,y=V,start=Return/Keypad_Enter,back=Backspace,guide=F1,left_shoulder=Q,right_shoulder=E,left_trigger=Z,right_trigger=X" "a remapped spec"
KEYBOARD_GAMEPAD_KEYS[a]="Space"
KEYBOARD_GAMEPAD_KEYS[dpad_up]="Up W"
KEYBOARD_GAMEPAD_KEYS[guide]=""

# Extra args that set the gamepad are not doubled.
for extra in "--gamepad=disabled" "--no-clipboard-autosync --gamepad=aoa" "-G" "-fG" "--gamekb=a=K"; do
  for mode in tv app; do
    output="$(IKA_SCRCPY="${extra}" input_args "${mode}" console "gamekb")"
    [[ "${output%%$'\n'*}" != *--gamepad* ]] || fail "a second --gamepad was added to '${extra}' in ${mode}: ${output}"
    expect_contains "${output}" "console gamepad: set by the extra args" "extra args '${extra}' are logged"
  done
done
output="$(IKA_SCRCPY="--no-clipboard-autosync -f" input_args app console "gamepad")"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --keyboard=sdk --prefer-text" "other extra args do not stand in"

echo "PASS"
