# ika: the VM's disks, options and environment, groups, adb, processes, logs and boot.
# Sourced by src/tools/ika, in its order; see there.

require_executable() {
  local path="$1"
  local label="$2"
  [[ -x "${path}" ]] || die "${label} not found or not executable: ${path}"
}

instance_has_userdata_state() {
  [[ -e "${CVD_INSTANCE_DIR}/overlay.img" || -e "${CVD_INSTANCE_DIR}/userdata.img" ]]
}

composite_disk_rebuild_reason() {
  local name="$1"
  local disk="${CVD_INSTANCE_DIR}/${name}.img"
  local config="${CVD_INSTANCE_DIR}/${name}_disk_config.txt"
  local component

  if [[ ! -e "${disk}" ]]; then
    printf '%s\n' "${name}.img is missing"
    return 0
  fi

  if [[ ! -e "${config}" ]]; then
    printf '%s\n' "${name}_disk_config.txt is missing"
    return 0
  fi

  while IFS= read -r component; do
    [[ -n "${component}" ]] || continue
    [[ "${component}" != "crosvm" ]] || continue
    [[ -e "${component}" ]] || continue

    if [[ "${component}" -nt "${disk}" ]]; then
      printf '%s\n' "${component} is newer than ${name}.img"
      return 0
    fi
  done < "${config}"

  return 1
}

is_generated_os_component() {
  [[ "$1" == "${CVD_INSTANCE_DIR}/metadata" || "$1" == "${CVD_INSTANCE_DIR}/misc" ]]
}

refresh_generated_os_component_mtimes() {
  local disk="${CVD_INSTANCE_DIR}/os_composite.img"
  local config="${CVD_INSTANCE_DIR}/os_composite_disk_config.txt"
  local overlay="${CVD_INSTANCE_DIR}/overlay.img"
  local component
  local path
  local needs_refresh="false"

  [[ -e "${overlay}" && -e "${disk}" && -e "${config}" ]] || return 0

  while IFS= read -r component; do
    [[ -n "${component}" ]] || continue
    [[ "${component}" != "crosvm" ]] || continue
    [[ -e "${component}" ]] || continue
    [[ "${component}" -nt "${disk}" ]] || continue

    if ! is_generated_os_component "${component}"; then
      return 0
    fi

    needs_refresh="true"
  done < "${config}"

  [[ "${needs_refresh}" == "true" ]] || return 0

  for path in \
    "${disk}" \
    "${CVD_INSTANCE_DIR}/os_composite_gpt_header.img" \
    "${CVD_INSTANCE_DIR}/os_composite_gpt_footer.img"; do
    [[ -e "${path}" ]] && touch "${path}" 2>/dev/null || true
  done
  touch "${overlay}" 2>/dev/null || true
}

protect_overlay_resume() {
  local reason

  [[ -e "${CVD_INSTANCE_DIR}/overlay.img" ]] || return 0

  refresh_generated_os_component_mtimes

  if reason="$(composite_disk_rebuild_reason os_composite)"; then
    respond_console "Refusing to start because Cuttlefish would rebuild the OS disk and discard VM data."
    respond_console "Reason: ${reason}"
    respond_console "Run '${SCRIPT_NAME} reset' if you want to discard the current VM data."
    die "refusing to discard overlay.img: ${reason}"
  fi

  if [[ -e "${CVD_INSTANCE_DIR}/ap_composite.img" ]] \
      && reason="$(composite_disk_rebuild_reason ap_composite)"; then
    respond_console "Refusing to start because Cuttlefish would rebuild the AP disk and discard VM data."
    respond_console "Reason: ${reason}"
    respond_console "Run '${SCRIPT_NAME} reset' if you want to discard the current VM data."
    die "refusing to discard overlay.img: ${reason}"
  fi
}

append_data_storage_args() {
  local -n args_array="$1"
  shift
  local configured_data_gb=""
  local data_gb
  local data_mb
  local has_existing_userdata_state="false"
  local explicit_data_policy="false"
  local explicit_data_size="false"

  if user_supplied_flag "data_policy" "$@"; then
    explicit_data_policy="true"
  fi
  if user_supplied_flag "blank_data_image_mb" "$@"; then
    explicit_data_size="true"
  fi

  if instance_has_userdata_state; then
    has_existing_userdata_state="true"
  fi

  if [[ "${explicit_data_policy}" != "true" && "${has_existing_userdata_state}" == "true" ]]; then
    return 0
  fi

  if [[ -s "${DATA_GB_CONFIG_FILE}" ]]; then
    IFS= read -r configured_data_gb < "${DATA_GB_CONFIG_FILE}"
    configured_data_gb="$(normalize_data_gb "${configured_data_gb}")"
  fi

  data_gb="${configured_data_gb:-${DEFAULT_DATA_GB}}"
  data_mb="$(data_gb_to_mib "${data_gb}")"

  if [[ "${explicit_data_policy}" != "true" ]]; then
    args_array+=("--data_policy=always_create")
  fi

  if [[ "${explicit_data_size}" != "true" ]]; then
    args_array+=("--blank_data_image_mb=${data_mb}")
  fi

  if [[ -n "${configured_data_gb}" ]]; then
    CVD_DATA_STORAGE_MESSAGE="Provisioning ${data_gb} GB userdata..."
    log "fresh userdata target: ${data_mb} MiB"
  fi
}

