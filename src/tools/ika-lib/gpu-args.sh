# ika: the GPU and gfxstream options given to Cuttlefish.
# Sourced by src/tools/ika, in its order; see there.

append_comma_option() {
  local existing="$1"
  local required="$2"
  local option
  local -a options=()

  IFS=',' read -r -a options <<<"${existing}"
  for option in "${options[@]}"; do
    if [[ "${option}" == "${required}" ]]; then
      printf '%s\n' "${existing}"
      return 0
    fi
  done

  printf '%s\n' "${existing}${existing:+,}${required}"
}

start_arg_value() {
  local flag="$1"
  local default_value="${2:-}"
  shift 2
  local value=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --${flag}=*|-${flag}=*)
        value="${1#*=}"
        ;;
      --${flag}|-${flag})
        shift
        [[ $# -gt 0 ]] || die "--${flag} requires a value"
        value="$1"
        ;;
    esac
    shift || true
  done

  printf '%s\n' "${value:-${default_value}}"
}

# Takes --gpu_mode=auto out of a start's arguments: it asks for what
# gpu_mode = auto in ika.ini does, the mode chosen from the host's GPU,
# whatever mode ika.ini sets. Cuttlefish, which the option would otherwise
# reach, has an auto of its own that knows nothing of Venus and takes
# SwiftShader on an NVIDIA GPU. As Cuttlefish does, the last --gpu_mode of
# several counts.
take_gpu_mode_auto() {
  local -n kept_args_ref="$1"
  shift
  local mode

  mode="$(start_arg_value "gpu_mode" "" "$@")"
  if [[ "${mode,,}" != "auto" ]]; then
    kept_args_ref=("$@")
    return 0
  fi
  GPU_MODE_AUTO_REQUESTED="true"
  CVD_GPU_DEFAULTS[gpu_mode]="${CVD_GPU_MODE_AUTO_BASE}"
  kept_args_ref=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gpu_mode=*|-gpu_mode=*)
        ;;
      --gpu_mode|-gpu_mode)
        shift
        ;;
      *)
        kept_args_ref+=("$1")
        ;;
    esac
    shift
  done
}

start_gpu_mode_value() {
  start_arg_value "gpu_mode" "${CVD_GPU_DEFAULTS[gpu_mode]}" "$@"
}

merge_gfxstream_renderer_features() {
  local existing="$1"
  local required="$2"
  local result=""
  local feature
  local name
  local -a existing_features=()

  IFS=';' read -r -a existing_features <<<"${existing}"
  for feature in "${existing_features[@]}"; do
    [[ -n "${feature}" ]] || continue
    name="${feature%%:*}"
    case "${name}" in
      ExternalBlob|SystemBlob|VulkanAllocateHostVisibleAsUdmabuf|VulkanUseDedicatedAhbMemoryType)
        continue
        ;;
    esac
    result+="${result:+;}${feature}"
  done

  result+="${result:+;}${required}"
  printf '%s\n' "${result}"
}

