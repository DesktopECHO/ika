# ika: host camera passthrough and hardware video decoding.
# Sourced by src/tools/ika, in its order; see there.

# ============================================================================
# Host camera passthrough (--camera)
# ============================================================================
#
# '--camera' passes a host V4L2 camera to the guest with crosvm virtio-media
# (cvd --media=v4l2_proxy:device=...). The guest's external camera HAL
# serves it as the front camera. Without a value, the first video capture
# device offering MJPEG, NV12 or YUYV is used: USB (UVC) webcams, the FaceTime
# camera of Apple Silicon Macs (Asahi apple-isp) and of older Intel Macs
# (facetimehd). Virtual cameras (v4l2loopback and vivid) are used only when
# there is no other.

# True when DEVICE is a camera the guest can use: a video capture node offering
# MJPEG, NV12 or YUYV. Without v4l2-ctl, accepts the first node of each device
# (sysfs index 0), as UVC cameras add metadata nodes after their capture node.
is_usable_camera_device() {
  local device="$1"
  local info
  local caps
  local formats

  if ! command -v v4l2-ctl >/dev/null 2>&1; then
    [[ "$(cat "/sys/class/video4linux/${device##*/}/index" 2>/dev/null)" == "0" ]]
    return
  fi

  info="$(v4l2-ctl -d "${device}" --info 2>/dev/null)" || return 1
  caps="$(awk '/Device Caps/ { print $NF; exit }' <<<"${info}")"
  [[ "${caps}" =~ ^0x[0-9a-fA-F]+$ ]] || return 1
  # V4L2_CAP_VIDEO_CAPTURE
  (( caps & 0x1 )) || return 1
  formats="$(v4l2-ctl -d "${device}" --list-formats 2>/dev/null)" || return 1
  [[ "${formats}" =~ \'(MJPG|NV12|YUYV)\' ]]
}

# Prints the V4L2 driver name of DEVICE (e.g. "uvcvideo", "v4l2 loopback").
camera_v4l2_driver() {
  v4l2-ctl -d "$1" --info 2>/dev/null \
    | sed -n 's/^[[:space:]]*Driver name[[:space:]]*:[[:space:]]*//p' | head -n 1
}

# True when DEVICE is a virtual camera: v4l2loopback or the vivid test driver.
# These have no parent device in sysfs.
is_virtual_camera_device() {
  local device="$1"

  case "$(camera_v4l2_driver "${device}")" in
    "v4l2 loopback"|vivid) return 0 ;;
  esac
  [[ ! -e "/sys/class/video4linux/${device##*/}/device" ]]
}

# Prints the host's video nodes as /dev/videoN, in number order.
list_video_devices() {
  local node

  while IFS= read -r node; do
    [[ -c "/dev/${node}" ]] && printf '/dev/%s\n' "${node}"
  done < <(find /sys/class/video4linux -maxdepth 1 -name 'video*' -printf '%f\n' 2>/dev/null | sort -V)
}

# Prints the first usable host camera in /dev/videoN order, preferring a
# physical camera over a virtual one.
detect_host_camera() {
  local device
  local virtual=""

  while IFS= read -r device; do
    is_usable_camera_device "${device}" || continue
    if ! is_virtual_camera_device "${device}"; then
      printf '%s\n' "${device}"
      return 0
    fi
    [[ -n "${virtual}" ]] || virtual="${device}"
  done < <(list_video_devices)
  [[ -n "${virtual}" ]] || return 1
  printf '%s\n' "${virtual}"
}

# Prints the camera of ika.ini to pass at start (camera.device, IKA_CAMERA),
# as resolve_camera_device does: none for off, the first usable camera for
# auto, else the one named. A camera that is missing, or that Ika cannot
# open, is logged and left out, and so is any while start keeps a running VM,
# which cannot take one; Ika then starts without a camera.
ini_camera_device() {
  local setting="${IKA_CAMERA:-off}"
  local device

  case "${setting,,}" in
    ""|off|false|no|0|none)
      return 1
      ;;
  esac
  if [[ "${START_KEEPS_RUNNING_VM}" == "true" ]] && has_live_cvd_processes; then
    return 1
  fi
  case "${setting,,}" in
    auto|on|true|yes|1)
      if ! device="$(detect_host_camera)"; then
        log "camera.device = ${setting}: no usable camera found; starting without one"
        return 1
      fi
      ;;
    *)
      if [[ ! "${setting}" =~ ^(/dev/)?video[0-9]+$ ]]; then
        log "camera.device must be off, auto or videoN, not '${setting}'; starting without a camera"
        return 1
      fi
      device="/dev/${setting#/dev/}"
      if [[ ! -c "${device}" ]]; then
        log "camera ${device} (camera.device) does not exist; starting without a camera"
        return 1
      fi
      ;;
  esac
  if [[ ! -r "${device}" || ! -w "${device}" ]]; then
    log "no access to camera ${device} (camera.device); add your user to the video group and log in again; starting without a camera"
    return 1
  fi
  resolve_camera_device "${device}"
}

# Prints the host camera for --camera: "auto" (or empty) detects one,
# "videoN" or "/dev/videoN" names one.
resolve_camera_device() {
  local requested="${1:-auto}"
  local device

  case "${requested}" in
    auto)
      device="$(detect_host_camera)" \
        || die_with_notification "No usable camera found." \
          "no usable camera found (a video capture device offering MJPEG, NV12 or YUYV); name one with --camera=videoN"
      ;;
    *)
      [[ "${requested}" =~ ^(/dev/)?video[0-9]+$ ]] \
        || die "--camera expects videoN or /dev/videoN, got '${requested}'"
      device="/dev/${requested#/dev/}"
      [[ -c "${device}" ]] || die "camera ${device} does not exist"
      is_usable_camera_device "${device}" \
        || log "warning: ${device} does not look like a camera (a video capture device offering MJPEG, NV12 or YUYV); Android may show none"
      ;;
  esac

  [[ -r "${device}" && -w "${device}" ]] \
    || die "no access to camera ${device}; add your user to the video group and log in again"
  printf '%s\n' "${device}"
}

