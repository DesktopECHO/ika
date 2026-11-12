# ika: Ika's own start options window (ika options).
# Sourced by src/tools/ika, in its order; see there.

# ============================================================================
# Ika's own start options (ika options): "Startup options" on Ika's launcher
# ============================================================================

# The ika.ini settings of the Startup Options tab of Ika's window, as
# SECTION.KEY, in its order, and their built-in values, as ika.ini's template
# has them.
IKA_OPTIONS_SETTINGS=(gpu.use_gpu gpu.gpu_mode gpu.gfxstream_vulkan compute.cpus compute.memory_mb
  console.dpi console.tv_dpi console.refresh_rate_hz gpu.hw_video_decode
  lowcpu.mode camera.device console.tv_keyboard_gamepad)
declare -A IKA_OPTIONS_DEFAULTS=(
  [console.dpi]="auto" [console.tv_dpi]="auto" [console.refresh_rate_hz]="auto"
  [compute.cpus]="auto" [compute.memory_mb]="auto"
  [gpu.use_gpu]="auto" [gpu.gpu_mode]="auto" [gpu.gfxstream_vulkan]="auto"
  [gpu.hw_video_decode]="auto" [lowcpu.mode]="auto" [camera.device]="off"
  [console.tv_keyboard_gamepad]="false"
)
# The GPU modes the window offers, as ika.ini spells them but for
# IKA_OPTIONS_AUTO, Auto as the window's other choices have it (gpu_mode =
# auto). Two of them are two settings: IKA_OPTIONS_GLES_ONLY is gfxstream with
# gfxstream_vulkan = off, and gfxstream, or Auto, chosen from another is that
# mode with gfxstream_vulkan = auto. ika.ini's own GPU mode, when another, is
# offered too.
IKA_OPTIONS_AUTO="Auto"
IKA_OPTIONS_GLES_ONLY="gfxstream, OpenGL ES"
IKA_OPTIONS_GPU_CHOICES=("${IKA_OPTIONS_AUTO}" gfxstream_guest_angle gfxstream
  "${IKA_OPTIONS_GLES_ONLY}" venus guest_swiftshader guest_lavapipe)
# The number boxes and short choices of the Startup Options, which ika's
# window makes as wide as each other
IKA_OPTIONS_EVEN_FIELDS=("CPUs, 0=Auto" "RAM, MB, 0=Auto" "Desktop display density, 0=Auto"
  "TV display density, 0=Auto" "Refresh rate, Hz, 0=Auto" "Hardware video decoding"
  "Low-CPU mode")
# The GPU modes that render with the CPU, which ika's window shows in yellow
IKA_OPTIONS_SOFTWARE_CHOICES=(guest_swiftshader guest_lavapipe)

# Prints VALUE, ika.ini's value of SETTING (SECTION.KEY of the Startup Options
# tab), as the window shows it: auto or a number for the numbers (a density
# under 96 is 96), the choices in lowercase, true or false; a value the window
# cannot show is shown as its built-in one.
ika_option_value() {
  local setting="$1"
  local value="${2,,}"

  case "${setting}" in
    console.dpi|console.tv_dpi)
      value="$(app_dpi_value "${value}" 2>/dev/null)" || value=""
      printf '%s\n' "${value:-auto}"
      ;;
    console.refresh_rate_hz|compute.cpus|compute.memory_mb)
      if [[ "${value}" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "${value}"
      else
        printf 'auto\n'
      fi
      ;;
    gpu.use_gpu)
      normalize_gpu_device "${value}" 2>/dev/null || printf '%s\n' "${value}"
      ;;
    gpu.gpu_mode)
      printf '%s\n' "${value:-${IKA_OPTIONS_DEFAULTS[${setting}]}}"
      ;;
    gpu.gfxstream_vulkan)
      case "${value}" in
        1|true|yes|on|enable|enabled) printf 'on\n' ;;
        0|false|no|off|disable|disabled) printf 'off\n' ;;
        *) printf 'auto\n' ;;
      esac
      ;;
    gpu.hw_video_decode)
      case "${value}" in
        0|false|no|off|disable|disabled) printf 'off\n' ;;
        *) printf 'auto\n' ;;
      esac
      ;;
    lowcpu.mode)
      case "${value}" in
        1|true|yes|on|enable|enabled) printf 'on\n' ;;
        0|false|no|off|disable|disabled) printf 'off\n' ;;
        *) printf 'auto\n' ;;
      esac
      ;;
    camera.device)
      case "${value}" in
        auto|on|true|yes|1) printf 'auto\n' ;;
        video[0-9]*|/dev/video[0-9]*) printf '%s\n' "${2}" ;;
        *) printf 'off\n' ;;
      esac
      ;;
    console.tv_keyboard_gamepad)
      case "${value}" in
        1|true|yes|on) printf 'true\n' ;;
        *) printf 'false\n' ;;
      esac
      ;;
  esac
}

