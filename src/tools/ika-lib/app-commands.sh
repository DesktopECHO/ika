# ika: games in the background, closing app windows, ika app.
# Sourced by src/tools/ika, in its order; see there.

# Prints "LABEL<TAB>PACKAGE" for each open app window, using the cached title.
list_open_app_windows() {
  local pid_file
  local app_dir
  local package
  local title

  for pid_file in "${CVD_TMP_DIR}"/app-supervisor-*.pid; do
    [[ -f "${pid_file}" ]] || continue
    supervisor_pid_from_file "${pid_file}" __app_supervisor >/dev/null || continue
    package="${pid_file##*/app-supervisor-}"
    package="${package%.pid}"
    app_dir="${IKA_APPS_DIR}/${package}"
    title="${package}"
    if [[ -s "${app_dir}/title" ]]; then
      title="$(<"${app_dir}/title")"
    fi
    printf '%s\t%s\n' "${title}" "${package}"
  done
}

# Prints "LABEL<TAB>PACKAGE" for each game in the background.
list_background_apps() {
  local file
  local package
  local title

  for file in "${CVD_TMP_DIR}"/app-background-*; do
    [[ -f "${file}" ]] || continue
    package="${file##*/app-background-}"
    title="${package}"
    if [[ -s "${IKA_APPS_DIR}/${package}/title" ]]; then
      title="$(<"${IKA_APPS_DIR}/${package}/title")"
    fi
    printf '%s\t%s\n' "${title}" "${package}"
  done
}

app_is_in_background() {
  [[ -f "$(app_background_file "$1")" ]]
}

# Whether opening a game sends the other games to the background
# (apps.background_games in ika.ini, IKA_BACKGROUND_GAMES).
background_games_enabled() {
  case "${IKA_BACKGROUND_GAMES:-true}" in
    [Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]|0) return 1 ;;
  esac
  return 0
}

# Prints the Android displays, other than the console's, that hold a task of
# PACKAGE: a task whose first activity is the package's.
guest_app_task_displays() {
  local package="$1"
  local adb_serial="$2"

  guest_adb "${adb_serial}" shell am stack list </dev/null 2>/dev/null | tr -d '\r' \
    | awk -v pkg="${package}" '
      /^RootTask id=/ {
        display = ""
        for (i = 1; i <= NF; i++) if ($i ~ /^displayId=/) display = substr($i, 11)
      }
      $1 ~ /^taskId=[0-9]+:$/ {
        split($2, component, "/")
        if (component[1] == pkg && display != "" && display != "0") print display
      }' | sort -un
}

# Whether an open app window, or another game in the background, shows the
# Cuttlefish display NUMBER: after a restart, a stale record's number can be
# another window's.
cuttlefish_display_in_use() {
  local number="$1"
  local except_package="$2"
  local pid_file
  local pid
  local file
  local boot_id
  local port
  local display

  for pid_file in "${CVD_TMP_DIR}"/app-supervisor-*.pid; do
    [[ -f "${pid_file}" ]] || continue
    pid="$(supervisor_pid_from_file "${pid_file}" __app_supervisor)" || continue
    tr '\0' '\n' <"/proc/${pid}/cmdline" 2>/dev/null \
      | grep -qxF -- "--cuttlefish-display=${number}" && return 0
  done
  for file in "${CVD_TMP_DIR}"/app-background-*; do
    [[ -f "${file}" && "${file##*/app-background-}" != "${except_package}" ]] || continue
    read -r boot_id port display <"${file}" || true
    [[ "${port}" == "${number}" ]] && return 0
  done
  return 1
}

# Ends a game in the background: its display goes, and the game with it.
discard_background_app() {
  local package="$1"
  local file
  local boot_id=""
  local port=""
  local display=""

  file="$(app_background_file "${package}")"
  [[ -f "${file}" ]] || return 0
  read -r boot_id port display <"${file}" || true
  if [[ "${port}" =~ ^[1-9][0-9]*$ ]] && ! cuttlefish_display_in_use "${port}" "${package}"; then
    remove_cuttlefish_display "${port}" || true
  fi
  rm -f "${file}"
}

