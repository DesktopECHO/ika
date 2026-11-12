# ika: the console: its supervisor, input and environment, starting it.
# Sourced by src/tools/ika, in its order; see there.

scrcpy_supervisor_cleanup() {
  if [[ -n "${scrcpy_supervisor_child_pid:-}" ]]; then
    kill "${scrcpy_supervisor_child_pid}" >/dev/null 2>&1 || true
    wait "${scrcpy_supervisor_child_pid}" 2>/dev/null || true
  fi
  remove_app_cuttlefish_display
  repair_wslg_taskbar_pins
  if [[ -f "${SCRCPY_SUPERVISOR_PID_FILE}" \
      && "$(<"${SCRCPY_SUPERVISOR_PID_FILE}")" == "$$" ]]; then
    rm -f "${SCRCPY_SUPERVISOR_PID_FILE}"
  fi
}

# scrcpy reaches its server through an "adb forward" of a local port, and adb
# rebinds a port that is already forwarded. Clients connecting at the same time
# (app windows opened together from the menu) would take over, and on failure
# remove, each other's forward, so each supervisor locks a port of its own for
# as long as it runs.
SCRCPY_FORWARD_PORT_FIRST=27183
SCRCPY_FORWARD_PORT_LAST=27299

# Sets the variables named by $1 and $2 to a free forward port and the open
# file descriptor that holds its lock.
lock_scrcpy_forward_port() {
  local -n port_ref="$1"
  local -n port_fd_ref="$2"
  local dir="${CVD_TMP_DIR}/scrcpy-ports"
  local port
  local fd

  mkdir -p "${dir}" || return 1
  for (( port = SCRCPY_FORWARD_PORT_FIRST; port <= SCRCPY_FORWARD_PORT_LAST; port++ )); do
    exec {fd}>"${dir}/${port}.lock" || continue
    if flock -n "${fd}"; then
      port_ref="${port}"
      port_fd_ref="${fd}"
      return 0
    fi
    exec {fd}>&-
  done
  return 1
}

