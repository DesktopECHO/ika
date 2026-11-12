# ika: app start options and controller mappings.
# Sourced by src/tools/ika, in its order; see there.

# ============================================================================
# App start options (ika app --options NAME)
# ============================================================================
#
# "Startup options" on an app's launcher opens a window with the app
# window's display density and a checkbox for each of the app's start options,
# and its controller mapping on a second tab. "Apply settings"
# saves them in APP_OPTIONS_FILE, one [PACKAGE] section per app, "Apply and
# start" saves them and starts the app, Cancel changes nothing, and 'ika app'
# adds the saved options to the options it is given, from the menu or a
# terminal.

# The start options an app can save, in the order the window lists them and
# they are saved in: a fullscreen window, the HID devices passed through to
# Android (see app_input_enabled), and touch input.
APP_START_OPTIONS=(fullscreen keyboard mouse gamepad gamekb touch)

# Prints the value of KEY in PACKAGE's section, or nothing.
saved_app_setting() {
  [[ -r "${APP_OPTIONS_FILE}" ]] || return 0
  awk -v section="[$1]" -v key="$2" '
    { sub(/[[:space:]]+$/, "") }
    /^\[/ { in_section = ($0 == section); next }
    in_section && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
      sub(/^[^=]*=[[:space:]]*/, "")
      print
      exit
    }' "${APP_OPTIONS_FILE}"
}

# Prints the options saved for PACKAGE, or nothing.
saved_app_options() {
  saved_app_setting "$1" options
}

# Prints the display density DPI as an app window takes it: nothing for auto
# (empty, 0 or auto), 96 for 1 to 95, the number itself up to 999. Decimals,
# as a form may give, are dropped. Fails for anything else.
app_dpi_value() {
  local dpi="${1,,}"

  dpi="${dpi%%[.,]*}"
  [[ -n "${dpi}" && "${dpi}" != "auto" ]] || return 0
  [[ "${dpi}" =~ ^[0-9]+$ ]] || return 1
  dpi=$((10#${dpi}))
  (( dpi != 0 )) || return 0
  (( dpi >= 96 )) || dpi=96
  (( dpi <= 999 )) || return 1
  printf '%s\n' "${dpi}"
}

# Prints the display density saved for PACKAGE, as app_dpi_value takes it:
# nothing for auto. A value it does not take, from a file edited by hand, is
# reported and left out.
saved_app_dpi() {
  local saved
  local dpi

  saved="$(saved_app_setting "$1" dpi)"
  if ! dpi="$(app_dpi_value "${saved}")"; then
    log "${APP_OPTIONS_FILE}: dpi '${saved}' of $1 is not auto or 96 to 999; ignored"
    return 0
  fi
  [[ -z "${dpi}" ]] || printf '%s\n' "${dpi}"
}

# Whether PACKAGE has a section, even an empty one: its options were set
# once, by the start options window or as a new game's default.
app_options_saved() {
  [[ -r "${APP_OPTIONS_FILE}" ]] \
    && awk -v section="[$1]" '
      { sub(/[[:space:]]+$/, "") }
      $0 == section { found = 1; exit }
      END { exit !found }' "${APP_OPTIONS_FILE}"
}

# Replaces the options saved for PACKAGE with the OPTIONS given, an empty
# section when there are none, so that a game whose options were all
# unticked does not get the new game's default again. Its display density is
# kept.
save_app_options() {
  local package="$1"
  shift

  save_app_options_with_dpi "${package}" "$(saved_app_dpi "${package}")" "$@"
}

# Replaces PACKAGE's section with the OPTIONS given and the display density
# DPI, none (auto) when empty. Other apps' sections and comments are kept, as
# in the launcher's action groups, without leaving blank lines behind.
save_app_options_with_dpi() {
  local package="$1"
  local dpi="$2"
  shift 2

  mkdir -p "$(dirname "${APP_OPTIONS_FILE}")"
  {
    if [[ -s "${APP_OPTIONS_FILE}" ]]; then
      awk -v section="[${package}]" '
        /^\[/ { line = $0; sub(/[[:space:]]+$/, "", line); skip = (line == section) }
        skip { next }
        /^[[:space:]]*$/ { blanks = blanks $0 "\n"; next }
        { printf "%s", blanks; blanks = ""; print }' "${APP_OPTIONS_FILE}"
    else
      cat <<'EOF'
# Start options of Android apps, one section per app, named by its package.
# "Startup options" on an app's launcher in the desktop's app menu sets
# them ('ika app --options NAME' from a terminal), and they apply whenever the
# app starts, from the menu or 'ika app': fullscreen, keyboard, mouse, gamepad,
# gamekb and touch, separated by spaces. A game added to the menu starts with
# fullscreen and keyboard. dpi, 96 to 999, gives the app's window a display
# density of its own; without it, the window has the console's.
EOF
    fi
    printf '\n[%s]\noptions =%s\n' "${package}" "${*:+ $*}"
    [[ -z "${dpi}" ]] || printf 'dpi = %s\n' "${dpi}"
  } > "${APP_OPTIONS_FILE}.tmp"
  mv -f "${APP_OPTIONS_FILE}.tmp" "${APP_OPTIONS_FILE}"
}

# Adds the options saved for PACKAGE to those 'ika app' was given: fullscreen
# sets the named variable to true, touch exports IKA_TOUCH as --touch does, and
# the HID devices are exported in IKA_APP_INPUT, replacing any it inherited.
# Anything else, from a file edited by hand, is reported and skipped.
apply_saved_app_options() {
  local package="$1"
  local -n saved_fullscreen_ref="$2"
  local -a options=()
  local -a inputs=()
  local option

  read -r -a options <<<"$(saved_app_options "${package}")"
  if [[ "${#options[@]}" -gt 0 ]]; then
    log "start options saved for ${package}: ${options[*]}"
  fi
  for option in "${options[@]}"; do
    case "${option}" in
      fullscreen)
        saved_fullscreen_ref="true"
        ;;
      touch)
        export IKA_TOUCH=1
        ;;
      keyboard|mouse|gamepad|gamekb)
        inputs+=("${option}")
        ;;
      *)
        log "${APP_OPTIONS_FILE}: '${option}' is not a start option; ignored"
        ;;
    esac
  done
  IKA_APP_INPUT="${inputs[*]}"
  export IKA_APP_INPUT
}