# Sends the game in an app window to the background: the window closes, but
# the game stays on its Cuttlefish display, which is turned off, so that
# Android stops the game (as when the screen goes off) without ending it, and
# out of the console's way. Opening the game again turns the display back on
# in a new window (resume_background_app). A game that cannot be kept so is
# closed as the window would be.
background_app_window() {
  local package="$1"
  local adb_serial="$2"
  local pid_file
  local pid
  local port=""
  local display=""
  local boot_id=""
  local label

  pid_file="$(app_supervisor_file "${package}" pid)"
  pid="$(supervisor_pid_from_file "${pid_file}" __app_supervisor)" || return 0
  label="${package}"
  if [[ -s "${IKA_APPS_DIR}/${package}/title" ]]; then
    label="$(<"${IKA_APPS_DIR}/${package}/title")"
  fi
  port="$(tr '\0' '\n' <"/proc/${pid}/cmdline" 2>/dev/null \
    | sed -n 's/^--cuttlefish-display=\([1-9][0-9]*\)$/\1/p' | head -n 1)"
  display="$(guest_app_task_displays "${package}" "${adb_serial}" | head -n 1)"
  boot_id="$(adb_guest_boot_id "${adb_serial}" || true)"
  if [[ -z "${port}" || -z "${display}" || -z "${boot_id}" ]]; then
    log "could not keep ${label} in the background; closing its window"
    stop_supervisor_from_file "${pid_file}" __app_supervisor
    return 0
  fi

  : > "$(app_keep_display_file "${package}")"
  stop_supervisor_from_file "${pid_file}" __app_supervisor
  rm -f "$(app_keep_display_file "${package}")"
  # A window whose supervisor does not know the mark (one opened before an
  # update) removes its display, and the game with it.
  if ! guest_app_task_displays "${package}" "${adb_serial}" | grep -qxF "${display}"; then
    log "${label} did not stay on its display; it was closed"
    return 0
  fi
  if guest_adb "${adb_serial}" shell cmd display power-off "${display}" </dev/null >/dev/null 2>&1; then
    printf '%s %s %s\n' "${boot_id}" "${port}" "${display}" > "$(app_background_file "${package}")"
    log "sent ${label} to the background (Cuttlefish display ${port}, Android display ${display}, off)"
  else
    log "could not turn off the display of ${label}; closing it"
    remove_cuttlefish_display "${port}" || true
  fi
}