run_scrcpy_supervisor() {
  local adb_serial="$1"
  local initial_fullscreen="$2"
  shift 2
  [[ "${1:-}" == "--" ]] || die "invalid console supervisor arguments"
  shift
  local -a base_command=("$@")
  local -a command
  local previous_boot_id
  local new_boot_id
  local window_width=""
  local window_height=""
  local fullscreen="${initial_fullscreen}"
  local status
  local started_at
  # Quick failures are retried: the guest may still be settling at the first
  # launch and right after a reboot.
  local quick_retries=4
  local quick_retry_sec=5
  local supervisor_lock_fd
  local forward_port=""
  local forward_port_fd=""
  local port_given="false"
  local arg
  local console_mode="desktop"
  local guest_mode
  local -a switch_options=()

  if [[ " ${base_command[*]} " == *" --window-state-file=${TV_CONSOLE_WINDOW_STATE_FILE} "* ]]; then
    console_mode="tv"
    SCRCPY_WINDOW_STATE_FILE="${TV_CONSOLE_WINDOW_STATE_FILE}"
  fi

  if [[ ! "${IKA_SCRCPY_REBOOT_TIMEOUT_SEC}" =~ ^[1-9][0-9]*$ ]]; then
    die "IKA_SCRCPY_REBOOT_TIMEOUT_SEC must be a positive whole number of seconds"
  fi

  exec {supervisor_lock_fd}>"${SCRCPY_SUPERVISOR_LOCK_FILE}"
  if ! flock -n "${supervisor_lock_fd}"; then
    log "another console supervisor is already active"
    return 0
  fi

  umask 077
  printf '%s\n' "$$" > "${SCRCPY_SUPERVISOR_PID_FILE}.tmp.$$"
  mv -f "${SCRCPY_SUPERVISOR_PID_FILE}.tmp.$$" "${SCRCPY_SUPERVISOR_PID_FILE}"
  scrcpy_supervisor_child_pid=""
  trap 'exit 0' INT TERM HUP
  trap scrcpy_supervisor_cleanup EXIT

  for arg in "${base_command[@]}"; do
    case "${arg}" in
      --port|--port=*|-p|-p[0-9]*) port_given="true" ;;
    esac
  done
  if [[ "${port_given}" != "true" ]]; then
    if lock_scrcpy_forward_port forward_port forward_port_fd; then
      base_command+=(--port="${forward_port}")
      log "using adb forward port ${forward_port}"
    else
      log "no free adb forward port; using the scrcpy default"
    fi
  fi

  # The boot id tells a reboot from a stop once the console is gone; an app
  # window does not reopen after either, so it skips the round trip.
  previous_boot_id=""
  if [[ "${APP_WINDOW_SUPERVISOR:-false}" != "true" ]]; then
    previous_boot_id="$(adb_guest_boot_id "${adb_serial}" || true)"
  fi
  local saved_fullscreen
  if read_scrcpy_window_state "${SCRCPY_WINDOW_STATE_FILE}" \
      window_width window_height saved_fullscreen; then
    log "restoring saved console size ${window_width}x${window_height}"
  fi
  # On WSLg, the window's task bar button gets its launcher's right-click
  # actions, once the window shows
  if [[ "${APP_WINDOW_SUPERVISOR:-false}" == "true" ]]; then
    set_wslg_jump_list \
      "$(app_menu_data_dir)/applications/$(app_window_id "${APP_WINDOW_PACKAGE}").desktop"
  else
    set_wslg_jump_list \
      "${XDG_DATA_HOME:-${HOME}/.local/share}/applications/ika-$(wslg_distro_id).desktop"
  fi
  # A normal launch obeys the requested windowed/fullscreen mode, which for
  # the console start_scrcpy_with_retries took from the saved state when -f
  # did not ask for fullscreen. The saved value is read again below when
  # recovering the same console from a confirmed guest reboot.
  while has_live_cvd_processes; do
    command=("${base_command[@]}")
    if [[ -n "${window_width}" && -n "${window_height}" ]]; then
      command+=(--window-width="${window_width}" --window-height="${window_height}")
    fi
    if [[ "${fullscreen}" == "true" ]]; then
      command+=(--fullscreen)
    fi

    log "starting console (fullscreen=${fullscreen})"
    started_at="${SECONDS}"
    "${command[@]}" &
    scrcpy_supervisor_child_pid="$!"
    set +e
    wait "${scrcpy_supervisor_child_pid}"
    status="$?"
    set -e
    scrcpy_supervisor_child_pid=""

    if [[ "${status}" -eq 0 ]]; then
      # Closing the window is intentional and must not create a reopen loop.
      log "console closed by user"
      return 0
    fi

    if [[ "${status}" -ne "${SCRCPY_EXIT_DISCONNECTED}" ]]; then
      if (( quick_retries > 0 && SECONDS - started_at < quick_retry_sec )) \
          && has_live_cvd_processes; then
        log "console exited quickly with status ${status}; retrying"
        quick_retries=$((quick_retries - 1))
        sleep 1
        continue
      fi
      log "console exited with status ${status}; not relaunching"
      return "${status}"
    fi

    quick_retries=0
    if [[ "${APP_WINDOW_SUPERVISOR:-false}" == "true" ]]; then
      # App windows do not reopen after a reboot: Android starts clean. The
      # display goes now, while its number cannot yet be another window's.
      log "guest disconnected; closing the app window"
      remove_app_cuttlefish_display
      return 0
    fi
    if ! read_scrcpy_window_state "${SCRCPY_WINDOW_STATE_FILE}" \
        window_width window_height fullscreen; then
      log "console window state was unavailable; retaining the previous launch size and mode"
    fi

    has_live_cvd_processes || return 0
    log "guest disconnected; waiting up to ${IKA_SCRCPY_REBOOT_TIMEOUT_SEC}s for reboot completion"
    new_boot_id="$(wait_for_guest_reboot "${adb_serial}" "${previous_boot_id}" \
      "${IKA_SCRCPY_REBOOT_TIMEOUT_SEC}" || true)"
    if [[ -z "${new_boot_id}" ]]; then
      if has_live_cvd_processes; then
        log "guest did not complete a new boot; console will remain closed"
      else
        log "Cuttlefish stopped; console will remain closed"
      fi
      return 0
    fi

    previous_boot_id="${new_boot_id}"
    # IkaMode's switcher changes Android's mode at a restart. Hand over to a
    # console for the new mode, started once this supervisor has released its
    # lock, as that mode's console was last used: fullscreen or windowed, from
    # its own window state, which the other mode's console does not touch.
    guest_mode="$(guest_ui_mode "${adb_serial}")"
    if [[ -n "${guest_mode}" && "${guest_mode}" != "${console_mode}" ]]; then
      console_switch_start_options switch_options "${guest_mode}"
      log "Android restarted in ${guest_mode} mode; opening its console${switch_options[0]:+ ${switch_options[*]}}"
      exec {supervisor_lock_fd}>&-
      if [[ -n "${forward_port_fd}" ]]; then
        exec {forward_port_fd}>&-
      fi
      setsid --fork bash -c 'while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
          exec "$2" start "${@:3}"' ika-console-switch "$$" "${IKA_SCRIPT_PATH}" \
        "${switch_options[@]}" </dev/null >/dev/null 2>&1 3>&-
      return 0
    fi
    # Connecting can take scrcpy's server about 10s on a freshly booted guest.
    quick_retries=4
    quick_retry_sec=30
    log "guest reboot completed; relaunching console at ${window_width:-default}x${window_height:-default}"
  done
}

# Prints the combined size of the guest's logs, which grow while it boots.
guest_log_bytes() {
  local total=0
  local size
  local log_file

  for log_file in "${CVD_INSTANCE_DIR}"/logs/{kernel.log,logcat,launcher.log}; do
    size="$(stat -L -c '%s' "${log_file}" 2>/dev/null || echo 0)"
    total=$((total + size))
  done
  printf '%s\n' "${total}"
}

# Succeeds while process PID runs. A zombie has exited.
process_is_running() {
  local state

  state="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1 || true)"
  [[ -n "${state}" && "${state}" != "Z" ]]
}

