#!/usr/bin/bash

# Ika's own window ("Startup options" on Ika's launcher, ika options): a yad
# notebook, "Startup Options · Ika", with a Startup Options tab of ika.ini's
# most used settings and a Gamepad Emulation tab of its keyboard gamepad. It
# writes only the settings that changed, in place of their lines in ika.ini
# (ika_ini_set), "Reset to default" writes their built-in values, and
# tv_keyboard_gamepad makes the keyboard a gamepad of the TV console too.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"
unset GTK_THEME IKADPI IKA_TV_DPI IKA_TV_KEYBOARD_GAMEPAD

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

# ika.ini as Ika writes it the first time, with a density, 3 vCPUs and a key
# of the user's
bash -c 'source "$1/tools/ika"' _ "${ROOT}" >/dev/null 2>&1 || true
ini="${CVD_HOME_DIR}/ika.ini"
[[ -f "${ini}" ]] || fail "no ika.ini was written"
sed -i -e 's/^dpi = auto$/dpi = 160/' -e 's/^cpus = auto$/cpus = 3/' -e 's/^a = Space$/a = H/' "${ini}"

# A yad stub, which has --css. A tab (--plug) records its arguments in
# yad.tabN.args and prints DIALOG_TABN; the notebook records its arguments in
# yad.notebook.args, a form of its own in yad.form.args (printing
# DIALOG_FORM), and the confirmation in yad.confirm.args. The notebook, a form
# of its own and the confirmation exit with the next of DIALOG_STATUS, counted
# in yad.calls; the last one stays. setsid records what it would start.
cat >"${T}/bin/yad" <<STUB
#!/usr/bin/bash
if [[ "\$1" == "--help-all" ]]; then
  printf '%s\n' "  --css=STRING"
  exit 0
fi
args=" \$* "
if [[ "\${args}" == *" --plug="* ]]; then
  for arg in "\$@"; do
    [[ "\${arg}" != --tabnum=* ]] || tab="\${arg#--tabnum=}"
  done
  printf '%s\n' "\$@" > "${T}/yad.tab\${tab}.args"
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
  printf '%s\n' "\$@" > "${T}/yad.notebook.args"
elif [[ "\${args}" == *" --form "* ]]; then
  printf '%s\n' "\$@" > "${T}/yad.form.args"
  printf '%s' "\${DIALOG_FORM:-}"
else
  printf '%s\n' "\$@" > "${T}/yad.confirm.args"
fi
exit "\${statuses[n - 1]}"
STUB
cat >"${T}/bin/setsid" <<STUB
#!/usr/bin/bash
printf '%s\n' "IKA_NOTIFY=\${IKA_NOTIFY:-} \$*" >> "${T}/setsid"
STUB
chmod +x "${T}/bin/yad" "${T}/bin/setsid"
export PATH="${T}/bin:${PATH}"

source "${ROOT}/tools/ika"

log() { printf '%s\n' "$*" >>"${T}/log"; }
respond() { printf '%s\n' "$*" >>"${T}/respond"; }
host_color_scheme() { :; }
export DISPLAY=":0"

# ika_ini_set writes a key in place of its lines, whatever their case, keeping
# comments and every other line; adds a missing key after its section's last
# setting, before the comments and blank lines that end it; and adds a
# missing section at the end
cp "${ini}" "${T}/before.ini"
ika_ini_set console dpi 200
expect_equal "$( { diff "${T}/before.ini" "${ini}" || true; } | grep -c '^[<>]')" 2 "one line changed"
grep -qx 'dpi = 200' "${ini}" || fail "the density was not written"
expect_equal "${IKA_INI[console.dpi]}" 200 "IKA_INI follows"
cat >"${T}/small.ini" <<'INI'
# A comment
[Console]
; a note
DPI = 120
dpi = 130
tv_dpi = auto
# trailing comment

[gpu]
gpu_mode = gfxstream
INI
IKA_INI_FILE="${T}/small.ini" ika_ini_set console dpi 144
IKA_INI_FILE="${T}/small.ini" ika_ini_set console refresh_rate_hz 60
IKA_INI_FILE="${T}/small.ini" ika_ini_set lowcpu mode on
expect_equal "$(<"${T}/small.ini")" "# A comment
[Console]
; a note
dpi = 144
tv_dpi = auto
refresh_rate_hz = 60
# trailing comment