# Sets the associative array named VALUES_VAR to the Startup Options tab's
# settings as ika.ini has them, else their built-in values, each as
# ika_option_value prints it.
load_ika_options_form() {
  local -n ika_values_ref="$1"
  local setting
  local value

  ika_values_ref=()
  for setting in "${IKA_OPTIONS_SETTINGS[@]}"; do
    ika_ini_get value "${setting%%.*}" "${setting#*.}" "${IKA_OPTIONS_DEFAULTS[${setting}]}"
    ika_values_ref[${setting}]="$(ika_option_value "${setting}" "${value}")"
  done
}

# Sets the associative arrays named KEYS_VAR and SETTINGS_VAR to the keyboard
# gamepad of ika.ini, as keyboard_gamepad_spec gives it to the TV console and
# to apps without a mapping of their own: a key an ika.ini line gives a
# control is gone from the control it is a default of.
load_ika_mapping_form() {
  local -n ika_keys_ref="$1"
  local -n ika_settings_ref="$2"
  local control
  local setting
  local key
  local -a words=()
  local -a kept=()
  local -A given_keys=()

  ika_keys_ref=()
  ika_settings_ref=()
  for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
    [[ -n "${IKA_INI[keyboard_gamepad.${control}]+set}" ]] || continue
    read -r -a words <<<"${KEYBOARD_GAMEPAD_KEYS[${control}]}"
    for key in "${words[@]}"; do
      given_keys["${key,,}"]=1
    done
  done
  for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
    read -r -a words <<<"${KEYBOARD_GAMEPAD_KEYS[${control}]}"
    if [[ -z "${IKA_INI[keyboard_gamepad.${control}]+set}" ]]; then
      kept=()
      for key in "${words[@]}"; do
        [[ -n "${given_keys[${key,,}]+set}" ]] || kept+=("${key}")
      done
      words=("${kept[@]}")
    fi
    ika_keys_ref[${control}]="${words[*]}"
  done
  for setting in "${KEYBOARD_GAMEPAD_SETTINGS[@]}"; do
    ika_settings_ref[${setting}]="$(normalize_keyboard_gamepad_setting "${setting}" \
      "${KEYBOARD_GAMEPAD_SETTING_VALUES[${setting}]}" \
      "${KEYBOARD_GAMEPAD_DEFAULT_SETTING_VALUES[${setting}]}")"
  done
}

# Prints the GPU mode choice of the associative array named VALUES_VAR:
# IKA_OPTIONS_GLES_ONLY for gfxstream with gfxstream_vulkan = off,
# IKA_OPTIONS_AUTO for auto, else the GPU mode.
ika_gpu_choice() {
  local -n choice_values_ref="$1"

  if [[ "${choice_values_ref[gpu.gpu_mode]}" == "gfxstream" \
      && "${choice_values_ref[gpu.gfxstream_vulkan]}" == "off" ]]; then
    printf '%s\n' "${IKA_OPTIONS_GLES_ONLY}"
  elif [[ "${choice_values_ref[gpu.gpu_mode]}" == "auto" ]]; then
    printf '%s\n' "${IKA_OPTIONS_AUTO}"
  else
    printf '%s\n' "${choice_values_ref[gpu.gpu_mode]}"
  fi
}