apply_default_args() {
  local -n config_map="$1"
  local -n args_array="$2"
  shift 2
  local key value

  for key in "${!config_map[@]}"; do
    if ! user_supplied_flag "${key}" "$@"; then
      value="${config_map[${key}]}"
      # Handle special case for report_anonymous_usage_stats which uses single dash
      if [[ "${key}" == "report_anonymous_usage_stats" ]]; then
        args_array+=("-${key}=${value}")
      else
        args_array+=("--${key}=${value}")
      fi
    fi
  done
}

# Gives the device its own serial number, generated on first start and kept
# across updates and factory resets, instead of Cuttlefish's CUTTLEFISHCVD01,
# which is the same on every install. Letters and digits only: GMS check-in
# rejects other serials.
append_serial_number_args() {
  local -n args_array="$1"
  shift
  local serial=""

  if user_supplied_flag "serial_number" "$@" \
      || user_supplied_flag "use_random_serial" "$@"; then
    return 0
  fi

  if [[ -s "${SERIAL_NUMBER_FILE}" ]]; then
    IFS= read -r serial < "${SERIAL_NUMBER_FILE}" || true
  fi
  if [[ ! "${serial}" =~ ^[A-Z0-9]+$ ]]; then
    serial="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n' | tr 'a-f' 'A-F')"
    printf '%s\n' "${serial}" > "${SERIAL_NUMBER_FILE}"
    log "generated device serial number ${serial}"
  fi
  args_array+=("--serial_number=${serial}")
}

apply_start_default_args() {
  local args_array_name="$1"
  shift
  local config_map

  for config_map in "${CVD_DEFAULT_ARG_MAPS[@]}"; do
    apply_default_args "${config_map}" "${args_array_name}" "$@"
  done
}

append_cuttlefish_audio_args() {
  local -n args_array="$1"
  shift

  if ! user_supplied_flag "enable_audio" "$@"; then
    args_array+=("--enable_audio=true")
    log "enabling Cuttlefish virtio-snd audio server"
  fi
}

host_timezone() {
  command -v timedatectl >/dev/null 2>&1 || return 0
  timedatectl show --property=Timezone --value 2>/dev/null || true
}

# Prints "dark" or "light" for Windows' app mode (Settings, Personalization,
# Colors), or fails without Windows interop
windows_color_scheme() {
  local reg
  local value

  reg="$(command -v reg.exe || true)"
  [[ -n "${reg}" ]] || reg="/mnt/c/Windows/System32/reg.exe"
  [[ -x "${reg}" ]] || return 1
  value="$(with_timeout 5 "${reg}" query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' \
    /v AppsUseLightTheme 2>/dev/null | tr -d '\r' | awk '$1 == "AppsUseLightTheme" { print $3 }')"
  case "${value}" in
    0x0) printf 'dark\n' ;;
    0x1) printf 'light\n' ;;
    *) return 1 ;;
  esac
}

# Prints "dark" or "light" for the desktop's color scheme, or nothing when it
# states no preference. Reads the freedesktop Settings portal, which ika-scrcpy
# window title bars follow too, then GNOME's setting. On WSLg, whose windows sit
# on the Windows desktop, Windows' app mode comes first.
host_color_scheme() {
  local value=""

  if [[ "${IKA_ON_WSLG}" == true ]] && windows_color_scheme; then
    return 0
  fi

  if command -v gdbus >/dev/null 2>&1; then
    value="$(with_timeout 3 gdbus call --session \
        --dest org.freedesktop.portal.Desktop \
        --object-path /org/freedesktop/portal/desktop \
        --method org.freedesktop.portal.Settings.Read \
        org.freedesktop.appearance color-scheme 2>/dev/null \
      | grep -oE 'uint32 [0-9]+' | awk '{ print $2 }' || true)"
  fi
  if [[ -z "${value}" ]] && command -v gsettings >/dev/null 2>&1; then
    case "$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)" in
      "'prefer-dark'") value=1 ;;
      "'prefer-light'") value=2 ;;
    esac
  fi

  case "${value}" in
    1) printf 'dark\n' ;;
    2) printf 'light\n' ;;
  esac
}

append_bootconfig_args() {
  local -n args_array="$1"
  local tz
  local bootconfig_value=""

  tz="$(host_timezone)"
  if [[ -n "${tz}" ]]; then
    bootconfig_value="androidboot.timezone=\"${tz}\" androidboot.cuttlefish_service_bluetooth_checker=false"
    log "timezone: ${tz}"
  fi

  if is_user_build; then
    [[ -n "${USER_ADB_PUBLIC_KEY_VALUE:-}" ]] || {
      log "public ADB key was not prepared for ${USER_ADB_PRIVATE_KEY}"
      return 1
    }
    bootconfig_value+="${bootconfig_value:+ }androidboot.ika.adb_pubkey=${USER_ADB_PUBLIC_KEY_VALUE}"
  fi

  [[ -n "${bootconfig_value}" ]] || return 0
  args_array+=("--extra_bootconfig_args=${bootconfig_value}")
}