# Prints the start options window's text for option KEY.
app_start_option_text() {
  case "$1" in
    fullscreen)
      echo "Fullscreen mode (F11, Cmd+F or Left-Alt+F exits)"
      ;;
    keyboard)
      echo "Send the keyboard straight to Android (many games need this)"
      ;;
    mouse)
      echo "Send the mouse straight to Android (Cmd or Left-Alt releases pointer)"
      ;;
    gamepad)
      echo "Use gamepads, including ones plugged in later"
      ;;
    gamekb)
      echo "Keyboard as a gamepad (keys on the Gamepad Emulation tab)"
      ;;
    touch)
      echo "Mouse as touch: clicks tap, drags swipe"
      ;;
  esac
}

# Prints TEXT escaped for the markup of ika's window: its text and labels.
markup_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Sets the variables named PACKAGE_VAR and LABEL_VAR to the app NAME's package
# and label, for the windows below. A package name is used as given, so that
# a launcher opens a window without starting the VM; a label is looked up
# among the launchable apps.
resolve_settings_app() {
  local name="$1"
  local -n settings_package_ref="$2"
  local -n settings_label_ref="$3"
  local resolved
  local adb_serial

  if is_app_package_name "${name}"; then
    settings_package_ref="${name}"
    settings_label_ref="$(app_display_name "${name}")"
  else
    ensure_guest_ready
    adb_serial="$(resolve_adb_serial)"
    resolved="$(resolve_launchable_app "${name}" "${adb_serial}")" || exit 1
    settings_package_ref="${resolved#*$'\t'}"
    settings_label_ref="${resolved%%$'\t'*}"
  fi
  validate_app_package "${settings_package_ref}"
}