# The choices of "GPU Hardware" the window shows, and the gpu.use_gpu value of each
# (set by ika_options_form_fields for read_ika_options_form).
declare -A IKA_OPTIONS_GPU_IDS=()

# Sets the array named CHOICES_VAR to the choices of "GPU Hardware" for gpu.use_gpu
# value CURRENT, ^ marking CURRENT's: "Auto ⋅ <the GPU auto takes>", then each
# GPU of the host by name, an ID ika.ini has that the host lacks as
# "<ID> (not found)". Fills IKA_OPTIONS_GPU_IDS.
ika_gpu_device_choices() {
  local current="$1"
  local -n gpu_choices_ref="$2"
  local gpu_lines
  local auto
  local line
  local id
  local name
  local label
  local found=false
  local -A labels_seen=()

  IKA_OPTIONS_GPU_IDS=()
  gpu_choices_ref=()
  gpu_lines="$(host_gpus)" || gpu_lines=""
  label="${IKA_OPTIONS_AUTO}"
  if auto="$(host_gpus_auto_choice "${gpu_lines}")"; then
    label+=" ⋅ $(gpu_display_name "$(cut -f2 <<<"${auto}")")"
  fi
  IKA_OPTIONS_GPU_IDS[${label}]="auto"
  [[ "${current}" != "auto" ]] || label="^${label}"
  gpu_choices_ref+=("${label}")
  while IFS=$'\t' read -r id name _; do
    [[ -n "${id}" ]] || continue
    label="$(gpu_display_name "${name}")"
    [[ -n "${label}" && "${label}" != "-" ]] || label="${id}"
    # Two GPUs of one name, told apart by their IDs
    [[ -z "${labels_seen[${label}]+set}" ]] || label+=" (${id})"
    labels_seen[${label}]=1
    IKA_OPTIONS_GPU_IDS[${label}]="${id}"
    if [[ "${id}" == "${current}" ]]; then
      found=true
      label="^${label}"
    fi
    gpu_choices_ref+=("${label}")
  done <<<"${gpu_lines}"
  if [[ "${current}" != "auto" && "${found}" != "true" ]]; then
    label="${current} (not found)"
    IKA_OPTIONS_GPU_IDS[${label}]="${current}"
    gpu_choices_ref+=("^${label}")
  fi
}

# Prints the number box value of SETTING in the associative array named
# VALUES_VAR: its number, or 0 for auto.
ika_option_number() {
  local -n number_values_ref="$1"
  local value="${number_values_ref[$2]}"

  [[ "${value}" =~ ^[0-9]+$ ]] || value=0
  printf '%s\n' "${value}"
}