# Prints what the start log says of camera DEVICE: its driver and name.
camera_description() {
  local device="$1"
  local sysfs
  local name
  local driver

  sysfs="/sys/class/video4linux/${device##*/}"
  name="$(cat "${sysfs}/name" 2>/dev/null || true)"
  # uvcvideo names nodes "PRODUCT: ENTITY" (cut at 31 characters); keep PRODUCT
  name="${name%: *}"
  driver="$(readlink -f "${sysfs}/device/driver" 2>/dev/null || true)"
  driver="${driver##*/}"
  # Virtual cameras have no parent device in sysfs
  [[ -n "${driver}" ]] || driver="$(camera_v4l2_driver "${device}")"
  # The Asahi driver names the Apple Silicon FaceTime HD camera after itself
  [[ "${driver}" == "apple-isp" ]] && name="FaceTime HD Camera (Built-in)"
  printf 'camera%s: %s%s\n' "${driver:+ ${driver}}" "${name:+${name} at }" "${device}"
}

normalize_camera_power_line_frequency() {
  case "${1,,}" in
    ""|auto) echo "auto" ;;
    50|50hz) echo "50" ;;
    60|60hz) echo "60" ;;
    0|off|no|false|disable|disabled) echo "off" ;;
    *) die "invalid camera power line frequency '${1}' (expected auto, 50, 60 or off)" ;;
  esac
}

# Prints the ISO 3166 code of the country of timezone ZONE, from tzdata.
timezone_country() {
  awk -v zone="$1" '!/^#/ && $3 == zone { print $1; exit }' \
    "${IKA_ZONE_TAB:-/usr/share/zoneinfo/zone.tab}" 2>/dev/null
}

# Prints the mains frequency of COUNTRY, 50 or 60, or nothing where it differs
# within the country (Japan, French Polynesia) or the country is unknown.
country_mains_frequency() {
  case "$1" in
    "") ;;
    JP|PF) ;;
    AG|AI|AS|AW|BM|BR|BS|BZ|CA|CO|CR|CU|DO|EC|FM|GT|GU|GY|HN|HT|KN|KR|KY|LR|MF|MS|MX|NI|PA|PE|PH|PR|PW|SA|SR|SV|SX|TT|TW|US|VE|VG|VI)
      echo "60" ;;
    *) echo "50" ;;
  esac
}