append_or_merge_gpu_renderer_features() {
  local -n renderer_args_array="$1"
  local required="$2"
  local i
  local existing

  for i in "${!renderer_args_array[@]}"; do
    case "${renderer_args_array[${i}]}" in
      --gpu_renderer_features=*|-gpu_renderer_features=*)
        existing="${renderer_args_array[${i}]#*=}"
        renderer_args_array[${i}]="--gpu_renderer_features=$(merge_gfxstream_renderer_features "${existing}" "${required}")"
        return 0
        ;;
      --gpu_renderer_features|-gpu_renderer_features)
        (( i + 1 < ${#renderer_args_array[@]} )) || die "--gpu_renderer_features requires a value"
        existing="${renderer_args_array[$((i + 1))]}"
        renderer_args_array[$((i + 1))]="$(merge_gfxstream_renderer_features "${existing}" "${required}")"
        return 0
        ;;
    esac
  done

  renderer_args_array+=("--gpu_renderer_features=${required}")
}

gfxstream_context_types_include_vulkan() {
  local context_types="$1"
  local contexts="${context_types%%,*}"

  [[ ":${contexts}:" == *":gfxstream-vulkan:"* ]]
}

gfxstream_guest_angle_uses_host_vulkan() {
  local gpu_mode="$1"

  [[ "${gpu_mode}" == "gfxstream_guest_angle" ]]
}

merge_gpu_context_types_for_vulkan() {
  local -n context_args_array="$1"
  local default_context_types="$2"
  local i
  local existing

  for i in "${!context_args_array[@]}"; do
    case "${context_args_array[${i}]}" in
      --gpu_context_types=*|-gpu_context_types=*)
        existing="${context_args_array[${i}]#*=}"
        printf '%s\n' "${existing}"
        return 0
        ;;
      --gpu_context_types|-gpu_context_types)
        (( i + 1 < ${#context_args_array[@]} )) || die "--gpu_context_types requires a value"
        existing="${context_args_array[$((i + 1))]}"
        printf '%s\n' "${existing}"
        return 0
        ;;
    esac
  done

  context_args_array+=("--gpu_context_types=${default_context_types}")
  printf '%s\n' "${default_context_types}"
}

set_or_append_start_arg() {
  local -n set_args_array="$1"
  local flag="$2"
  local value="$3"
  local i

  for i in "${!set_args_array[@]}"; do
    case "${set_args_array[${i}]}" in
      --${flag}=*|-${flag}=*)
        set_args_array[${i}]="--${flag}=${value}"
        return 0
        ;;
      --${flag}|-${flag})
        if (( i + 1 < ${#set_args_array[@]} )); then
          set_args_array[$((i + 1))]="${value}"
        else
          set_args_array+=("${value}")
        fi
        return 0
        ;;
    esac
  done

  set_args_array+=("--${flag}=${value}")
}

# The host-cached memory setting (IKA_HOST_CACHED_MEMORY, gpu.host_cached_memory
# in ika.ini): on or off. Prints the normalized value; fails on anything else.
normalize_host_cached_memory_mode() {
  case "${1,,}" in
    ""|0|false|no|off|disable|disabled)
      echo "off"
      ;;
    1|true|yes|on|enable|enabled)
      echo "on"
      ;;
    *)
      return 1
      ;;
  esac
}

host_cached_memory_mode() {
  local mode

  if ! mode="$(normalize_host_cached_memory_mode "${IKA_HOST_CACHED_MEMORY:-off}")"; then
    log "${IKA_INI_FILE}: gpu.host_cached_memory must be on or off, not '${IKA_HOST_CACHED_MEMORY}'; using off"
    mode="off"
  fi
  printf '%s\n' "${mode}"
}

# With host_cached_memory = on, gfxstream takes the guest's host-visible
# Vulkan memory from a cached coherent host memory type instead of a
# write-combined one (its VulkanPreferHostCachedMemory feature): the guest
# writes its uploads through its mapping of that memory, and write-combined
# memory is slow for them on some drivers. Off by default until measured on
# the host drivers Ika runs on.
#
# NVIDIA's proprietary driver gets it whatever the setting says. KVM maps the
# guest's view of host memory write-back, and the NVIDIA GPU reads its
# write-combined memory without snooping the CPU caches, so it read uploads
# the guest had not yet written back: text drawn as noise and every launcher
# icon the same.
append_host_cached_memory_args() {
  local -n cached_args_array="$1"

  if [[ "$(host_cached_memory_mode)" == "on" ]]; then
    log "host cached memory: on (VulkanPreferHostCachedMemory, guest host-visible Vulkan memory from cached coherent host memory types)"
  elif primary_vulkan_device_is_nvidia_proprietary; then
    log "NVIDIA proprietary driver: guest host-visible Vulkan memory from cached coherent host memory types (VulkanPreferHostCachedMemory), as its GPU does not snoop write-combined memory"
  else
    return 0
  fi
  append_or_merge_gpu_renderer_features \
    cached_args_array "VulkanPreferHostCachedMemory:enabled"
}

primary_vulkan_device_is_nvidia_proprietary() {
  local primary_device

  primary_device="$(primary_vulkan_device_summary)" || return 1
  grep -Eq '^[[:space:]]*driverID[[:space:]]*=[[:space:]]*DRIVER_ID_NVIDIA_PROPRIETARY([[:space:]]|$)' \
    <<<"${primary_device}"
}

# Prints the primary Vulkan device's block of the vulkaninfo summary.
primary_vulkan_device_summary() {
  local summary
  local primary_device

  summary="$(vulkaninfo_summary || true)"
  [[ -n "${summary}" ]] || return 1

  primary_device="$(
    awk '
      /^GPU[0-9]+:/ {
        if (seen) {
          exit
        }
        seen = 1
        next
      }
      seen {
        print
      }
    ' <<<"${summary}"
  )"
  [[ -n "${primary_device}" ]] || return 1
  printf '%s\n' "${primary_device}"
}