# Sets the array named FIELDS_VAR to the Startup Options tab of Ika's window
# for the associative array named VALUES_VAR: the GPU Ika uses and
# the GPU mode; the vCPUs and the memory, the densities and the refresh rate,
# 0 for auto; hardware video decoding and low-CPU mode; then the camera at
# every start and the keyboard gamepad in TV mode.
ika_options_form_fields() {
  local -n form_values_ref="$1"
  local -n ika_fields_ref="$2"
  local host_cpus
  local host_mb
  local value
  local mode
  local current
  local choices=""
  local gpu_choices=""
  local -a modes=()
  local -a gpu_labels=()

  ika_gpu_device_choices "${form_values_ref[gpu.use_gpu]}" gpu_labels
  for mode in "${gpu_labels[@]}"; do
    gpu_choices+="${mode//!/ }!"
  done
  for mode in "${IKA_OPTIONS_GPU_CHOICES[@]}"; do
    modes+=("${mode}")
  done
  host_cpus="$(nproc 2>/dev/null)" || host_cpus=64
  host_mb="$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null)"
  [[ "${host_mb}" =~ ^[0-9]+$ ]] || host_mb=65536
  # A value of ika.ini's above the host's stays as it is
  value="$(ika_option_number form_values_ref compute.cpus)"
  (( value <= host_cpus )) || host_cpus="${value}"
  value="$(ika_option_number form_values_ref compute.memory_mb)"
  (( value <= host_mb )) || host_mb="${value}"
  current="$(ika_gpu_choice form_values_ref)"
  for mode in "${modes[@]}"; do
    [[ "${mode}" != "${current}" ]] || current=""
  done
  [[ -z "${current}" ]] || modes+=("${current}")
  current="$(ika_gpu_choice form_values_ref)"
  for mode in "${modes[@]}"; do
    [[ "${mode}" != "${current}" ]] || choices+="^"
    choices+="${mode}!"
  done

  ika_fields_ref=(--field="GPU Hardware  :CB" "${gpu_choices%!}")
  ika_fields_ref+=(--field="GPU Mode  :CB" "${choices%!}")
  ika_fields_ref+=(--field="CPUs, 0=Auto  :NUM" "$(ika_option_number form_values_ref compute.cpus)!0..${host_cpus}!1")
  ika_fields_ref+=(--field="RAM, MB, 0=Auto  :NUM" "$(ika_option_number form_values_ref compute.memory_mb)!0..${host_mb}!1024")
  ika_fields_ref+=(--field="Desktop display density, 0=Auto  :NUM" "$(ika_option_number form_values_ref console.dpi)!0..999!8")
  ika_fields_ref+=(--field="TV display density, 0=Auto  :NUM" "$(ika_option_number form_values_ref console.tv_dpi)!0..999!8")
  ika_fields_ref+=(--field="Refresh rate, Hz, 0=Auto  :NUM" "$(ika_option_number form_values_ref console.refresh_rate_hz)!0..360!1")
  case "${form_values_ref[gpu.hw_video_decode]}" in
    off) ika_fields_ref+=(--field="Hardware video decoding  :CB" "Auto!^Off") ;;
    *) ika_fields_ref+=(--field="Hardware video decoding  :CB" "^Auto!Off") ;;
  esac
  case "${form_values_ref[lowcpu.mode]}" in
    on) ika_fields_ref+=(--field="Low-CPU mode  :CB" "Auto!^On!Off") ;;
    off) ika_fields_ref+=(--field="Low-CPU mode  :CB" "Auto!On!^Off") ;;
    *) ika_fields_ref+=(--field="Low-CPU mode  :CB" "^Auto!On!Off") ;;
  esac
  ika_fields_ref+=(--field="<span font_size='8pt'> </span>:LBL" "")
  ika_fields_ref+=(--field="  Start with the camera:CHK")
  if [[ "${form_values_ref[camera.device]}" == "off" ]]; then
    ika_fields_ref+=(FALSE)
  else
    ika_fields_ref+=(TRUE)
  fi
  ika_fields_ref+=(--field="  Enable gamepad emulation in TV mode:CHK")
  if [[ "${form_values_ref[console.tv_keyboard_gamepad]}" == "true" ]]; then
    ika_fields_ref+=(TRUE)
  else
    ika_fields_ref+=(FALSE)
  fi
  ika_fields_ref+=(--field="<span font_size='8pt'> </span>:LBL" "")
}