# Sets the array named ENV_VAR to the environment of ika's windows: GTK 3
# windows on GNOME stay light in a dark session unless GTK_THEME says
# otherwise, as for the console's title bar.
set_window_env() {
  local -n window_env_ref="$1"

  local fontconfig_file

  window_env_ref=()
  if [[ -z "${GTK_THEME:-}" && "$(host_color_scheme)" == "dark" ]]; then
    window_env_ref=(GTK_THEME=Adwaita:dark)
  fi
  fontconfig_file="$(wslg_fontconfig_file)"
  if [[ -n "${fontconfig_file}" ]]; then
    window_env_ref+=("FONTCONFIG_FILE=${fontconfig_file}")
  fi
  # On WSLg, where no desktop sets GTK's font, the text is two points larger
  # than GTK's default (Sans 10), the Gamepad Emulation tab's too (not smaller,
  # as elsewhere, its fields without the padding the text no longer leaves
  # room for), and ika's window (ika_window_py) gives its title
  # bar Windows 11's look and behavior, as scrcpy's title bars have them, for
  # Windows' display scale
  if [[ "${IKA_ON_WSLG}" == true ]]; then
    window_env_ref+=("IKA_WINDOW_CSS=window { font-size: 12pt; } .ika-compact { font-size: 100%; }
.ika-compact entry, .ika-compact spinbutton, .ika-compact combobox button {
 min-height: 0; padding-top: 0; padding-bottom: 0; }"
                  "IKA_WINDOWS_SCALE=$(wslg_windows_scale)")
  fi
}

# The Startup Options windows' app ID on Wayland (their class on X11), which
# ika-startup-options.desktop names, so that the dock and the task bar show
# them with the Ika icon: GNOME goes by the desktop entry a window's class
# names.
# WSLg skips desktop entries with NoDisplay, as ika-startup-options.desktop
# has, and shows the generic Linux icon for their windows; there they take
# the console's (see console_app_id).
APP_SETTINGS_WINDOW_CLASS="ika-startup-options"
[[ "${IKA_ON_WSLG}" != true ]] || APP_SETTINGS_WINDOW_CLASS="$(console_app_id)"

# The Startup Options tab's border, about two characters: its fields start
# that far in from the tab's frame, as the window's start in from its edge.
APP_OPTIONS_TAB_BORDER_PX=20
# The Gamepad Emulation tab's, smaller: its rows are closer as well (--compact)
# for the window to fit on a screen 768 pixels high.
CONTROLLER_MAPPING_TAB_BORDER_PX=8

# Sets the array named FIELDS_VAR to the start options form of PACKAGE,
# labelled LABEL, for ika's window: the display density (0 for auto), then a checkbox
# for each start option, ticked as TICKED_VAR (an associative array) says,
# with DPI, a number or empty for auto.
app_options_form_fields() {
  local label="$1"
  local dpi="$2"
  local -n options_ticked_ref="$3"
  local -n options_fields_ref="$4"
  local option

  # A blank label under the density, the line above the checkboxes with a half
  # line of space under it, as a smaller blank line, and a blank label between
  # the checkboxes and the buttons.
  options_fields_ref=(--field="Display density, 0=Auto  :NUM" "${dpi:-0}!0..999!8")
  options_fields_ref+=(--field="<span font_size='8pt'> </span>:LBL" "")
  options_fields_ref+=(--field="Start $(markup_escape "${label}") with:"$'\n'"<span font_size='5pt'> </span>:LBL" "")
  for option in "${APP_START_OPTIONS[@]}"; do
    options_fields_ref+=(--field="  $(app_start_option_text "${option}"):CHK")
    options_fields_ref+=("$([[ -n "${options_ticked_ref[${option}]:-}" ]] && echo TRUE || echo FALSE)")
  done
  options_fields_ref+=(--field="<span font_size='8pt'> </span>:LBL" "")
}

# Reads the start options form's OUTPUT, one value per field: the density,
# the two labels' empty values, TRUE or FALSE for each checkbox, then the
# blank label's. Sets the array named OPTIONS_VAR to the ticked options, in
# their usual order, and the variable named DPI_VAR to the density as
# app_dpi_value prints it (1 to 95 is 96; 0 is auto, empty).
read_app_options_form() {
  local output="$1"
  local -n read_options_ref="$2"
  local -n read_dpi_ref="$3"
  local -a values=()
  local i

  IFS='|' read -r -a values <<<"${output}"
  read_options_ref=()
  for i in "${!APP_START_OPTIONS[@]}"; do
    if [[ "${values[i + 3]:-}" == "TRUE" ]]; then
      read_options_ref+=("${APP_START_OPTIONS[i]}")
    fi
  done
  read_dpi_ref="$(app_dpi_value "${values[0]:-}")" || read_dpi_ref=""
}

# Saves PACKAGE's start OPTIONS and display density DPI, as the start options
# windows read them, and says so for the app named LABEL.
save_app_options_form() {
  local package="$1"
  local label="$2"
  local dpi="$3"
  shift 3

  save_app_options_with_dpi "${package}" "${dpi}" "$@"
  if [[ "$#" -gt 0 ]]; then
    respond "${label} starts with $*${dpi:+ at ${dpi} DPI}"
  else
    respond "${label} starts without saved options${dpi:+, at ${dpi} DPI}"
  fi
}