# Whether the ROM's android-info.txt declares Venus support:
# vulkan_venus_apex=supported, which also makes Cuttlefish's assemble_cvd
# activate the guest's Venus driver APEX. (venus among gpu_mode_candidates
# alone is not enough: the host tools then start the mode without the driver.)
guest_supports_venus() {
  local android_info="$1"

  [[ -r "${android_info}" ]] || return 1
  grep -Eiq '^[[:space:]]*vulkan_venus_apex[[:space:]]*=[[:space:]]*supported' "${android_info}"
}

# gpu_mode=venus: the guest's Vulkan is Mesa's Venus driver over virglrenderer
# on the host, with ANGLE for OpenGL ES, which Cuttlefish 1.58's host tools
# run (crosvm with the virglrenderer backend and the venus and cross-domain
# context types). It needs a ROM built with Venus support (Mesa's vulkan.virtio
# driver, declared in android-info.txt), as Ika's ROM is from Mesa 26.3 on.
# Upstream tests it on Intel (ANV) and Qualcomm (Turnip) hosts; Ika on AMD
# (RADV) and Apple Silicon (Honeykrisp), where crosvm maps Venus's GPU memory
# into the guest with fixed blob mapping. Checked here so that the start fails
# with a reason rather than deep in assemble_cvd.
check_venus_gpu_mode() {
  local android_info="${CVD_PRODUCT_OUT}/android-info.txt"
  local primary_device

  if ! guest_supports_venus "${android_info}"; then
    die "gpu_mode=venus: the ROM under ${CVD_PRODUCT_OUT} does not declare Venus support (vulkan_venus_apex=supported in android-info.txt); it needs a ROM built with Mesa's Venus driver"
  fi
  primary_device="$(primary_vulkan_device_summary || true)"
  if [[ -n "${primary_device}" ]] \
      && ! grep -Eiq '(driverName[[:space:]]*=.*(anv|turnip|radv|honeykrisp)|DRIVER_ID_(INTEL_OPEN_SOURCE_MESA|MESA_TURNIP|MESA_RADV|MESA_HONEYKRISP))' <<<"${primary_device}"; then
    log "gpu_mode=venus: Venus is tested on Intel (ANV), Qualcomm (Turnip), AMD (RADV) and Apple Silicon (Honeykrisp) hosts; this host's primary Vulkan driver is untested with it"
  fi
}

append_apple_16k_gfxstream_vulkan_args() {
  local -n apple_args_array="$1"

  append_or_merge_gpu_renderer_features \
    apple_args_array "${GFXSTREAM_APPLE_16K_VULKAN_RENDERER_FEATURES}"
  set_or_append_start_arg apple_args_array "enable_gpu_udmabuf" "true"
  log "Apple Silicon 16K host: using udmabuf-backed ExternalBlob with Vulkano gralloc; disabling SystemBlob"
}

UDMABUF_DEVICE="/dev/udmabuf"

# crosvm does not start with enable_gpu_udmabuf on a kernel without udmabuf,
# such as Microsoft's WSL2 kernel; gfxstream then uses other memory.
drop_udmabuf_without_device() {
  local -n udmabuf_args_array="$1"

  [[ ! -e "${UDMABUF_DEVICE}" ]] || return 0
  [[ "$(start_arg_value enable_gpu_udmabuf false "${udmabuf_args_array[@]}")" == true ]] || return 0
  set_or_append_start_arg udmabuf_args_array enable_gpu_udmabuf false
  log "this kernel has no ${UDMABUF_DEVICE}: starting with enable_gpu_udmabuf=false"
}