[gpu]
gpu_mode = gfxstream

[lowcpu]
mode = on" "ika_ini_set edits in place"
ika_ini_set console dpi 160
# IKA_INI followed the other file too: back to ika.ini's
IKA_INI=()
ika_ini_load "${ini}"
echo "ok: ika_ini_set"

# The window: the two tabs, under "Startup Options · Ika", with the Ika
# icon's window class and the buttons; the settings of ika.ini, 0 for auto;
# ika.ini's keyboard gamepad, with a key of the user's moved off its default
reset_calls() {
  : >"${T}/yad.calls"
  : >"${T}/respond"
  : >"${T}/setsid"
  rm -f "${T}"/yad.*.args
}

# The Startup Options tab's output: the vCPUs, the memory, the densities and
# the refresh rate as yad prints numbers, the three choices, the spacer, the
# camera's box and the TV gamepad's, the spacer
options_output() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s||%s|%s||\n' "${@}"
}

# The Gamepad Emulation tab's output, as test_ika_app_settings_window.sh's:
# a value per field of CONTROLLER_MAPPING_FORM_LAYOUT, from KEYS (an
# associative array name) unless given as control=keys, the settings as yad
# prints them, each column with blank rows to the longer's height, and the
# tab's small blank row
mapping_output() {
  local -n output_keys_ref="$1"
  shift
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
      value="${output_keys_ref[${entry}]}"
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

declare -A ini_keys=()
declare -A ini_settings=()
load_ika_mapping_form ini_keys ini_settings
expect_equal "${ini_keys[a]}" "H" "the user's key for A"
expect_equal "${ini_keys[right_stick_left]}" "J" "J stays the right stick's"
expect_equal "${ini_keys[left_stick_left]}" "A" "the left stick's default key"

shown_tab1="$(options_output 3.000000 0.000000 160.000000 0.000000 0.000000 Auto Auto Auto FALSE FALSE)"
reset_calls
cp "${ini}" "${T}/before.ini"
DIALOG_TAB1="${shown_tab1}" DIALOG_TAB2="$(mapping_output ini_keys)" edit_ika_settings
notebook="$(<"${T}/yad.notebook.args")"
tab1="$(<"${T}/yad.tab1.args")"
tab2="$(<"${T}/yad.tab2.args")"
expect_contains "${notebook}" $'--name=ika-startup-options\n--class=ika-startup-options\n--notebook\n' "the Ika icon's class"
expect_contains "${notebook}" $'\n--tab=Startup Options\n--tab=Gamepad Emulation\n--active-tab=1\n' "the two tabs, on the first"
expect_contains "${notebook}" $'\n--title=Startup Options · Ika\n' "the title"
expect_contains "${notebook}" $'--button=Reset to default:4\n--button=Apply settings:2\n--button=      Apply and restart      :0\n--button=Cancel:1' \
  "the buttons, in order"
expect_contains "${tab1}" $'\n--field=Desktop display density, 0=Auto  :NUM\n160!0..999!8\n' "ika.ini's desktop density"
expect_contains "${tab1}" $'\n--field=TV display density, 0=Auto  :NUM\n0!0..999!8\n' "auto as 0"
expect_contains "${tab1}" $'--css='"${CVD_TMP_DIR}"$'/yad-css/ika-options.css\n--field=CPUs, 0=Auto  :NUM\n3!0..' "the vCPUs first"
expect_contains "${tab1}" $'!1\n--field=RAM, MB, 0=Auto  :NUM\n0!0..' "then the memory"
expect_contains "${tab1}" $'\n--field=GPU mode  :CB\n^Auto!gfxstream_guest_angle!gfxstream!gfxstream, OpenGL ES only!guest_swiftshader\n' "the GPU modes, Auto first"
expect_contains "${tab1}" $'\n--field=Hardware video decoding  :CB\n^Auto!Off\n' "video decoding"
expect_contains "${tab1}" $'\n--field=Low-CPU mode  :CB\n^Auto!On!Off\n' "low-CPU mode"
expect_contains "${tab1}" $'\n--field=  Start with the camera:CHK\nFALSE\n--field=  Keyboard as a gamepad in TV mode:CHK\nFALSE\n' \
  "the camera, then the TV gamepad, off"
expect_contains "${tab1}" $'\n--css='"${CVD_TMP_DIR}"$'/yad-css/ika-options.css\n' "narrow boxes"
expect_contains "${tab2}" $'\n--css='"${CVD_TMP_DIR}"$'/yad-css/gamepad.css\n' "the gamepad tab as an app's"
expect_contains "${tab2}" $'\n--field=\xe2\x80\x87\xe2\x80\x87A\xc2\xa0:\xc2\xa0\nH\n' "ika.ini's key for A"
cmp -s "${T}/before.ini" "${ini}" || fail "Apply settings with nothing changed wrote ika.ini"
expect_equal "$(<"${T}/respond")" "ika.ini left as it was" "and said so"
echo "ok: the window shows ika.ini, and writes nothing unchanged"

# Changed settings and keys are written in place of their lines, and nothing
# else: J given to A leaves the right stick, which is written without it
reset_calls
cp "${ini}" "${T}/before.ini"
DIALOG_TAB1="$(options_output 3.000000 0.000000 200.000000 0.000000 60.000000 gfxstream Off On FALSE TRUE)" \
  DIALOG_TAB2="$(mapping_output ini_keys a=J)" edit_ika_settings
{ diff "${T}/before.ini" "${ini}" || true; } | grep '^>' | sort >"${T}/added"
expect_equal "$(<"${T}/added")" "> a = J
> dpi = 200
> gpu_mode = gfxstream
> hw_video_decode = off
> mode = on
> refresh_rate_hz = 60
> right_stick_left =
> tv_keyboard_gamepad = true" "the changed lines"
expect_equal "$( { diff "${T}/before.ini" "${ini}" || true; } | grep -c '^<')" 8 "each in place of its line"
expect_contains "$(<"${T}/respond")" "they apply the next time Ika starts" "and said so"
[[ ! -s "${T}/setsid" ]] || fail "Apply settings restarted Ika"
echo "ok: Apply settings writes the changes in place"

# "gfxstream, OpenGL ES only" is gfxstream with gfxstream_vulkan = off;
# gfxstream chosen from it writes gfxstream_vulkan = auto; a gfxstream_vulkan
# of ika.ini's stays as it is while the GPU mode is not changed
tab1_with() {
  options_output 3.000000 0.000000 200.000000 0.000000 60.000000 "$1" Off On FALSE TRUE
}
reset_calls
cp "${ini}" "${T}/before.ini"
DIALOG_TAB1="$(tab1_with "gfxstream, OpenGL ES only")" DIALOG_TAB2="$(mapping_output ini_keys a=J right_stick_left=)" \
  edit_ika_settings
expect_equal "$( { diff "${T}/before.ini" "${ini}" || true; } | grep '^>')" "> gfxstream_vulkan = off" "OpenGL ES only"
expect_contains "$(<"${T}/yad.tab1.args")" $'\n--field=GPU mode  :CB\nAuto!gfxstream_guest_angle!^gfxstream!' "shown as gfxstream before"
reset_calls
DIALOG_TAB1="$(tab1_with "gfxstream, OpenGL ES only")" DIALOG_TAB2="$(mapping_output ini_keys a=J right_stick_left=)" \
  edit_ika_settings
expect_contains "$(<"${T}/yad.tab1.args")" $'!^gfxstream, OpenGL ES only!' "and as OpenGL ES only after"
reset_calls
cp "${ini}" "${T}/before.ini"
DIALOG_TAB1="$(tab1_with gfxstream)" DIALOG_TAB2="$(mapping_output ini_keys a=J right_stick_left=)" edit_ika_settings
expect_equal "$( { diff "${T}/before.ini" "${ini}" || true; } | grep '^>')" "> gfxstream_vulkan = auto" "gfxstream with Vulkan as auto"
ika_ini_set gpu gfxstream_vulkan on
reset_calls
cp "${ini}" "${T}/before.ini"
DIALOG_TAB1="$(tab1_with gfxstream)" DIALOG_TAB2="$(mapping_output ini_keys a=J right_stick_left=)" edit_ika_settings
cmp -s "${T}/before.ini" "${ini}" || fail "gfxstream_vulkan = on was changed by an untouched GPU mode"
echo "ok: gfxstream, OpenGL ES only"

# Auto is gpu_mode = auto, and with gfxstream_vulkan = auto, whatever the
# choice before it; the gfxstream_guest_angle of an ika.ini from before auto is
# shown selected, and stays while the GPU mode is not changed
ika_ini_set gpu gpu_mode gfxstream
ika_ini_set gpu gfxstream_vulkan off
reset_calls
cp "${ini}" "${T}/before.ini"
DIALOG_TAB1="$(tab1_with Auto)" DIALOG_TAB2="$(mapping_output ini_keys a=J right_stick_left=)" edit_ika_settings
expect_equal "$( { diff "${T}/before.ini" "${ini}" || true; } | grep '^>' | sort)" "> gfxstream_vulkan = auto
> gpu_mode = auto" "Auto from OpenGL ES only"
ika_ini_set gpu gpu_mode gfxstream_guest_angle
reset_calls
cp "${ini}" "${T}/before.ini"
DIALOG_TAB1="$(tab1_with gfxstream_guest_angle)" DIALOG_TAB2="$(mapping_output ini_keys a=J right_stick_left=)" edit_ika_settings
expect_contains "$(<"${T}/yad.tab1.args")" $'\n--field=GPU mode  :CB\nAuto!^gfxstream_guest_angle!gfxstream!gfxstream, OpenGL ES only!guest_swiftshader\n' \
  "gfxstream_guest_angle shown selected"
cmp -s "${T}/before.ini" "${ini}" || fail "an untouched gfxstream_guest_angle was changed"
echo "ok: Auto"

# "Start with the camera": ticked, camera.device is auto, unless ika.ini names
# a camera, which stays; unticked, off
camera_tab1() {
  options_output 3.000000 0.000000 200.000000 0.000000 60.000000 gfxstream Off On "$1" TRUE
}
reset_calls
DIALOG_TAB1="$(camera_tab1 TRUE)" DIALOG_TAB2="$(mapping_output ini_keys a=J right_stick_left=)" edit_ika_settings
grep -qx "device = auto" "${ini}" || fail "the camera ticked did not write device = auto"
ika_ini_set camera device video2
reset_calls
DIALOG_TAB1="$(camera_tab1 TRUE)" DIALOG_TAB2="$(mapping_output ini_keys a=J right_stick_left=)" edit_ika_settings
expect_contains "$(<"${T}/yad.tab1.args")" $'\n--field=  Start with the camera:CHK\nTRUE\n' "a camera of ika.ini's is shown ticked"
grep -qx "device = video2" "${ini}" || fail "a camera ika.ini names did not stay"
reset_calls
DIALOG_TAB1="$(camera_tab1 FALSE)" DIALOG_TAB2="$(mapping_output ini_keys a=J right_stick_left=)" edit_ika_settings
grep -qx "device = off" "${ini}" || fail "the camera unticked did not write device = off"
echo "ok: Start with the camera"

# Apply and restart restarts Ika as its launcher does; Cancel leaves ika.ini
reset_calls
DIALOG_TAB1="$(options_output 3.000000 0.000000 200.000000 0.000000 60.000000 gfxstream Off On FALSE TRUE)" \
  DIALOG_TAB2="$(mapping_output ini_keys a=J right_stick_left=)" DIALOG_STATUS=0 edit_ika_settings
expect_equal "$(<"${T}/setsid")" "IKA_NOTIFY=true --fork ${IKA_SCRIPT_PATH} restart" "Apply and restart"
reset_calls
cp "${ini}" "${T}/before.ini"
DIALOG_TAB1="$(options_output 0.000000 0.000000 300.000000 0.000000 0.000000 gfxstream Auto Auto FALSE FALSE)" \
  DIALOG_TAB2="$(mapping_output ini_keys)" DIALOG_STATUS=1 edit_ika_settings
cmp -s "${T}/before.ini" "${ini}" || fail "Cancel changed ika.ini"
expect_equal "$(<"${T}/respond")" "ika.ini left as it was" "Cancel says so"
echo "ok: Apply and restart, Cancel"

# Reset to default, once confirmed, writes the built-in values and keys, and
# the window comes back with them, on the Startup Options tab
reset_calls
DIALOG_TAB1="$(options_output 3.000000 0.000000 200.000000 0.000000 60.000000 gfxstream Off On FALSE TRUE)" \
  DIALOG_TAB2="$(mapping_output ini_keys a=J right_stick_left=)" DIALOG_STATUS="4 0 1" edit_ika_settings
expect_contains "$(<"${T}/yad.confirm.args")" "Apply defaults to Ika</span>" "the confirmation"
expect_contains "$(<"${T}/yad.confirm.args")" "This will reset Ika's startup options and gamepad emulation mappings." "and what it resets"
for line in "dpi = auto" "cpus = auto" "gpu_mode = auto" "gfxstream_vulkan = auto" "hw_video_decode = auto" \
    "mode = auto" "device = off" "tv_keyboard_gamepad = false" "a = Space" "right_stick_left = J"; do
  grep -qxF "${line}" "${ini}" || fail "Reset to default did not write '${line}'"
done
expect_contains "$(<"${T}/yad.notebook.args")" $'\n--active-tab=1\n' "back on the first tab"
expect_contains "$(<"${T}/yad.tab1.args")" $'\n--field=Desktop display density, 0=Auto  :NUM\n0!0..999!8\n' "with the defaults"
expect_equal "$(tail -1 "${T}/respond")" "ika.ini has Ika's default start options and keyboard gamepad again" "and said so"
echo "ok: Reset to default"

# Without an X display, the Startup Options tab is a window of its own
reset_calls
unset DISPLAY
DIALOG_FORM="$(options_output 0.000000 0.000000 0.000000 0.000000 0.000000 Auto Auto Auto FALSE TRUE)" \
  edit_ika_settings
expect_contains "$(<"${T}/yad.form.args")" $'\n--title=Startup Options · Ika\n' "the window of its own"
grep -qx "tv_keyboard_gamepad = true" "${ini}" || fail "the window of its own did not save"
export DISPLAY=":0"
echo "ok: without an X display"

# tv_keyboard_gamepad: the TV console makes the keyboard a gamepad too, with
# ika.ini's keys; not by default, and never on the desktop console
declare -a input_args=()
IKA_TV_KEYBOARD_GAMEPAD=false append_scrcpy_input_args input_args tv Console
[[ " ${input_args[*]} " == *" --gamepad=uhid "* ]] || fail "TV mode lost its gamepads"
[[ " ${input_args[*]} " != *"--gamekb="* ]] || fail "the keyboard was a gamepad by default"
input_args=()
IKA_TV_KEYBOARD_GAMEPAD=true append_scrcpy_input_args input_args tv Console
expect_contains " ${input_args[*]} " " --gamekb=$(keyboard_gamepad_spec) " "the keyboard as a gamepad in TV mode"
input_args=()
IKA_TV_KEYBOARD_GAMEPAD=true append_scrcpy_input_args input_args desktop Console
[[ " ${input_args[*]} " != *"--gamekb="* ]] || fail "the desktop console got the keyboard gamepad"
echo "ok: tv_keyboard_gamepad"

# camera.device at start: off passes none; auto the first usable camera, or
# none, logged, without one; a videoN that is missing is left out, logged;
# --no-camera passes none, and --camera wins
camera_args() (
  detect_host_camera() { [[ -n "${FAKE_CAMERA:-}" ]] && printf '%s\n' "${FAKE_CAMERA}"; }
  resolve_camera_device() { printf '%s\n' "${1:-auto}"; }
  apply_camera_power_line_frequency() { :; }
  has_live_cvd_processes() { return 1; }
  fullscreen=""
  args=()
  parse_start_options fullscreen args "$@"
  printf '%s\n' "${args[@]}"
)
: >"${T}/log"
expect_equal "$(IKA_CAMERA=off camera_args)" "" "off"
expect_equal "$(IKA_CAMERA=auto FAKE_CAMERA=/dev/null camera_args)" "--media=v4l2_proxy:device=/dev/null" "auto"
expect_equal "$(IKA_CAMERA=auto camera_args)" "" "auto without a camera"
expect_contains "$(<"${T}/log")" "no usable camera found; starting without one" "logged"
expect_equal "$(IKA_CAMERA=video97 camera_args)" "" "a missing camera"
expect_contains "$(<"${T}/log")" "camera /dev/video97 (camera.device) does not exist" "logged"
expect_equal "$(IKA_CAMERA=auto FAKE_CAMERA=/dev/null camera_args --no-camera)" "" "--no-camera"
expect_equal "$(IKA_CAMERA=off camera_args --camera=video5)" "--media=v4l2_proxy:device=video5" "--camera wins"
if (IKA_CAMERA=off camera_args --camera --no-camera) >/dev/null 2>&1; then
  fail "--camera and --no-camera together were taken"
fi
echo "ok: camera.device at start"

printf 'PASS: Ika settings window\n'
