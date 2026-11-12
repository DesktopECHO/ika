# ika: app windows: guest apps, their displays, names and sizes.
# Sourced by src/tools/ika, in its order; see there.

# ============================================================================
# App windows (ika app)
# ============================================================================
#
# Each app window is a separate scrcpy client that shows a Cuttlefish display
# of its own (--cuttlefish-display=N), launches one app on it, and follows host
# window resizes. Like the desktop console, it shows raw Cuttlefish frames.

is_app_package_name() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]]
}

validate_app_package() {
  is_app_package_name "$1" || die "invalid package name '$1'"
}

use_app_window_paths() {
  local app_dir="${IKA_APPS_DIR}/$1"

  SCRCPY_SUPERVISOR_PID_FILE="$(app_supervisor_file "$1" pid)"
  SCRCPY_SUPERVISOR_LOCK_FILE="$(app_supervisor_file "$1" lock)"
  SCRCPY_WINDOW_STATE_FILE="${app_dir}/window-state"
  SCRCPY_LOG_FILE="${app_dir}/window.log"
}

guest_adb() {
  local adb_serial="$1"
  shift
  host_adb "${GUEST_ADB_TIMEOUT:-10}" -s "${adb_serial}" "$@"
}

# Guest shell queries an app window needs, which ensure_guest_ready runs
# along with its boot check when given them, each adb round trip taking a
# tenth of a second on its own. Their answers stay in GUEST_QUERY_CACHE, keyed
# "SERIAL<TAB>QUERY", for guest_shell_query for the rest of the command.
readonly GUEST_QUERY_LEANBACK="cmd package has-feature android.software.leanback"
readonly GUEST_QUERY_DENSITY="wm density"
declare -A GUEST_QUERY_CACHE=()

guest_query_package_path() {
  printf 'pm path %s\n' "$1"
}

# Prints the output of QUERY in the guest's shell, cached or over adb now.
guest_shell_query() {
  local adb_serial="$1"
  local query="$2"
  local key="${adb_serial}"$'\t'"${query}"

  if [[ -n "${GUEST_QUERY_CACHE[${key}]+set}" ]]; then
    printf '%s\n' "${GUEST_QUERY_CACHE[${key}]}"
    return 0
  fi
  guest_adb "${adb_serial}" shell "${query}" 2>/dev/null | tr -d '\r' || true
}

# One adb round trip for the boot check and QUERY...: true once the guest has
# booted, with the queries' answers in GUEST_QUERY_CACHE.
guest_booted_with_queries() {
  local adb_serial="$1"
  shift
  local separator="--ika-query-end--"
  local command="getprop sys.boot_completed"
  local query
  local output
  local line
  local answer=""
  local -a answers=()

  for query in "$@"; do
    command+="; echo ${separator}; ${query}"
  done
  output="$(host_adb 10 -s "${adb_serial}" shell "${command}" 2>/dev/null \
    | tr -d '\r' || true)"
  while IFS= read -r line; do
    if [[ "${line}" == "${separator}" ]]; then
      answers+=("${answer}")
      answer=""
    else
      answer+="${line}"$'\n'
    fi
  done <<<"${output}"
  answers+=("${answer}")
  [[ "${answers[0]}" == 1$'\n' ]] || return 1
  for query in "$@"; do
    answer="${answers[1]-}"
    answers=("${answers[@]:1}")
    while [[ "${answer}" == *$'\n' ]]; do
      answer="${answer%$'\n'}"
    done
    GUEST_QUERY_CACHE["${adb_serial}"$'\t'"${query}"]="${answer}"
  done
}

app_is_installed() {
  local package="$1"
  local adb_serial="$2"
  local package_path

  package_path="$(guest_shell_query "${adb_serial}" "$(guest_query_package_path "${package}")")"
  [[ "${package_path}" == package:* ]]
}