# Waits up to CVD_BOOT_TIMEOUT_SEC for Android to boot, and past it while the
# guest's logs still grow (see CVD_BOOT_MAX_SEC). LAUNCHER_PID counts as a live
# VM process: cvd_internal_start replaces itself with 'cvd create', which
# CVD_PROCESS_REGEX does not match, and run_cvd only starts after it.
wait_for_boot() {
  local launcher_log="$1"
  local min_mtime="${2:-0}"
  local launcher_pid="${3:-}"
  local adb_serial=""
  local crosvm_command_reported="false"
  local deadline
  local max_deadline
  local stall_deadline=0
  local log_bytes
  local last_log_bytes=""

  deadline="$(make_deadline "${CVD_BOOT_TIMEOUT_SEC}")"
  max_deadline="$(make_deadline "${CVD_BOOT_MAX_SEC}")"
  while within_deadline "${max_deadline}"; do
    if [[ -f "${launcher_log}" ]]; then
      local log_mtime
      log_mtime="$(stat -c '%Y' "${launcher_log}" 2>/dev/null || echo 0)"
      if [[ "${crosvm_command_reported}" != "true" ]]; then
        if maybe_respond_crosvm_command "${launcher_log}" "${min_mtime}"; then
          crosvm_command_reported="true"
        fi
      fi
    fi
    # The serial depends on this launch's adb mode, so wait for its config.
    if [[ -z "${adb_serial}" ]] \
        && (( $(stat -c '%Y' "${CVD_CONFIG_PATH}" 2>/dev/null || echo 0) >= min_mtime )); then
      adb_serial="$(resolve_adb_serial)"
    fi
    if [[ -n "${adb_serial}" ]] && adb_first_frame_shown "${adb_serial}"; then
      return 0
    fi
    if ! has_live_cvd_processes \
        && ! { [[ -n "${launcher_pid}" ]] && process_is_running "${launcher_pid}"; }; then
      return 1
    fi
    if ! within_deadline "${deadline}"; then
      log_bytes="$(guest_log_bytes)"
      if [[ -z "${last_log_bytes}" ]]; then
        log "Android has not finished booting after ${CVD_BOOT_TIMEOUT_SEC}s; waiting while it makes progress"
      fi
      if [[ "${log_bytes}" != "${last_log_bytes}" ]]; then
        last_log_bytes="${log_bytes}"
        stall_deadline="$(make_deadline "${CVD_BOOT_STALL_SEC}")"
      elif ! within_deadline "${stall_deadline}"; then
        log "the guest logs have not changed for ${CVD_BOOT_STALL_SEC}s"
        return 1
      fi
    fi
    sleep 0.1
  done

  return 1
}

# Installs Chromium until it has succeeded once for this VM. 'ika reset'
# removes the stamp, so a reset VM gets it again; one removed by the user stays
# removed.
ensure_chromium() {
  local adb_serial="$1"
  local hardware_vulkan=1

  if [[ -e "${CHROMIUM_INSTALL_STAMP}" ]]; then
    return 0
  fi

  if [[ ! -x "${PACKAGED_GETCHROMIUM_BIN}" ]]; then
    log "${PACKAGED_GETCHROMIUM_BIN} is unavailable; skipping Chromium."
    return 0
  fi

  # Without a hardware Vulkan device (none, llvmpipe first, or one gfxstream
  # passes over for a software one), getchromium turns off Chromium's
  # Vulkan-only GPU path
  load_vulkaninfo_summary
  if [[ -z "${VULKANINFO_SUMMARY}" ]] || primary_vulkan_device_is_llvmpipe \
      || gfxstream_passes_over_hardware_vulkan >/dev/null; then
    hardware_vulkan=0
  fi
  if ANDROID_SERIAL="${adb_serial}" IKA_CHROMIUM_APK="${CHROMIUM_APK}" \
      IKA_HARDWARE_VULKAN="${hardware_vulkan}" \
      "${PACKAGED_GETCHROMIUM_BIN}" >&3 2>&3; then
    mkdir -p "$(dirname "${CHROMIUM_INSTALL_STAMP}")"
    : > "${CHROMIUM_INSTALL_STAMP}"
    log "getchromium completed."
  else
    log "getchromium failed; it runs again on the next start."
  fi
}

# 'ika app --touch' exports IKA_TOUCH, which the console client reads to send
# left-button clicks and drags as real touch input. Unset, empty and 0 mean
# off, as in the client.
touch_enabled() {
  [[ -n "${IKA_TOUCH:-}" && "${IKA_TOUCH}" != "0" ]]
}

# Whether the extra scrcpy args (IKA_SCRCPY) set the gamepad themselves, as
# --gamepad=MODE, scrcpy's -G, or --gamekb (the keyboard as the gamepad).
scrcpy_extra_args_set_gamepad() {
  local -a scrcpy_extra_args=()
  local arg

  [[ -n "${IKA_SCRCPY:-}" ]] || return 1
  read -r -a scrcpy_extra_args <<<"${IKA_SCRCPY}"
  for arg in "${scrcpy_extra_args[@]}"; do
    case "${arg}" in
      --gamepad|--gamepad=*|--gamekb|--gamekb=*)
        return 0
        ;;
      -[!-]*)
        [[ "${arg}" != *G* ]] || return 0
        ;;
    esac
  done
  return 1
}

# The spec's name of a setting of [keyboard_gamepad]
keyboard_gamepad_setting_spec_name() {
  case "$1" in
    stick_ramp_ms) echo "ramp_ms" ;;
    *) echo "$1" ;;
  esac
}