# Fails start before the launcher when this user cannot open a device crosvm
# opens, which crosvm would otherwise report as "Permission denied" seconds
# into the boot, seen only in the start log. WSL2's distributions share one
# kernel and so one /dev: another distribution's udev gives the devices to its
# own kvm or cvdnetwork group, whose ID is another group, or none, here.
# Running this distribution's udev rules for them again gives them back.
check_vm_device_access() {
  local -n device_args_array="$1"
  local -a devices=(/dev/kvm /dev/vhost-vsock)
  local -a denied=()
  local -a sysnames=()
  local device
  local group

  [[ "$(start_arg_value vhost_net false "${device_args_array[@]}")" != true ]] \
    || devices+=(/dev/vhost-net)
  for device in "${devices[@]}"; do
    [[ -e "${device}" ]] || continue
    [[ ! -r "${device}" || ! -w "${device}" ]] || continue
    group="$(stat -c %G "${device}" 2>/dev/null || true)"
    [[ -n "${group}" && "${group}" != UNKNOWN ]] \
      || group="$(stat -c %g "${device}" 2>/dev/null || true), which has no name here"
    log "cannot open ${device}: it belongs to group ${group}, mode $(stat -c %a "${device}" 2>/dev/null || true)"
    denied+=("${device}")
    sysnames+=("--sysname-match=${device#/dev/}")
  done
  [[ "${#denied[@]}" -gt 0 ]] || return 0

  CONSOLE_FAILURE_MESSAGE="Startup Failed: cannot open ${denied[*]}"
  if [[ -d /proc/sys/fs/binfmt_misc/WSLInterop || -n "${WSL_DISTRO_NAME:-}" ]]; then
    CONSOLE_FAILURE_MESSAGE+=" (another WSL distribution's udev likely changed their group)"
  fi
  CONSOLE_FAILURE_MESSAGE+=". To give them back to this distribution's groups, run:
  sudo udevadm trigger --action=add --subsystem-match=misc ${sysnames[*]}"
  die_with_notification "Ika cannot open ${denied[*]}" \
    "cannot open ${denied[*]}; run: sudo udevadm trigger --action=add --subsystem-match=misc ${sysnames[*]}"
}

append_radv_gfxstream_vulkan_args() {
  local -n radv_args_array="$1"

  primary_vulkan_device_is_radv_vega_or_older || return 1
  append_or_merge_gpu_renderer_features \
    radv_args_array "${GFXSTREAM_RADV_VULKAN_RENDERER_FEATURES}"
  log "RADV Vega-or-older gfxstream: using device-only Vulkan memory to avoid AMD host-visible memory corruption"
}