# Whether PACKAGE runs, as far as ika can tell without asking Android: in a
# window of its own, or, a game, in the background.
app_is_running() {
  app_window_is_open "$1" || app_is_in_background "$1"
}

# "Apply and start" of a Startup Options window, "Apply and restart" while
# the app runs: opens PACKAGE's window, which starts it with the options just
# saved. One that runs is closed first, a game in the background ended, so
# that it starts again with them.
start_app_with_options() {
  local package="$1"

  if app_is_running "${package}"; then
    log "restarting ${package} with its start options"
    if app_window_is_open "${package}"; then
      stop_supervisor_from_file "$(app_supervisor_file "${package}" pid)" __app_supervisor
    fi
    discard_background_app "${package}"
  fi
  open_app_window "${package}" false "" ""
}

# The label of a control of the keyboard gamepad in the controller mapping
# window
keyboard_gamepad_control_text() {
  case "$1" in
    left_stick_up) echo "Left stick up" ;;
    left_stick_down) echo "Left stick down" ;;
    left_stick_left) echo "Left stick left" ;;
    left_stick_right) echo "Left stick right" ;;
    dpad_up) echo "D-pad up" ;;
    dpad_down) echo "D-pad down" ;;
    dpad_left) echo "D-pad left" ;;
    dpad_right) echo "D-pad right" ;;
    right_stick_up) echo "Right stick up" ;;
    right_stick_down) echo "Right stick down" ;;
    right_stick_left) echo "Right stick left" ;;
    right_stick_right) echo "Right stick right" ;;
    a) echo "A" ;;
    b) echo "B" ;;
    x) echo "X" ;;
    y) echo "Y" ;;
    start) echo "Start" ;;
    back) echo "Back" ;;
    guide) echo "Guide (Home)" ;;
    left_shoulder) echo "Left shoulder" ;;
    right_shoulder) echo "Right shoulder" ;;
    left_stick) echo "Left stick click" ;;
    right_stick) echo "Right stick click" ;;
    left_trigger) echo "Left trigger" ;;
    right_trigger) echo "Right trigger" ;;
    walk) echo "Hold to walk" ;;
    *) echo "$1" ;;
  esac
}

# Writes PACKAGE's controller mapping from the associative arrays KEYS and
# SETTINGS: every control and setting, so that the game's mapping stands on
# its own, over whatever ika.ini says.
save_controller_mapping() {
  local package="$1"
  local -n saved_keys_ref="$2"
  local -n saved_settings_ref="$3"
  local file control setting

  file="$(app_controller_mapping_file "${package}")"
  mkdir -p "$(dirname "${file}")"
  {
    cat <<EOF
# Controller mapping of ${package}: the keyboard gamepad's keys and settings
# for this game, over [keyboard_gamepad] in ika.ini. 'ika app --controller
# NAME' edits it; delete the file, or press "Reset to default" there, to go
# back to ika.ini. The keys
# are SDL's key names, with _ for a space; an empty value leaves the control
# without a key.

[keyboard_gamepad]
EOF
    for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
      printf '%s = %s\n' "${control}" "${saved_keys_ref[${control}]:-}"
    done
    for setting in "${KEYBOARD_GAMEPAD_SETTINGS[@]}"; do
      printf '%s = %s\n' "${setting}" "${saved_settings_ref[${setting}]:-}"
    done
  } > "${file}.tmp"
  mv -f "${file}.tmp" "${file}"
}

# Prints the start options PACKAGE has by default, on one line: fullscreen
# and the keyboard straight to Android for a game, as a game added to the
# menu gets, none for another app.
default_app_options() {
  if is_game_app "$1"; then
    printf 'fullscreen keyboard\n'
  fi
}

# "Reset to default" once confirmed: PACKAGE's start options go back to its
# default ones, at the console's density, and its controller mapping is
# deleted, so that it uses ika.ini's [keyboard_gamepad] again.
reset_app_to_default() {
  local package="$1"

  rm -f "$(app_controller_mapping_file "${package}")"
  # shellcheck disable=SC2046 # one word per option
  save_app_options_with_dpi "${package}" "" $(default_app_options "${package}")
}