append_cvd_env_args() {
  local -n env_args_ref="$1"
  local config_path="${2:-}"
  local glibc_tunables
  local radv_debug
  local adb_vendor_keys

  env_args_ref+=(
    "HOME=${CVD_HOME_DIR}"
    "TMPDIR=${CVD_TMP_DIR}"
    "ANDROID_HOST_OUT=${CVD_HOST_OUT}"
    "ANDROID_SOONG_HOST_OUT=${CVD_HOST_OUT}"
    "ANDROID_PRODUCT_OUT=${CVD_PRODUCT_OUT}"
  )

  if is_user_build; then
    adb_vendor_keys="${USER_ADB_PRIVATE_KEY}"
    [[ -n "${ADB_VENDOR_KEYS:-}" ]] && adb_vendor_keys+=":${ADB_VENDOR_KEYS}"
    env_args_ref+=("ADB_VENDOR_KEYS=${adb_vendor_keys}")
  fi

  # gfxstream creates its host EGL display without a window-system surface.
  # Selecting this explicitly also avoids inheriting a broken/unavailable X11
  # platform from SSH sessions on headless and Apple Silicon hosts.
  if [[ "${CVD_GPU_MODE}" == gfxstream* ]]; then
    env_args_ref+=("EGL_PLATFORM=${EGL_PLATFORM:-surfaceless}")
  fi

  # On WSL2, the gfxstream mode runs the guest's OpenGL ES on the host's
  # OpenGL, which Mesa otherwise gives llvmpipe, on the CPU: the GPU is
  # reached only through Direct3D 12 (/dev/dxg). Use Mesa's d3d12 driver, as
  # the console does (see append_scrcpy_env): Ika's build where
  # setup_wsl_gpu_env found the D3D12 GPU, else the distribution's. Unless
  # the user set a GALLIUM_DRIVER or an EGL vendor.
  if [[ "${CVD_GPU_MODE}" == "gfxstream" && -e /dev/dxg && -z "${GALLIUM_DRIVER:-}" \
        && "${IKA_WSL_GPU_FIX:-1}" != "0" ]]; then
    if [[ -n "${IKA_WSL_GPU_ENV:-}" && -z "${__EGL_VENDOR_LIBRARY_FILENAMES:-}" \
          && -f "${PACKAGED_WSL_GPU_DIR}/mesa-gl/egl_vendor.json" ]]; then
      env_args_ref+=("GALLIUM_DRIVER=d3d12"
                     "__EGL_VENDOR_LIBRARY_FILENAMES=${PACKAGED_WSL_GPU_DIR}/mesa-gl/egl_vendor.json")
    elif compgen -G '/usr/lib*/dri/d3d12_dri.so' >/dev/null \
        || compgen -G '/usr/lib/*/dri/d3d12_dri.so' >/dev/null; then
      env_args_ref+=("GALLIUM_DRIVER=d3d12")
    fi
  fi

  # RADV's default asynchronous shader compilation can report fence completion
  # before a transform-feedback pipeline has finished compiling. Gfxstream can
  # then execute an incomplete pipeline, producing intermittent missing
  # primitives even though the associated query result is correct. Compile
  # shaders synchronously for gfxstream on RADV, while preserving any options
  # supplied by the caller. Other Vulkan drivers are left unchanged.
  if [[ "${CVD_GPU_MODE}" == gfxstream* ]] && primary_vulkan_device_is_radv; then
    radv_debug="$(append_comma_option "${RADV_DEBUG:-}" "syncshaders")"
    env_args_ref+=("RADV_DEBUG=${radv_debug}")
    log "RADV gfxstream correctness options: ${radv_debug}"
  fi

  # gfxstream creates many short-lived render threads. On glibc's default
  # arena policy, allocations freed during guest graphics-process cleanup can
  # remain resident in dozens of per-thread arenas. This is especially costly
  # on the Apple 16K udmabuf path, where Asphalt otherwise leaves hundreds of
  # MiB of free allocator pages resident after each launch. Cap the arena count
  # and retain any caller-provided tunables.
  if [[ "${CVD_GPU_MODE}" == gfxstream* ]] && is_apple_silicon_16k_host; then
    glibc_tunables="${GLIBC_TUNABLES:-}"
    if [[ ":${glibc_tunables}:" != *":glibc.malloc.arena_max="* ]]; then
      glibc_tunables="${glibc_tunables:+${glibc_tunables}:}glibc.malloc.arena_max=4"
    fi
    if [[ ":${glibc_tunables}:" != *":glibc.malloc.trim_threshold="* ]]; then
      glibc_tunables="${glibc_tunables:+${glibc_tunables}:}glibc.malloc.trim_threshold=131072"
    fi
    env_args_ref+=("GLIBC_TUNABLES=${glibc_tunables}")
    log "Apple Silicon gfxstream allocator tunables: ${glibc_tunables}"
  fi

  if [[ -n "${config_path}" ]]; then
    env_args_ref+=("CUTTLEFISH_CONFIG_FILE=${config_path}")
  fi
}

