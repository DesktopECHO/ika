# ika: logging, notifications, prompts, option values, the data partition's size.
# Sourced by src/tools/ika, in its order; see there.

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$*" >&2
}

log_file_only() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$*" >>"${START_LOG_FILE}"
}

# Lines for the start log that come before start has redirected its output to
# it, as the camera's do in parse_start_options: kept in START_LOG_NOTES, and
# written by flush_start_log_notes once the log is open, after its header for
# the run. restart gives the ones it has to the start it runs, in
# IKA_START_LOG_NOTES. Not for a subshell: its notes are gone with it.
START_LOG_NOTES=()
log_start_note() {
  START_LOG_NOTES+=("$*")
}

flush_start_log_notes() {
  local note

  while IFS= read -r note; do
    [[ -z "${note}" ]] || log "${note}"
  done <<<"${IKA_START_LOG_NOTES:-}"
  unset IKA_START_LOG_NOTES
  for note in "${START_LOG_NOTES[@]}"; do
    log "${note}"
  done
  START_LOG_NOTES=()
}

die() {
  die_with_notification "$*" "$*"
}

# Like die, with a separate (shorter) message for the desktop notification.
die_with_notification() {
  local notification="$1"
  shift

  log "error: $*"
  if [[ -n "${CONSOLE_FAILURE_MESSAGE:-}" ]]; then
    printf '%s\n' "${CONSOLE_FAILURE_MESSAGE}" >&3
  fi
  close_progress_notifications
  notify_user "${notification}"
  exit 1
}

# Whether a notification server runs now, asked without starting one. The
# session bus starts one for the first notification where it can, but GNOME's
# and Plasma's, which it lists, only come up with their desktops: in a session
# without one, such as Ika's own, each notify-send waited about a minute for
# them. Without gdbus to ask, as if one ran.
notification_server_running() {
  command -v gdbus >/dev/null 2>&1 || return 0
  [[ "$(timeout 2 gdbus call --session --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.NameHasOwner org.freedesktop.Notifications \
      2>/dev/null)" == "(true,)" ]]
}

# Shows a desktop notification when ika runs without a terminal, for example
# from a menu launcher (see run_app_command), where messages would be lost.
# With no notification server running, it is sent in the background, for one
# the session bus may start on demand, so that ika never waits for it.
notify_user() {
  [[ "${IKA_NOTIFY:-}" == "true" ]] || return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  if notification_server_running; then
    notify-send --app-name=Ika --icon=ika-scrcpy "Ika" "$1" >/dev/null 2>&1 || true
    return 0
  fi
  (
    close_inherited_fds
    exec timeout 60 notify-send --app-name=Ika --icon=ika-scrcpy "Ika" "$1"
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

IKA_PROGRESS_NOTIFICATIONS=()

# Like notify_user, for a message that close_progress_notifications withdraws
# once the work is done. Plasma holds back popups while a fullscreen window has
# focus and shows them when it leaves fullscreen, so a "Starting…" message left
# open would reappear when a fullscreen window leaves fullscreen.
notify_progress() {
  local id

  [[ "${IKA_NOTIFY:-}" == "true" ]] || return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  # Only to a running server: the message is withdrawn once the work is done,
  # and one started on demand would show it after that
  notification_server_running || return 0
  id="$(notify-send --print-id --app-name=Ika --icon=ika-scrcpy "Ika" "$1" 2>/dev/null)" || id=""
  if [[ "${id}" =~ ^[0-9]+$ ]]; then
    IKA_PROGRESS_NOTIFICATIONS+=("${id}")
  elif [[ -z "${id}" ]]; then
    # notify-send before libnotify 0.7.9 has no --print-id.
    notify-send --app-name=Ika --icon=ika-scrcpy "Ika" "$1" >/dev/null 2>&1 || true
  fi
}

close_progress_notifications() {
  local id

  command -v gdbus >/dev/null 2>&1 || return 0
  for id in "${IKA_PROGRESS_NOTIFICATIONS[@]}"; do
    gdbus call --session --dest org.freedesktop.Notifications \
      --object-path /org/freedesktop/Notifications \
      --method org.freedesktop.Notifications.CloseNotification "${id}" >/dev/null 2>&1 || true
  done
  IKA_PROGRESS_NOTIFICATIONS=()
}

ensure_open_file_limit() {
  local min_open_files="${IKA_MIN_OPEN_FILES:-65536}"
  local soft_limit
  local hard_limit

  if [[ ! "${min_open_files}" =~ ^[1-9][0-9]*$ ]]; then
    log "invalid IKA_MIN_OPEN_FILES='${min_open_files}'; using 65536"
    min_open_files="65536"
  fi

  soft_limit="$(ulimit -Sn 2>/dev/null || true)"
  hard_limit="$(ulimit -Hn 2>/dev/null || true)"
  [[ -n "${soft_limit}" && -n "${hard_limit}" ]] || return 0
  [[ "${soft_limit}" == "unlimited" ]] && return 0

  if [[ "${soft_limit}" =~ ^[0-9]+$ ]] && (( soft_limit >= min_open_files )); then
    return 0
  fi

  if [[ "${hard_limit}" != "unlimited" ]]; then
    if [[ ! "${hard_limit}" =~ ^[0-9]+$ ]]; then
      log "could not parse open-file hard limit '${hard_limit}'"
      return 0
    fi
    if (( hard_limit < min_open_files )); then
      log "open-file soft limit is ${soft_limit}, but hard limit ${hard_limit} prevents raising it to ${min_open_files}"
      return 0
    fi
  fi

  if ulimit -Sn "${min_open_files}" 2>/dev/null; then
    log "raised open-file soft limit: ${soft_limit} -> $(ulimit -Sn)"
  else
    log "could not raise open-file soft limit from ${soft_limit} to ${min_open_files}"
  fi
}

normalize_hw_video_decode_mode() {
  case "${1,,}" in
    ""|auto|1|true|yes|on|enable|enabled)
      echo "auto"
      ;;
    0|false|no|off|disable|disabled)
      echo "off"
      ;;
    *)
      die "invalid hardware video decoding mode '${1}' (expected auto or off)"
      ;;
  esac
}