# Asks whether the app named LABEL is to have its default start options and
# controller mapping again (reset_app_to_default), or what MESSAGE says
# instead: true if so
confirm_reset_to_default() {
  local label="$1"
  local message="${2:-This will reset your app options and gamepad emulation mappings.}"
  local text
  local -a window_env=()

  set_window_env window_env
  text="<span font_size='13pt' weight='bold'>Apply defaults to $(markup_escape "${label}")</span>"
  text+=$'\n\n'"$(markup_escape "${message}")"
  ika_window window_env --title="" --undecorated --icon="${IKA_MENU_ICON}" \
    --app-id="${APP_SETTINGS_WINDOW_CLASS}" --button=Ok:0 --button=Cancel:1 \
    --tab=Confirm --border=12 --text="${text}"
}

# The controller mapping form's explanation, above its fields: in two lines,
# no wider than the fields, since as a label among them it widened its column,
# and the window, to its whole length; then a small blank line, which keeps
# the fields up from the buttons as the form's last row does.
controller_mapping_form_text() {
  printf "%s\n%s\n<span font_size='4pt'> </span>" \
    "One or more keys per control, separated by spaces: Space, Return, Left_Shift," \
    "Keypad_Enter, Mouse_Left, Mouse_Right, Mouse_Middle, Wheel_Up, Wheel_Down"
}

# The settings the controller mapping form shows, besides the controls' keys.
CONTROLLER_MAPPING_FORM_SETTINGS=(stick_ramp_ms walk_percent socd mouse_stick mouse_sensitivity)

# The controller mapping form's fields as the hands have them: the first
# column has the left half of the pad, the left stick and its click, the
# D-pad, the left shoulder and trigger and Back, then the walk key, its
# speed and the sticks' other settings; after the "|", the second has the
# right half, the face buttons, the right stick and its click, the right
# shoulder and trigger and Start, then Guide and the mouse's settings. Each control and setting is
# there once; ika.ini, the mappings and the spec keep their own order.
CONTROLLER_MAPPING_FORM_LAYOUT=(
  left_stick_up left_stick_down left_stick_left left_stick_right left_stick
  dpad_up dpad_down dpad_left dpad_right left_shoulder left_trigger back
  walk walk_percent stick_ramp_ms socd
  "|"
  a b x y right_stick_up right_stick_down right_stick_left right_stick_right
  right_stick right_shoulder right_trigger start guide
  mouse_stick mouse_sensitivity)

# Sets the associative arrays named KEYS_VAR and SETTINGS_VAR to the controller
# mapping the form shows for PACKAGE: its own, else ika.ini's keys and
# settings, and APP_SETTINGS_VAR to the settings of its own mapping.
load_controller_mapping_form() {
  local package="$1"
  local -n form_keys_ref="$2"
  local -n form_settings_ref="$3"
  local -n form_app_settings_ref="$4"
  local -A own_keys=()
  local -A own_settings=()
  local control
  local setting
  local value

  load_app_controller_mapping "${package}" own_keys own_settings
  form_keys_ref=()
  form_settings_ref=()
  form_app_settings_ref=()
  for setting in "${!own_settings[@]}"; do
    form_app_settings_ref[${setting}]="${own_settings[${setting}]}"
  done
  for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
    if [[ -n "${own_keys[${control}]+set}" ]]; then
      form_keys_ref[${control}]="${own_keys[${control}]}"
    else
      form_keys_ref[${control}]="${KEYBOARD_GAMEPAD_KEYS[${control}]}"
    fi
  done
  for setting in "${KEYBOARD_GAMEPAD_SETTINGS[@]}"; do
    if [[ -n "${own_settings[${setting}]+set}" ]]; then
      value="${own_settings[${setting}]}"
    else
      value="${KEYBOARD_GAMEPAD_SETTING_VALUES[${setting}]}"
    fi
    form_settings_ref[${setting}]="$(normalize_keyboard_gamepad_setting "${setting}" \
      "${value}" "${KEYBOARD_GAMEPAD_SETTING_VALUES[${setting}]}")"
  done
}

# Prints what the controller mapping form shows of the associative arrays
# named KEYS_VAR and SETTINGS_VAR, a line per control and setting, to tell an
# edited mapping from the one the window opened with.
controller_mapping_form_signature() {
  local -n signature_keys_ref="$1"
  local -n signature_settings_ref="$2"
  local control
  local setting

  for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
    printf '%s=%s\n' "${control}" "${signature_keys_ref[${control}]:-}"
  done
  for setting in "${CONTROLLER_MAPPING_FORM_SETTINGS[@]}"; do
    printf '%s=%s\n' "${setting}" "${signature_settings_ref[${setting}]:-}"
  done
}

