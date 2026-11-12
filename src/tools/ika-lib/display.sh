# ika: launch messages, display density, the host display's size and refresh rate, low-CPU mode, ARM64 page sizes.
# Sourced by src/tools/ika, in its order; see there.

shell_join() {
  local joined
  printf -v joined '%q ' "$@"
  printf '%s' "${joined% }"
}

latest_launcher_log_message() {
  local launcher_log="$1"
  local min_mtime="$2"
  local pattern="$3"
  local log_mtime

  [[ -f "${launcher_log}" ]] || return 1

  log_mtime="$(stat -c '%Y' "${launcher_log}" 2>/dev/null || echo 0)"
  [[ "${log_mtime}" -ge "${min_mtime}" ]] || return 1

  grep -F "${pattern}" "${launcher_log}" | tail -n 1 || true
}

# How the console's frames travel from crosvm, from ika_stream's latest log
# line about it: as DMA-BUFs (no copy), or as pixels read back by crosvm (the
# costly path, three copies per frame). Silent before the first frame.
respond_console_frame_path() {
  local line

  line="$(latest_launcher_log_message "${CVD_LAUNCHER_LOG}" 0 "frames arrive as")" || return 0
  [[ -n "${line}" ]] || return 0
  case "${line}" in
    *"frames arrive as DMA-BUFs"*)
      respond "Console frames: DMA-BUFs (${line##*"frames arrive as DMA-BUFs: "})"
      ;;
    *"frames arrive as pixels"*)
      respond "Console frames: pixels read back by crosvm (${line##*"read back by crosvm: "})"
      ;;
  esac
}

maybe_respond_crosvm_command() {
  local launcher_log="$1"
  local min_mtime="$2"
  local line
  local command

  line="$(latest_launcher_log_message "${launcher_log}" "${min_mtime}" "crosvm launch command:")"
  [[ -n "${line}" ]] || return 1

  command="${line#*"crosvm launch command: "}"
  respond "[${SCRIPT_NAME}] crosvm launch command: ${command}"
  return 0
}

emit_launch_command() {
  local launch_command
  local -a env_args=(env)

  append_cvd_env_args env_args

  launch_command="$(
    shell_join \
      "${env_args[@]}" \
      "${CVD_BIN}" \
      "$@"
  )"

  log "launch command: cd $(printf '%q' "${CVD_PRODUCT_OUT}") && ${launch_command}"
}