normalize_lowcpu_mode() {
  case "${1,,}" in
    ""|auto)
      echo "auto"
      ;;
    1|true|yes|on|enable|enabled)
      echo "on"
      ;;
    0|false|no|off|disable|disabled)
      echo "off"
      ;;
    *)
      die "invalid low-CPU mode '${1}' (expected auto, on, or off)"
      ;;
  esac
}

normalize_gfxstream_vulkan_mode() {
  local mode="${1,,}"

  case "${mode}" in
    ""|auto)
      echo "auto"
      ;;
    1|true|yes|on|enable|enabled)
      echo "on"
      ;;
    0|false|no|off|disable|disabled)
      echo "off"
      ;;
    *)
      die "invalid gfxstream Vulkan mode '${1}' (expected auto, on, or off)"
      ;;
  esac
}

respond() {
  printf '%s\n' "$*"
}

respond_console() {
  printf '%s\n' "$*" >&3
}

# Prints WARNING and returns success only when the user types Y; otherwise
# prints ABORTED.
confirm() {
  local warning="$1"
  local aborted="$2"
  local reply=""

  printf 'WARNING: %s, type "Y" to continue. ' "${warning}" >&3
  IFS= read -r -n 1 reply || true
  printf '\n' >&3
  if [[ "${reply}" != "Y" && "${reply}" != "y" ]]; then
    respond_console "${aborted}"
    return 1
  fi
}

normalize_data_gb() {
  local data_gb="$1"

  if [[ ! "${data_gb}" =~ ^[1-9][0-9]*$ ]]; then
    die "--data_gb must be a positive whole number of gigabytes"
  fi

  printf '%s\n' "${data_gb}"
}

data_gb_to_mib() {
  local data_gb="$1"
  printf '%s\n' "$((data_gb * 1000000000 / 1048576))"
}

parse_reset_options() {
  local -n data_gb_ref="$1"
  local -n reset_args_ref="$2"
  shift 2

  data_gb_ref=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --data_gb=*)
        data_gb_ref="$(normalize_data_gb "${1#*=}")"
        shift
        ;;
      --data_gb)
        shift
        [[ $# -gt 0 ]] || die "--data_gb requires a value"
        data_gb_ref="$(normalize_data_gb "$1")"
        shift
        ;;
      *)
        reset_args_ref+=("$1")
        shift
        ;;
    esac
  done
}

save_data_gb_configuration() {
  local data_gb="$1"

  [[ -n "${data_gb}" ]] || return 0
  mkdir -p "${CVD_HOME_DIR}"
  printf '%s\n' "${data_gb}" > "${DATA_GB_CONFIG_FILE}"
  log "userdata size configured: ${data_gb} GB (applies on next start)"
}

