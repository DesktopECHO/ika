#!/usr/bin/bash

# The gamepad setting (console.gamepad in ika.ini, IKA_GAMEPAD): on passes a
# gamepad the host has when the desktop console starts, and any gamepad in
# game mode and TV mode, where the keyboard is the gamepad when the host has
# none; off never passes one; extra args that set --gamepad themselves are
# left alone.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"

# The host's input devices: event nodes, udev's properties for each, and the
# kernel's name for each.
export IKA_INPUT_DEVICES_DIR="${T}/dev-input"
export IKA_SYS_INPUT_DIR="${T}/sys-input"
cat >"${T}/bin/udevadm" <<'STUB'
#!/usr/bin/env bash
device="${*##*--name=}"
cat "${UDEV_PROPERTIES_DIR}/${device##*/}"
STUB
chmod +x "${T}/bin/udevadm"
export UDEV_PROPERTIES_DIR="${T}/udev"
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

# add_input_device NODE NAME PROPERTY...: an input device the host has.
add_input_device() {
  local node="$1" name="$2"
  shift 2
  mkdir -p "${IKA_INPUT_DEVICES_DIR}" "${IKA_SYS_INPUT_DIR}/${node}/device" "${UDEV_PROPERTIES_DIR}"
  : >"${IKA_INPUT_DEVICES_DIR}/${node}"
  printf '%s\n' "${name}" >"${IKA_SYS_INPUT_DIR}/${node}/device/name"
  printf '%s\n' "$@" >"${UDEV_PROPERTIES_DIR}/${node}"
}

clear_input_devices() {
  rm -rf "${IKA_INPUT_DEVICES_DIR}" "${IKA_SYS_INPUT_DIR}" "${UDEV_PROPERTIES_DIR}"
}

# Prints the input args for the given game mode and label, then Ika's log.
input_args() {
  local -a args=()

  append_scrcpy_input_args args "$1" "${2:-console}" 2>"${T}/log"
  printf '%s\n' "${args[*]}"
  cat "${T}/log"
}

expect_equal "$(normalize_gamepad_mode "" 2>/dev/null)" "off" "empty mode is off, the default"
expect_equal "$(normalize_gamepad_mode ON 2>/dev/null)" "on" "on"
expect_equal "$(normalize_gamepad_mode true 2>/dev/null)" "on" "true"
expect_equal "$(normalize_gamepad_mode Off 2>/dev/null)" "off" "off"
expect_equal "$(normalize_gamepad_mode false 2>/dev/null)" "off" "false"
expect_equal "$(normalize_gamepad_mode disabled 2>/dev/null)" "off" "disabled"
output="$(normalize_gamepad_mode auto 2>&1)"
expect_contains "${output}" "console.gamepad must be on, off or disabled, not 'auto'; using off" "an invalid mode is reported"
expect_equal "${output##*$'\n'}" "off" "an invalid mode is taken as off"

# A keyboard and a mouse are not gamepads.
clear_input_devices
add_input_device event0 "AT Translated Set 2 keyboard" ID_INPUT=1 ID_INPUT_KEYBOARD=1
add_input_device event1 "Logitech USB Optical Mouse" ID_INPUT=1 ID_INPUT_MOUSE=1
host_gamepad_name >/dev/null 2>&1 && fail "a gamepad was found among a keyboard and a mouse"