run_with_cvd_env() {
  local config_path=""
  local -a env_args=(env)

  if [[ "${1:-}" == "--config" ]]; then
    config_path="${2:-}"
    shift 2
  fi

  append_cvd_env_args env_args "${config_path}"
  "${env_args[@]}" "$@"
}

run_stop_helper() {
  local status

  set +e
  run_with_cvd_env "$@" >/dev/null 2>&1
  status="$?"
  set -e

  return "${status}"
}

has_session_group() {
  id -nG | tr ' ' '\n' | grep -Fxq "$1"
}

has_configured_group() {
  id -nG "${USER}" | tr ' ' '\n' | grep -Fxq "$1"
}

check_required_groups() {
  local -a required_groups=(kvm video render cvdnetwork)
  local -a missing_groups=()
  local -a inactive_groups=()
  local -a add_groups=()
  local group

  for group in "${required_groups[@]}"; do
    if getent group "${group}" >/dev/null 2>&1 && ! has_session_group "${group}"; then
      missing_groups+=("${group}")
      if has_configured_group "${group}"; then
        inactive_groups+=("${group}")
      else
        add_groups+=("${group}")
      fi
    fi
  done

  if [[ "${#missing_groups[@]}" -eq 0 ]]; then
    return 0
  fi

  cat <<EOF
[${SCRIPT_NAME}] error: current shell is missing required groups.

Active groups:
  $(id -nG)

Missing groups:
  ${missing_groups[*]}

EOF

  if [[ "${#add_groups[@]}" -gt 0 ]]; then
    cat <<EOF
To add the missing account membership:
  pkexec /usr/libexec/cuttlefish/cuttlefish-add-user-to-groups

EOF
  fi

  if [[ "${#inactive_groups[@]}" -gt 0 ]]; then
    cat <<EOF
Configured on the account but not active in this login session:
  ${inactive_groups[*]}

EOF
  fi

  cat <<EOF

Log out fully and back in after updating group membership.
EOF
  exit 1
}

resolve_adb_serial() {
  local adb_ip_and_port=""
  local vsock_cid=""

  if [[ -f "${CVD_CONFIG_PATH}" ]]; then
    if grep -q '"native_vsock"' "${CVD_CONFIG_PATH}"; then
      vsock_cid="$(grep -oE '"vsock_guest_cid"[[:space:]]*:[[:space:]]*[0-9]+' "${CVD_CONFIG_PATH}" | head -n1 | grep -oE '[0-9]+$' || true)"
      if [[ -n "${vsock_cid}" ]] && (( vsock_cid > 2 )); then
        printf 'vsock:%s:5555\n' "${vsock_cid}"
        return 0
      fi
    fi
    adb_ip_and_port="$(grep -oE '"adb_ip_and_port"[[:space:]]*:[[:space:]]*"[^"]+"' "${CVD_CONFIG_PATH}" | head -n1 | sed -E 's/.*"([^"]+)"$/\1/' || true)"
  fi

  case "${adb_ip_and_port:-127.0.0.1:6520}" in
    0.0.0.0:*)
      printf '127.0.0.1:%s\n' "${adb_ip_and_port#*:}"
      ;;
    '[::]':*)
      printf '127.0.0.1:%s\n' "${adb_ip_and_port##*:}"
      ;;
    *)
      printf '%s\n' "${adb_ip_and_port:-127.0.0.1:6520}"
      ;;
  esac
}

resolve_cuttlefish_frames_socket() {
  local frame_sock_path=""
  local socket_path

  if [[ -f "${CVD_CONFIG_PATH}" ]]; then
    frame_sock_path="$(grep -oE '"frame_sock_path"[[:space:]]*:[[:space:]]*"[^"]+"' "${CVD_CONFIG_PATH}" | head -n1 | sed -E 's/.*"([^"]+)"$/\1/' || true)"
  fi

  if [[ -n "${frame_sock_path}" ]]; then
    socket_path="$(dirname "${frame_sock_path}")/ika_frames.sock"
  else
    socket_path="/tmp/cf_avd_${UID}/cvd-1/internal/ika_frames.sock"
  fi

  printf '%s\n' "${socket_path}"
}

has_live_cvd_processes() {
  pgrep -f "${CVD_PROCESS_REGEX}" >/dev/null 2>&1
}

stop_dnsmasq() {
  local pid_file
  for pid_file in /var/tmp/cvd/cuttlefish-dnsmasq-*.pid /var/run/cuttlefish-dnsmasq-*.pid; do
    [[ -f "${pid_file}" ]] || continue
    kill "$(cat "${pid_file}")" 2>/dev/null || true
    rm -f "${pid_file}"
    rm -f "${pid_file%.pid}.leases"
  done
  pkill -f 'dnsmasq.*cvd-' 2>/dev/null || true
}

