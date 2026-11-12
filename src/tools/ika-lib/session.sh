# ika: the login session that runs only Ika (ika session).
# Sourced by src/tools/ika, in its order; see there.

# The login session that runs only Ika ("Android" on the login screen, from
# /usr/share/wayland-sessions/ika.desktop): Cage, a compositor that shows one
# window full screen and nothing else, runs `ika session` again inside it,
# which starts Android with its console full screen and returns once the
# console is gone, ending Cage and the session. Every key reaches the console,
# as no desktop takes any first. Cage's -s keeps Ctrl+Alt+F1 to F12 switching
# virtual terminals, a way out to another session or a text login.
run_session_command() {
  (( $# == 0 )) || die "usage: ${SCRIPT_NAME} session"
  host_is_wsl2 && die "ika session is a login session of its own; WSL has no login screen, so start Ika as usual"
  if [[ "${IKA_SESSION_IN_CAGE:-}" == "true" ]]; then
    run_session_in_cage
    return
  fi
  command -v "${IKA_SESSION_CAGE:-cage}" >/dev/null 2>&1 \
    || die "ika session needs Cage: install the cage package"
  export IKA_SESSION_IN_CAGE="true"
  exec "${IKA_SESSION_CAGE:-cage}" -s -- "${IKA_SCRIPT_PATH}" session
}

# The session's lines, and the output of the start and stop it runs, which no
# terminal shows.
SESSION_LOG_FILE="${CVD_HOME_DIR}/session.log"

session_log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"${SESSION_LOG_FILE}"
}

# Inside Cage: starts Ika full screen, waits for its console to close (MOD+Q,
# or Android turned off), then stops Android if this session started it. An
# Android already running, from a desktop session of the same user, is left
# running, with its console moved here.
run_session_in_cage() {
  local was_running="false"
  local supervisor=""
  local deadline
  local status=0
  local reason

  mkdir -p "${CVD_HOME_DIR}"
  : >"${SESSION_LOG_FILE}"
  session_log "session started on ${WAYLAND_DISPLAY:-no Wayland display}"
  hold_power_keys_from_logind
  if has_live_cvd_processes; then
    was_running="true"
  fi

  run_without_inherited_fds "${IKA_SCRIPT_PATH}" start --fullscreen \
    </dev/null >>"${SESSION_LOG_FILE}" 2>&1 || status=$?
  if (( status == 0 )); then
    # The console may open a moment after start returns, once Android shows
    # its first frame.
    deadline=$((SECONDS + ${IKA_SESSION_CONSOLE_WAIT_SEC:-60}))
    while (( SECONDS < deadline )) && has_live_cvd_processes; do
      supervisor="$(scrcpy_supervisor_pid || true)"
      [[ -z "${supervisor}" ]] || break
      sleep 0.5
    done
  fi
  if [[ -z "${supervisor}" ]]; then
    reason="$(start_log_last_error)"
    [[ -n "${reason}" ]] || reason="The console did not open."
    session_log "no console: ${reason}"
    show_session_failure "${reason}"
  else
    session_log "console supervisor ${supervisor}"
    while kill -0 "${supervisor}" 2>/dev/null; do
      sleep 1
    done
    session_log "console closed"
  fi

  if [[ "${was_running}" != "true" ]] && has_live_cvd_processes; then
    run_without_inherited_fds "${IKA_SCRIPT_PATH}" stop \
      </dev/null >>"${SESSION_LOG_FILE}" 2>&1 || true
    session_log "Android stopped"
  fi
  release_power_keys
  session_log "session ended"
}

# Runs a command with only standard input, output and error open. Cage ends
# its session once every holder of a pipe it gives its program has closed it,
# and ika start leaves helpers running past the console (madbfs for Android's
# files, adb's server): holding Cage's pipe, they kept the screen black after
# the console closed, instead of ending the session.
run_without_inherited_fds() {
  (
    close_inherited_fds
    exec "$@"
  )
}

# Closes this shell's descriptors past standard error (run_without_inherited_fds).
close_inherited_fds() {
  local fd

  for fd in /proc/"${BASHPID}"/fd/*; do
    fd="${fd##*/}"
    [[ "${fd}" =~ ^[0-9]+$ ]] && (( fd > 2 )) || continue
    eval "exec ${fd}>&-" 2>/dev/null || true
  done
}

# Holds the power, suspend and hibernate keys back from logind for as long as
# this session runs, so that they reach Android, which turns its screen off
# and on with them, instead of turning the computer off or suspending it:
# Cage, unlike a desktop, handles none of them. Taken from inside Cage, where
# the session is already the active one, as polkit requires of an inhibitor.
hold_power_keys_from_logind() {
  local inhibit="${IKA_SESSION_INHIBIT:-systemd-inhibit}"

  if ! command -v "${inhibit}" >/dev/null 2>&1; then
    session_log "no ${inhibit}: the power and sleep keys act on the computer"
    return 0
  fi
  # The background job closes the descriptors and becomes the inhibitor
  # itself: a shell left waiting on it would hold Cage's pipe. The session
  # ends it (release_power_keys); tail is the backstop should the session die
  # first.
  (
    close_inherited_fds
    exec "${inhibit}" \
      --what=handle-power-key:handle-suspend-key:handle-hibernate-key \
      --who=Ika --why="Android takes the power and sleep keys" --mode=block \
      tail --pid="$$" -f /dev/null
  ) </dev/null >>"${SESSION_LOG_FILE}" 2>&1 &
  SESSION_INHIBITOR_PID="$!"
  session_log "power and sleep keys held back from logind (pid ${SESSION_INHIBITOR_PID})"
}

# Gives the power and sleep keys back to logind.
release_power_keys() {
  [[ -n "${SESSION_INHIBITOR_PID:-}" ]] || return 0
  kill "${SESSION_INHIBITOR_PID}" 2>/dev/null || true
  SESSION_INHIBITOR_PID=""
}

# The last error of the latest start in the start log, which ika start writes
# its output to (redirect_start_logs); nothing if it gave none.
start_log_last_error() {
  awk -v run="${START_LOG_RUN_PREFIX}" '
    index($0, run) == 1 { error = "" }
    /^\[[^]]*\] error: / { error = $0; sub(/^\[[^]]*\] error: /, "", error) }
    END { print error }
  ' "${START_LOG_FILE}" 2>/dev/null || true
}

# Shows why the session could not start, in a window of its own, so that the
# session does not end straight back at the login screen without a word.
show_session_failure() {
  local reason="$1"
  local text
  local -a window_env=()

  ika_window_available || return 0
  set_window_env window_env
  text="<span font_size='13pt' weight='bold'>Ika could not start</span>"
  text+=$'\n\n'"$(markup_escape "${reason}")"
  text+=$'\n\n'"$(markup_escape "Details: ${START_LOG_FILE}, ${SESSION_LOG_FILE}")"
  ika_window window_env --title="" --undecorated --icon="${IKA_MENU_ICON}" \
    --button="Log out:0" --tab=Failure --border=12 --text="${text}" || true
}