append_gfxstream_vulkan_args() {
  local -n args_array="$1"
  shift
  local mode
  local selected_mode
  local gpu_mode
  local vulkan_decision
  local user_context_types
  local effective_context_types
  local passed_over

  mode="$(normalize_gfxstream_vulkan_mode "${GFXSTREAM_VULKAN_MODE}")"
  GFXSTREAM_VULKAN_MODE="${mode}"

  gpu_mode="$(start_gpu_mode_value "$@")"
  CVD_GPU_MODE="${gpu_mode}"
  if gfxstream_guest_angle_uses_host_vulkan "${gpu_mode}"; then
    CVD_GRAPHICS_DRIVER_MESSAGE="${gpu_mode} (ANGLE over gfxstream Vulkan)"
    log "gfxstream-vulkan=${mode} context toggle has no effect with gpu_mode=${gpu_mode} (Vulkan-only)"
    if append_radv_gfxstream_vulkan_args args_array; then
      CVD_GRAPHICS_DRIVER_MESSAGE="${gpu_mode} (ANGLE over gfxstream Vulkan; RADV device memory)"
    fi
    if is_apple_silicon_16k_host; then
      append_apple_16k_gfxstream_vulkan_args args_array
      CVD_GRAPHICS_DRIVER_MESSAGE="${gpu_mode} (ANGLE over gfxstream Vulkan; Apple 16K udmabuf)"
    fi
    append_host_cached_memory_args args_array
    return 0
  fi

  if [[ "${gpu_mode}" == "venus" ]]; then
    check_venus_gpu_mode
    CVD_GRAPHICS_DRIVER_MESSAGE="venus (ANGLE over Venus Vulkan)"
    log "gfxstream-vulkan=${mode} has no effect with gpu_mode=venus"
    return 0
  fi

  if [[ "${gpu_mode}" != "gfxstream" ]]; then
    # auto, the default, goes unmentioned: only a setting of the user's is noted
    CVD_GRAPHICS_DRIVER_MESSAGE="GPU: ${gpu_mode}"
    [[ "${mode}" == "auto" ]] || CVD_GRAPHICS_DRIVER_MESSAGE+=" (gfxstream-vulkan=${mode} ignored)"
    log "gfxstream-vulkan=${mode} has no effect with gpu_mode=${gpu_mode}"
    return 0
  fi

  if user_supplied_flag "gpu_context_types" "$@"; then
    user_context_types="$(merge_gpu_context_types_for_vulkan args_array \
      "${GFXSTREAM_VULKAN_CONTEXT_TYPES}")"
    effective_context_types="$(start_arg_value "gpu_context_types" "${user_context_types}" "${args_array[@]}")"
    CVD_GRAPHICS_DRIVER_MESSAGE="gfxstream (user gpu_context_types; gfxstream-vulkan=${mode})"
    log "using user supplied gpu_context_types=${effective_context_types}; gfxstream-vulkan=${mode}"
    if gfxstream_context_types_include_vulkan "${effective_context_types}" \
        && is_apple_silicon_16k_host; then
      append_apple_16k_gfxstream_vulkan_args args_array
    fi
    if gfxstream_context_types_include_vulkan "${effective_context_types}"; then
      append_radv_gfxstream_vulkan_args args_array || true
      append_host_cached_memory_args args_array
    fi
    return 0
  fi

  selected_mode="${mode}"
  vulkan_decision="gfxstream-vulkan=${mode}"
  if [[ "${selected_mode}" == "auto" ]]; then
    if primary_vulkan_device_is_llvmpipe; then
      selected_mode="off"
      vulkan_decision="gfxstream-vulkan=auto -> off (primary Vulkan device is llvmpipe)"
    elif passed_over="$(gfxstream_passes_over_hardware_vulkan)"; then
      selected_mode="off"
      vulkan_decision="gfxstream-vulkan=auto -> off (gfxstream would render with ${passed_over})"
    elif is_apple_silicon_16k_host; then
      append_apple_16k_gfxstream_vulkan_args args_array
      append_host_cached_memory_args args_array
      CVD_GRAPHICS_DRIVER_MESSAGE="gfxstream (OpenGL ES + Vulkan, Apple Silicon)"
      log "gfxstream-vulkan=auto; leaving Cuttlefish gfxstream defaults with Apple 16K udmabuf"
      return 0
    else
      append_radv_gfxstream_vulkan_args args_array || true
      append_host_cached_memory_args args_array
      CVD_GRAPHICS_DRIVER_MESSAGE="gfxstream (Default settings, vulkan=auto)"
      log "gfxstream-vulkan=auto; leaving Cuttlefish gfxstream defaults"
      return 0
    fi
  fi

  case "${selected_mode}" in
    off)
      args_array+=("--gpu_context_types=${GFXSTREAM_GLES_CONTEXT_TYPES}")
      CVD_GRAPHICS_DRIVER_MESSAGE="gfxstream (OpenGL ES)"
      log "${vulkan_decision}; context-types=${GFXSTREAM_GLES_CONTEXT_TYPES}"
      ;;
    on)
      args_array+=("--gpu_context_types=${GFXSTREAM_VULKAN_CONTEXT_TYPES}")
      CVD_GRAPHICS_DRIVER_MESSAGE="gfxstream (OpenGL ES + Vulkan; ${vulkan_decision})"
      log "${vulkan_decision}; context-types=${GFXSTREAM_VULKAN_CONTEXT_TYPES}"
      if is_apple_silicon_16k_host; then
        append_apple_16k_gfxstream_vulkan_args args_array
      fi
      append_radv_gfxstream_vulkan_args args_array || true
      append_host_cached_memory_args args_array
      ;;
  esac
}