cleanup_user_processes() {
  local -a pids=()
  local -a survivors=()
  local any_survivor
  local deadline
  local pid

  while read -r pid; do
    [[ -n "${pid}" ]] || continue
    [[ "${pid}" == "$$" ]] && continue
    pids+=("${pid}")
  done < <(pgrep -f "${CVD_PROCESS_REGEX}" || true)

  if [[ "${#pids[@]}" -eq 0 ]]; then
    return 0
  fi

  mapfile -t pids < <(printf '%s\n' "${pids[@]}" | sort -u)
  log "stopping leftover Cuttlefish processes: ${pids[*]}"
  kill "${pids[@]}" 2>/dev/null || true

  # SECONDS has one-second resolution. Add one tick so the configured grace
  # period is never shortened by entering this loop partway through a tick.
  deadline=$((SECONDS + IKA_STOP_GRACE_SEC + 1))
  while (( SECONDS < deadline )); do
    survivors=()
    for pid in "${pids[@]}"; do
      if cvd_pid_is_alive "${pid}"; then
        survivors+=("${pid}")
      fi
    done
    if [[ "${#survivors[@]}" -eq 0 ]]; then
      return 0
    fi
    sleep 0.2
  done

  survivors=()
  for pid in "${pids[@]}"; do
    if cvd_pid_is_alive "${pid}"; then
      survivors+=("${pid}")
    fi
  done
  if [[ "${#survivors[@]}" -gt 0 ]]; then
    log "Cuttlefish processes did not exit within ${IKA_STOP_GRACE_SEC}s; forcing termination: ${survivors[*]}"
    kill -9 "${survivors[@]}" 2>/dev/null || true

    deadline=$((SECONDS + 6))
    while (( SECONDS < deadline )); do
      any_survivor="false"
      for pid in "${survivors[@]}"; do
        if cvd_pid_is_alive "${pid}"; then
          any_survivor="true"
          break
        fi
      done
      [[ "${any_survivor}" == "true" ]] || return 0
      sleep 0.2
    done
  fi
}

cvd_pid_is_alive() {
  local pid="$1"
  local command_line
  local state

  [[ -r "/proc/${pid}/stat" ]] || return 1
  state="$(awk '{ print $3 }' "/proc/${pid}/stat" 2>/dev/null || true)"
  [[ -n "${state}" && "${state}" != "Z" ]] || return 1

  command_line="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  [[ "${command_line}" =~ ${CVD_PROCESS_REGEX} ]]
}

normalize_stop_grace_seconds() {
  if [[ ! "${IKA_STOP_GRACE_SEC}" =~ ^[1-9][0-9]*$ ]]; then
    die "IKA_STOP_GRACE_SEC must be a positive whole number of seconds"
  fi
}

read_udmabuf_snapshot() {
  local bufinfo="/sys/kernel/debug/dma_buf/bufinfo"
  local contents

  # Some Asahi kernels can retain imported udmabufs after an unclean renderer
  # exit. Keep this probe advisory: failure to read debugfs must never prevent
  # the VM from starting or stopping.
  if [[ -r "${bufinfo}" ]]; then
    contents="$(<"${bufinfo}")"
  elif command -v sudo >/dev/null 2>&1; then
    contents="$(sudo -n cat "${bufinfo}" 2>/dev/null)" || return 1
  else
    return 1
  fi

  awk '$5 == "udmabuf" && $1 ~ /^[0-9]+$/ { count++; bytes += $1 }
       END { printf "%d %.0f\n", count, bytes }' <<<"${contents}"
}

record_udmabuf_baseline() {
  local snapshot

  host_is_apple_silicon || return 0

  snapshot="$(read_udmabuf_snapshot || true)"
  [[ "${snapshot}" =~ ^[0-9]+\ [0-9]+$ ]] || return 0

  printf '%s\n' "${snapshot}" >"${UDMABUF_BASELINE_FILE}"
  log "Asahi udmabuf baseline: $(format_udmabuf_snapshot "${snapshot}")"
}

format_udmabuf_bytes() {
  local bytes="$1"

  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "${bytes}" 2>/dev/null || printf '%s bytes\n' "${bytes}"
  else
    printf '%s bytes\n' "${bytes}"
  fi
}

format_udmabuf_snapshot() {
  local snapshot="$1"
  local count bytes

  read -r count bytes <<<"${snapshot}"
  printf '%s object(s), %s' "${count}" "$(format_udmabuf_bytes "${bytes}")"
}

