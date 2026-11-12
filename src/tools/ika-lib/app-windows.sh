# ika: opening, supervising and listing app windows.
# Sourced by src/tools/ika, in its order; see there.

open_app_window() {
  local name="$1"
  local fullscreen_mode="$2"
  local title="$3"
  local window_size="$4"
  local start_app="${5:-}"
  local dpi_given="${6:-}"
  local app_dpi=""
  local package=""
  local label=""
  local resolved
  local adb_serial
  local guest_dpi
  local dpi
  local display_size
  local cuttlefish_display
  local app_icon
  local saved_width=""
  local saved_height=""
  local saved_fullscreen=""
  local window_size_is_default="false"
  local resumed_display=""
  local attempt
  local -a start_app_args=()
  local -a scrcpy_env=()
  local -a scrcpy_cmd=()
  local -a guest_queries=()

  release_app_settings_lock

  require_executable "${SCRCPY_BIN}" "console client"
  # Shift held at a menu launch opens the app's Startup Options instead
  # (APP_SHIFT_CHECK): answered now when Ika would first have to start, else
  # below, once the guest queries have run alongside the probe. The check is
  # used up there: "Apply and start" opens the app in this same process, where
  # Shift's kept answer would otherwise bring the window back.
  if [[ "${APP_SHIFT_CHECK:-}" == "true" ]] && ! has_live_cvd_processes \
      && shift_held; then
    APP_SHIFT_CHECK=""
    edit_app_settings "${name}" 1
    return 0
  fi
  # The guest answers the queries below along with the boot check, in the one
  # adb round trip, instead of one of a tenth of a second each.
  if is_app_package_name "${name}"; then
    guest_queries+=("$(guest_query_package_path "${name}")")
  fi
  guest_queries+=("${GUEST_QUERY_LEANBACK}" "${GUEST_QUERY_DENSITY}")
  # wayland-info, read once here for the host display probes below, which run
  # in subshells that could not share it.
  wayland_info_output >/dev/null 2>&1 || true
  ensure_guest_ready "${guest_queries[@]}"
  adb_serial="$(resolve_adb_serial)"

  # A package name is used as given (menu launchers pass one); anything else is
  # looked up by label.
  if is_app_package_name "${name}" \
      && app_is_installed "${name}" "${adb_serial}"; then
    package="${name}"
    label="$(app_display_name "${package}")"
    [[ "${label}" != "${package}" ]] || label=""
  else
    resolved="$(resolve_launchable_app "${name}" "${adb_serial}")" || exit 1
    package="${resolved#*$'\t'}"
    label="${resolved%%$'\t'*}"
  fi
  if [[ -z "${title}" ]]; then
    title="${label}"
  fi
  validate_app_package "${package}"
  if [[ "${APP_SHIFT_CHECK:-}" == "true" ]] && shift_held; then
    APP_SHIFT_CHECK=""
    edit_app_settings "${name}" 1
    return 0
  fi
  apply_saved_app_options "${package}" fullscreen_mode
  scrcpy_env=("IKA_APP_PACKAGE=${package}")

  use_app_window_paths "${package}"
  (umask 077 && mkdir -p "${IKA_APPS_DIR}/${package}")
  # Cache the label so the window can later be matched by name.
  if [[ -n "${label}" ]]; then
    printf '%s\n' "${label}" > "${IKA_APPS_DIR}/${package}/title"
  fi

  if supervisor_pid_from_file "${SCRCPY_SUPERVISOR_PID_FILE}" __app_supervisor >/dev/null; then
    respond "${label:-${package}} is already open in its own window"
    return 0
  fi

  background_other_games "${package}" "${adb_serial}"
  if app_is_in_background "${package}"; then
    resume_background_app "${package}" "${adb_serial}" resumed_display || resumed_display=""
  fi

  if [[ -z "${title}" ]]; then
    title="$(app_window_title "${package}" "${adb_serial}")"
  fi

  if [[ -z "${window_size}" ]]; then
    if read_scrcpy_window_state "${SCRCPY_WINDOW_STATE_FILE}" \
        saved_width saved_height saved_fullscreen; then
      window_size="${saved_width}x${saved_height}"
      # The window comes back as it closed: at its size, and fullscreen when it
      # was. That size is the windowed one, which leaving fullscreen returns to.
      # A size given with --size asks for a window, so it skips this.
      if [[ "${saved_fullscreen}" == "true" ]]; then
        fullscreen_mode="true"
        log "${package} was fullscreen when its window closed; opening it fullscreen"
      fi
    else
      window_size="$(default_app_window_size)"
      window_size_is_default="true"
    fi
  fi
  [[ "${window_size}" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] \
    || die "--size must be WIDTHxHEIGHT (example: 1600x900)"
  window_size="$(clamp_app_window_size "${window_size}")"

  # App windows are desktop windows: at the console's density on the desktop,
  # and in TV mode, where the console runs at the TV density, at the desktop's.
  if [[ "$(guest_ui_mode "${adb_serial}")" == "tv" ]]; then
    dpi="$(resolve_scrcpy_dpi "")"
  else
    guest_dpi="$(guest_display_density "${adb_serial}")"
    [[ "${guest_dpi}" =~ ^[1-9][0-9]*$ ]] || die "could not read the guest display density"
    dpi="${guest_dpi}"
  fi
  # A density of the app's own goes over that: given to 'ika app' (--dpi=auto
  # keeps the one above), else saved in its start options.
  if [[ -n "${dpi_given}" ]]; then
    [[ "${dpi_given}" == "auto" ]] || dpi="${dpi_given}"
  else
    app_dpi="$(saved_app_dpi "${package}")"
    [[ -z "${app_dpi}" ]] || dpi="${app_dpi}"
  fi
  if [[ "${window_size_is_default}" == "true" && "${package}" == "${IKA_MODE_PACKAGE}" ]]; then
    window_size="$(mode_app_window_size "${dpi}")" || window_size="$(default_app_window_size)"
  fi
  display_size="$(app_window_display_size "${window_size}")" \
    || die "could not size the app window display for ${window_size}"

  # The app gets a Cuttlefish display of its own, as large as the host screen;
  # --dpi enables flex resizing: the app is drawn at the window size inside it,
  # as the console is. "+" force-stops the app first so it starts on that
  # display instead of resurfacing an existing task on the desktop. The
  # supervisor removes the display when the window closes. START_APP replaces
  # the app's own start (Settings' "+info:PACKAGE" opens an App info page).
  # A game back from the background keeps its display, where it still runs,
  # and is not started again.
  if [[ -n "${resumed_display}" ]]; then
    cuttlefish_display="${resumed_display}"
  else
    cuttlefish_display="$(add_cuttlefish_display \
      "$(app_cuttlefish_display_size "${display_size}")" "${dpi}")" \
      || die "could not add a Cuttlefish display for ${label:-${package}}"
  fi
  if [[ -z "${resumed_display}" || -n "${start_app}" ]]; then
    start_app_args=(--start-app="${start_app:-+${package}}")
  fi
  scrcpy_cmd=(
    "${SCRCPY_BIN}"
    -s "${adb_serial}"
    --cuttlefish-frames-socket="$(resolve_cuttlefish_frames_socket)"
    --cuttlefish-display="${cuttlefish_display}"
    --dpi="${dpi}"
    "${start_app_args[@]}"
    --window-title="${title}"
    --window-state-file="${SCRCPY_WINDOW_STATE_FILE}"
    --window-width="${window_size%x*}"
    --window-height="${window_size#*x}"
    --mouse-bind=++++:b+++
    --force-adb-forward
    --render-driver=opengl
    --no-audio
  )
  append_scrcpy_input_args scrcpy_cmd app "app window" "${package}"
  append_scrcpy_extra_args scrcpy_cmd "app window"

  # A distinct app ID lets the host desktop treat each app as its own window
  # group instead of stacking it under the Ika console.
  append_scrcpy_env scrcpy_env
  scrcpy_env+=("SDL_APP_ID=$(app_window_id "${package}")")
  # Without the app's own icon, the window would set the generic Ika icon,
  # which taskbars prefer over the launcher's.
  app_icon="$(app_menu_icon "${package}")"
  if [[ -f "${app_icon}" ]]; then
    scrcpy_env+=("IKA_WINDOW_ICON=${app_icon}")
  fi
  # The title bar starts in the color the app's content gave it last time.
  scrcpy_env+=("IKA_TITLEBAR_COLOR_FILE=${IKA_APPS_DIR}/${package}/titlebar-color")
  scrcpy_cmd=(env "${scrcpy_env[@]}" "${scrcpy_cmd[@]}")

  : > "${SCRCPY_LOG_FILE}"
  log "opening ${package} (${window_size}/${dpi}) on Cuttlefish display ${cuttlefish_display}${resumed_display:+, back from the background,} as \"${title}\""
  setsid --fork "${IKA_SCRIPT_PATH}" __app_supervisor "${package}" \
    "${adb_serial}" "${fullscreen_mode}" -- "${scrcpy_cmd[@]}" \
    </dev/null >>"${SCRCPY_LOG_FILE}" 2>&1 3>&- &
  disown || true

  # Return as soon as the supervisor has registered, instead of a fixed wait.
  for attempt in {1..30}; do
    if supervisor_pid_from_file "${SCRCPY_SUPERVISOR_PID_FILE}" __app_supervisor >/dev/null; then
      respond "Opened ${title} in its own window"
      return 0
    fi
    sleep 0.05
  done

  remove_cuttlefish_display "${cuttlefish_display}" || true
  die "could not open a window for ${label:-${title}}; see ${SCRCPY_LOG_FILE}"
}

# Opens Android's App info page for NAME in the Settings app window: a new
# window starts with the page, an open one gets it on its display.
open_app_info() {
  local name="$1"
  local settings="com.android.settings"
  local adb_serial
  local resolved
  local package
  local label
  local log_file
  local display_id
  local output

  require_executable "${SCRCPY_BIN}" "console client"
  ensure_guest_ready
  adb_serial="$(resolve_adb_serial)"

  if is_app_package_name "${name}" \
      && app_is_installed "${name}" "${adb_serial}"; then
    package="${name}"
    label="$(app_display_name "${package}")"
  else
    resolved="$(resolve_launchable_app "${name}" "${adb_serial}")" || exit 1
    package="${resolved#*$'\t'}"
    label="${resolved%%$'\t'*}"
  fi
  validate_app_package "${package}"

  # The scrcpy server opens the page as the window's first page, so the
  # Settings home page never shows.
  if ! app_window_is_open "${settings}"; then
    ( open_app_window "${settings}" false "" "" "+info:${package}" ) >/dev/null || exit 1
    respond "Opened App info for ${label}"
    return 0
  fi

  log_file="${IKA_APPS_DIR}/${settings}/window.log"
  display_id="$(sed -n 's/.*Starting app .* on display \([0-9][0-9]*\)\.\.\..*/\1/p' \
    "${log_file}" 2>/dev/null | tail -n1)"
  [[ -n "${display_id}" ]] || die "could not find the Settings window's display"

  # App info alone in the window, without Settings' list beside it, as the
  # server opens it: it replaces the window's Settings pages
  # (FLAG_ACTIVITY_NEW_TASK and FLAG_ACTIVITY_CLEAR_TASK), and opens as a
  # subpage, which Settings does not turn into its two-pane deep link, as it
  # does a task's first page on a large screen.
  output="$(guest_adb "${adb_serial}" shell am start --display "${display_id}" \
    -a android.settings.APPLICATION_DETAILS_SETTINGS -d "package:${package}" \
    --ez :settings:show_fragment_as_subsetting true \
    -f 0x10008000 2>&1 | tr -d '\r' || true)"
  if [[ "${output}" == *Error* || "${output}" == *Exception* ]]; then
    die "could not open App info for ${label}: ${output}"
  fi
  respond "Opened App info for ${label}"
}

run_app_supervisor() {
  local package="$1"
  local arg
  local status=0
  shift

  validate_app_package "${package}"
  use_app_window_paths "${package}"
  APP_WINDOW_SUPERVISOR="true"
  APP_WINDOW_PACKAGE="${package}"
  for arg in "$@"; do
    if [[ "${arg}" =~ ^--cuttlefish-display=([0-9]+)$ ]]; then
      APP_CUTTLEFISH_DISPLAY="${BASH_REMATCH[1]}"
    fi
  done
  run_scrcpy_supervisor "$@" || status="$?"
  remove_app_cuttlefish_display
  return "${status}"
}

# Removes the Cuttlefish display of the app window this supervisor runs, once.
# A game sent to the background keeps it, with the game on it.
remove_app_cuttlefish_display() {
  local keep_file

  if [[ -n "${APP_CUTTLEFISH_DISPLAY:-}" ]]; then
    keep_file="$(app_keep_display_file "${APP_WINDOW_PACKAGE:-}")"
    if [[ -n "${APP_WINDOW_PACKAGE:-}" && -f "${keep_file}" ]]; then
      rm -f "${keep_file}"
    else
      remove_cuttlefish_display "${APP_CUTTLEFISH_DISPLAY}" || true
    fi
    APP_CUTTLEFISH_DISPLAY=""
  fi
}

app_window_is_open() {
  supervisor_pid_from_file "$(app_supervisor_file "$1" pid)" __app_supervisor >/dev/null
}

# Lists launchable apps sorted by label. Apps already open in their own window
# are shown in bold on a terminal, or marked "(open)" when the output is not a
# terminal or NO_COLOR is set; games in the background are marked
# "(background)".
list_launchable_apps() {
  local adb_serial
  local -a labels=()
  local -a packages=()
  local label
  local package
  local width=0
  local max_width=40
  local bold=""
  local plain=""
  local i

  require_executable "${SCRCPY_BIN}" "console client"
  has_live_cvd_processes || die "Android virtual device not running; start it with '${SCRIPT_NAME} start'"
  adb_serial="$(resolve_adb_serial)"
  adb_boot_completed "${adb_serial}" || die "Android virtual device has not finished booting"

  while IFS=$'\t' read -r label package; do
    [[ -n "${label}" && -n "${package}" ]] || continue
    labels+=("${label}")
    packages+=("${package}")
    if (( ${#label} > width )); then
      width="${#label}"
    fi
  done < <(list_guest_apps "${adb_serial}" | sort -f -t $'\t' -k1,1 -k2,2)

  if [[ "${#packages[@]}" -eq 0 ]]; then
    die "could not list apps from the Android virtual device"
  fi
  if (( width > max_width )); then
    width="${max_width}"
  fi

  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    bold=$'\e[1m'
    plain=$'\e[0m'
  fi

  for i in "${!packages[@]}"; do
    label="${labels[i]}"
    package="${packages[i]}"
    if app_window_is_open "${package}"; then
      if [[ -n "${bold}" ]]; then
        printf '%s%-*s  %s%s\n' "${bold}" "${width}" "${label}" "${package}" "${plain}"
      else
        printf '%-*s  %s  (open)\n' "${width}" "${label}" "${package}"
      fi
    elif app_is_in_background "${package}"; then
      printf '%-*s  %s  (background)\n' "${width}" "${label}" "${package}"
    else
      printf '%-*s  %s\n' "${width}" "${label}" "${package}"
    fi
  done
}