# Host Bluetooth is off by default, so the guest HCI port has no controller
# behind it and com.android.bluetooth aborts on every enable attempt. Clear the
# persisted bluetooth_on setting so later boots don't try, and stop the retry
# loop on this one.
disable_guest_bluetooth() {
  local adb_serial="$1"
  shift
  local bluetooth_on

  if user_supplied_flag "enable_host_bluetooth" "$@" || user_supplied_flag "netsim_bt" "$@"; then
    return 0
  fi

  bluetooth_on="$(guest_adb "${adb_serial}" shell settings get global bluetooth_on 2>/dev/null | tr -d '\r' || true)"
  [[ "${bluetooth_on}" == "0" ]] && return 0

  guest_adb "${adb_serial}" shell settings put global bluetooth_on 0 >/dev/null 2>&1 || true
  guest_adb "${adb_serial}" shell cmd bluetooth_manager disable >/dev/null 2>&1 || true
  log "disabled guest Bluetooth (no host Bluetooth controller)"
}

# On a VM's first boot, start Android in the host's light or dark theme. The
# ika_theme_seeded marker lives in the guest, so later boots leave a theme the
# user picked in Android alone, and a wiped VM is seeded again.
seed_guest_theme() {
  local adb_serial="$1"
  local seeded
  local scheme
  local night

  # Only an explicit "null" means unset; an adb error must not re-seed.
  seeded="$(guest_adb "${adb_serial}" shell settings get global ika_theme_seeded 2>/dev/null | tr -d '\r' || true)"
  [[ "${seeded}" == "null" ]] || return 0

  # LineageOS defaults to dark, and GNOME's light style reports no preference,
  # so anything but dark is applied as light.
  scheme="$(host_color_scheme)"
  if [[ "${scheme}" == "dark" ]]; then
    night=yes
  else
    scheme="light"
    night=no
  fi
  # Through the uimode service, which applies the change at once and saves it
  # to ui_night_mode; writing the setting directly only applies after reboot.
  guest_adb "${adb_serial}" shell cmd uimode night "${night}" >/dev/null 2>&1 || true
  log "set the guest theme to ${scheme} to match the host"
  guest_adb "${adb_serial}" shell settings put global ika_theme_seeded 1 >/dev/null 2>&1 || true
}

# Applies low-CPU mode's guest settings once Android is up: window blurs
# off and animations at half their length. The values they replace are kept
# in the global setting ika_lowcpu_mode, so that a start without the
# profile puts them back.
apply_lowcpu_mode_guest_settings() {
  local adb_serial="$1"
  local saved
  local blurs
  local window
  local transition
  local animator

  saved="$(guest_adb "${adb_serial}" shell settings get global ika_lowcpu_mode 2>/dev/null | tr -d '\r' || true)"
  if [[ "${LOWCPU_MODE_ACTIVE}" == "true" ]]; then
    if [[ "${saved}" == "null" || -z "${saved}" ]]; then
      saved="$(guest_adb "${adb_serial}" shell "echo \$(settings get global disable_window_blurs),\$(settings get global window_animation_scale),\$(settings get global transition_animation_scale),\$(settings get global animator_duration_scale)" 2>/dev/null | tr -d '\r ' || true)"
      [[ "${saved}" =~ ^[^,]*,[^,]*,[^,]*,[^,]*$ ]] || return 0
    fi
    guest_adb "${adb_serial}" shell "settings put global ika_lowcpu_mode '${saved}'; \
      settings put global disable_window_blurs 1; \
      settings put global window_animation_scale 0.5; \
      settings put global transition_animation_scale 0.5; \
      settings put global animator_duration_scale 0.5" >/dev/null 2>&1 || return 0
    log "low-CPU mode: window blurs off, animations at half length"
  elif [[ "${saved}" =~ ^([^,]*),([^,]*),([^,]*),([^,]*)$ ]]; then
    blurs="${BASH_REMATCH[1]}"
    window="${BASH_REMATCH[2]}"
    transition="${BASH_REMATCH[3]}"
    animator="${BASH_REMATCH[4]}"
    guest_adb "${adb_serial}" shell "$(lowcpu_mode_restore_command disable_window_blurs "${blurs}"); \
      $(lowcpu_mode_restore_command window_animation_scale "${window}"); \
      $(lowcpu_mode_restore_command transition_animation_scale "${transition}"); \
      $(lowcpu_mode_restore_command animator_duration_scale "${animator}"); \
      settings delete global ika_lowcpu_mode" >/dev/null 2>&1 || return 0
    log "low-CPU mode off: window blurs and animations restored"
  fi
}