report_udmabuf_leaks() {
  local baseline
  local current
  local baseline_count baseline_bytes
  local current_count current_bytes
  local leaked_count leaked_bytes

  host_is_apple_silicon || return 0

  [[ -r "${UDMABUF_BASELINE_FILE}" ]] || return 0
  baseline="$(<"${UDMABUF_BASELINE_FILE}")"
  current="$(read_udmabuf_snapshot || true)"
  [[ "${baseline}" =~ ^[0-9]+\ [0-9]+$ ]] || return 0
  [[ "${current}" =~ ^[0-9]+\ [0-9]+$ ]] || return 0

  read -r baseline_count baseline_bytes <<<"${baseline}"
  read -r current_count current_bytes <<<"${current}"
  leaked_count=$((current_count - baseline_count))
  leaked_bytes=$((current_bytes - baseline_bytes))

  if (( leaked_count > 0 || leaked_bytes > 0 )); then
    (( leaked_count > 0 )) || leaked_count=0
    (( leaked_bytes > 0 )) || leaked_bytes=0
    log_file_only "WARNING: Asahi retained ${leaked_count} udmabuf object(s) ($(format_udmabuf_bytes "${leaked_bytes}")) after Cuttlefish stopped. Kernels without the deferred drm_gpuvm_bo cleanup fix (AsahiLinux/linux#548) need a host reboot to reclaim kernel-pinned memory."
  else
    log_file_only "Asahi udmabuf usage returned to baseline: $(format_udmabuf_snapshot "${current}")"
  fi
}

within_deadline() {
  local deadline="$1"
  [[ "${deadline}" -eq 0 || ${SECONDS} -lt ${deadline} ]]
}

make_deadline() {
  local timeout_sec="$1"
  if [[ "${timeout_sec}" -gt 0 ]]; then
    printf '%s\n' "$((SECONDS + timeout_sec))"
  else
    printf '0\n'
  fi
}

resolve_adb_bin() {
  if [[ -x "${CVD_ADB_BIN}" ]]; then
    printf '%s\n' "${CVD_ADB_BIN}"
  else
    command -v adb || true
  fi
}

# 'ika shell': adb shell in Android, starting the VM without the console first
# when it is not running; COMMAND, when given, runs there instead
open_android_shell() {
  local adb_bin
  local adb_serial

  adb_bin="$(resolve_adb_bin)"
  [[ -n "${adb_bin}" ]] || die "adb not found"
  ensure_guest_ready
  adb_serial="$(resolve_adb_serial)"
  exec "${adb_bin}" -s "${adb_serial}" shell "$@"
}

is_user_build() {
  [[ "${CVD_BUILD_VARIANT}" == "user" ]]
}

prepare_user_adb_key() {
  is_user_build || return 0

  local adb_bin
  local public_key_tmp
  local public_key
  mkdir -p "${HOST_HOME}/.android" || return 1
  adb_bin="$(resolve_adb_bin)"
  [[ -n "${adb_bin}" ]] || {
    log "adb is required to provision the user ADB key"
    return 1
  }

  if [[ ! -s "${USER_ADB_PRIVATE_KEY}" ]]; then
    "${adb_bin}" keygen "${USER_ADB_PRIVATE_KEY}" >/dev/null || {
      log "could not generate the user ADB key: ${USER_ADB_PRIVATE_KEY}"
      return 1
    }
  fi
  public_key="$("${adb_bin}" pubkey "${USER_ADB_PRIVATE_KEY}")" || {
    log "could not derive the public user ADB key: ${USER_ADB_PRIVATE_KEY}"
    return 1
  }
  USER_ADB_PUBLIC_KEY_VALUE="${public_key%% *}"
  [[ -n "${USER_ADB_PUBLIC_KEY_VALUE}" ]] || {
    log "adb returned an empty public key for ${USER_ADB_PRIVATE_KEY}"
    return 1
  }
  if ! printf '%s\n' "${public_key}" | cmp -s - "${USER_ADB_PUBLIC_KEY}"; then
    public_key_tmp="$(mktemp "${USER_ADB_PUBLIC_KEY}.XXXXXX")" || return 1
    if ! printf '%s\n' "${public_key}" > "${public_key_tmp}"; then
      rm -f "${public_key_tmp}"
      return 1
    fi
    mv -f "${public_key_tmp}" "${USER_ADB_PUBLIC_KEY}"
  fi
  chmod 600 "${USER_ADB_PRIVATE_KEY}" || return 1
  chmod 644 "${USER_ADB_PUBLIC_KEY}" || return 1
}

host_adb() {
  local timeout_seconds="$1"
  shift
  local adb_bin

  adb_bin="$(resolve_adb_bin)"
  [[ -n "${adb_bin}" ]] || return 1
  with_timeout "${timeout_seconds}" "${adb_bin}" "$@"
}

# Drops the guest's adb transport once the VM has stopped. Otherwise the adb
# server keeps reconnecting to it about four times a second until the VM
# starts again. Starts no adb server when none is running.
disconnect_guest_adb() {
  local adb_serial="$1"

  pgrep -u "${UID}" -f '(^|/)adb .*fork-server server' >/dev/null 2>&1 || return 0
  host_adb 5 disconnect "${adb_serial}" >/dev/null 2>&1 || true
}

# Seconds a stop waits for Android to answer over adb before it goes on
# without the sync below: a hung guest must not hold the stop up.
readonly GUEST_SYNC_PROBE_SEC=3