unset IKA_SCRCPY
export IKA_GAMEPAD=on
DEFAULT_SPEC="dpad_up=Up/W,dpad_down=Down/S,dpad_left=Left/A,dpad_right=Right/D,a=Space,b=Escape,x=C,y=V,start=Return/Keypad_Enter,back=Backspace,left_shoulder=Q,right_shoulder=E,left_trigger=Z,right_trigger=X"
output="$(input_args false)"
expect_equal "${output%%$'\n'*}" "--keyboard=sdk --prefer-text" "desktop console without a gamepad"
expect_contains "${output}" "console gamepad: none found, not adding --gamepad" "no gamepad is logged"
output="$(input_args tv)"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --gamekb=${DEFAULT_SPEC} --keyboard=sdk --prefer-text" "TV mode without a gamepad makes the keyboard one"
expect_equal "$(keyboard_gamepad_spec)" "${DEFAULT_SPEC}" "the default keyboard gamepad spec"
output="$(input_args true)"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --gamekb=${DEFAULT_SPEC} --keyboard=uhid --mouse=uhid" "game mode without a gamepad makes the keyboard one"
expect_contains "${output}" "console gamepad: none found, the keyboard is the gamepad (dpad_up=Up/W," "the keyboard gamepad is logged"
output="$(input_args true "app window")"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --gamekb=${DEFAULT_SPEC} --keyboard=uhid --mouse=uhid" "a game window without a gamepad too"

# [keyboard_gamepad] in ika.ini remaps: several keys, none, extra spaces.
KEYBOARD_GAMEPAD_KEYS[a]="H  J"
KEYBOARD_GAMEPAD_KEYS[dpad_up]=""
KEYBOARD_GAMEPAD_KEYS[guide]="F1"
expect_equal "$(keyboard_gamepad_spec)" "dpad_down=Down/S,dpad_left=Left/A,dpad_right=Right/D,a=H/J,b=Escape,x=C,y=V,start=Return/Keypad_Enter,back=Backspace,guide=F1,left_shoulder=Q,right_shoulder=E,left_trigger=Z,right_trigger=X" "a remapped spec"
KEYBOARD_GAMEPAD_KEYS[a]="Space"
KEYBOARD_GAMEPAD_KEYS[dpad_up]="Up W"
KEYBOARD_GAMEPAD_KEYS[guide]=""

# A gamepad is attached.
add_input_device event2 "Microsoft X-Box One pad" ID_INPUT=1 ID_INPUT_JOYSTICK=1 ID_BUS=usb
expect_equal "$(host_gamepad_name)" "Microsoft X-Box One pad" "the gamepad's name"
output="$(input_args false)"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --keyboard=sdk --prefer-text" "desktop console with a gamepad"
expect_contains "${output}" "console gamepad: Microsoft X-Box One pad found, adding --gamepad=uhid" "the gamepad is logged"
output="$(input_args tv)"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --keyboard=sdk --prefer-text" "TV mode with a gamepad"
output="$(input_args false "app window")"
expect_equal "${output%%$'\n'*}" "--keyboard=sdk --prefer-text" "an app window does not take the gamepad"
output="$(input_args true "app window")"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --keyboard=uhid --mouse=uhid" "a game window with a gamepad passes it, keys type"
output="$(input_args false)"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --keyboard=sdk --prefer-text" "gamepad = on"

# gamepad = off (or disabled) passes none, in any mode.
export IKA_GAMEPAD=disabled
for mode in false tv true; do
  output="$(input_args "${mode}")"
  [[ "${output%%$'\n'*}" != *--gamepad* ]] || fail "gamepad = off passed a gamepad in mode ${mode}: ${output}"
  expect_contains "${output}" "console gamepad: off (gamepad = off)" "off is logged in mode ${mode}"
done
unset IKA_GAMEPAD
output="$(input_args true)"
[[ "${output%%$'\n'*}" != *--gamepad* ]] || fail "the default, with no setting, passed a gamepad: ${output}"
export IKA_GAMEPAD=on

# Extra args that set the gamepad are not doubled.
for extra in "--gamepad=disabled" "--no-clipboard-autosync --gamepad=aoa" "-G" "-fG"; do
  output="$(IKA_SCRCPY="${extra}" input_args false)"
  [[ "${output%%$'\n'*}" != *--gamepad* ]] || fail "a second --gamepad was added to '${extra}': ${output}"
  expect_contains "${output}" "console gamepad: set by the extra args" "extra args '${extra}' are logged"
done
output="$(IKA_SCRCPY="--no-clipboard-autosync -f" input_args false)"
expect_equal "${output%%$'\n'*}" "--gamepad=uhid --keyboard=sdk --prefer-text" "other extra args do not stand in"

echo "PASS"