# Sets the anti-flicker (power line frequency) control of camera DEVICE to the
# mains frequency of the host's lights: IKA_CAMERA_POWER_LINE_FREQUENCY, or with
# "auto" that of the country of the host's timezone (the one Android gets).
# Lights flicker at twice the mains frequency; set for the wrong one, a camera
# shows bands, and in dim light it can lower its frame rate further than needed
# (a 2011 MacBook Pro camera: 14 fps at 50 Hz, 17 fps at 60 Hz, in the same
# room). Nothing in Android sets the control, and it stays set until the camera
# is reset.
apply_camera_power_line_frequency() {
  local device="$1"
  local mode
  local hz
  local reason=""
  local zone
  local country
  local value
  local label

  mode="$(normalize_camera_power_line_frequency "${IKA_CAMERA_POWER_LINE_FREQUENCY}")"
  command -v v4l2-ctl >/dev/null 2>&1 || return 0
  if ! v4l2-ctl -d "${device}" --list-ctrls 2>/dev/null | grep -qw power_line_frequency; then
    log_start_note "camera anti-flicker: the camera has no such control"
    return 0
  fi

  case "${mode}" in
    auto)
      zone="$(host_timezone)"
      country="$(timezone_country "${zone}")"
      hz="$(country_mains_frequency "${country}")"
      if [[ -z "${hz}" ]]; then
        log_start_note "camera anti-flicker: left as the camera has it (no single mains frequency for timezone '${zone:-unknown}'); set camera.power_line_frequency in ${IKA_INI_FILE}"
        return 0
      fi
      reason=" (timezone ${zone})"
      ;;
    off) hz="" ;;
    *) hz="${mode}" ;;
  esac

  # V4L2_CID_POWER_LINE_FREQUENCY: 0 disabled, 1 50 Hz, 2 60 Hz
  case "${hz}" in
    50) value=1; label="50 Hz" ;;
    60) value=2; label="60 Hz" ;;
    *) value=0; label="off" ;;
  esac
  if v4l2-ctl -d "${device}" -c "power_line_frequency=${value}" 2>/dev/null; then
    log_start_note "camera anti-flicker: ${label}${reason}"
  else
    log "warning: could not set the anti-flicker of camera ${device} to ${label}"
  fi
}

# Prints the VA-API driver names libva would try for the GPU behind render
# node NODE, from its kernel driver. Prints nothing for a GPU without VA-API
# video decoding.
vaapi_driver_names() {
  local node="$1"
  local kernel_driver

  kernel_driver="$(readlink -f "/sys/class/drm/$(basename "${node}")/device/driver" 2>/dev/null)"
  case "$(basename "${kernel_driver}")" in
    i915) printf '%s\n' iHD i965 ;;
    xe) printf '%s\n' iHD ;;
    amdgpu) printf '%s\n' radeonsi ;;
    radeon) printf '%s\n' radeonsi r600 ;;
    nouveau) printf '%s\n' nouveau ;;
  esac
}

# True when one of the VA-API drivers named on stdin is installed where libva
# looks for it (LIBVA_DRIVERS_PATH, or the distribution's driver directories).
vaapi_driver_installed() {
  local name
  local dir
  local -a dirs=()

  if [[ -n "${LIBVA_DRIVERS_PATH:-}" ]]; then
    IFS=: read -r -a dirs <<<"${LIBVA_DRIVERS_PATH}"
  else
    dirs=(/usr/lib64/dri /usr/lib64/dri-freeworld /usr/lib64/dri-nonfree
      "/usr/lib/$(uname -m)-linux-gnu/dri" /usr/lib/dri)
  fi
  while IFS= read -r name; do
    for dir in "${dirs[@]}"; do
      [[ -e "${dir}/${name}_drv_video.so" ]] && return 0
    done
  done
  return 1
}