# Reads the Startup Options tab's OUTPUT, a value per field in the order of
# ika_options_form_fields, over the values it showed, into the
# associative array named VALUES_VAR, as ika_option_value prints them.
read_ika_options_form() {
  local output="$1"
  local -n read_values_ref="$2"
  local -a words=()
  local value
  local choice
  local i=0
  local setting

  IFS='|' read -r -a words <<<"${output}"
  # "GPU Hardware" first
  choice="${words[0]:-}"
  if [[ -n "${choice}" && -n "${IKA_OPTIONS_GPU_IDS[${choice}]+set}" ]]; then
    read_values_ref[gpu.use_gpu]="${IKA_OPTIONS_GPU_IDS[${choice}]}"
  fi
  # Then the GPU mode choice, read only when it changed, so that a
  # gfxstream_vulkan of ika.ini's stays as it is otherwise
  choice="${words[1]:-}"
  if [[ -n "${choice}" && "${choice}" != "$(ika_gpu_choice read_values_ref)" ]]; then
    case "${choice}" in
      "${IKA_OPTIONS_GLES_ONLY}")
        read_values_ref[gpu.gpu_mode]="gfxstream"
        read_values_ref[gpu.gfxstream_vulkan]="off"
        ;;
      gfxstream)
        read_values_ref[gpu.gpu_mode]="gfxstream"
        read_values_ref[gpu.gfxstream_vulkan]="auto"
        ;;
      "${IKA_OPTIONS_AUTO}")
        read_values_ref[gpu.gpu_mode]="auto"
        read_values_ref[gpu.gfxstream_vulkan]="auto"
        ;;
      *)
        read_values_ref[gpu.gpu_mode]="${choice}"
        ;;
    esac
  fi
  i=2
  for setting in compute.cpus compute.memory_mb console.dpi console.tv_dpi console.refresh_rate_hz; do
    value="${words[i]%%[.,]*}"
    [[ "${value}" =~ ^[1-9][0-9]*$ ]] || value="auto"
    read_values_ref[${setting}]="$(ika_option_value "${setting}" "${value}")"
    i=$((i + 1))
  done
  read_values_ref[gpu.hw_video_decode]="$(ika_option_value gpu.hw_video_decode "${words[7]:-}")"
  read_values_ref[lowcpu.mode]="$(ika_option_value lowcpu.mode "${words[8]:-}")"
  # Ticked, the camera is the first usable one, unless ika.ini names one
  if [[ "${words[10]:-}" != "TRUE" ]]; then
    read_values_ref[camera.device]="off"
  elif [[ "${read_values_ref[camera.device]}" == "off" ]]; then
    read_values_ref[camera.device]="auto"
  fi
  if [[ "${words[11]:-}" == "TRUE" ]]; then
    read_values_ref[console.tv_keyboard_gamepad]="true"
  else
    read_values_ref[console.tv_keyboard_gamepad]="false"
  fi
}

# Writes the Startup Options tab's settings of the associative array named
# VALUES_VAR, and the keyboard gamepad of KEYS_VAR and SETTINGS_VAR, in
# ika.ini: those that differ from what the window showed, SHOWN_VALUES_VAR,
# SHOWN_KEYS_VAR and SHOWN_SETTINGS_VAR, so that the lines left alone stay as
# they are. Sets the array named CHANGED_VAR to "KEY = VALUE" for each.
save_ika_settings_form() {
  local -n save_values_ref="$1"
  local -n save_keys_ref="$2"
  local -n save_settings_ref="$3"
  local -n shown_values_ref="$4"
  local -n shown_keys_ref="$5"
  local -n shown_settings_ref="$6"
  local -n changed_ref="$7"
  local setting
  local control

  changed_ref=()
  for setting in "${IKA_OPTIONS_SETTINGS[@]}"; do
    [[ "${save_values_ref[${setting}]}" != "${shown_values_ref[${setting}]}" ]] || continue
    ika_ini_set "${setting%%.*}" "${setting#*.}" "${save_values_ref[${setting}]}" \
      || die "could not write ${IKA_INI_FILE}"
    changed_ref+=("${setting#*.} = ${save_values_ref[${setting}]}")
  done
  for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
    [[ "${save_keys_ref[${control}]}" != "${shown_keys_ref[${control}]}" ]] || continue
    ika_ini_set keyboard_gamepad "${control}" "${save_keys_ref[${control}]}" \
      || die "could not write ${IKA_INI_FILE}"
    changed_ref+=("${control} = ${save_keys_ref[${control}]}")
  done
  for setting in "${CONTROLLER_MAPPING_FORM_SETTINGS[@]}"; do
    [[ "${save_settings_ref[${setting}]}" != "${shown_settings_ref[${setting}]}" ]] || continue
    ika_ini_set keyboard_gamepad "${setting}" "${save_settings_ref[${setting}]}" \
      || die "could not write ${IKA_INI_FILE}"
    changed_ref+=("${setting} = ${save_settings_ref[${setting}]}")
  done
}