# Has Android write the data it still holds in memory to its disks, before a
# stop: the stop ends the VM at once, as pulling the plug would, and Android
# gets no shutdown. /data (F2FS) keeps a new or renamed file that was not
# synced only from its next checkpoint, which can be a minute away, so without
# this an app installed or a download finished shortly before the stop is gone
# at the next start.
sync_guest_disks() {
  local adb_serial="$1"

  host_adb "${GUEST_SYNC_PROBE_SEC}" -s "${adb_serial}" shell : >/dev/null 2>&1 || return 0
  host_adb "${IKA_STOP_GRACE_SEC}" -s "${adb_serial}" shell sync >/dev/null 2>&1 \
    || log "Android did not write its data to disk within ${IKA_STOP_GRACE_SEC}s; stopping anyway"
}

# Prints an epoch time in a date(1) format, with GNU or BSD date.
format_epoch() {
  date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2"
}

# Drops the lines of a log before line $2, or all of them when $2 is empty.
# The file is rewritten in place, so a process that keeps it open for
# appending goes on writing to it; lines written during the rewrite may be
# lost.
drop_log_lines_before() {
  local log_file="$1"
  local first_kept="$2"
  local kept

  [[ "${first_kept}" != "1" ]] || return 0
  if [[ -z "${first_kept}" ]]; then
    : > "${log_file}" || true
    return 0
  fi
  kept="$(mktemp "${log_file}.XXXXXX")" || return 0
  if tail -n "+${first_kept}" "${log_file}" > "${kept}"; then
    cat "${kept}" > "${log_file}" || true
  fi
  rm -f "${kept}"
}

# ikastart.log and madbfs.log keep this many of their last lines.
readonly LOG_MAX_LINES=1000

# Keeps the last LOG_MAX_LINES lines of a log.
trim_log_lines() {
  local log_file="$1"
  local line_count

  [[ -s "${log_file}" ]] || return 0
  line_count="$(wc -l <"${log_file}" 2>/dev/null || true)"
  line_count="${line_count//[[:space:]]/}"
  [[ "${line_count}" =~ ^[0-9]+$ ]] || return 0
  (( line_count > LOG_MAX_LINES )) || return 0
  drop_log_lines_before "${log_file}" "$(( line_count - LOG_MAX_LINES + 1 ))"
}

# Keeps the last 24 hours of the adb server's log. The server outlives VM
# restarts and never trims its log, which grows by about 1 MB a day from
# adb_connector's checks every 5 seconds; a running server keeps the file open
# for appending.
trim_adb_server_log() {
  local log_file="${ADB_SERVER_LOG}"
  local cutoff
  local first_kept

  [[ -s "${log_file}" ]] || return 0
  cutoff="$(( $(date +%s) - 86400 ))"
  # Lines start with "MM-DD HH:MM:SS.mmm", without the year: a line is recent
  # when it is from today, or from yesterday at or after the cutoff time.
  first_kept="$(awk -v yesterday="$(format_epoch "${cutoff}" '%m-%d')" \
      -v cutoff_time="$(format_epoch "${cutoff}" '%H:%M:%S')" \
      -v today="$(date +%m-%d)" '
    { day = substr($0, 1, 5) }
    day == today || (day == yesterday && substr($0, 7, 8) >= cutoff_time) {
      print NR
      exit
    }' "${log_file}" || true)"
  drop_log_lines_before "${log_file}" "${first_kept}"
}

adb_boot_completed() {
  local adb_serial="$1"
  local boot_completed

  # timeout guards against the dead-guest host proxy accepting the connection
  # and never answering, which would stall wait_for_boot's poll loop.
  boot_completed="$(host_adb 5 -s "${adb_serial}" shell getprop sys.boot_completed 2>/dev/null \
    | tr -d '\r' || true)"
  [[ "${boot_completed}" == "1" ]]
}

# True once Android has shown its first frame (SurfaceFlinger's
# sf_stop_bootanim event), seconds before sys.boot_completed on slow hosts.
adb_first_frame_shown() {
  local output

  output="$(host_adb 5 -s "$1" shell 'getprop sys.boot_completed; logcat -b events -d -m 1 -s sf_stop_bootanim' \
    2>/dev/null | tr -d '\r' || true)"
  [[ "${output}" == 1* || "${output}" == *sf_stop_bootanim* ]]
}

# Prints the mode Android booted in, tv or desktop, or nothing when the guest
# does not answer. Android's mode is switched by IkaMode's Desktop/TV entry
# and takes effect at boot, when TV mode adds the leanback feature.
guest_ui_mode() {
  local adb_serial="$1"
  local leanback

  leanback="$(guest_shell_query "${adb_serial}" "${GUEST_QUERY_LEANBACK}")"
  case "${leanback}" in
    true) printf 'tv\n' ;;
    false) printf 'desktop\n' ;;
  esac
  return 0
}

adb_guest_boot_id() {
  local adb_serial="$1"
  local boot_id

  boot_id="$(host_adb 5 -s "${adb_serial}" shell cat /proc/sys/kernel/random/boot_id 2>/dev/null \
    | tr -d '\r' || true)"
  [[ "${boot_id}" =~ ^[0-9a-fA-F-]{36}$ ]] || return 1
  printf '%s\n' "${boot_id}"
}