# resolve_scrcpy_dpi [DPI]: DPI when given, else IKADPI, else auto_scrcpy_dpi.
resolve_scrcpy_dpi() {
  local explicit_dpi="${1:-}"

  if [[ -n "${explicit_dpi}" ]]; then
    printf '%s\n' "${explicit_dpi}"
    return 0
  fi

  if [[ "${IKADPI:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${IKADPI}"
    return 0
  fi

  auto_scrcpy_dpi
}

# resolve_tv_dpi: the console's density in Android's TV mode, IKA_TV_DPI when it
# is a number, else 1.5 times auto_scrcpy_dpi, so that the TV interface is
# larger than the desktop.
resolve_tv_dpi() {
  local dpi

  if [[ "${IKA_TV_DPI:-}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "${IKA_TV_DPI}"
    return 0
  fi

  dpi="$(auto_scrcpy_dpi)"
  printf '%s\n' "$(( dpi * 3 / 2 / 8 * 8 ))"
}

# auto_scrcpy_dpi: a density from the host display's width.
auto_scrcpy_dpi() {
  local size
  local width
  local dpi

  size="$(host_display_size || true)"
  if [[ ! "${size}" =~ ^([0-9]+)x[0-9]+$ ]]; then
    log "could not determine host display width; defaulting to 144 DPI"
    printf '%s\n' 144
    return 0
  fi

  # Heuristic: DPI = (native display width / 10)
  width="${BASH_REMATCH[1]}"
  dpi=$(( width / 10 - 24 ))
  dpi=$(( dpi / 8 * 8 ))
  if (( dpi < 96 )); then
    dpi=96
  fi

  printf '%s\n' "${dpi}"
}

split_start_args() {
  local -n args_array="$1"
  local -n scrcpy_dpi_ref="$2"
  shift 2
  local dpi_user_supplied="false"

  scrcpy_dpi_ref=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dpi=*)
        scrcpy_dpi_ref="${1#*=}"
        dpi_user_supplied="true"
        args_array+=("$1")
        shift
        ;;
      --dpi)
        args_array+=("$1")
        shift
        [[ $# -gt 0 ]] || die "--dpi requires a value"
        scrcpy_dpi_ref="$1"
        dpi_user_supplied="true"
        args_array+=("$1")
        shift
        ;;
      *)
        args_array+=("$1")
        shift
        ;;
    esac
  done

  scrcpy_dpi_ref="$(resolve_scrcpy_dpi "${scrcpy_dpi_ref}")"
  SCRCPY_DPI_GIVEN="${dpi_user_supplied}"
  if [[ "${dpi_user_supplied}" != "true" ]]; then
    args_array+=("--dpi=${scrcpy_dpi_ref}")
  fi
}

# Largest enabled, connected DRM connector's preferred (native) mode as WxH,
# read from sysfs. Used when wayland-info finds nothing, e.g. in an X11 session.
drm_display_size() {
  local connector
  local mode
  local width
  local height
  local best_area=0
  local best=""

  for connector in /sys/class/drm/card*-*; do
    [[ "$(cat "${connector}/status" 2>/dev/null)" == "connected" ]] || continue
    [[ "$(cat "${connector}/enabled" 2>/dev/null)" == "enabled" ]] || continue
    mode="$(head -n 1 "${connector}/modes" 2>/dev/null || true)"
    [[ "${mode}" =~ ^([0-9]+)x([0-9]+) ]] || continue
    width="${BASH_REMATCH[1]}"
    height="${BASH_REMATCH[2]}"
    if (( width * height > best_area )); then
      best_area=$(( width * height ))
      best="${width}x${height}"
    fi
  done

  [[ -n "${best}" ]] || return 0
  printf '%s\n' "${best}"
}

# wayland-info's output, read at most once per run: spawning it costs some
# 30 ms, and the three host display probes below each want it, some from
# subshells, which share the output read before them but not one of their own.
# In a Wayland session it is read again, for up to 2 seconds, until an output
# has a current mode: a compositor still starting has none yet.
_wayland_info_probed=""
_wayland_info_output=""
wayland_info_output() {
  local attempt

  if [[ -z "${_wayland_info_probed}" ]]; then
    _wayland_info_probed="yes"
    if command -v wayland-info >/dev/null 2>&1; then
      for (( attempt = 0; attempt < 8; ++attempt )); do
        _wayland_info_output="$(wayland-info 2>/dev/null || true)"
        [[ -n "${WAYLAND_DISPLAY:-}" ]] || break
        grep -q 'flags:.*current' <<<"${_wayland_info_output}" && break
        sleep 0.25
      done
    fi
  fi
  [[ -n "${_wayland_info_output}" ]] || return 1
  printf '%s\n' "${_wayland_info_output}"
}

# Largest "current" Wayland output mode as WxH, falling back to the DRM
# connectors in sysfs, then to the size found last in HOST_DISPLAY_SIZE_FILE
# (monitors asleep report none, and some hosts' DRM connectors are not the
# outputs). Probed at most once per run and cached: a single start queries it
# more than once (DPI heuristic + display ceiling).
_host_display_size_probed=""
_host_display_size_value=""
host_display_size() {
  if [[ -z "${_host_display_size_probed}" ]]; then
    _host_display_size_probed="yes"
    if wayland_info_output >/dev/null; then
      _host_display_size_value="$(
        wayland_info_output | awk '
          /mode:/ { in_mode = 1; width = 0; height = 0; next }
          in_mode && /width:/ {
            w = $0; sub(/.*width:[[:space:]]*/, "", w);  width  = int(w)
            h = $0; sub(/.*height:[[:space:]]*/, "", h); height = int(h)
          }
          in_mode && /flags:/ {
            if (/current/ && width && height) {
              area = width * height
              if (area > best_area) {
                best_area = area; best_width = width; best_height = height
              }
            }
            in_mode = 0
          }
          END { if (best_width && best_height) printf "%sx%s\n", best_width, best_height }
        ' || true
      )"
    fi
    if [[ -z "${_host_display_size_value}" ]]; then
      _host_display_size_value="$(drm_display_size)"
    fi
    if [[ -n "${_host_display_size_value}" ]]; then
      if [[ "$(cat "${HOST_DISPLAY_SIZE_FILE}" 2>/dev/null)" != "${_host_display_size_value}" ]]; then
        printf '%s\n' "${_host_display_size_value}" >"${HOST_DISPLAY_SIZE_FILE}" 2>/dev/null || true
      fi
    else
      _host_display_size_value="$(cat "${HOST_DISPLAY_SIZE_FILE}" 2>/dev/null || true)"
      if [[ "${_host_display_size_value}" =~ ^[0-9]+x[0-9]+$ ]]; then
        log "no host display found; using the size it had last, ${_host_display_size_value}"
      else
        _host_display_size_value=""
      fi
    fi
  fi

  [[ -n "${_host_display_size_value}" ]] || return 1
  printf '%s\n' "${_host_display_size_value}"
}

# The refresh rate of the host display host_display_size picks (the largest
# current Wayland output mode), in whole Hz. Probed once per run and cached.
_host_display_refresh_hz_probed=""
_host_display_refresh_hz_value=""
host_display_refresh_hz() {
  if [[ -z "${_host_display_refresh_hz_probed}" ]]; then
    _host_display_refresh_hz_probed="yes"
    if wayland_info_output >/dev/null; then
      _host_display_refresh_hz_value="$(
        wayland_info_output | awk '
          /mode:/ { in_mode = 1; width = 0; height = 0; refresh = 0; next }
          in_mode && /width:/ {
            w = $0; sub(/.*width:[[:space:]]*/, "", w);  width  = int(w)
            h = $0; sub(/.*height:[[:space:]]*/, "", h); height = int(h)
            r = $0; sub(/.*refresh:[[:space:]]*/, "", r); refresh = r + 0
          }
          in_mode && /flags:/ {
            if (/current/ && width && height && refresh > 0) {
              area = width * height
              if (area > best_area) {
                best_area = area; best_refresh = refresh
              }
            }
            in_mode = 0
          }
          END { if (best_refresh > 0) printf "%d\n", int(best_refresh + 0.5) }
        ' || true
      )"
    fi
  fi

  [[ "${_host_display_refresh_hz_value}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "${_host_display_refresh_hz_value}"
}

# The refresh rate of the Cuttlefish display outside low-CPU mode, from
# IKA_REFRESH_RATE_HZ (console.refresh_rate_hz in ika.ini): a number as given,
# auto the host display's, 60 when that cannot be read. Prints "RATE SOURCE".
resolve_display_refresh_hz() {
  local setting="${IKA_REFRESH_RATE_HZ:-auto}"
  local host_hz

  if [[ "${setting}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s %s\n' "${setting}" "set by refresh_rate_hz"
    return 0
  fi
  if [[ "${setting}" != "auto" ]]; then
    log "refresh_rate_hz must be auto or a positive whole number, not '${setting}'; using auto"
  fi
  if host_hz="$(host_display_refresh_hz)"; then
    printf '%s %s\n' "${host_hz}" "the host display's"
  else
    printf '%s %s\n' 60 "the default, the host display's rate is unknown"
  fi
}

# WSLg presents to Windows at a rate of its own, 60 Hz unless its
# configuration says otherwise, and its Weston output reports that rate, so
# with refresh_rate_hz = auto Android ran at 60 Hz on a 144 Hz panel.
# sync_wslg_refresh_rate keeps WESTON_RDP_MONITOR_REFRESH_RATE in the Windows
# user's .wslgconfig at Ika's rate: refresh_rate_hz as set, or with auto the
# slowest refresh rate among Windows' displays (Microsoft's advice: the
# Windows compositor's clock), at most WSLg's ceiling of 144. WSLg reads the
# file when WSL starts, so a new rate shows after "wsl --shutdown"; until then
# Android follows the rate WSLg presents at. It runs in the background at
# start, and does nothing outside WSLg or when Windows cannot be asked.
WSLG_MAX_REFRESH_HZ=144
WSLG_DEFAULT_REFRESH_HZ=60

# The rate for WSLg from refresh_rate_hz and the Windows displays' slowest rate
# (empty when unknown), or nothing when neither gives one.
wslg_wanted_refresh_hz() {
  local setting="$1"
  local windows_hz="$2"
  local hz

  if [[ "${setting}" =~ ^[1-9][0-9]*$ ]]; then
    hz="${setting}"
  elif [[ "${windows_hz}" =~ ^[1-9][0-9]*$ ]]; then
    hz="${windows_hz}"
  else
    return 1
  fi
  (( hz <= WSLG_MAX_REFRESH_HZ )) || hz="${WSLG_MAX_REFRESH_HZ}"
  printf '%s\n' "${hz}"
}

# Prints the .wslgconfig on standard input with WESTON_RDP_MONITOR_REFRESH_RATE
# in [system-distro-env] set to the rate given, adding the section or the key
# where missing and leaving every other line as it was. Lines end in CRLF, as
# a file Windows' editors write.
wslgconfig_with_refresh_rate() {
  local hz="$1"

  awk -v key="WESTON_RDP_MONITOR_REFRESH_RATE" -v hz="${hz}" '
    { sub(/\r$/, "") }
    /^[ \t]*\[/ {
      if (in_section && !done) { print key "=" hz; done = 1 }
      in_section = (tolower($0) ~ /^[ \t]*\[system-distro-env\][ \t]*$/)
      print; next
    }
    in_section && $0 ~ ("^[ \t]*" key "[ \t]*=") {
      if (!done) { print key "=" hz; done = 1 }
      next
    }
    { print }
    END {
      if (!done) {
        if (!in_section) { if (NR > 0) print ""; print "[system-distro-env]" }
        print key "=" hz
      }
    }' | sed 's/$/\r/'
}

# Prints the Windows user's profile folder and the slowest refresh rate among
# Windows' displays, one a line, the rate empty when Windows gives none.
wslg_refresh_probe_script() {
  cat <<'EOF'
$rate = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
  Where-Object { $_.CurrentRefreshRate -gt 1 } |
  Measure-Object -Property CurrentRefreshRate -Minimum).Minimum
$env:USERPROFILE
"$rate"
EOF
}

sync_wslg_refresh_rate() {
  local powershell

  [[ "${IKA_ON_WSLG}" == true ]] || return 0
  powershell="$(windows_powershell)" || return 0
  mkdir -p "${CVD_TMP_DIR}"
  (
    detach_background_job 9
    flock -n 9 || exit 0
    local probe profile windows_hz wanted file current new presented
    probe="$(with_timeout 30 "${powershell}" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -EncodedCommand "$(wslg_refresh_probe_script | iconv -t UTF-16LE | base64 -w 0)" \
      </dev/null 2>/dev/null | tr -d '\r')" || exit 0
    profile="$(sed -n 1p <<<"${probe}")"
    windows_hz="$(sed -n 2p <<<"${probe}")"
    wanted="$(wslg_wanted_refresh_hz "${IKA_REFRESH_RATE_HZ:-auto}" "${windows_hz}")" || exit 0
    [[ -n "${profile}" ]] || exit 0
    file="$(wslpath -u "${profile}" 2>/dev/null)/.wslgconfig" || exit 0
    [[ -d "${file%/*}" ]] || exit 0
    if [[ -f "${file}" ]]; then
      current="$(cat "${file}")"
    elif (( wanted == WSLG_DEFAULT_REFRESH_HZ )); then
      exit 0
    else
      current=""
    fi
    new="$(printf '%s' "${current}" | wslgconfig_with_refresh_rate "${wanted}")"
    if [[ "${new}" != "${current}" ]]; then
      printf '%s\n' "${new}" > "${file}.ika-tmp" && mv -f "${file}.ika-tmp" "${file}" || exit 0
      log "WSLg: WESTON_RDP_MONITOR_REFRESH_RATE=${wanted} in ${profile}\\.wslgconfig"
    fi
    presented="$(host_display_refresh_hz || true)"
    if [[ -n "${presented}" && "${presented}" != "${wanted}" ]]; then
      log "WSLg presents at ${presented} Hz until WSL restarts (wsl --shutdown), then at ${wanted} Hz"
    fi
  ) 9>"${CVD_TMP_DIR}/wslg-refresh.lock" &
  disown "$!" 2>/dev/null || true
}

_host_display_logical_size_probed=""
_host_display_logical_size_value=""
host_display_logical_size() {
  if [[ -z "${_host_display_logical_size_probed}" ]]; then
    _host_display_logical_size_probed="yes"
    if wayland_info_output >/dev/null; then
      _host_display_logical_size_value="$(
        wayland_info_output | awk '
          /logical_width:/ {
            line = $0
            sub(/.*logical_width:[[:space:]]*/, "", line)
            split(line, width_parts, ",")
            width = int(width_parts[1])

            line = $0
            sub(/.*logical_height:[[:space:]]*/, "", line)
            height = int(line)

            if (width && height) {
              area = width * height
              if (area > best_area) {
                best_area = area; best_width = width; best_height = height
              }
            }
          }
          END { if (best_width && best_height) printf "%sx%s\n", best_width, best_height }
        ' || true
      )"
    fi
    # X11 has no output scaling, so the native size is the logical size.
    if [[ -z "${_host_display_logical_size_value}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
      _host_display_logical_size_value="$(host_display_size || true)"
    fi
  fi

  [[ -n "${_host_display_logical_size_value}" ]] || return 1
  printf '%s\n' "${_host_display_logical_size_value}"
}

default_scrcpy_window_size() {
  local size
  local width
  local height
  local host_width
  local host_height

  size="$(host_display_logical_size || true)"
  if [[ "${size}" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    host_width="${BASH_REMATCH[1]}"
    host_height="${BASH_REMATCH[2]}"
    width=$(( host_width * 85 / 100 ))
    height=$(( host_height * 85 / 100 ))
  else
    width=1280
    height=720
  fi

  printf '%sx%s\n' "${width}" "${height}"
}

has_display_size_override() {
  local flag

  for flag in display display0 display1 display2 display3 \
              displays_textproto displays_binproto x_res y_res; do
    if user_supplied_flag "${flag}" "$@"; then
      return 0
    fi
  done

  return 1
}

# Decides whether this start runs low-CPU mode, from IKA_LOWCPU (auto, on
# or off) and, for auto, the host: no hardware Vulkan driver, guest_swiftshader
# or guest_lavapipe, 2 vCPUs or fewer (4 or fewer under WSL), or less than
# 8 GB of host memory. Sets LOWCPU_MODE_ACTIVE and LOWCPU_MODE_REASON.
resolve_lowcpu_mode() {
  local mode
  local gpu_mode
  local cpus
  local cpu_limit=2
  local mem_mb
  local summary
  local reason=""

  [[ "${IKA_ON_WSLG}" != true ]] || cpu_limit=4
  mode="$(normalize_lowcpu_mode "${IKA_LOWCPU:-auto}")"
  case "${mode}" in
    on)
      reason="requested"
      ;;
    auto)
      gpu_mode="$(start_gpu_mode_value "$@")"
      cpus="$(start_arg_value "cpus" "${CVD_COMPUTE_DEFAULTS[cpus]}" "$@")"
      mem_mb="$(host_physical_memory_mb || true)"
      summary="$(vulkaninfo_summary || true)"
      if [[ "${gpu_mode}" == "guest_swiftshader" || "${gpu_mode}" == "guest_lavapipe" ]]; then
        reason="software rendering"
      elif [[ -n "${summary}" ]] && vulkan_summary_has_only_software_devices "${summary}"; then
        reason="no hardware Vulkan driver"
      elif [[ "${cpus}" =~ ^[0-9]+$ ]] && (( cpus <= cpu_limit )); then
        reason="$(count_noun "${cpus}" vCPU vCPUs)"
      elif [[ "${mem_mb}" =~ ^[0-9]+$ ]] && (( mem_mb > 0 && mem_mb < 8192 )); then
        reason="${mem_mb} MB of host memory"
      fi
      ;;
  esac

  LOWCPU_MODE_REASON="${reason}"
  if [[ -n "${reason}" ]]; then
    LOWCPU_MODE_ACTIVE="true"
    log "low-CPU mode: on (${reason})"
  else
    LOWCPU_MODE_ACTIVE="false"
  fi
}

append_default_display_arg() {
  local -n args_array="$1"
  local dpi="$2"
  shift 2
  local size
  local width
  local height
  local refresh_rate_hz=60
  local refresh_source="low-CPU mode's"

  if has_display_size_override "$@"; then
    return 0
  fi

  size="$(host_display_size || true)"
  if [[ ! "${size}" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    log "could not determine host display size; leaving Cuttlefish display defaults unchanged"
    return 0
  fi

  width="${BASH_REMATCH[1]}"
  height="${BASH_REMATCH[2]}"

  if [[ "${LOWCPU_MODE_ACTIVE}" == "true" ]]; then
    refresh_rate_hz="${IKA_LOWCPU_REFRESH_RATE_HZ}"
  else
    read -r refresh_rate_hz refresh_source < <(resolve_display_refresh_hz)
  fi

  args_array+=("--display=width=${width},height=${height},dpi=${dpi},refresh_rate_hz=${refresh_rate_hz}")
  log "display ceiling: ${width}x${height}/${dpi} at ${refresh_rate_hz} Hz (${refresh_source})"
}

host_is_apple_silicon() {
  host_is_arm64 || return 1

  [[ -r /proc/device-tree/compatible ]] || return 1
  tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null | grep -q '^apple,'
}

is_apple_silicon_16k_host() {
  local page_size

  host_is_apple_silicon || return 1

  page_size="$(getconf PAGESIZE 2>/dev/null || echo 0)"
  [[ "${page_size}" =~ ^[0-9]+$ ]] || return 1
  (( page_size > 4096 ))
}

host_is_arm64() {
  local arch
  arch="$(uname -m 2>/dev/null || true)"
  [[ "${arch}" == "aarch64" || "${arch}" == "arm64" ]]
}

host_page_size() {
  local page_size
  page_size="$(getconf PAGESIZE 2>/dev/null || true)"
  if [[ ! "${page_size}" =~ ^[0-9]+$ ]]; then
    page_size=0
  fi
  printf '%s\n' "${page_size}"
}

normalize_kernel_page_size_mode() {
  local mode="${1:-auto}"
  mode="${mode,,}"

  case "${mode}" in
    ""|auto)
      printf '%s\n' "auto"
      ;;
    4|4k|4096)
      printf '%s\n' "4k"
      ;;
    16|16k|16384)
      printf '%s\n' "16k"
      ;;
    *)
      die "invalid IKA_KERNEL_PAGE_SIZE='${1}' (expected auto, 4k, or 16k)"
      ;;
  esac
}

arm64_kernel_page_size() {
  local mode
  local page_size

  host_is_arm64 || return 1

  mode="$(normalize_kernel_page_size_mode "${IKA_KERNEL_PAGE_SIZE:-auto}")"
  case "${mode}" in
    4k|16k)
      printf '%s\n' "${mode}"
      ;;
    auto)
      page_size="$(host_page_size)"
      if (( page_size > 4096 )); then
        printf '%s\n' "16k"
      else
        printf '%s\n' "4k"
      fi
      ;;
  esac
}

cvd_product_out_has_arm64_16k_artifacts() {
  [[ -s "${CVD_PRODUCT_OUT}/boot_16k.img" || -s "${CVD_PRODUCT_OUT}/kernel_16k" ]]
}

append_arm64_kernel_page_args() {
  local -n args_array="$1"
  shift
  local selected_page_size
  local page_size
  local boot_16k

  host_is_arm64 || return 0
  cvd_product_out_has_arm64_16k_artifacts || return 0

  if user_supplied_flag "use_16k" "$@" \
      || user_supplied_flag "boot_image" "$@" \
      || user_supplied_flag "kernel_path" "$@" \
      || user_supplied_flag "initramfs_path" "$@" \
      || user_supplied_flag "vendor_boot_image" "$@"; then
    log "arm64 kernel page-size auto-selection skipped because boot/kernel args were supplied"
    return 0
  fi

  selected_page_size="$(arm64_kernel_page_size)"
  page_size="$(host_page_size)"

  case "${selected_page_size}" in
    16k)
      boot_16k="${CVD_PRODUCT_OUT}/boot_16k.img"
      [[ -s "${boot_16k}" ]] || \
        die "ARM64 host page size is ${page_size} bytes, but ${boot_16k} is missing"

      args_array+=("--boot_image=${boot_16k}")
      log "arm64 kernel page-size: ${page_size} byte host pages -> boot_16k.img"
      ;;
    4k)
      log "arm64 kernel page-size: ${page_size} byte host pages -> boot.img"
      ;;
  esac
}