# Checks whether crosvm's VA-API decoder backend can be used. On success sets
# CODECS_REF to the codecs it would decode (H.264, HEVC, VP8, VP9) that the
# host's VA-API driver also decodes. Otherwise sets REASON_REF to why not and
# fails. Like crosvm's libva, uses the first render node whose VA driver
# loads, and sets NODE_REF to it; that must be the GPU Ika uses, when
# setup_gpu_selection named its render node (IKA_GPU_RENDER_NODE).
vaapi_decoder_check() {
  local -n codecs_ref="$1"
  local -n reason_ref="$2"
  local -n node_ref="$3"
  local node
  local profiles
  local capable="false"
  local driver_installed="false"
  local have_vainfo="false"

  codecs_ref=""
  reason_ref=""
  node_ref=""
  command -v vainfo >/dev/null 2>&1 && have_vainfo="true"
  for node in /dev/dri/renderD*; do
    [[ -c "${node}" ]] || continue
    if [[ -n "$(vaapi_driver_names "${node}")" ]]; then
      capable="true"
      vaapi_driver_names "${node}" | vaapi_driver_installed && driver_installed="true"
    fi
    [[ "${have_vainfo}" == "true" ]] || continue
    profiles="$(with_timeout 10 vainfo --display drm --device "${node}" 2>/dev/null)" || continue
    node_ref="${node}"
    if [[ -n "${IKA_GPU_RENDER_NODE:-}" && "${node}" != "${IKA_GPU_RENDER_NODE}" ]]; then
      reason_ref="crosvm would decode on ${node}, another GPU than the one Ika uses (${IKA_GPU_RENDER_NODE})"
      return 1
    fi
    codecs_ref="$(sed -n 's/^[[:space:]]*VAProfile\([A-Za-z0-9_]*\)[[:space:]]*:[[:space:]]*VAEntrypointVLD.*/\1/p' \
        <<<"${profiles}" \
      | sed -n -e 's/^H264\(Baseline\|Main\|High\|StereoHigh\|MultiviewHigh\)$/H.264/p' \
        -e 's/^HEVC\(Main\|Main10\)$/HEVC/p' \
        -e 's/^VP8Version0_3$/VP8/p' \
        -e 's/^VP9Profile[0-3]$/VP9/p' \
      | sort -u | paste -sd ' ')"
    [[ -n "${codecs_ref}" ]] && return 0
    reason_ref="the VA-API driver for ${node} decodes none of H.264, HEVC, VP8 or VP9"
    return 1
  done

  if [[ "${capable}" != "true" ]]; then
    reason_ref="no VA-API capable GPU found"
  elif [[ "${driver_installed}" != "true" || "${have_vainfo}" == "true" ]]; then
    # No driver, or vainfo could not initialize the one that is there.
    reason_ref="VA-API Capable device but drivers are not installed"
  else
    reason_ref="vainfo not found; install libva-utils so Ika can check VA-API decoding"
  fi
  return 1
}

# Fedora's own Mesa and Intel iHD VA-API drivers leave out H.264 and HEVC,
# though the GPUs they drive decode H.264 in hardware (its i965 driver, for
# Haswell and older Intel GPUs, keeps H.264); RPM Fusion's builds put them
# back, installed beside Fedora's in directories libva searches first. Prints
# a warning naming the RPM Fusion package when the driver for render node NODE
# decodes CODECS without H.264, and nothing otherwise.
vaapi_rpmfusion_warning() {
  local node="$1"
  local codecs="$2"
  local package
  local driver

  [[ -n "${node}" && " ${codecs} " != *" H.264 "* ]] || return 0
  grep -qsE '^(ID|ID_LIKE)=.*fedora' /etc/os-release || return 0
  case "$(vaapi_driver_names "${node}" | head -n 1)" in
    radeonsi) package="mesa-va-drivers-freeworld" driver="/usr/lib64/dri-freeworld/radeonsi_drv_video.so" ;;
    iHD) package="intel-media-driver" driver="/usr/lib64/dri-nonfree/iHD_drv_video.so" ;;
    *) return 0 ;;
  esac
  [[ -e "${driver}" ]] && return 0
  printf '%s\n' "H.264/HEVC hardware video decoding needs the VA-API driver from RPM Fusion: sudo dnf install ${package}"
}

# Attaches the virtio-media video decoder when the host's VA-API driver
# decodes video Android would use it for, unless hw_video_decode is off or the
# start args name a decoder. Android only uses it with a V4L2 Codec2 HAL in the
# ROM; without one it decodes in software as before. Runs once the start log
# is set up, so what it finds is logged there.
append_hw_video_decode_args() {
  local -n args_array="$1"
  shift
  local vaapi_codecs
  local vaapi_reason
  local vaapi_node
  local vaapi_warning

  [[ "$(normalize_hw_video_decode_mode "${IKA_HW_VIDEO_DECODE}")" == "auto" ]] || return 0
  user_supplied_flag "crosvm_media_decoder" "$@" && return 0
  if vaapi_decoder_check vaapi_codecs vaapi_reason vaapi_node; then
    log "hardware video decoding: VA-API ${vaapi_codecs}"
    args_array+=("--crosvm_media_decoder=vaapi")
  else
    [[ "${vaapi_reason}" == "VA-API Capable device but drivers are not installed" ]] \
      && respond_console "${vaapi_reason}"
    log "hardware video decoding: ${vaapi_reason}; decoding in software"
  fi
  vaapi_warning="$(vaapi_rpmfusion_warning "${vaapi_node}" "${vaapi_codecs}")"
  if [[ -n "${vaapi_warning}" ]]; then
    respond_console "${vaapi_warning}"
    log "${vaapi_warning}"
  fi
}