# Prints the value of the keyboard gamepad setting NAME, or its default with
# a log line when VALUE is not one: stick_ramp_ms 0 to 5000, walk_percent 1
# to 100, socd last or neutral, the per-pad socd settings those or empty.
normalize_keyboard_gamepad_setting() {
  local name="$1"
  local value="${2,,}"
  local default="$3"
  local ok="false"

  case "${name}" in
    stick_ramp_ms)
      [[ "${value}" =~ ^[0-9]+$ && "${value}" -le 5000 ]] && ok="true"
      ;;
    walk_percent)
      [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge 1 && "${value}" -le 100 ]] && ok="true"
      ;;
    socd)
      [[ "${value}" == last || "${value}" == neutral ]] && ok="true"
      ;;
    socd_dpad|socd_left_stick|socd_right_stick)
      [[ "${value}" == last || "${value}" == neutral || -z "${value}" ]] && ok="true"
      ;;
    mouse_stick)
      [[ "${value}" == off || "${value}" == right || "${value}" == left ]] && ok="true"
      ;;
    mouse_sensitivity)
      [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge 1 && "${value}" -le 1000 ]] && ok="true"
      ;;
  esac
  if [[ "${ok}" != "true" ]]; then
    log "keyboard gamepad: ${name} must be $(keyboard_gamepad_setting_values "${name}"), not '${2}'; using '${default}'"
    value="${default}"
  fi
  printf '%s\n' "${value}"
}

keyboard_gamepad_setting_values() {
  case "$1" in
    stick_ramp_ms) echo "0 to 5000" ;;
    walk_percent) echo "1 to 100" ;;
    socd) echo "last or neutral" ;;
    mouse_stick) echo "off, right or left" ;;
    mouse_sensitivity) echo "1 to 1000" ;;
    *) echo "last, neutral or empty" ;;
  esac
}

# A game's controller mapping: ~/ika/apps/PACKAGE/controller.ini, the keys
# and settings of [keyboard_gamepad] for that game, over ika.ini's.
app_controller_mapping_file() {
  printf '%s/%s/controller.ini\n' "${IKA_APPS_DIR}" "$1"
}