# The shell command that puts the global setting NAME back to VALUE, as
# 'settings get' printed it: "null" means it was unset.
lowcpu_mode_restore_command() {
  if [[ "$2" == "null" || -z "$2" ]]; then
    printf 'settings delete global %s' "$1"
  else
    printf 'settings put global %s %s' "$1" "$(shell_quote "$2")"
  fi
}

# Density of the desktop display, preferring the override that ika applies
# when the console window is resized.
guest_display_density() {
  local adb_serial="$1"
  local output
  local override
  local physical

  output="$(guest_shell_query "${adb_serial}" "${GUEST_QUERY_DENSITY}")"
  override="$(sed -n 's/^Override density: *\([0-9][0-9]*\).*/\1/p' <<<"${output}")"
  physical="$(sed -n 's/^Physical density: *\([0-9][0-9]*\).*/\1/p' <<<"${output}")"
  printf '%s\n' "${override:-${physical}}"
}

# The size of an app window in native host pixels rather than logical window
# points, so that on HiDPI hosts the app draws at native resolution instead of
# being upscaled: the logical window size scaled by the host's native/logical
# ratio, rounded to the nearest pixel as SDL does, then down to an even size.
app_window_display_size() {
  local window_size="$1"
  local native
  local logical
  local native_max
  local logical_max
  local width
  local height

  [[ "${window_size}" =~ ^([0-9]+)x([0-9]+)$ ]] || return 1
  width="${BASH_REMATCH[1]}"
  height="${BASH_REMATCH[2]}"

  native="$(host_display_size || true)"
  logical="$(host_display_logical_size || true)"
  if [[ "${native}" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    native_max=$(( BASH_REMATCH[1] > BASH_REMATCH[2] ? BASH_REMATCH[1] : BASH_REMATCH[2] ))
    if [[ "${logical}" =~ ^([0-9]+)x([0-9]+)$ ]]; then
      logical_max=$(( BASH_REMATCH[1] > BASH_REMATCH[2] ? BASH_REMATCH[1] : BASH_REMATCH[2] ))
      if (( native_max > 0 && logical_max > 0 )); then
        width=$(( (width * native_max + logical_max / 2) / logical_max ))
        height=$(( (height * native_max + logical_max / 2) / logical_max ))
      fi
    fi
  fi

  width=$(( width / 2 * 2 ))
  height=$(( height / 2 * 2 ))
  (( width > 0 && height > 0 )) || return 1
  printf '%sx%s\n' "${width}" "${height}"
}

# App windows show a Cuttlefish display of their own, added to crosvm's GPU
# device while the VM runs, through ika_stream's raw frames (scrcpy
# --cuttlefish-display), as the console shows the main display.

# The control socket of crosvm's GPU device, which adds and removes displays:
# the vhost-user GPU's own socket when the GPU runs in its own process, else the
# VM's control socket. ('cvd display' always sends to the VM's control socket,
# which cannot reach a vhost-user GPU.)
cuttlefish_gpu_control_socket() {
  local dir
  dir="$(dirname "$(resolve_cuttlefish_frames_socket)")"
  if [[ -S "${dir}/vhost-user-gpu-control" ]]; then
    printf '%s/vhost-user-gpu-control\n' "${dir}"
  else
    printf '%s/crosvm_control.sock\n' "${dir}"
  fi
}

# Prints the numbers of the Cuttlefish displays, one per line.
cuttlefish_display_numbers() {
  with_timeout 10 "${CVD_HOST_OUT}/bin/crosvm" gpu list-displays "$1" 2>/dev/null \
    | tr -d ' \n' | grep -o '"[0-9][0-9]*":{' | tr -dc '0-9\n'
}

# Adds a Cuttlefish display of WIDTHxHEIGHT pixels at DPI and prints its
# number, which crosvm picks.
add_cuttlefish_display() {
  local size="$1"
  local dpi="$2"
  local socket
  local lock_fd
  local before
  local number
  local added=""

  socket="$(cuttlefish_gpu_control_socket)"
  exec {lock_fd}>"${CVD_TMP_DIR}/cuttlefish-displays.lock"
  if flock -w 10 "${lock_fd}"; then
    before="$(cuttlefish_display_numbers "${socket}")"
    local app_refresh_hz
    if [[ "${LOWCPU_MODE_ACTIVE:-false}" == "true" ]]; then
      app_refresh_hz="${IKA_LOWCPU_REFRESH_RATE_HZ}"
    else
      read -r app_refresh_hz _ < <(resolve_display_refresh_hz)
    fi
    if with_timeout 10 "${CVD_HOST_OUT}/bin/crosvm" gpu add-displays \
        "--gpu-display=mode=windowed[${size/x/,}],dpi=[${dpi},${dpi}],refresh-rate=${app_refresh_hz}" \
        "${socket}" >/dev/null 2>&1; then
      while read -r number; do
        if [[ -n "${number}" ]] && ! grep -qx "${number}" <<<"${before}"; then
          added="${number}"
          break
        fi
      done < <(cuttlefish_display_numbers "${socket}")
    fi
  fi
  exec {lock_fd}>&-
  [[ -n "${added}" ]] || return 1
  printf '%s\n' "${added}"
}

remove_cuttlefish_display() {
  with_timeout 10 "${CVD_HOST_OUT}/bin/crosvm" gpu remove-displays --display-id="$1" \
    "$(cuttlefish_gpu_control_socket)" >/dev/null 2>&1
}

# The size of an app window's Cuttlefish display: the host screen, the largest
# the window can get (else the window's own size in pixels). Like the
# console's display, the app is drawn at the window size inside it.
app_cuttlefish_display_size() {
  host_display_size || printf '%s\n' "$1"
}

# Limits a window size in logical points to the host screen: a size saved
# under another desktop or scale can be larger.
clamp_app_window_size() {
  local width
  local height

  [[ "$1" =~ ^([0-9]+)x([0-9]+)$ ]] || return 1
  width="${BASH_REMATCH[1]}"
  height="${BASH_REMATCH[2]}"
  if [[ "$(host_display_logical_size || true)" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    (( width <= BASH_REMATCH[1] )) || width="${BASH_REMATCH[1]}"
    (( height <= BASH_REMATCH[2] )) || height="${BASH_REMATCH[2]}"
  fi
  printf '%sx%s\n' "${width}" "${height}"
}

# 16:9 at 60% of the host's logical width, capped at 75% of its height.
default_app_window_size() {
  local size
  local host_width
  local host_height
  local width=1280
  local height=720
  local max_height

  size="$(host_display_logical_size || true)"
  if [[ "${size}" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    host_width="${BASH_REMATCH[1]}"
    host_height="${BASH_REMATCH[2]}"
    width=$(( host_width * 60 / 100 ))
    height=$(( width * 9 / 16 ))
    max_height=$(( host_height * 75 / 100 ))
    if (( height > max_height )); then
      height="${max_height}"
      width=$(( height * 16 / 9 ))
    fi
  fi

  printf '%sx%s\n' "$(( width / 8 * 8 ))" "$(( height / 8 * 8 ))"
}

# Apps kept out of the app list, name matching and the desktop menu. They can
# still be opened by giving their full package name.
IKA_HIDDEN_APPS=(
  com.google.android.apps.restore
  com.google.android.googlequicksearchbox
  com.android.calculator2
  org.lineageos.etar
  com.android.deskclock
  com.android.contacts
  org.lineageos.recorder
  org.lineageos.audiofx
)
ika_ini_list IKA_HIDDEN_APPS apps hidden_apps

# Apps treated as games even though they do not declare
# android:appCategory="game", which Android uses to identify games.
IKA_GAME_APPS=(
)
ika_ini_list IKA_GAME_APPS apps game_apps

# Games are apps that declare themselves as such (recorded by the last sync in
# APP_GAMES_FILE, see IkaAppIcons) or that are listed in IKA_GAME_APPS. Given
# an adb serial, a game installed since the last sync is also recognized, by
# asking the guest's game mode service, which only accepts games.
is_game_app() {
  local package="$1"
  local adb_serial="${2:-}"
  local game

  for game in "${IKA_GAME_APPS[@]}"; do
    [[ "${package}" == "${game}" ]] && return 0
  done
  if [[ -f "${APP_GAMES_FILE}" ]] && grep -qxF "${package}" "${APP_GAMES_FILE}"; then
    return 0
  fi
  [[ -n "${adb_serial}" ]] || return 1
  guest_adb "${adb_serial}" shell cmd game list-modes "${package}" </dev/null 2>/dev/null \
    | grep -q 'current mode'
}

is_hidden_app() {
  local hidden

  for hidden in "${IKA_HIDDEN_APPS[@]}"; do
    [[ "$1" == "${hidden}" ]] && return 0
  done
  return 1
}

# Prints "LABEL<TAB>PACKAGE" for every enabled app with a launcher entry,
# except hidden apps, and caches the result for name lookups.
list_guest_apps() {
  local apps

  apps="$(query_guest_apps "$1")"
  [[ -n "${apps}" ]] || return 0
  mkdir -p "${IKA_APPS_DIR}"
  if printf '%s\n' "${apps}" > "${APP_LIST_CACHE}.$$"; then
    mv -f "${APP_LIST_CACHE}.$$" "${APP_LIST_CACHE}"
  fi
  printf '%s\n' "${apps}"
}

# Queries the launchable apps from scrcpy's app list, which prints each app as
# " * LABEL  PACKAGE" (system) or " - LABEL  PACKAGE", but moves the package to
# an indented continuation line when the label is 30 characters or longer.
query_guest_apps() {
  local adb_serial="$1"
  local output
  local -a scrcpy_env=()

  append_scrcpy_env scrcpy_env
  # Nothing unless the query succeeded: a partial list would make the menu sync
  # remove the launchers of the apps missing from it.
  output="$(with_timeout 30 env "${scrcpy_env[@]}" "${SCRCPY_BIN}" -s "${adb_serial}" --list-apps 2>&1)" \
    || return 0
  printf '%s\n' "${output}" \
    | tr -d '\r' \
    | awk '
        function is_package(s) {
          return s ~ /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/
        }
        function emit_same_line(    name, package) {
          name = pending
          package = name
          sub(/.*[[:space:]]/, "", package)
          sub(/[[:space:]]+[^[:space:]]+[[:space:]]*$/, "", name)
          if (is_package(package) && name != "") {
            printf "%s\t%s\n", name, package
          }
          pending = ""
        }
        /^ [*-] / {
          if (pending != "") {
            emit_same_line()
          }
          pending = substr($0, 4)
          # The app list is tab-separated, so a tab in a label would split it.
          gsub(/\t/, " ", pending)
          next
        }
        pending != "" && /^[[:space:]]+[^[:space:]]+[[:space:]]*$/ && is_package($1) {
          sub(/[[:space:]]+$/, "", pending)
          printf "%s\t%s\n", pending, $1
          pending = ""
          next
        }
        pending != "" {
          emit_same_line()
        }
        END {
          if (pending != "") {
            emit_same_line()
          }
        }' \
    | IKA_HIDDEN="${IKA_HIDDEN_APPS[*]}" awk -F '\t' '
        BEGIN {
          n = split(ENVIRON["IKA_HIDDEN"], packages, " ")
          for (i = 1; i <= n; i++) {
            hidden[packages[i]] = 1
          }
        }
        !($2 in hidden)' || true
}

# Resolves the app's label, cached per package because listing apps is slow.
# Falls back to the package name.
app_window_title() {
  local package="$1"
  local adb_serial="$2"
  local title_file="${IKA_APPS_DIR}/${package}/title"
  local title=""

  if [[ -s "${title_file}" ]]; then
    title="$(<"${title_file}")"
  else
    title="$(list_guest_apps "${adb_serial}" \
      | awk -F '\t' -v pkg="${package}" '$2 == pkg { print $1; exit }' || true)"
    if [[ -n "${title}" ]]; then
      printf '%s\n' "${title}" > "${title_file}"
    fi
  fi

  printf '%s\n' "${title:-${package}}"
}

# Prints an app window's app ID, which its launcher's file name repeats:
# ika-PACKAGE. WSLg keeps a desktop entry under the last dot-separated part of
# its name only, and finds no entry, and so no icon, for an app ID with dots;
# there the dots become dashes, which package names cannot have, and the
# distribution's name comes first (see wslg_distro_id): ika-DISTRIBUTION-PACKAGE.
app_window_id() {
  local id="ika-$1"
  local distro

  if [[ "${IKA_ON_WSLG}" == true ]]; then
    distro="$(wslg_distro_id)"
    id="ika-${distro:+${distro}-}$1"
    id="${id//./-}"
  fi
  printf '%s\n' "${id}"
}

# Prints the app's name as its menu launcher shows it, without the game/app
# marker (see app_launcher_name), for messages and notifications. It comes from
# the launcher, the cached app list, or the cached window title, without asking
# the guest, and falls back to the package name.
app_display_name() {
  local package="$1"
  local launcher
  local name=""

  launcher="$(app_menu_data_dir)/applications/$(app_window_id "${package}").desktop"
  if [[ -f "${launcher}" ]]; then
    name="$(sed -n '/^Name=/{s///p;q}' "${launcher}")"
    # The game or app marker, or the app marker of older launchers
    name="${name#🎮 ∙ }"
    name="${name#ᗩ ∙ }"
    name="${name#∙ }"
    name="${name//\\\\/\\}"
  fi
  if [[ -z "${name}" && -s "${APP_LIST_CACHE}" ]]; then
    name="$(awk -F '\t' -v pkg="${package}" '$2 == pkg { print $1; exit }' "${APP_LIST_CACHE}")"
  fi
  if [[ -z "${name}" && -s "${IKA_APPS_DIR}/${package}/title" ]]; then
    name="$(<"${IKA_APPS_DIR}/${package}/title")"
  fi
  printf '%s\n' "${name:-${package}}"
}

# Resolves NAME to "LABEL<TAB>PACKAGE" among the launchable apps. The app list
# cached by the last listing or sync answers most lookups without the live
# query, which takes over half a second; a miss, an ambiguous name, or an app
# that is no longer installed falls back to the live list.
resolve_launchable_app() {
  local name="$1"
  local adb_serial="$2"
  local matches

  if [[ -s "${APP_LIST_CACHE}" ]]; then
    matches="$(match_app_name "${name}" < "${APP_LIST_CACHE}")"
    if [[ -n "${matches}" && "$(grep -c . <<<"${matches}")" -eq 1 ]] \
        && app_is_installed "${matches#*$'\t'}" "${adb_serial}"; then
      printf '%s\n' "${matches}"
      return 0
    fi
  fi
  resolve_app_name "${name}" "$(list_guest_apps "${adb_serial}")" "launchable app"
}

# Android's mode switch ("Desktop/TV" in the app menu, IkaMode in Android) is a
# list and a question, so like any app it opens in a window of its own. The
# window is sized to that list (in dp, at the guest's density) rather than to
# 60% of the screen; a size saved from resizing it wins.
IKA_MODE_PACKAGE="org.lineageos.desktop.mode"
IKA_MODE_WINDOW_DP_WIDTH=480
IKA_MODE_WINDOW_DP_HEIGHT=560

# Prints the size of the Desktop/TV window in logical points, as
# default_app_window_size does, for a guest display density of DPI: the dp
# size in the guest's pixels, then in logical points by the host's
# native/logical ratio (the app is drawn at native resolution), and no larger
# than the host screen.
mode_app_window_size() {
  local dpi="$1"
  local width
  local height
  local native
  local logical
  local native_width

  [[ "${dpi}" =~ ^[1-9][0-9]*$ ]] || return 1
  width=$(( IKA_MODE_WINDOW_DP_WIDTH * dpi / 160 ))
  height=$(( IKA_MODE_WINDOW_DP_HEIGHT * dpi / 160 ))
  native="$(host_display_size || true)"
  logical="$(host_display_logical_size || true)"
  if [[ "${native}" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    native_width="${BASH_REMATCH[1]}"
    if [[ "${logical}" =~ ^([0-9]+)x([0-9]+)$ ]] && (( native_width > 0 )); then
      width=$(( width * BASH_REMATCH[1] / native_width ))
      height=$(( height * BASH_REMATCH[1] / native_width ))
    fi
  fi
  (( width >= 320 )) || width=320
  (( height >= 320 )) || height=320
  clamp_app_window_size "$(( width / 8 * 8 ))x$(( height / 8 * 8 ))"
}

# Starts the VM without its console when it is not running, so that menu
# launchers work while Ika is stopped, then waits for the guest to boot.
# QUERY... are guest shell commands the caller needs next, answered in the boot
# check's adb round trip when the guest has booted (see guest_shell_query).
ensure_guest_ready() {
  local -a queries=("$@")
  local adb_serial
  local deadline
  local autostart_lock_fd

  # Serialize concurrent launches, so only one of them starts the VM.
  exec {autostart_lock_fd}>"${CVD_TMP_DIR}/autostart.lock"
  flock -w "$((CVD_BOOT_MAX_SEC + 60))" "${autostart_lock_fd}" \
    || die "timed out waiting for Ika to start"
  if ! has_live_cvd_processes; then
    log "Android virtual device not running; starting it without the console"
    notify_progress "Starting Android, one moment..."
    # Close the lock for the child: the VM processes it starts outlive this
    # command and would otherwise hold the lock for as long as the VM runs.
    IKA_NOTIFY=false "${IKA_SCRIPT_PATH}" start --no-console </dev/null >/dev/null 2>&1 \
      {autostart_lock_fd}>&- \
      || die "could not start the Android virtual device; see ${START_LOG_FILE}"
  fi
  exec {autostart_lock_fd}>&-

  adb_serial="$(resolve_adb_serial)"
  if (( ${#queries[@]} )) && guest_booted_with_queries "${adb_serial}" "${queries[@]}"; then
    return 0
  fi
  deadline="$(make_deadline "${CVD_BOOT_MAX_SEC}")"
  until adb_boot_completed "${adb_serial}"; do
    has_live_cvd_processes || die "the Android virtual device stopped while booting"
    within_deadline "${deadline}" || die "the Android virtual device did not finish booting"
    sleep 1
  done
}

# Filters "LABEL<TAB>PACKAGE" lines on stdin to the apps NAME refers to: an
# exact package or case-insensitive label match, otherwise every label that
# contains NAME case-insensitively.
match_app_name() {
  IKA_APP_NAME="$1" awk -F '\t' '
    BEGIN { name = tolower(ENVIRON["IKA_APP_NAME"]) }
    { labels[NR] = $1; packages[NR] = $2 }
    tolower($1) == name || tolower($2) == name { exact[++n_exact] = NR }
    index(tolower($1), name) { partial[++n_partial] = NR }
    END {
      if (n_exact) {
        for (i = 1; i <= n_exact; i++) print labels[exact[i]] "\t" packages[exact[i]]
      } else {
        for (i = 1; i <= n_partial; i++) print labels[partial[i]] "\t" packages[partial[i]]
      }
    }'
}

# Resolves NAME to exactly one "LABEL<TAB>PACKAGE" line from the LIST of apps,
# or dies naming the candidates when NAME is unknown or ambiguous.
resolve_app_name() {
  local name="$1"
  local list="$2"
  local what="$3"
  local matches
  local count
  local label
  local package

  matches="$(match_app_name "${name}" <<<"${list}")"
  count="$(grep -c . <<<"${matches}" || true)"
  if [[ "${count}" -eq 1 ]]; then
    printf '%s\n' "${matches}"
    return 0
  fi

  if [[ "${count}" -eq 0 ]]; then
    # Menu launchers pass the package of an app that may since have been removed.
    if is_app_package_name "${name}"; then
      die "$(app_display_name "${name}") is not installed in Android; see '${SCRIPT_NAME} app'"
    fi
    die "no ${what} matches '${name}'; see '${SCRIPT_NAME} app'"
  fi
  log "'${name}' matches several ${what}s:"
  while IFS=$'\t' read -r label package; do
    log "  ${label}  (${package})"
  done <<<"${matches}"
  die "use a longer name or the package name"
}

