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

  IKA_APP_INPUT="$3" append_scrcpy_input_args args "$1" "$2" "${4:-}" 2>"${T}/log"
  printf '%s\n' "${args[*]}"
  cat "${T}/log"
}

DEFAULT_SPEC="left_stick_up=W,left_stick_down=S,left_stick_left=A,left_stick_right=D,dpad_up=Up,dpad_down=Down,dpad_left=Left,dpad_right=Right,right_stick_up=I,right_stick_down=K,right_stick_left=J,right_stick_right=L,a=Space,b=Escape,x=C,y=V,start=Return/Keypad_Enter,back=Backspace,left_shoulder=Q/Wheel_Up,right_shoulder=E/Wheel_Down,left_stick=Left_Shift,right_stick=F/Mouse_Middle,left_trigger=Z/Mouse_Right,right_trigger=X/Mouse_Left,walk=Tab,ramp_ms=100,walk_percent=50,socd=last,mouse_stick=off,mouse_sensitivity=100"
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
expect_contains "${output}" "app window keyboard gamepad: left_stick_up=W," "the keyboard gamepad is logged"
output="$(input_args app "app window" "gamepad gamekb")"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --gamekb=${DEFAULT_SPEC} --keyboard=sdk --prefer-text" "gamepads and the keyboard as one"

# Touch input needs the SDK mouse.
output="$(IKA_TOUCH=1 input_args app console "keyboard mouse")"
expect_equal "${output%%$'\n'*}" "--keyboard=uhid --no-mouse-hover" "touch input wins over the mouse"
expect_contains "${output}" "console touch input: the mouse is not a HID device" "the mouse left out is logged"
output="$(IKA_TOUCH=1 input_args app console "")"
expect_equal "${output%%$'\n'*}" "--keyboard=sdk --prefer-text --no-mouse-hover" "touch input alone"

# [keyboard_gamepad] in ika.ini remaps: several keys, none, extra spaces. A
# key an ika.ini line gives a control leaves the control it is a default of,
# whatever its case; keys of other ika.ini lines stay as given.
keyboard_gamepad_ini() {
  local line control

  IKA_INI=()
  for line in "$@"; do
    control="${line%%=*}"
    IKA_INI["keyboard_gamepad.${control}"]="${line#*=}"
  done
  # As ika reads them: the ika.ini values, or the defaults.
  for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
    ika_ini_get "KEYBOARD_GAMEPAD_KEYS[${control}]" keyboard_gamepad "${control}" \
      "${DEFAULT_KEYS[${control}]}"
  done
}
declare -A DEFAULT_KEYS=()
for control in "${!KEYBOARD_GAMEPAD_KEYS[@]}"; do
  DEFAULT_KEYS["${control}"]="${KEYBOARD_GAMEPAD_KEYS[${control}]}"
done
keyboard_gamepad_ini "a=H  J" "dpad_up=" "guide=F1" "left_trigger=left_shift" "start=Return W"
expect_equal "$(keyboard_gamepad_spec)" "left_stick_down=S,left_stick_left=A,left_stick_right=D,dpad_down=Down,dpad_left=Left,dpad_right=Right,right_stick_up=I,right_stick_down=K,right_stick_right=L,a=H/J,b=Escape,x=C,y=V,start=Return/W,back=Backspace,guide=F1,left_shoulder=Q/Wheel_Up,right_shoulder=E/Wheel_Down,right_stick=F/Mouse_Middle,left_trigger=left_shift,right_trigger=X/Mouse_Left,walk=Tab,ramp_ms=100,walk_percent=50,socd=last,mouse_stick=off,mouse_sensitivity=100" "a remapped spec"
keyboard_gamepad_ini
expect_equal "$(keyboard_gamepad_spec)" "${DEFAULT_SPEC}" "the defaults again without ika.ini lines"

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

# A game's controller mapping (~/ika/apps/PACKAGE/controller.ini) goes over
# ika.ini: its keys replace the control's, a key it gives leaves the control
# the key is a default of, and its settings replace ika.ini's; a setting out
# of range falls back with a log line.
mkdir -p "${IKA_APPS_DIR}/com.example.game"
cat >"${IKA_APPS_DIR}/com.example.game/controller.ini" <<'EOF'
# a comment
[keyboard_gamepad]
a = J
guide = Home
walk =
stick_ramp_ms = 0
socd_dpad = neutral
walk_percent = 500
mouse_stick = left
mouse_sensitivity = 250
nonsense = 1
EOF
spec="$(keyboard_gamepad_spec com.example.game 2>"${T}/log")"
expect_contains ",${spec}," ",a=J," "the game's key for A"
[[ ",${spec}," != *",right_stick_left="* ]] || fail "J did not leave the right stick (its default control): ${spec}"
expect_contains ",${spec}," ",guide=Home," "a control without a default key gets one"
expect_contains ",${spec}," ",ramp_ms=0," "the game's stick ramp"
expect_contains ",${spec}," ",socd=last,socd_dpad=neutral" "the game's D-pad SOCD rule"
expect_contains ",${spec}," ",mouse_stick=left,mouse_sensitivity=250" "the game's mouse settings"
expect_contains ",${spec}," ",walk_percent=50," "a walk speed out of range falls back"
[[ ",${spec}," != *",walk="* ]] || fail "an empty value leaves the control without a key: ${spec}"
expect_contains "$(<"${T}/log")" "walk_percent must be 1 to 100, not '500'; using '50'" "the bad setting is logged"
expect_contains "$(<"${T}/log")" "'nonsense' is not a control or a setting" "an unknown line is logged"
expect_equal "$(keyboard_gamepad_spec com.example.other)" "${DEFAULT_SPEC}" "a game without a mapping uses ika.ini"
output="$(input_args app "app window" "gamekb" com.example.game)"
expect_contains "${output%%$'\n'*}" "--gamekb=left_stick_up=W," "the app window passes the game's mapping"
expect_contains "${output%%$'\n'*}" ",a=J," "with the game's keys"
echo "ok: a game's controller mapping goes over ika.ini"