# Reads PACKAGE's controller mapping into the associative arrays KEYS (control
# to its keys) and SETTINGS (setting to its value); nothing when the game has
# none. Lines that are not a control or a setting are reported and skipped.
load_app_controller_mapping() {
  local package="$1"
  local -n mapping_keys_ref="$2"
  local -n mapping_settings_ref="$3"
  local file line name value

  file="$(app_controller_mapping_file "${package}")"
  [[ -r "${file}" ]] || return 0
  while IFS= read -r line; do
    name="${line%%=*}"
    value="${line#*=}"
    if [[ " ${KEYBOARD_GAMEPAD_CONTROLS[*]} " == *" ${name} "* ]]; then
      mapping_keys_ref["${name}"]="${value}"
    elif [[ " ${KEYBOARD_GAMEPAD_SETTINGS[*]} " == *" ${name} "* ]]; then
      mapping_settings_ref["${name}"]="${value}"
    else
      log "${file}: '${name}' is not a control or a setting of the keyboard gamepad; ignored"
    fi
  done < <(awk '
    { sub(/[[:space:]]+$/, "") }
    /^[[:space:]]*[#;]/ || /^[[:space:]]*$/ { next }
    /^\[/ { in_section = (tolower($0) == "[keyboard_gamepad]"); next }
    in_section && /=/ {
      name = $0; sub(/[[:space:]]*=.*/, "", name); sub(/^[[:space:]]+/, "", name)
      value = $0; sub(/^[^=]*=[[:space:]]*/, "", value)
      print tolower(name) "=" value
    }' "${file}")
}

# Prints scrcpy's --gamekb spec from the [keyboard_gamepad] keys and settings,
# and those of PACKAGE's controller mapping over them when PACKAGE is given:
# control=key/key,control=key,setting=value, controls without keys left out.
# A key that an ika.ini line or the game's mapping gives a control is left out
# of the control it is a default of, so that moving a key takes one line
# (scrcpy keeps a key given twice for its first control).
keyboard_gamepad_spec() {
  local package="${1:-}"
  local control key keys setting value spec=""
  local -a words kept
  local -A given_keys=()
  local -A app_keys=()
  local -A app_settings=()

  if [[ -n "${package}" ]]; then
    load_app_controller_mapping "${package}" app_keys app_settings
  fi

  for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
    if [[ -n "${app_keys[${control}]+set}" ]]; then
      read -r -a words <<<"${app_keys[${control}]}"
    elif [[ -n "${IKA_INI[keyboard_gamepad.${control}]+set}" ]]; then
      read -r -a words <<<"${KEYBOARD_GAMEPAD_KEYS[${control}]}"
    else
      continue
    fi
    for key in "${words[@]}"; do
      given_keys["${key,,}"]=1
    done
  done

  for control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
    if [[ -n "${app_keys[${control}]+set}" ]]; then
      read -r -a words <<<"${app_keys[${control}]}"
    else
      read -r -a words <<<"${KEYBOARD_GAMEPAD_KEYS[${control}]}"
      if [[ -z "${IKA_INI[keyboard_gamepad.${control}]+set}" ]]; then
        kept=()
        for key in "${words[@]}"; do
          [[ -n "${given_keys[${key,,}]+set}" ]] || kept+=("${key}")
        done
        words=("${kept[@]}")
      fi
    fi
    [[ "${#words[@]}" -gt 0 ]] || continue
    keys="$(IFS=/; printf '%s' "${words[*]}")"
    spec+="${spec:+,}${control}=${keys}"
  done

  for setting in "${KEYBOARD_GAMEPAD_SETTINGS[@]}"; do
    if [[ -n "${app_settings[${setting}]+set}" ]]; then
      value="${app_settings[${setting}]}"
    else
      value="${KEYBOARD_GAMEPAD_SETTING_VALUES[${setting}]}"
    fi
    value="$(normalize_keyboard_gamepad_setting "${setting}" "${value}" \
      "${KEYBOARD_GAMEPAD_SETTING_VALUES[${setting}]}")"
    [[ -n "${value}" ]] || continue
    spec+="${spec:+,}$(keyboard_gamepad_setting_spec_name "${setting}")=${value}"
  done
  printf '%s\n' "${spec}"
}

# Whether the app's start options pass INPUT through to Android as a HID
# device: keyboard, mouse, gamepad, or gamekb (the keyboard as a gamepad).
# apply_saved_app_options exports them in IKA_APP_INPUT, separated by spaces,
# for the app window it opens.
app_input_enabled() {
  [[ " ${IKA_APP_INPUT:-} " == *" $1 "* ]]
}

# Whether the TV console also makes the keyboard a gamepad
# (console.tv_keyboard_gamepad in ika.ini, IKA_TV_KEYBOARD_GAMEPAD).
tv_keyboard_gamepad_enabled() {
  case "${IKA_TV_KEYBOARD_GAMEPAD:-false}" in
    [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]|1) return 0 ;;
    *) return 1 ;;
  esac
}

# The input of a console or app window, for MODE: "desktop" (the desktop
# console), "tv" (the TV console) or "app" (an app window). The consoles keep
# text-friendly SDK keyboard injection, and the TV console passes the gamepad
# through as the remote, with the keyboard as a gamepad too when
# tv_keyboard_gamepad_enabled. An app passes through the
# HID devices its start options tick (IKA_APP_INPUT), each a UHID device: the
# keyboard, the mouse, gamepads, and the keyboard as a gamepad (scrcpy's
# --gamekb, with the [keyboard_gamepad] keys: those keys no longer type, other
# keys still do). Extra args that set --gamepad or --gamekb themselves win.
# Touch input needs the SDK mouse, so it wins over the mouse; a finger does
# not hover.
append_scrcpy_input_args() {
  local -n input_args_ref="$1"
  local mode="$2"
  local label="$3"
  local package="${4:-}"
  local -a gamepad_args=()

  if [[ "${mode}" == "tv" ]] && tv_keyboard_gamepad_enabled; then
    log "${label} TV mode: the gamepad is the remote, and the keyboard a gamepad too: $(keyboard_gamepad_spec)"
    gamepad_args=(--gamepad=uhid "--gamekb=$(keyboard_gamepad_spec)")
  elif [[ "${mode}" == "tv" ]]; then
    log "${label} TV mode: the gamepad is the remote, desktop keyboard and mouse"
    gamepad_args=(--gamepad=uhid)
  elif [[ "${mode}" == "app" ]]; then
    log "${label} HID devices: ${IKA_APP_INPUT:-none}"
    if app_input_enabled gamekb; then
      log "${label} keyboard gamepad: $(keyboard_gamepad_spec "${package}")"
      gamepad_args=(--gamepad=uhid "--gamekb=$(keyboard_gamepad_spec "${package}")")
    elif app_input_enabled gamepad; then
      gamepad_args=(--gamepad=uhid)
    fi
  fi
  if [[ "${#gamepad_args[@]}" -gt 0 ]] && scrcpy_extra_args_set_gamepad; then
    log "${label} gamepad: set by the extra args"
    gamepad_args=()
  fi
  input_args_ref+=("${gamepad_args[@]}")

  if [[ "${mode}" == "app" ]] && app_input_enabled keyboard; then
    input_args_ref+=(--keyboard=uhid)
  else
    input_args_ref+=(--keyboard=sdk --prefer-text)
  fi
  if [[ "${mode}" != "tv" ]] && touch_enabled; then
    if [[ "${mode}" == "app" ]] && app_input_enabled mouse; then
      log "${label} touch input: the mouse is not a HID device"
    else
      log "${label} touch input"
    fi
    input_args_ref+=(--no-mouse-hover)
  elif [[ "${mode}" == "app" ]] && app_input_enabled mouse; then
    input_args_ref+=(--mouse=uhid)
  fi
}

append_scrcpy_extra_args() {
  local -n extra_args_ref="$1"
  local label="$2"
  local -a scrcpy_extra_args=()

  [[ -n "${IKA_SCRCPY:-}" ]] || return 0
  read -r -a scrcpy_extra_args <<<"${IKA_SCRCPY}"
  if [[ "${#scrcpy_extra_args[@]}" -gt 0 ]]; then
    log "using extra ${label} args: $(shell_join "${scrcpy_extra_args[@]}")"
    extra_args_ref+=("${scrcpy_extra_args[@]}")
  fi
}

# Windows' display scale, in percent, as WSLg last saw it for the primary
# monitor: weston.log records every monitor layout Windows sends it (at
# start and when the displays or their scale change). 100 when unknown.
wslg_windows_scale() {
  local weston_log="${IKA_WSLG_WESTON_LOG:-/mnt/wslg/weston.log}"
  local scale=""

  if [[ -r "${weston_log}" ]]; then
    scale="$(awk '
      /rdpMonitor\[[0-9]+\]: x:.*is_primary:/ {
        primary = ($0 ~ /is_primary:1/)
      }
      primary && match($0, /desktopScaleFactor:[0-9]+/) {
        value = substr($0, RSTART + 19, RLENGTH - 19) + 0
        if (value > 0) {
          scale = value
        }
      }
      END { print scale }
    ' "${weston_log}" 2>/dev/null || true)"
  fi
  [[ "${scale}" =~ ^[0-9]+$ ]] || scale=100
  printf '%s\n' "${scale}"
}

# Ika's copy of Windows' Segoe UI Variable, for the title bars of its windows
# on WSLg, made once (and again when Windows' changes); nothing when Windows
# has none.
wslg_caption_font() {
  local source="${IKA_WINDOWS_FONTS_DIR:-/mnt/c/Windows/Fonts}/SegUIVar.ttf"
  local copy="${CVD_HOME_DIR}/fonts/SegUIVar.ttf"

  [[ -f "${source}" ]] || return 0
  if [[ ! -f "${copy}" ]] \
      || [[ "$(stat -c %s "${source}")" != "$(stat -c %s "${copy}")" ]]; then
    mkdir -p "${copy%/*}" \
      && cp -f "${source}" "${copy}.tmp.$$" \
      && mv -f "${copy}.tmp.$$" "${copy}" \
      || { rm -f "${copy}.tmp.$$"; return 0; }
  fi
  printf '%s\n' "${copy}"
}

# On WSLg, a fontconfig file of Ika's for its windows (FONTCONFIG_FILE): the
# system's configuration, with Segoe UI Variable, Windows' own font
# (wslg_caption_font's copy), as the sans-serif font, so that the text of the
# Startup Options windows and Ika's dialogs matches Windows' (scrcpy's title
# bars load the font themselves). Prints
# its path; nothing when Windows has no such font, or the user set
# FONTCONFIG_FILE.
wslg_fontconfig_file() {
  local font
  local file="${CVD_HOME_DIR}/fonts/fonts.conf"

  [[ "${IKA_ON_WSLG}" == true && -z "${FONTCONFIG_FILE:-}" ]] || return 0
  font="$(wslg_caption_font)"
  [[ -n "${font}" ]] || return 0
  write_file_if_changed "${file}" <<EOF || true
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- Written by ika: Windows' Segoe UI Variable as the sans-serif font of
     Ika's windows on WSLg -->
<fontconfig>
  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
  <dir>${font%/*}</dir>
  <alias binding="strong">
    <family>sans-serif</family>
    <prefer><family>Segoe UI Variable</family></prefer>
  </alias>
</fontconfig>
EOF
  [[ -f "${file}" ]] && printf '%s\n' "${file}"
}

append_scrcpy_env() {
  local -n scrcpy_env_ref="$1"
  local caption_font

  if [[ -d "${SCRCPY_ICON_DIR_DEFAULT}" ]]; then
    scrcpy_env_ref+=("SCRCPY_ICON_DIR=${SCRCPY_ICON_DIR_DEFAULT}")
  fi

  if [[ -x "${CVD_CLI_BIN}" ]]; then
    scrcpy_env_ref+=("IKA_CVD_BIN=${CVD_CLI_BIN}")
  fi

  # The window's title bar and shadow come from libdecor's GTK plugin. WSLg
  # shows each as a window of its own and leaves it on screen once the
  # plugin unmaps it, as it does in fullscreen; Ika's build of the plugin
  # (tools/wsl/libdecor) destroys them instead. A plugin directory the user
  # set is kept.
  if [[ "${IKA_ON_WSLG}" == true && -z "${LIBDECOR_PLUGIN_DIR:-}" \
        && -f "${PACKAGED_WSL_GPU_DIR}/libdecor/libdecor-gtk.so" ]]; then
    scrcpy_env_ref+=("LIBDECOR_PLUGIN_DIR=${PACKAGED_WSL_GPU_DIR}/libdecor")
  fi

  # On WSL2 the GPU is reached only through Direct3D 12 (/dev/dxg). Mesa's
  # OpenGL then falls back to llvmpipe, drawing every frame of the window on
  # the CPU (Zink, OpenGL on Dozen, refuses without robustness2's
  # nullDescriptor); its d3d12 driver draws on the GPU. Ika's own build of it
  # (tools/mesa) stages texture uploads in write-back
  # memory: the distribution's stages them in write-combined memory, which
  # WSL2 maps uncached, and uploading a video's frames took scrcpy 70% of a
  # core instead of 14%. Ika's build has no software renderer to fall back to,
  # so only with the D3D12 GPU setup_wsl_gpu_env found; else the
  # distribution's d3d12 driver where it has one. Unless the user set a
  # GALLIUM_DRIVER or an EGL vendor.
  if [[ -e /dev/dxg && -z "${GALLIUM_DRIVER:-}" && "${IKA_WSL_GPU_FIX:-1}" != "0" ]]; then
    if [[ -n "${IKA_WSL_GPU_ENV:-}" && -z "${__EGL_VENDOR_LIBRARY_FILENAMES:-}" \
          && -f "${PACKAGED_WSL_GPU_DIR}/mesa-gl/egl_vendor.json" ]]; then
      scrcpy_env_ref+=("GALLIUM_DRIVER=d3d12"
                       "__EGL_VENDOR_LIBRARY_FILENAMES=${PACKAGED_WSL_GPU_DIR}/mesa-gl/egl_vendor.json")
    elif compgen -G '/usr/lib*/dri/d3d12_dri.so' >/dev/null \
        || compgen -G '/usr/lib/*/dri/d3d12_dri.so' >/dev/null; then
      scrcpy_env_ref+=("GALLIUM_DRIVER=d3d12")
    fi
  fi

  # On WSLg the title bars look like Windows': scrcpy sizes them for Windows'
  # display scale, read when the window opens, and sets their title in
  # Windows' font.
  if [[ "${IKA_ON_WSLG}" == true ]]; then
    scrcpy_env_ref+=("IKA_WINDOWS_SCALE=$(wslg_windows_scale)")
    caption_font="$(wslg_caption_font)"
    if [[ -n "${caption_font}" ]]; then
      scrcpy_env_ref+=("IKA_CAPTION_FONT=${caption_font}")
    fi
  fi

  # scrcpy spawns `adb` to push the server jar and open the shell. Point it
  # at the cuttlefish-bundled adb explicitly so it doesn't rely on PATH —
  # on a stock Asahi system there's no /usr/bin/adb, and even where there
  # is one we want the cuttlefish version that's known to match the rest
  # of the cvd-host_package.
  local packaged_adb="${PACKAGED_CVD_HOST_OUT}/bin/adb"
  if [[ -x "${packaged_adb}" ]]; then
    scrcpy_env_ref+=("ADB=${packaged_adb}")
  fi

  if [[ -n "${SCRCPY_SERVER_PATH_OVERRIDE}" && -f "${SCRCPY_SERVER_PATH_OVERRIDE}" ]]; then
    scrcpy_env_ref+=("SCRCPY_SERVER_PATH=${SCRCPY_SERVER_PATH_OVERRIDE}")
  fi

  # On GNOME Wayland, GTK draws the window title bar (libdecor's GTK plugin)
  # and only goes dark when GTK_THEME says so. Match the desktop's light or
  # dark style, unless the user set a theme.
  if [[ -z "${GTK_THEME:-}" ]]; then
    if [[ "$(host_color_scheme)" == "dark" ]]; then
      scrcpy_env_ref+=("GTK_THEME=Adwaita:dark")
    else
      scrcpy_env_ref+=("GTK_THEME=Adwaita")
    fi
  fi

  # The window follows the session: Wayland on a Wayland session, X11 on an
  # X11 one. Left to itself, scrcpy's SDL opens an X11 window through
  # Xwayland on a Wayland compositor without the fifo-v1 protocol (KWin
  # before 6.4), and every frame then crosses Xwayland. A driver set in the
  # environment is kept.
  if [[ -z "${SDL_VIDEO_DRIVER:-}${SDL_VIDEODRIVER:-}" ]]; then
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
      scrcpy_env_ref+=("SDL_VIDEO_DRIVER=wayland" "SDL_VIDEODRIVER=wayland")
    elif [[ -n "${DISPLAY:-}" ]]; then
      scrcpy_env_ref+=("SDL_VIDEO_DRIVER=x11" "SDL_VIDEODRIVER=x11")
    fi
  fi
}

start_scrcpy_with_retries() {
  local adb_serial="$1"
  local fullscreen_mode="${2:-false}"
  local input_mode="desktop"
  local cuttlefish_frames_socket
  local scrcpy_log="${SCRCPY_LOG_FILE}"
  local scrcpy_lock_file="${CVD_TMP_DIR}/console-launch.lock"
  local scrcpy_lock_fd=""
  local scrcpy_window_size
  local scrcpy_window_width
  local console_dpi="${SCRCPY_DPI}"
  local scrcpy_window_height
  local saved_width
  local saved_height
  local saved_fullscreen
  local -a scrcpy_env=()
  local -a scrcpy_cmd=(
    "${SCRCPY_BIN}"
    -s "${adb_serial}"
  )

  # In Android's TV mode the console is the TV screen: fullscreen, at the TV
  # density (--dpi wins in either mode), with the gamepad as the remote.
  if [[ "$(guest_ui_mode "${adb_serial}")" == "tv" ]]; then
    log "Android is in TV mode"
    fullscreen_mode="true"
    input_mode="tv"
    if [[ "${SCRCPY_DPI_GIVEN}" != "true" ]]; then
      console_dpi="$(resolve_tv_dpi)"
    fi
  elif [[ "${fullscreen_mode}" != "true" ]] \
      && read_scrcpy_window_state "${SCRCPY_WINDOW_STATE_FILE}" \
        saved_width saved_height saved_fullscreen \
      && [[ "${saved_fullscreen}" == "true" ]]; then
    # The console comes back as it closed, with MOD+Q or its close button:
    # fullscreen when it was. The supervisor restores its size from the same
    # file, the windowed one that leaving fullscreen returns to.
    fullscreen_mode="true"
    log "the console was fullscreen when it closed; opening it fullscreen"
  fi
  exec {scrcpy_lock_fd}>"${scrcpy_lock_file}"
  if ! flock "${scrcpy_lock_fd}"; then
    log "unable to acquire console launch lock: ${scrcpy_lock_file}"
    return 1
  fi

  scrcpy_window_size="$(default_scrcpy_window_size)"
  if [[ "${scrcpy_window_size}" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    scrcpy_window_width="${BASH_REMATCH[1]}"
    scrcpy_window_height="${BASH_REMATCH[2]}"
  else
    scrcpy_window_width=1280
    scrcpy_window_height=720
  fi

  if [[ -n "${console_dpi}" ]]; then
    scrcpy_cmd+=("--dpi=${console_dpi}")
  fi
  # Right, middle, 4th and 5th buttons, then the same with Shift: a right click
  # is a right click on the desktop (Back with Shift), and Back in TV mode, as
  # a remote's Back button (a right click with Shift). The middle button is
  # Home, the 4th and 5th the recent apps and the notifications.
  if [[ "${input_mode}" == "tv" ]]; then
    scrcpy_cmd+=(--mouse-bind=bhsn:++++)
  else
    scrcpy_cmd+=(--mouse-bind=+hsn:b+++)
  fi
  scrcpy_cmd+=(
    --force-adb-forward
    --render-driver=opengl
    --window-borderless
    --window-width="${scrcpy_window_width}"
    --window-height="${scrcpy_window_height}"
    --no-audio
  )

  append_scrcpy_input_args scrcpy_cmd "${input_mode}" console

  cuttlefish_frames_socket="$(resolve_cuttlefish_frames_socket)"
  scrcpy_cmd+=(--cuttlefish-frames-socket="${cuttlefish_frames_socket}")
  if [[ "${input_mode}" == "tv" ]]; then
    scrcpy_cmd+=(--window-state-file="${TV_CONSOLE_WINDOW_STATE_FILE}")
  else
    scrcpy_cmd+=(--window-state-file="${SCRCPY_WINDOW_STATE_FILE}")
  fi
  log "console video source: raw Cuttlefish frames (${cuttlefish_frames_socket})"

  append_scrcpy_extra_args scrcpy_cmd console
  append_scrcpy_env scrcpy_env
  # ika.desktop's ID, or on WSLg the distribution's (see console_app_id).
  # Otherwise SDL uses the executable name, scrcpy, which KDE's taskbar also
  # derives for app windows and would match to the console.
  write_wslg_console_entry
  scrcpy_env+=("SDL_APP_ID=$(console_app_id)")

  if [[ "${#scrcpy_env[@]}" -gt 0 ]]; then
    scrcpy_cmd=(
      env
      "${scrcpy_env[@]}"
      "${scrcpy_cmd[@]}"
    )
  fi

  mkdir -p "$(dirname "${scrcpy_log}")"
  : > "${scrcpy_log}"

  ensure_chromium "${adb_serial}"

  flock -u "${scrcpy_lock_fd}"
  exec {scrcpy_lock_fd}>&-

  log "starting supervised console for ${adb_serial}"
  setsid --fork "${IKA_SCRIPT_PATH}" __console_supervisor \
    "${adb_serial}" "${fullscreen_mode}" -- "${scrcpy_cmd[@]}" \
    </dev/null >>"${scrcpy_log}" 2>&1 3>&- &
  disown || true

  sleep 1.5
  if has_packaged_scrcpy || scrcpy_supervisor_pid >/dev/null; then
    return 0
  fi

  log "unable to start the console supervisor"
  return 1
}

schedule_scrcpy_when_launcher_ready() {
  local adb_serial="$1"
  local fullscreen_mode="${2:-false}"

  (
    detach_background_job
    while has_live_cvd_processes; do
      if adb_first_frame_shown "${adb_serial}"; then
        break
      fi
      sleep 0.1
    done

    if ! has_live_cvd_processes; then
      log "deferred console watcher stopped because Cuttlefish exited before Android's first frame."
      exit 0
    fi
    start_scrcpy_with_retries "${adb_serial}" "${fullscreen_mode}" || true
  ) &

  disown || true
  log "scheduled console launch for Android's first frame"
}

maybe_start_scrcpy() {
  local adb_serial="$1"
  local fullscreen_mode="${2:-false}"

  if [[ ! -x "${SCRCPY_BIN}" ]]; then
    log "console client not found at ${SCRCPY_BIN}; skipping launch."
    return 0
  fi

  if adb_first_frame_shown "${adb_serial}"; then
    log "Ika console ready; starting the console immediately."
    start_scrcpy_with_retries "${adb_serial}" "${fullscreen_mode}" || true
    return 0
  fi

  log "Android has not shown its first frame; deferring console launch."
  schedule_scrcpy_when_launcher_ready "${adb_serial}" "${fullscreen_mode}"
  return 0
}