read_scrcpy_window_state() {
  local state_file="$1"
  local -n width_ref="$2"
  local -n height_ref="$3"
  local -n fullscreen_ref="$4"
  local key
  local value
  local version=""
  local width=""
  local height=""
  local fullscreen=""

  [[ -f "${state_file}" ]] || return 1
  while IFS='=' read -r key value; do
    case "${key}" in
      version) version="${value}" ;;
      width) width="${value}" ;;
      height) height="${value}" ;;
      fullscreen) fullscreen="${value}" ;;
    esac
  done < "${state_file}"

  [[ "${version}" == "1" ]] || return 1
  [[ "${width}" =~ ^[1-9][0-9]*$ && "${width}" -le 65535 ]] || return 1
  [[ "${height}" =~ ^[1-9][0-9]*$ && "${height}" -le 65535 ]] || return 1
  [[ "${fullscreen}" == "true" || "${fullscreen}" == "false" ]] || return 1

  width_ref="${width}"
  height_ref="${height}"
  fullscreen_ref="${fullscreen}"
}

# The window state file of the console of MODE, desktop or tv.
mode_console_window_state_file() {
  case "$1" in
    tv) printf '%s\n' "${TV_CONSOLE_WINDOW_STATE_FILE}" ;;
    *) printf '%s\n' "${DESKTOP_CONSOLE_WINDOW_STATE_FILE}" ;;
  esac
}

# Sets the array named by $1 to the options of the 'ika start' that opens the
# console after Android restarted in MODE ($2): --fullscreen when that mode's
# console was last used fullscreen, so that a mode switch brings each console
# back as it was. Its size comes from the same file when the console starts.
console_switch_start_options() {
  local -n options_ref="$1"
  local mode="$2"
  local saved_width=""
  local saved_height=""
  local saved_fullscreen=""

  options_ref=()
  if read_scrcpy_window_state "$(mode_console_window_state_file "${mode}")" \
      saved_width saved_height saved_fullscreen \
      && [[ "${saved_fullscreen}" == "true" ]]; then
    options_ref+=(--fullscreen)
  fi
}

wait_for_guest_reboot() {
  local adb_serial="$1"
  local previous_boot_id="$2"
  local timeout_sec="$3"
  local deadline
  local current_boot_id

  deadline=$((SECONDS + timeout_sec))
  while (( SECONDS < deadline )); do
    has_live_cvd_processes || return 1
    current_boot_id="$(adb_guest_boot_id "${adb_serial}" || true)"
    # An adb reconnect alone can be transient. A new kernel boot ID followed
    # by Android boot completion proves that this was an actual guest reboot.
    if [[ -n "${current_boot_id}" \
        && "${current_boot_id}" != "${previous_boot_id}" ]] \
        && adb_boot_completed "${adb_serial}"; then
      printf '%s\n' "${current_boot_id}"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# Windows' PowerShell, through WSL's interop; fails without it
windows_powershell() {
  local powershell

  powershell="$(command -v powershell.exe || true)"
  [[ -n "${powershell}" ]] || powershell="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  [[ -x "${powershell}" ]] || return 1
  printf '%s\n' "${powershell}"
}

# Each wsl.exe session has an interop socket of its own, which WSL_INTEROP
# names and which stops answering when that session ends: PowerShell started
# through it waits 10 seconds and gives up. A job in the background outlives
# the command from Windows that started Ika, and Android's storage is mounted
# 20 or 30 seconds after "ika start" returns, so by then "Android (Ika)" could
# not be added to Explorer. A distribution with systemd also has a socket for
# the whole VM, which lasts as long as the VM does; the job's Windows programs
# go through it, in the subshell that calls this, where it is no other
# process's business. Without that socket the session's own stays.
WSL_SYSTEM_INTEROP="/run/WSL/1_interop"
use_system_wsl_interop() {
  [[ -S "${WSL_SYSTEM_INTEROP}" ]] || return 0
  export WSL_INTEROP="${WSL_SYSTEM_INTEROP}"
}

# Readies a job left running in the background, which outlives its caller. It
# ignores the hangup that ends the processes of a command started from Windows
# (from the Start menu or the task bar, by wslg.exe, or in a Windows terminal)
# when the command ends: "ika stop" from there ended before PowerShell had
# removed Android's storage from Explorer, and "ika start" before Android's
# storage was mounted. It starts Windows programs through WSL's own interop
# socket (see use_system_wsl_interop). And it closes the files it
# inherited, but standard input, output and error and the descriptors given:
# a console supervisor's lock, held on after it exits, made the next console
# find another supervisor active and not open.
detach_background_job() {
  local fd

  trap '' HUP
  use_system_wsl_interop
  for fd in /proc/"${BASHPID}"/fd/*; do
    fd="${fd##*/}"
    if (( fd > 2 )) && [[ " $* " != *" ${fd} "* ]]; then
      { exec {fd}>&-; } 2>/dev/null || true
    fi
  done
}