# "Reset to default" in Ika's window, once confirmed: ika.ini gets the
# built-in value of each of the window's settings, and the built-in keys and
# settings of the keyboard gamepad.
reset_ika_settings_to_default() {
  local setting
  local control

  for setting in "${IKA_OPTIONS_SETTINGS[@]}"; do
    ika_ini_set "${setting%%.*}" "${setting#*.}" "${IKA_OPTIONS_DEFAULTS[${setting}]}" \
      || die "could not write ${IKA_INI_FILE}"
  done
  for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
    ika_ini_set keyboard_gamepad "${control}" "${KEYBOARD_GAMEPAD_DEFAULT_KEYS[${control}]}" \
      || die "could not write ${IKA_INI_FILE}"
    KEYBOARD_GAMEPAD_KEYS[${control}]="${KEYBOARD_GAMEPAD_DEFAULT_KEYS[${control}]}"
  done
  for setting in "${CONTROLLER_MAPPING_FORM_SETTINGS[@]}"; do
    ika_ini_set keyboard_gamepad "${setting}" "${KEYBOARD_GAMEPAD_DEFAULT_SETTING_VALUES[${setting}]}" \
      || die "could not write ${IKA_INI_FILE}"
    KEYBOARD_GAMEPAD_SETTING_VALUES[${setting}]="${KEYBOARD_GAMEPAD_DEFAULT_SETTING_VALUES[${setting}]}"
  done
}