# Sets the array named FIELDS_VAR to the controller mapping form of the
# associative arrays named KEYS_VAR and SETTINGS_VAR, for ika's window, in the two
# columns of CONTROLLER_MAPPING_FORM_LAYOUT, and BLANKS_VAR (an associative
# array) to the indexes of its blank rows, whose values reading the form
# leaves out. The shorter column ends with blank rows, to be as high as the
# longer; each column ends with one more, which leaves space between the
# fields and the buttons: a line's worth with BLANK_ROWS true, as a window of
# its own, and a small one as a tab, whose frame adds to it.
controller_mapping_form_fields() {
  local -n fields_keys_ref="$1"
  local -n fields_settings_ref="$2"
  local -n mapping_fields_ref="$3"
  local -n mapping_blanks_ref="$4"
  local blank_rows="$5"
  local entry
  local column=1
  local label
  local half_space
  local socd_choice
  local mouse_choice
  local rows=0
  local shown
  local indent
  local gap
  local field
  local i
  local -a items=()
  local -a item_values=()
  local -a item_columns=()
  local -a column_rows=([1]=0 [2]=0)

  # A narrow no-break space (U+202F), about half a space, on each side of "="
  half_space=$'\xe2\x80\xaf'
  if [[ "${fields_settings_ref[socd]}" == "neutral" ]]; then
    socd_choice="Last pressed wins!^Cancel out"
  else
    socd_choice="^Last pressed wins!Cancel out"
  fi
  case "${fields_settings_ref[mouse_stick]}" in
    right) mouse_choice="Off!^Right stick!Left stick" ;;
    left) mouse_choice="Off!Right stick!^Left stick" ;;
    *) mouse_choice="^Off!Right stick!Left stick" ;;
  esac
  for entry in "${CONTROLLER_MAPPING_FORM_LAYOUT[@]}"; do
    case "${entry}" in
      "|")
        column=2
        continue
        ;;
      stick_ramp_ms)
        items+=("Full tilt, ms (0${half_space}=${half_space}Instant):NUM")
        item_values+=("${fields_settings_ref[stick_ramp_ms]}!0..5000!10")
        ;;
      walk_percent)
        items+=("Walk speed, %:NUM")
        item_values+=("${fields_settings_ref[walk_percent]}!1..100!5")
        ;;
      socd)
        items+=("Opposite directions:CB")
        item_values+=("${socd_choice}")
        ;;
      mouse_stick)
        items+=("Mouse → Analog stick:CB")
        item_values+=("${mouse_choice}")
        ;;
      mouse_sensitivity)
        items+=("Mouse sensitivity, %:NUM")
        item_values+=("${fields_settings_ref[mouse_sensitivity]}!1..1000!10")
        ;;
      *)
        # A control's label has no colon, as the settings' have none
        label="$(keyboard_gamepad_control_text "${entry}")"
        items+=("${label}")
        item_values+=("${fields_keys_ref[${entry}]}")
        ;;
    esac
    item_columns+=("${column}")
    column_rows[${column}]=$(( column_rows[${column}] + 1 ))
  done
  # ika's window fills the first of the two columns with half the fields,
  # then the second: both columns are as high, blank rows included.
  # The second column's labels start two figure spaces (U+2007, a digit's
  # width) in: with the window's own spacing, about four characters between
  # them and the first column's fields. Every label ends with a no-break
  # space, to set it off its field, as close as a colon and a space would.
  # The window takes what follows a field's last colon as its type, so a key
  # field's label ("Up") gets a colon and a no-break space as a type after
  # the space, which it does not know and shows as a text field, as it does
  # without a type.
  for column in 1 2; do
    (( column_rows[${column}] <= rows )) || rows="${column_rows[${column}]}"
  done
  [[ "${blank_rows}" != "true" ]] || rows=$(( rows + 1 ))
  indent=$'\xe2\x80\x87\xe2\x80\x87'
  gap=$'\xc2\xa0'
  mapping_fields_ref=()
  mapping_blanks_ref=()
  for column in 1 2; do
    shown=0
    for i in "${!items[@]}"; do
      (( item_columns[i] == column )) || continue
      case "${items[i]}" in
        *:NUM|*:CB) field="${items[i]%:*}${gap}:${items[i]##*:}" ;;
        *) field="${items[i]}${gap}:"$'\xc2\xa0' ;;
      esac
      (( column == 1 )) || field="${indent}${field}"
      mapping_fields_ref+=(--field="${field}" "${item_values[i]}")
      shown=$((shown + 1))
    done
    for (( ; shown < rows; shown++ )); do
      mapping_blanks_ref[$(( ${#mapping_fields_ref[@]} / 2 ))]=1
      mapping_fields_ref+=(--field=" :LBL" "")
    done
    # As a tab, a small blank row, a little space between the last fields
    # and the frame above the buttons
    if [[ "${blank_rows}" != "true" ]]; then
      mapping_blanks_ref[$(( ${#mapping_fields_ref[@]} / 2 ))]=1
      mapping_fields_ref+=(--field="<span font_size='6pt'> </span>:LBL" "")
    fi
  done
}

# Reads the controller mapping form's OUTPUT, the blank rows of BLANKS_VAR left
# out: a value per field of CONTROLLER_MAPPING_FORM_LAYOUT, in its order, a
# control's keys or a setting, into the associative arrays named KEYS_VAR
# and SETTINGS_VAR, which hold the mapping the form showed. The settings the
# form does not show come from APP_SETTINGS_VAR, the game's own mapping.
read_controller_mapping_form() {
  local output="$1"
  local -n read_blanks_ref="$2"
  local -n read_keys_ref="$3"
  local -n read_settings_ref="$4"
  local -n read_app_settings_ref="$5"
  local i
  local entry
  local control
  local other
  local key
  local value
  local -a words=()
  local -a values=()
  local -a kept=()
  local -A shown=()
  local -A form_values=()

  IFS='|' read -r -a words <<<"${output}"
  for i in "${!words[@]}"; do
    [[ -n "${read_blanks_ref[${i}]+set}" ]] || values+=("${words[i]}")
  done
  i=0
  for entry in "${CONTROLLER_MAPPING_FORM_LAYOUT[@]}"; do
    [[ "${entry}" != "|" ]] || continue
    form_values[${entry}]="${values[i]:-}"
    i=$((i + 1))
  done
  for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
    shown[${control}]="${read_keys_ref[${control}]}"
    value="${form_values[${control}]:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    read_keys_ref[${control}]="${value}"
  done
  # A key given to a control in the window leaves the controls that still
  # have it as they were shown, so that moving a key takes one edit (scrcpy
  # keeps a key given twice for its first control)
  for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
    [[ "${read_keys_ref[${control}]}" != "${shown[${control}]}" ]] || continue
    for other in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
      [[ "${other}" != "${control}" && "${read_keys_ref[${other}]}" == "${shown[${other}]}" ]] || continue
      read -r -a words <<<"${read_keys_ref[${other}]}"
      kept=()
      for key in "${words[@]}"; do
        [[ " ${read_keys_ref[${control}],,} " == *" ${key,,} "* ]] || kept+=("${key}")
      done
      read_keys_ref[${other}]="${kept[*]}"
    done
  done
  # Numbers may come with decimals, and the choices as shown
  value="${form_values[stick_ramp_ms]:-}"
  read_settings_ref[stick_ramp_ms]="${value%%[.,]*}"
  value="${form_values[walk_percent]:-}"
  read_settings_ref[walk_percent]="${value%%[.,]*}"
  case "${form_values[socd]:-}" in
    "Cancel out") read_settings_ref[socd]="neutral" ;;
    *) read_settings_ref[socd]="last" ;;
  esac
  case "${form_values[mouse_stick]:-}" in
    "Right stick") read_settings_ref[mouse_stick]="right" ;;
    "Left stick") read_settings_ref[mouse_stick]="left" ;;
    *) read_settings_ref[mouse_stick]="off" ;;
  esac
  value="${form_values[mouse_sensitivity]:-}"
  read_settings_ref[mouse_sensitivity]="${value%%[.,]*}"
  read_settings_ref[socd_dpad]="${read_app_settings_ref[socd_dpad]:-}"
  read_settings_ref[socd_left_stick]="${read_app_settings_ref[socd_left_stick]:-}"
  read_settings_ref[socd_right_stick]="${read_app_settings_ref[socd_right_stick]:-}"
}