# Before PACKAGE opens: when it is a game, sends the other games with open
# windows to the background.
background_other_games() {
  local package="$1"
  local adb_serial="$2"
  local title
  local other
  local -a games=()

  background_games_enabled || return 0
  while IFS=$'\t' read -r title other; do
    [[ -n "${other}" && "${other}" != "${package}" ]] || continue
    if is_game_app "${other}"; then
      games+=("${other}")
    fi
  done < <(list_open_app_windows)
  (( ${#games[@]} > 0 )) || return 0
  is_game_app "${package}" "${adb_serial}" || return 0
  for other in "${games[@]}"; do
    background_app_window "${other}" "${adb_serial}"
  done
}

# Brings PACKAGE back from the background: turns its display back on and sets
# the variable named by $3 to the display's number, for a new window to show
# it. Fails, dropping the record, when the game is no longer there (Android
# restarted, or ended the game): the app then opens as usual.
resume_background_app() {
  local package="$1"
  local adb_serial="$2"
  local -n _resume_port="$3"
  local file
  local boot_id=""
  local port=""
  local display=""
  local current_boot_id

  file="$(app_background_file "${package}")"
  [[ -f "${file}" ]] || return 1
  read -r boot_id port display <"${file}" || true
  rm -f "${file}"
  [[ "${port}" =~ ^[1-9][0-9]*$ && "${display}" =~ ^[1-9][0-9]*$ ]] || return 1
  current_boot_id="$(adb_guest_boot_id "${adb_serial}" || true)"
  [[ -n "${current_boot_id}" && "${current_boot_id}" == "${boot_id}" ]] || return 1
  if ! guest_app_task_displays "${package}" "${adb_serial}" | grep -qxF "${display}"; then
    if ! cuttlefish_display_in_use "${port}" "${package}"; then
      remove_cuttlefish_display "${port}" || true
    fi
    return 1
  fi
  guest_adb "${adb_serial}" shell cmd display power-reset "${display}" </dev/null >/dev/null 2>&1 || true
  _resume_port="${port}"
}

close_app_window() {
  local name="$1"
  local open_windows
  local resolved
  local package

  open_windows="$(list_open_app_windows; list_background_apps)"
  if [[ -z "${open_windows}" ]]; then
    respond "No app windows are open"
    return 0
  fi
  resolved="$(resolve_app_name "${name}" "${open_windows}" "open app window")" || exit 1
  package="${resolved#*$'\t'}"
  validate_app_package "${package}"

  if app_window_is_open "${package}"; then
    stop_supervisor_from_file "$(app_supervisor_file "${package}" pid)" __app_supervisor
  fi
  discard_background_app "${package}"
  respond "Closed ${resolved%%$'\t'*}"
}

# Whether Shift is held down as Ika or an app is launched from a menu, a dock or
# a task bar, which opens its Startup Options instead. On Linux the keyboards
# answer, through ika-shift-held, at once: start_shift_probe asks then, while
# Shift is still held. On WSLg, whose distributions have no keyboard devices,
# Windows answers: PowerShell takes about 0.3 s, so start_shift_probe asks in
# the background, the work until the answer is needed runs meanwhile, and
# shift_held reads it then. shift_held asks on the spot when no probe ran. The
# answer is kept: Shift at the launch is what counts.
SHIFT_PROBE_STARTED=""
SHIFT_PROBE_FD=""
SHIFT_HELD=""

windows_shift_probe_command() {
  with_timeout 5 powershell.exe -NoProfile -NonInteractive -Command \
    'Add-Type -AssemblyName System.Windows.Forms; [int][System.Windows.Forms.Control]::ModifierKeys' \
    2>/dev/null | tr -d '\r'
}

start_shift_probe() {
  SHIFT_PROBE_STARTED="true"
  if [[ "${IKA_ON_WSLG}" != true ]]; then
    shift_held || true
    return 0
  fi
  command -v powershell.exe >/dev/null 2>&1 || return 0
  exec {SHIFT_PROBE_FD}< <(windows_shift_probe_command)
}

shift_held() {
  local keys=""

  if [[ -n "${SHIFT_HELD}" ]]; then
    [[ "${SHIFT_HELD}" == true ]]
    return
  fi
  SHIFT_HELD="false"
  if [[ "${IKA_ON_WSLG}" != true ]]; then
    if [[ -x "${PACKAGED_SHIFT_HELD_BIN}" ]] && "${PACKAGED_SHIFT_HELD_BIN}"; then
      SHIFT_HELD="true"
    fi
  else
    if [[ -n "${SHIFT_PROBE_FD}" ]]; then
      read -r keys <&"${SHIFT_PROBE_FD}" || true
      exec {SHIFT_PROBE_FD}<&-
      SHIFT_PROBE_FD=""
    elif command -v powershell.exe >/dev/null 2>&1; then
      keys="$(windows_shift_probe_command)"
    fi
    # Keys.Shift
    if [[ "${keys}" =~ ^[0-9]+$ ]] && (( keys & 0x10000 )); then
      SHIFT_HELD="true"
    fi
  fi
  [[ "${SHIFT_HELD}" == true ]]
}

run_app_command() {
  local name=""
  local launcher="false"
  local info_mode="false"
  local options_mode="false"
  local controller_mode="false"
  local fullscreen_mode="false"
  local title=""
  local window_size=""
  local dpi_given=""

  # Without a terminal (a menu launcher), report errors as notifications.
  if [[ ! -t 0 && ! -t 2 ]]; then
    IKA_NOTIFY="true"
    launcher="true"
  fi

  case "${1:-}" in
    "")
      list_launchable_apps
      return 0
      ;;
    sync)
      shift
      case "${1:-}" in
        "")
          rm -f "${APP_MENU_DISABLED_FILE}"
          sync_app_menu
          start_app_menu_watcher
          ;;
        --remove)
          : > "${APP_MENU_DISABLED_FILE}"
          stop_app_menu_watcher
          remove_app_menu
          ;;
        *)
          die "usage: ${SCRIPT_NAME} app sync [--remove]"
          ;;
      esac
      return 0
      ;;
    close)
      shift
      [[ $# -gt 0 ]] || die "usage: ${SCRIPT_NAME} app close NAME|PACKAGE|--all"
      if [[ "$1" == "--all" ]]; then
        stop_app_supervisors
        respond "Closed all app windows"
      else
        # Unquoted multi-word labels arrive as separate arguments.
        close_app_window "$*"
      fi
      return 0
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--fullscreen)
        fullscreen_mode="true"
        shift
        ;;
      --touch)
        # Read by the console client, which the app window started below
        # inherits it from.
        export IKA_TOUCH=1
        shift
        ;;
      --info)
        info_mode="true"
        shift
        ;;
      --options)
        options_mode="true"
        shift
        ;;
      --controller)
        controller_mode="true"
        shift
        ;;
      --title=*)
        title="${1#*=}"
        shift
        ;;
      --title)
        shift
        [[ $# -gt 0 ]] || die "--title requires a value"
        title="$1"
        shift
        ;;
      --size=*)
        window_size="${1#*=}"
        shift
        ;;
      --size)
        shift
        [[ $# -gt 0 ]] || die "--size requires a value"
        window_size="$1"
        shift
        ;;
      --dpi=*|--dpi)
        if [[ "$1" == --dpi ]]; then
          shift
          [[ $# -gt 0 ]] || die "--dpi requires a value"
          dpi_given="$1"
        else
          dpi_given="${1#*=}"
        fi
        shift
        # auto, or 0, leaves the window at the console's density, whatever
        # the app's start options say.
        dpi_given="$(app_dpi_value "${dpi_given}")" \
          || die "--dpi must be auto, 0, or 96 to 999"
        dpi_given="${dpi_given:-auto}"
        ;;
      --ika_scrcpy=*)
        IKA_SCRCPY="${1#*=}"
        shift
        ;;
      --ika_scrcpy)
        shift
        [[ $# -gt 0 ]] || die "--ika_scrcpy requires a value"
        IKA_SCRCPY="$1"
        shift
        ;;
      -*)
        die "unknown app option: $1"
        ;;
      *)
        # Unquoted multi-word labels arrive as separate arguments.
        name="${name:+${name} }$1"
        shift
        ;;
    esac
  done

  [[ -n "${name}" ]] || die "usage: ${SCRIPT_NAME} app NAME|PACKAGE [options]"
  if [[ "${info_mode}" == "true" ]]; then
    open_app_info "${name}"
    return 0
  fi
  if [[ "${options_mode}" == "true" ]]; then
    edit_app_settings "${name}" 1
    return 0
  fi
  if [[ "${controller_mode}" == "true" ]]; then
    edit_app_settings "${name}" 2
    return 0
  fi
  # An app launched from a menu, a dock or a task bar with Shift held down
  # opens its Startup Options instead, as the launcher's "Startup options"
  # action does (Windows' Start menu and task bar offer no such actions). main
  # asked as the launch began; open_app_window reads the answer.
  if [[ "${launcher}" == "true" && -n "${SHIFT_PROBE_STARTED}" ]]; then
    APP_SHIFT_CHECK="true"
  fi
  open_app_window "${name}" "${fullscreen_mode}" "${title}" "${window_size}" "" "${dpi_given}"
}