# ika options, and "Startup options" on Ika's launcher: Ika's window, as an
# app's ("Startup Options · Ika", the same size and buttons), with two tabs:
# Startup Options, the common settings of ika.ini (the GPU Ika uses, the
# vCPUs and memory, the
# densities, the refresh rate, the GPU mode, hardware video decoding, low-CPU
# mode, the camera, and the keyboard gamepad in TV mode), and Gamepad
# Emulation,
# ika.ini's keyboard gamepad, which TV mode and apps without a mapping of
# their own use. "Apply settings" writes in ika.ini what was changed, "Apply
# and restart" also restarts Ika, so that they apply, "Reset to default"
# asks, then writes the built-in values and shows them, and Cancel leaves
# ika.ini as it was.
edit_ika_settings() {
  local key
  local status=0
  local tab_dir
  local joined=""
  local default_used=false
  local -a fields1=()
  local -a fields2=()
  local -a changed=()
  local -a window_env=()
  local -A values=()
  local -A shown_values=()
  local -A keys=()
  local -A settings=()
  local -A shown_keys=()
  local -A shown_settings=()
  local -A ini_settings=()
  local -A blank_at=()

  require_ika_window
  set_window_env window_env
  mkdir -p "${CVD_TMP_DIR}"
  tab_dir="$(mktemp -d "${CVD_TMP_DIR}/ika-settings.XXXXXX")"

  # The window is shown again after "Reset to default", on the Startup Options
  # tab, with the defaults once confirmed, else with the edits as they were
  load_ika_options_form values
  load_ika_mapping_form keys settings
  while true; do
    for key in "${!values[@]}"; do shown_values[${key}]="${values[${key}]}"; done
    for key in "${!keys[@]}"; do shown_keys[${key}]="${keys[${key}]}"; done
    for key in "${!settings[@]}"; do shown_settings[${key}]="${settings[${key}]}"; done
    for key in "${!settings[@]}"; do ini_settings[${key}]="${settings[${key}]}"; done
    ika_options_form_fields values fields1
    controller_mapping_form_fields keys settings fields2 blank_at false
    status=0
    ika_window window_env --title="Startup Options · Ika" \
      --icon="${IKA_MENU_ICON}" --app-id="${APP_SETTINGS_WINDOW_CLASS}" \
      "${IKA_OPTIONS_SOFTWARE_CHOICES[@]/#/--yellow-choice=}" \
      --same-width="GPU Hardware!GPU Mode" \
      --same-width="$(IFS='!'; printf '%s' "${IKA_OPTIONS_EVEN_FIELDS[*]}")" \
      --active-tab=1 --button="Reset to default:4" \
      --button="Apply settings:2" --button="Apply and restart:0" --button="Cancel:1" \
      --tab="Startup Options" --output="${tab_dir}/1" --align=right \
      --border="${APP_OPTIONS_TAB_BORDER_PX}" "${fields1[@]}" \
      --tab="Gamepad Emulation" --output="${tab_dir}/2" --compact --columns=2 \
      --border="${CONTROLLER_MAPPING_TAB_BORDER_PX}" --align=right \
      --text="$(controller_mapping_form_text)" "${fields2[@]}" \
      || status=$?
    case "${status}" in
      0|2|4)
        ;;
      1|252)
        rm -rf "${tab_dir}"
        if [[ "${default_used}" == "true" ]]; then
          respond "ika.ini has Ika's default start options and keyboard gamepad again"
        else
          respond "ika.ini left as it was"
        fi
        return 0
        ;;
      *)
        rm -rf "${tab_dir}"
        die "could not open the start options window (it exited with ${status})"
        ;;
    esac

    read_ika_options_form "$(<"${tab_dir}/1")" values
    read_controller_mapping_form "$(<"${tab_dir}/2")" blank_at keys settings ini_settings
    [[ "${status}" -eq 4 ]] || break
    if confirm_reset_to_default "Ika" \
        "This will reset Ika's startup options and gamepad emulation mappings."; then
      reset_ika_settings_to_default
      default_used=true
      load_ika_options_form values
      load_ika_mapping_form keys settings
    fi
  done
  rm -rf "${tab_dir}"

  save_ika_settings_form values keys settings shown_values shown_keys shown_settings changed
  for key in "${changed[@]}"; do
    joined+="${joined:+, }${key}"
  done
  if [[ "${#changed[@]}" -gt 0 ]]; then
    respond "ika.ini: ${joined}; they apply the next time Ika starts"
  elif [[ "${default_used}" == "true" ]]; then
    respond "ika.ini has Ika's default start options and keyboard gamepad again"
  else
    respond "ika.ini left as it was"
  fi
  if [[ "${status}" -eq 0 ]]; then
    respond "Restarting Ika"
    IKA_NOTIFY=true setsid --fork "${IKA_SCRIPT_PATH}" restart \
      </dev/null >/dev/null 2>&1
  fi
}

# open_app_window NAME FULLSCREEN TITLE SIZE [START_APP [DPI]]: DPI is the
# display density 'ika app --dpi' gives, as app_dpi_value prints it, or auto.
# Releases the lock of an app's Startup Options window (see edit_app_settings),
# so that the window can open again while the app it started runs
release_app_settings_lock() {
  if [[ -n "${APP_SETTINGS_LOCK_FD:-}" ]]; then
    exec {APP_SETTINGS_LOCK_FD}>&-
    APP_SETTINGS_LOCK_FD=""
  fi
}

