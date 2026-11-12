# ika: finding the host's GPUs and Vulkan drivers, and choosing the GPU mode.
# Sourced by src/tools/ika, in its order; see there.

# Prints the GPU Ika renders with, from a vulkaninfo summary, as tab-separated
# fields: "vendor:device" in MESA_VK_DEVICE_SELECT's hex form, its name, its
# type, its driver ID and how many other hardware GPUs rank below it. A
# discrete GPU goes before an integrated one, which goes before a virtual or
# other one, whatever their Vulkan versions; among equals the first listed. A
# software device (llvmpipe, Lavapipe, SwiftShader, Microsoft's WARP) never
# counts. With a driver ID, only that driver's devices count; with a
# "vendor:device" too, prints that device instead (any spelling Mesa's device
# selection takes: 0x prefixes, leading zeros, a trailing "!"). Fails when
# there is none.
vulkan_summary_preferred_gpu() {
  local summary="$1"
  local driver_filter="${2:-}"
  local want="${3:-}"

  awk -v driver_filter="${driver_filter}" -v want="${want}" '
    function hex_id(value) {
      value = tolower(value)
      sub(/^0x/, "", value)
      sub(/^0+/, "", value)
      return value == "" ? "0" : value
    }
    function field(value) {
      return value == "" ? "-" : value
    }
    function finish_device(    rank, key) {
      if (!in_device) {
        return
      }
      in_device = 0
      if (driver_filter != "" && driver != driver_filter) {
        return
      }
      key = hex_id(vendor) ":" hex_id(id)
      if (want != "") {
        # A software device can have the ID of a GPU: llvmpipe that of the Apple GPU
        if (!found && key == want_key && !software && type != "PHYSICAL_DEVICE_TYPE_CPU") {
          found = 1
          best_line = key "\t" field(name) "\t" field(type) "\t" field(driver)
        }
        return
      }
      if (software || type == "PHYSICAL_DEVICE_TYPE_CPU" || hex_id(vendor) == "1414") {
        return
      }
      rank = 1
      if (type == "PHYSICAL_DEVICE_TYPE_DISCRETE_GPU") {
        rank = 3
      } else if (type == "PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU") {
        rank = 2
      }
      hardware++
      if (rank > best_rank) {
        best_rank = rank
        best_line = key "\t" field(name) "\t" field(type) "\t" field(driver)
      }
      ranks[hardware] = rank
    }
    BEGIN {
      if (want != "") {
        sub(/!$/, "", want)
        split(want, parts, ":")
        want_key = hex_id(parts[1]) ":" hex_id(parts[2])
      }
    }
    /^GPU[0-9]+:/ {
      finish_device()
      in_device = 1
      software = 0
      vendor = id = type = driver = name = ""
      next
    }
    in_device && $1 == "vendorID" { vendor = $3 }
    in_device && $1 == "deviceID" { id = $3 }
    in_device && $1 == "deviceType" { type = $3 }
    in_device && $1 == "driverID" { driver = $3 }
    in_device && $1 == "deviceName" {
      name = $0
      sub(/^[^=]*=[[:space:]]*/, "", name)
      sub(/[[:space:]]+$/, "", name)
    }
    in_device && tolower($0) ~ /(llvmpipe|lavapipe|swiftshader|software rasterizer|software device)/ {
      software = 1
    }
    END {
      finish_device()
      if (best_line == "") {
        exit 1
      }
      below = 0
      for (i = 1; i <= hardware; i++) {
        if (ranks[i] < best_rank) {
          below++
        }
      }
      if (want != "") {
        print best_line
      } else {
        print best_line "\t" below
      }
    }
  ' <<<"${summary}"
}

# The PCI slot ("0000:03:00.0") of the display controller with the given
# "vendor:device" (hex, as vulkan_summary_preferred_gpu prints it).
pci_slot_of_gpu() {
  local want_vendor="0x${1%%:*}"
  local want_device="0x${1#*:}"
  local dev
  local class
  local vendor
  local device

  for dev in /sys/bus/pci/devices/*; do
    read -r class < "${dev}/class" 2>/dev/null || continue
    [[ "${class}" == 0x03* ]] || continue
    read -r vendor < "${dev}/vendor" 2>/dev/null || continue
    read -r device < "${dev}/device" 2>/dev/null || continue
    if (( vendor == want_vendor && device == want_device )); then
      printf '%s\n' "${dev##*/}"
      return 0
    fi
  done
  return 1
}

# Whether the host GPU is reached through WSL2's Direct3D 12 device.
host_has_dxg() {
  [[ -e /dev/dxg ]]
}

# Prints the hardware GPUs of a vulkaninfo summary, one a line, in the order
# it lists them, as tab-separated fields: "vendor:device" as
# vulkan_summary_preferred_gpu prints it, the name, the type and the driver
# ID. Each ID once; never a software device or Microsoft's WARP. With a
# driver ID, only that driver's devices.
vulkan_summary_gpus() {
  local summary="$1"
  local driver_filter="${2:-}"

  awk -v driver_filter="${driver_filter}" '
    function hex_id(value) {
      value = tolower(value)
      sub(/^0x/, "", value)
      sub(/^0+/, "", value)
      return value == "" ? "0" : value
    }
    function field(value) {
      return value == "" ? "-" : value
    }
    function finish_device(    key) {
      if (!in_device) {
        return
      }
      in_device = 0
      if (driver_filter != "" && driver != driver_filter) {
        return
      }
      if (software || type == "PHYSICAL_DEVICE_TYPE_CPU" || hex_id(vendor) == "1414") {
        return
      }
      key = hex_id(vendor) ":" hex_id(id)
      if (key in seen) {
        return
      }
      seen[key] = 1
      print key "\t" field(name) "\t" field(type) "\t" field(driver)
    }
    /^GPU[0-9]+:/ {
      finish_device()
      in_device = 1
      software = 0
      vendor = id = type = driver = name = ""
      next
    }
    in_device && $1 == "vendorID" { vendor = $3 }
    in_device && $1 == "deviceID" { id = $3 }
    in_device && $1 == "deviceType" { type = $3 }
    in_device && $1 == "driverID" { driver = $3 }
    in_device && $1 == "deviceName" {
      name = $0
      sub(/^[^=]*=[[:space:]]*/, "", name)
      sub(/[[:space:]]+$/, "", name)
    }
    in_device && tolower($0) ~ /(llvmpipe|lavapipe|swiftshader|software rasterizer|software device)/ {
      software = 1
    }
    END {
      finish_device()
    }
  ' <<<"${summary}"
}

# The name of a GPU as a person knows it, from its Vulkan device name: Dozen's
# "Microsoft Direct3D12 (NVIDIA GeForce RTX 4080 Laptop GPU)" is the adapter
# inside the brackets.
gpu_display_name() {
  local name="$1"

  if [[ "${name}" == "Microsoft Direct3D12 ("*")" ]]; then
    name="${name#Microsoft Direct3D12 (}"
    name="${name%)}"
  fi
  printf '%s\n' "${name}"
}

# Prints "GPU Hardware" (ika.ini's [gpu] use_gpu, IKA_GPU) as Ika takes it: auto, or
# a GPU's "vendor:device" in lowercase hex without 0x or leading zeros, as
# vulkan_summary_preferred_gpu prints it (10de:27a0). Fails on anything else.
normalize_gpu_device() {
  local value="${1,,}"

  value="${value%!}"
  case "${value}" in
    ""|auto)
      printf 'auto\n'
      return 0
      ;;
  esac
  [[ "${value}" =~ ^(0x)?([0-9a-f]{1,8}):(0x)?([0-9a-f]{1,8})$ ]] || return 1
  printf '%x:%x\n' "$((16#${BASH_REMATCH[2]}))" "$((16#${BASH_REMATCH[4]}))"
}

# The GPU the running VM was started on, so that a console or app window
# opened while it runs renders on the same GPU, whatever ika.ini says by
# then.
GPU_IN_USE_FILE="${CVD_TMP_DIR}/gpu-device"
# The GPU this ika selected (setup_gpu_selection), auto or "vendor:device".
GPU_SELECTED="auto"

# Prints the GPU to use for COMMAND, as normalize_gpu_device prints it: the
# running VM's, except for restart, which starts a new one; else IKA_GPU,
# ika.ini's [gpu] use_gpu. A value that is not a GPU ID is reported and taken
# for auto.
gpu_device_setting() {
  local command="${1:-}"
  local value

  if [[ "${command}" != "restart" && -r "${GPU_IN_USE_FILE}" ]] \
      && has_live_cvd_processes; then
    read -r value < "${GPU_IN_USE_FILE}" || value=""
    normalize_gpu_device "${value}" 2>/dev/null && return 0
  fi
  if ! normalize_gpu_device "${IKA_GPU}"; then
    ika_ini_warn "${IKA_INI_FILE}: gpu.use_gpu must be auto or a GPU's vendor:device ID, such as 10de:27a0, not '${IKA_GPU}'; using auto"
    printf 'auto\n'
  fi
}

# Records, at start, the GPU the VM renders on (see GPU_IN_USE_FILE).
record_gpu_in_use() {
  mkdir -p "${CVD_TMP_DIR}" 2>/dev/null || return 0
  printf '%s\n' "${GPU_SELECTED}" > "${GPU_IN_USE_FILE}" 2>/dev/null || true
}

# The environment setup_gpu_selection sets, a line per variable it set:
# "+NAME=VALUE" for one that had VALUE before, "-NAME" for one that was unset.
# Exported, so that an ika this one runs (restart, "Apply and restart" in the
# Startup Options) puts all of it back before it selects again, from ika.ini
# as it is then; a variable it did not set is the user's.
IKA_GPU_ENV="${IKA_GPU_ENV:-}"

# gpu_env_export NAME VALUE: exports NAME=VALUE, recording it in IKA_GPU_ENV.
gpu_env_export() {
  local name="$1"

  if [[ -n "${!name+set}" ]]; then
    IKA_GPU_ENV+="+${name}=${!name}"$'\n'
  else
    IKA_GPU_ENV+="-${name}"$'\n'
  fi
  export IKA_GPU_ENV
  export "${name}=$2"
}

# gpu_env_default NAME VALUE: the same, unless the environment sets NAME.
gpu_env_default() {
  [[ -n "${!1:-}" ]] || gpu_env_export "$1" "$2"
}

# Puts back what IKA_GPU_ENV records, the latest first.
restore_gpu_env() {
  local -a lines=()
  local line
  local i

  if [[ -n "${IKA_GPU_ENV:-}" ]]; then
    mapfile -t lines <<<"${IKA_GPU_ENV%$'\n'}"
    for (( i = ${#lines[@]} - 1; i >= 0; i-- )); do
      line="${lines[i]}"
      case "${line}" in
        +?*=*)
          line="${line#+}"
          export "${line%%=*}=${line#*=}"
          ;;
        -?*)
          unset "${line#-}"
          ;;
      esac
    done
  fi
  IKA_GPU_ENV=""
  unset IKA_GPU_ENV
}

# Prints a vulkaninfo summary with only the device with "vendor:device"
# DEVICE and the software ones: what gfxstream would rank if no other GPU
# were there.
vulkan_summary_device_and_software() {
  local summary="$1"
  local want="$2"

  awk -v want="${want}" '
    function hex_id(value) {
      value = tolower(value)
      sub(/^0x/, "", value)
      sub(/^0+/, "", value)
      return value == "" ? "0" : value
    }
    function finish_device() {
      if (block != "" && (software || type == "PHYSICAL_DEVICE_TYPE_CPU" ||
          hex_id(vendor) ":" hex_id(id) == want)) {
        printf "%s", block
      }
      block = ""
    }
    /^GPU[0-9]+:/ {
      finish_device()
      in_device = 1
      software = 0
      vendor = id = type = ""
    }
    !in_device { print; next }
    $1 == "vendorID" { vendor = $3 }
    $1 == "deviceID" { id = $3 }
    $1 == "deviceType" { type = $3 }
    tolower($0) ~ /(llvmpipe|lavapipe|swiftshader|software rasterizer|software device)/ { software = 1 }
    { block = block $0 "\n" }
    END { finish_device() }
  ' <<<"${summary}"
}

# Whether DRIVER_ID is one of Mesa's drivers, which DRI_PRIME steers.
is_mesa_vulkan_driver() {
  [[ "$1" == DRIVER_ID_MESA_* || "$1" == DRIVER_ID_INTEL_OPEN_SOURCE_MESA ]]
}

# Prints, colon-separated, the Vulkan driver manifests (ICD files) of the
# driver with DRIVER_ID, from the directories the Vulkan loader reads, by the
# library each loads. Fails for a driver it does not know, or when none is
# found.
vulkan_icd_files_for_driver() {
  local driver="$1"
  local -a libraries=()
  local -a dirs=()
  local -a data_dirs=()
  local -a config_dirs=()
  local dir
  local file
  local library
  local want
  local files=""

  case "${driver}" in
    DRIVER_ID_MESA_RADV) libraries=(libvulkan_radeon.so) ;;
    DRIVER_ID_INTEL_OPEN_SOURCE_MESA) libraries=(libvulkan_intel.so libvulkan_intel_hasvk.so) ;;
    DRIVER_ID_MESA_NVK) libraries=(libvulkan_nouveau.so) ;;
    DRIVER_ID_MESA_HONEYKRISP) libraries=(libvulkan_asahi.so) ;;
    DRIVER_ID_MESA_TURNIP) libraries=(libvulkan_freedreno.so) ;;
    DRIVER_ID_MESA_PANVK) libraries=(libvulkan_panfrost.so) ;;
    DRIVER_ID_MESA_V3DV) libraries=(libvulkan_broadcom.so) ;;
    DRIVER_ID_MESA_IMAGINATION_OPEN_SOURCE_MESA) libraries=(libvulkan_powervr_mesa.so) ;;
    DRIVER_ID_NVIDIA_PROPRIETARY) libraries=(libGLX_nvidia.so.0 libGLX_nvidia.so) ;;
    DRIVER_ID_AMD_OPEN_SOURCE) libraries=(amdvlk64.so amdvlk32.so) ;;
    *) return 1 ;;
  esac

  IFS=: read -r -a config_dirs <<<"${XDG_CONFIG_DIRS:-/etc/xdg}"
  IFS=: read -r -a data_dirs <<<"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  dirs=("${XDG_CONFIG_HOME:-${HOME}/.config}" "${config_dirs[@]}" /etc
        "${XDG_DATA_HOME:-${HOME}/.local/share}" "${data_dirs[@]}" /usr/local/share /usr/share)
  for dir in "${dirs[@]}"; do
    [[ -n "${dir}" ]] || continue
    for file in "${dir%/}"/vulkan/icd.d/*.json; do
      [[ -f "${file}" ]] || continue
      [[ ":${files}:" != *":${file}:"* ]] || continue
      library="$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${file}" 2>/dev/null | head -n 1)"
      library="${library##*/}"
      for want in "${libraries[@]}"; do
        if [[ "${library}" == "${want}" ]]; then
          files+="${files:+:}${file}"
          break
        fi
      done
    done
  done
  [[ -n "${files}" ]] || return 1
  printf '%s\n' "${files}"
}

# Prints the glvnd EGL vendor file (egl_vendor.d) whose library is
# libEGL_<VENDOR>.so.0: mesa or nvidia.
egl_vendor_file() {
  local vendor="$1"
  local dir
  local file

  for dir in /etc/glvnd/egl_vendor.d /usr/local/share/glvnd/egl_vendor.d /usr/share/glvnd/egl_vendor.d; do
    for file in "${dir}"/*.json; do
      [[ -f "${file}" ]] || continue
      if grep -q "\"libEGL_${vendor}\.so" "${file}" 2>/dev/null; then
        printf '%s\n' "${file}"
        return 0
      fi
    done
  done
  return 1
}

# Prints how many GPUs the kernel drives, by their render nodes, with or
# without a Vulkan driver: a PCI display controller's, or a GPU's that is no
# PCI device (Apple's, many ARM boards'); not the virtual vgem's or vkms's.
host_render_gpu_count() {
  local node
  local device
  local class
  local driver
  local count=0

  for node in /sys/class/drm/renderD*; do
    device="$(readlink -f "${node}/device" 2>/dev/null)" || continue
    [[ -n "${device}" && -d "${device}" ]] || continue
    driver="$(readlink -f "${device}/driver" 2>/dev/null)" || driver=""
    case "${driver##*/}" in
      vgem|vkms) continue ;;
    esac
    if [[ -r "${device}/class" ]]; then
      read -r class < "${device}/class" 2>/dev/null || continue
      [[ "${class}" == 0x03* ]] || continue
    fi
    count=$((count + 1))
  done
  printf '%s\n' "${count}"
}

# The render node (/dev/dri/renderDN) of the GPU at PCI slot SLOT.
render_node_of_pci_slot() {
  local node

  for node in "/sys/bus/pci/devices/$1/drm/"renderD*; do
    [[ -e "${node}" ]] || continue
    printf '/dev/dri/%s\n' "${node##*/}"
    return 0
  done
  return 1
}

# Makes everything Ika runs render on the GPU of SUMMARY with "vendor:device"
# DEVICE, named NAME, of driver DRIVER, and nothing else on a host GPU:
# - Vulkan (gfxstream, Venus's render server, the GPU mode probes):
#   MESA_VK_DEVICE_SELECT=<vendor>:<device>! hides every other device, and
#   VK_DRIVER_FILES loads only that GPU's driver, so that no other driver
#   opens its GPU to list it, unless the device then goes missing (a GPU's
#   ID is no longer unique once a software device has it too: the Apple GPU
#   and llvmpipe are both 10005:0). On WSL2 Ika's Dozen makes a D3D12 device
#   on that adapter alone (dzn-adapter-select.patch).
# - OpenGL (the console, app windows, gpu_mode=gfxstream): on WSL2 Mesa's
#   d3d12 driver takes the adapter MESA_D3D12_DEFAULT_ADAPTER_NAME names;
#   elsewhere DRI_PRIME names the GPU's PCI slot for Mesa, and glvnd is
#   pointed at NVIDIA's EGL and GLX for NVIDIA's own driver, at Mesa's when
#   NVIDIA's are installed beside it.
# - Video decoding: IKA_GPU_RENDER_NODE names the GPU's render node, which
#   append_hw_video_decode_args holds crosvm's VA-API decoder to.
# - The GPU mode: on bare metal, a GPU gfxstream would rank below llvmpipe,
#   which it no longer sees, keeps the GPU mode auto chose for it before,
#   gfxstream with OpenGL ES (IKA_GPU_PASSED_OVER). On WSL2 Dozen's GPU of
#   Vulkan 1.2 runs gfxstream_guest_angle, as it did.
# A variable the environment sets is kept. WSL is true on WSL2.
apply_gpu_selection() {
  local summary="$1"
  local device="$2"
  local name="$3"
  local driver="$4"
  local wsl="$5"
  local slot=""
  local node
  local files
  local check
  local nvidia_egl=""
  local mesa_egl=""
  local passed_over

  gpu_env_export MESA_VK_DEVICE_SELECT "${device}!"
  if [[ "${wsl}" == "true" ]]; then
    name="$(gpu_display_name "${name}")"
    [[ -z "${name}" || "${name}" == "-" ]] \
      || gpu_env_default MESA_D3D12_DEFAULT_ADAPTER_NAME "${name}"
    return 0
  fi

  # Hidden from gfxstream now, llvmpipe would still have won over this GPU
  # (an older Vulkan, such as Haswell's 1.2): the GPU mode and Vulkan in
  # gfxstream are chosen as they were without the selection, OpenGL ES on
  # this GPU (see gfxstream_passes_over_hardware_vulkan)
  if passed_over="$(vulkan_summary_gfxstream_passes_over_hardware \
                      "$(vulkan_summary_device_and_software "${summary}" "${device}")")"; then
    gpu_env_export IKA_GPU_PASSED_OVER "${passed_over}"
  fi

  if slot="$(pci_slot_of_gpu "${device}")"; then
    if is_mesa_vulkan_driver "${driver}"; then
      gpu_env_export DRI_PRIME "pci-${slot//[:.]/_}"
    fi
    if node="$(render_node_of_pci_slot "${slot}")"; then
      gpu_env_export IKA_GPU_RENDER_NODE "${node}"
    fi
  fi

  nvidia_egl="$(egl_vendor_file nvidia)" || nvidia_egl=""
  if [[ "${driver}" == "DRIVER_ID_NVIDIA_PROPRIETARY" ]]; then
    gpu_env_default __NV_PRIME_RENDER_OFFLOAD 1
    gpu_env_default __GLX_VENDOR_LIBRARY_NAME nvidia
    gpu_env_default __VK_LAYER_NV_optimus NVIDIA_only
    [[ -z "${nvidia_egl}" ]] || gpu_env_default __EGL_VENDOR_LIBRARY_FILENAMES "${nvidia_egl}"
  elif [[ -n "${nvidia_egl}" ]] && is_mesa_vulkan_driver "${driver}"; then
    gpu_env_default __GLX_VENDOR_LIBRARY_NAME mesa
    gpu_env_default __VK_LAYER_NV_optimus non_NVIDIA_only
    mesa_egl="$(egl_vendor_file mesa)" || mesa_egl=""
    [[ -z "${mesa_egl}" ]] || gpu_env_default __EGL_VENDOR_LIBRARY_FILENAMES "${mesa_egl}"
  fi

  # Only the GPU's own Vulkan driver, if it still lists the GPU on its own
  if [[ -z "${VK_DRIVER_FILES:-}${VK_ICD_FILENAMES:-}" ]] \
      && files="$(vulkan_icd_files_for_driver "${driver}")" \
      && check="$(VK_DRIVER_FILES="${files}" probe_vulkaninfo_summary)" \
      && vulkan_summary_preferred_gpu "${check}" "" "${device}" >/dev/null; then
    gpu_env_export VK_DRIVER_FILES "${files}"
  fi
}

# Selects the GPU Ika uses ("GPU Hardware" in the Startup Options; ika.ini's [gpu]
# use_gpu, IKA_GPU), for COMMAND: everything Ika runs renders on it alone (see
# apply_gpu_selection). auto, or a GPU the host no longer has, renders on the
# discrete GPU beside another GPU (one without a Vulkan driver too, counted
# by its render node: Sandy Bridge's), as on WSL2, where it also picks the
# GPU of a host with one (Dozen lists WARP, Microsoft's software renderer,
# too): Mesa's device selection lists the GPU that drives the display first,
# the integrated one on most laptops, and gfxstream (getSelectedGpuIndex) can
# rank an integrated GPU first for a newer Vulkan version; on bare metal with
# one GPU it leaves the environment as it is. On WSL2 the GPU is one of
# Dozen's, and nothing is selected without Ika's WSL2 GPU setup
# (setup_wsl_gpu_env). Runs before the first vulkaninfo probe of the GPU mode
# selection, so that it sees what crosvm will. What an earlier ika selected
# (IKA_GPU_ENV) is undone first. A MESA_VK_DEVICE_SELECT or DRI_PRIME the
# user set keeps all of it off; on WSL2 the OpenGL driver then follows their
# MESA_VK_DEVICE_SELECT.
setup_gpu_selection() {
  local command="${1:-}"
  local setting
  local summary
  local gpu=""
  local device
  local name
  local type
  local driver
  local below
  local filter=""
  local wsl=false
  local drivers

  restore_gpu_env
  GPU_SELECTED="auto"
  if host_has_dxg; then
    [[ -n "${IKA_WSL_GPU_ENV:-}" ]] || return 0
    wsl=true
    filter="DRIVER_ID_MESA_DOZEN"
  fi
  setting="$(gpu_device_setting "${command}")"

  if [[ -n "${MESA_VK_DEVICE_SELECT:-}" || -n "${DRI_PRIME:-}" ]]; then
    [[ "${setting}" == "auto" ]] \
      || log_start_note "GPU Hardware ${setting} left aside: the environment sets MESA_VK_DEVICE_SELECT or DRI_PRIME"
    if [[ "${wsl}" == "true" && -n "${MESA_VK_DEVICE_SELECT:-}" && -z "${MESA_D3D12_DEFAULT_ADAPTER_NAME:-}" ]] \
        && summary="$(probe_vulkaninfo_summary)" \
        && gpu="$(vulkan_summary_preferred_gpu "${summary}" "${filter}" "${MESA_VK_DEVICE_SELECT}")"; then
      name="$(gpu_display_name "$(cut -f2 <<<"${gpu}")")"
      [[ -z "${name}" || "${name}" == "-" ]] || gpu_env_export MESA_D3D12_DEFAULT_ADAPTER_NAME "${name}"
    fi
    return 0
  fi

  summary="$(probe_vulkaninfo_summary)" || return 0
  if [[ "${setting}" != "auto" ]]; then
    if gpu="$(vulkan_summary_preferred_gpu "${summary}" "${filter}" "${setting}")"; then
      GPU_SELECTED="${setting}"
    else
      log_start_note "GPU Hardware ${setting}: no such GPU on this host; choosing one as auto does"
      gpu=""
    fi
  fi
  if [[ -z "${gpu}" ]]; then
    gpu="$(vulkan_summary_preferred_gpu "${summary}" "${filter}")" || return 0
    IFS=$'\t' read -r device name type driver below <<<"${gpu}"
    # Beside another GPU, Vulkan or not: an integrated GPU without a Vulkan
    # driver would keep OpenGL, the console and video decoding
    [[ "${wsl}" == "true" || ( "${type}" == "PHYSICAL_DEVICE_TYPE_DISCRETE_GPU" &&
         ( "${below}" -gt 0 || "$(host_render_gpu_count)" -gt 1 ) ) ]] \
      || return 0
  fi
  IFS=$'\t' read -r device name type driver _ <<<"${gpu}"

  apply_gpu_selection "${summary}" "${device}" "${name}" "${driver}" "${wsl}"
  # restart's start selects again, and says so
  [[ "${command}" != "restart" ]] || return 0
  drivers=""
  [[ "${wsl}" == "true" || $'\n'"${IKA_GPU_ENV:-}" != *$'\n'[-+]VK_DRIVER_FILES* ]] \
    || drivers=", VK_DRIVER_FILES=${VK_DRIVER_FILES}"
  log_start_note "GPU (${GPU_SELECTED}): $(gpu_display_name "${name}"), MESA_VK_DEVICE_SELECT=${MESA_VK_DEVICE_SELECT}${DRI_PRIME:+, DRI_PRIME=${DRI_PRIME}}${MESA_D3D12_DEFAULT_ADAPTER_NAME:+, MESA_D3D12_DEFAULT_ADAPTER_NAME=${MESA_D3D12_DEFAULT_ADAPTER_NAME}}${drivers}"
}

# Prints the GPUs "GPU Hardware" offers, as vulkan_summary_gpus does, from a
# vulkaninfo summary of all of them, without what an earlier ika or the user
# selected: on WSL2 Dozen's, with Ika's WSL2 GPU setup.
host_gpus() {
  (
    local summary
    local filter=""

    restore_gpu_env
    unset MESA_VK_DEVICE_SELECT DRI_PRIME
    if host_has_dxg; then
      setup_wsl_gpu_env
      filter="DRIVER_ID_MESA_DOZEN"
    fi
    summary="$(probe_vulkaninfo_summary)" || exit 1
    vulkan_summary_gpus "${summary}" "${filter}"
  ) 2>/dev/null
}

# Prints the GPU auto renders on, of host_gpus' GPUS, as vulkan_summary_gpus
# prints it: the discrete one before an integrated one, else the first.
host_gpus_auto_choice() {
  local gpus="$1"
  local line

  [[ -n "${gpus}" ]] || return 1
  while IFS= read -r line; do
    if [[ "$(cut -f3 <<<"${line}")" == "PHYSICAL_DEVICE_TYPE_DISCRETE_GPU" ]]; then
      printf '%s\n' "${line}"
      return 0
    fi
  done <<<"${gpus}"
  while IFS= read -r line; do
    if [[ "$(cut -f3 <<<"${line}")" == "PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU" ]]; then
      printf '%s\n' "${line}"
      return 0
    fi
  done <<<"${gpus}"
  head -n 1 <<<"${gpus}"
}

# WSL2 reaches the host GPU only through Direct3D 12 (/dev/dxg), which Mesa's
# Dozen driver offers as Vulkan: 1.3 in Ika's build on a GPU with shader model
# 6.6 and wave operations, 1.2 on others, such as Kaby Lake's Iris Plus 650.
# gfxstream runs on it with these settings (GRAPHICS.md, "WSL2"):
# VK_DRIVER_FILES loads Ika's own Dozen build, with Ika's Lavapipe for the
# instance extensions gfxstream needs and Dozen does not list;
# IKA_DZN_FIX turns on the VK_LAYER_IKA_dzn_fix layer, which works
# around Dozen's gaps; and the
# libd3d12.so shim first in LD_LIBRARY_PATH makes every Vulkan instance share
# one D3D12 device, as WSL allows only a few per process and does not give
# back a released one's address space. setup_gpu_selection then picks the
# Dozen GPU (MESA_VK_DEVICE_SELECT), which gfxstream would otherwise rank
# below Lavapipe, and the adapter of Mesa's d3d12 OpenGL driver. Done only
# where Dozen finds a GPU. Keeps a VK_DRIVER_FILES the user set;
# IKA_SYSTEM_DOZEN=1 uses the distribution's Dozen instead of Ika's;
# IKA_WSL_GPU_FIX=0 turns all of it off.
setup_wsl_gpu_env() {
  local summary
  local dozen_icd="${PACKAGED_WSL_GPU_DIR}/dozen/dzn_icd.json"
  local lavapipe_icd="${PACKAGED_CVD_HOST_OUT}/bin/vk_lavapipe_icd.json"
  local driver_files=""
  local dozen_name="Mesa Dozen"

  [[ -e /dev/dxg && -d "${PACKAGED_WSL_GPU_DIR}" ]] || return 0
  [[ "${IKA_WSL_GPU_FIX:-1}" != "0" ]] || return 0
  # Already done by the ika that ran this one, as restart does to start.
  [[ -z "${IKA_WSL_GPU_ENV:-}" ]] || return 0
  if [[ -z "${VK_DRIVER_FILES:-}" && "${IKA_SYSTEM_DOZEN:-0}" != "1" &&
        -f "${dozen_icd}" && -f "${lavapipe_icd}" ]]; then
    driver_files="${dozen_icd}:${lavapipe_icd}"
    dozen_name="Ika's Mesa Dozen"
    summary="$(VK_DRIVER_FILES="${driver_files}" probe_vulkaninfo_summary)" || return 0
  else
    summary="$(probe_vulkaninfo_summary)" || return 0
  fi
  # A Dozen GPU, never WARP, Microsoft's software renderer
  vulkan_summary_preferred_gpu "${summary}" DRIVER_ID_MESA_DOZEN >/dev/null || return 0

  [[ -z "${driver_files}" ]] || export VK_DRIVER_FILES="${driver_files}"
  export IKA_DZN_FIX=1
  export LD_LIBRARY_PATH="${PACKAGED_WSL_GPU_DIR}/d3d12${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  export IKA_WSL_GPU_ENV=1
  log_start_note "WSL2: GPU through ${dozen_name}"
}

VULKANINFO_SUMMARY=""
# Empty until load_vulkaninfo_summary has run; then "ok" or "none".
VULKANINFO_SUMMARY_STATE=""

# What the summary depends on, as one line: the host boot, the drivers
# Vulkan loads, the ICD files the environment names or those in the loader's
# directories, by their modification times, and the environment that picks
# among the devices or changes what they report: Mesa's device selection, and
# the Dozen layer and D3D12 shim. setup_wsl_gpu_env probes before it sets
# those, and a summary from then lists Lavapipe beside Dozen, ranked above a
# Dozen GPU of Vulkan 1.2 where gfxstream would not see it.
vulkaninfo_cache_key() {
  local boot_id
  local -a paths=()
  local stamps

  read -r boot_id < /proc/sys/kernel/random/boot_id || return 1
  IFS=: read -r -a paths <<<"${VK_DRIVER_FILES:-}:${VK_ICD_FILENAMES:-}:${VK_ADD_DRIVER_FILES:-}"
  paths+=(/usr/share/vulkan/icd.d /usr/local/share/vulkan/icd.d /etc/vulkan/icd.d
          "${XDG_DATA_HOME:-${HOME}/.local/share}/vulkan/icd.d")
  stamps="$(stat -c '%n=%Y' "${paths[@]}" 2>/dev/null | tr '\n' ' ' || true)"
  printf '%s %s %s %s\n' "${boot_id}" \
    "${VK_DRIVER_FILES:-}|${VK_ICD_FILENAMES:-}|${VK_ADD_DRIVER_FILES:-}" \
    "${MESA_VK_DEVICE_SELECT:-}|${MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE:-}|${DRI_PRIME:-}|${__VK_LAYER_NV_optimus:-}|${IKA_DZN_FIX:-}|${LD_LIBRARY_PATH:-}" \
    "${stamps% }"
}

# Prints vulkaninfo's summary, kept for the host boot in a cache file (a key
# line, then the summary): the devices do not change within one, and the
# probe takes 0.2 s in every command on WSL (setup_wsl_gpu_env), twice for an
# app window with its supervisor.
probe_vulkaninfo_summary() {
  local cache_file="${CVD_TMP_DIR}/vulkaninfo-summary"
  local key=""
  local cached_key
  local summary

  command -v vulkaninfo >/dev/null 2>&1 || return 1

  if [[ -d "${CVD_TMP_DIR}" ]] && key="$(vulkaninfo_cache_key)"; then
    if { IFS= read -r cached_key && [[ "${cached_key}" == "${key}" ]] && cat; } \
        2>/dev/null < "${cache_file}"; then
      return 0
    fi
  fi

  # GPU classification does not need a presentation surface. Keep the probe
  # independent of X11/Wayland authentication, especially for SSH launches
  # that inherit DISPLAY without a usable authorization cookie.
  summary="$(env -u DISPLAY -u WAYLAND_DISPLAY vulkaninfo --summary 2>/dev/null)" \
    || return 1
  printf '%s\n' "${summary}"
  if [[ -n "${key}" ]]; then
    { (umask 077 && printf '%s\n%s\n' "${key}" "${summary}" > "${cache_file}.$$") \
        && mv -f "${cache_file}.$$" "${cache_file}"; } 2>/dev/null \
      || rm -f "${cache_file}.$$"
  fi
}

# Runs vulkaninfo once and keeps its summary for the GPU checks that follow,
# which each took a tenth of a second to run it again. Call it outside a
# command substitution, which would keep the result in a subshell.
load_vulkaninfo_summary() {
  [[ -z "${VULKANINFO_SUMMARY_STATE}" ]] || return 0
  if VULKANINFO_SUMMARY="$(probe_vulkaninfo_summary)"; then
    VULKANINFO_SUMMARY_STATE="ok"
  else
    VULKANINFO_SUMMARY=""
    VULKANINFO_SUMMARY_STATE="none"
  fi
}

vulkaninfo_summary() {
  load_vulkaninfo_summary
  [[ "${VULKANINFO_SUMMARY_STATE}" == "ok" ]] || return 1
  printf '%s\n' "${VULKANINFO_SUMMARY}"
}

vulkan_summary_has_only_software_devices() {
  local summary="$1"

  awk '
    function finish_device() {
      if (!in_device) {
        return
      }
      device_count++
      if (software_device) {
        software_count++
      }
    }
    /^GPU[0-9]+:/ {
      finish_device()
      in_device = 1
      software_device = 0
      next
    }
    in_device {
      line = tolower($0)
      if (line ~ /(llvmpipe|lavapipe|swiftshader|software rasterizer|software device)/) {
        software_device = 1
      }
    }
    END {
      finish_device()
      exit !(device_count > 0 && device_count == software_count)
    }
  ' <<<"${summary}"
}

# Whether the primary Vulkan device (GPU0) offers ETC2 textures as Venus's
# guest sees it: crosvm starts Venus's render server with vk_require_etc2 and
# vk_require_astc, which make drivers that can emulate them (RADV) offer them,
# so vulkaninfo runs with the same settings. Haswell's hasvk cannot. awk reads
# the whole report: leaving early would end vulkaninfo with SIGPIPE, which
# pipefail takes for a failure. with_timeout is a shell function, which env
# cannot run: it goes first, and runs env.
primary_vulkan_device_has_venus_etc2() {
  command -v vulkaninfo >/dev/null 2>&1 || return 1

  with_timeout 30 env -u DISPLAY -u WAYLAND_DISPLAY vk_require_etc2=true vk_require_astc=true \
    vulkaninfo 2>/dev/null | awk '
      /^GPU0:/ { in_gpu = 1; next }
      /^GPU[0-9]+:/ { in_gpu = 0 }
      in_gpu && !seen && $1 == "textureCompressionETC2" { seen = 1; found = ($3 == "true") }
      END { exit !found }
    '
}

# Whether this is a WSL2 distribution: Microsoft's kernel names itself in its
# release string (5.15.167.4-microsoft-standard-WSL2).
host_is_wsl2() {
  grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

# Whether gpu_mode=auto runs Venus here: the primary Vulkan device is a GPU
# with Vulkan 1.3 or newer and ETC2 textures as Venus's guest sees them, which
# Android expects of a Vulkan device and Chromium requires (gfxstream emulates
# ETC2, Venus does not), and this is not WSL2 or Apple Silicon. Prints why not
# when it does not suit.
host_suits_venus() {
  local primary_device
  local version
  local major
  local minor

  if host_is_wsl2; then
    printf '%s\n' "this is WSL2, whose GPU memory cannot be exported as dma-bufs"
    return 1
  fi
  # On the M1 Pro, 3DMark Wild Life Extreme scored 27%, Steel Nomad Light 14%
  # and Geekbench GPU 9% higher with gfxstream_guest_angle than with Venus.
  if host_is_apple_silicon; then
    printf '%s\n' "games run faster with gfxstream on the Apple GPU"
    return 1
  fi
  primary_device="$(primary_vulkan_device_summary || true)"
  if [[ -z "${primary_device}" ]]; then
    printf '%s\n' "no Vulkan device found"
    return 1
  fi
  if grep -Eiq '(llvmpipe|lavapipe|swiftshader|software rasterizer|software device|PHYSICAL_DEVICE_TYPE_CPU)' \
      <<<"${primary_device}"; then
    printf '%s\n' "the first Vulkan device is a software one"
    return 1
  fi
  if grep -q 'DRIVER_ID_MESA_DOZEN' <<<"${primary_device}"; then
    printf '%s\n' "Dozen cannot export its memory as dma-bufs"
    return 1
  fi
  version="$(awk -F'=' '/apiVersion/ { split($2, v, " "); print v[1]; exit }' <<<"${primary_device}")"
  IFS=. read -r major minor _ <<<"${version}"
  if ! [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "the GPU's Vulkan version is unknown"
    return 1
  fi
  if (( major < 1 || (major == 1 && minor < 3) )); then
    printf '%s\n' "the GPU's Vulkan is ${version}, below 1.3"
    return 1
  fi
  if ! primary_vulkan_device_has_venus_etc2; then
    printf '%s\n' "the GPU has no ETC2 textures, even emulated"
    return 1
  fi
}

default_gpu_mode_for_start() {
  local summary
  local passed_over
  local ini_mode
  local venus_blocker

  if user_supplied_flag "gpu_mode" "$@"; then
    start_arg_value "gpu_mode" "${CVD_GPU_DEFAULTS[gpu_mode]}" "$@"
    return 0
  fi

  summary="$(vulkaninfo_summary || true)"
  if [[ -n "${summary}" ]] && vulkan_summary_has_only_software_devices "${summary}"; then
    log "only software Vulkan devices detected; defaulting gpu_mode=gfxstream"
    printf '%s\n' "gfxstream"
    return 0
  fi
  # gfxstream_guest_angle would render everything on that software device.
  if passed_over="$(gfxstream_passes_over_hardware_vulkan)"; then
    log "gfxstream would render with ${passed_over}; defaulting gpu_mode=gfxstream"
    printf '%s\n' "gfxstream"
    return 0
  fi
  # A mode set in ika.ini stands on a GPU that gfxstream uses, unless this
  # start asked for auto.
  ika_ini_get ini_mode gpu gpu_mode auto
  [[ "${GPU_MODE_AUTO_REQUESTED}" != "true" ]] || ini_mode="auto"
  if [[ "${ini_mode,,}" != "auto" ]]; then
    printf '%s\n' "${CVD_GPU_DEFAULTS[gpu_mode]}"
    return 0
  fi
  if venus_blocker="$(host_suits_venus)"; then
    log "the GPU has Vulkan 1.3 or newer and ETC2 for Venus; defaulting gpu_mode=venus"
    printf '%s\n' "venus"
    return 0
  fi
  log "gpu_mode=auto keeps ${CVD_GPU_DEFAULTS[gpu_mode]}, not venus: ${venus_blocker}"

  printf '%s\n' "${CVD_GPU_DEFAULTS[gpu_mode]}"
}

primary_vulkan_device_is_llvmpipe() {
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

  grep -Eiq '(^[[:space:]]*(deviceName|driverName|driverID)[[:space:]]*=.*llvmpipe|DRIVER_ID_MESA_LLVMPIPE)' <<<"${primary_device}"
}

# Succeeds, printing "<software device> (Vulkan x.y.z) over <hardware device>
# (Vulkan x.y.z)", when gfxstream would render with a software Vulkan device
# although the summary lists a hardware one. gfxstream takes the first device
# with the highest score (getSelectedGpuIndex in
# host/vulkan/vk_common_operations.cpp, with
# PATCH.gfxstream.integrated-gpu-score.patch): its type (discrete 2000,
# integrated 1500, CPU 600, virtual 500, other 100) plus
# major * 5000 + min(minor, 10) * 500 + min(patch, 400) of its Vulkan version.
# An older GPU loses to llvmpipe that way: a Haswell GPU's Vulkan 1.2 against
# llvmpipe's 1.4. Fails when a device's type or version is missing.
vulkan_summary_gfxstream_passes_over_hardware() {
  local summary="$1"

  awk '
    BEGIN {
      type_score["PHYSICAL_DEVICE_TYPE_OTHER"] = 100
      type_score["PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU"] = 1500
      type_score["PHYSICAL_DEVICE_TYPE_DISCRETE_GPU"] = 2000
      type_score["PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU"] = 500
      type_score["PHYSICAL_DEVICE_TYPE_CPU"] = 600
    }
    function finish_device(    ver, v, minor, patch, score) {
      if (!in_device) {
        return
      }
      if (!(type in type_score) || !match(version, /[0-9]+\.[0-9]+\.[0-9]+/)) {
        unknown = 1
        return
      }
      ver = substr(version, RSTART, RLENGTH)
      split(ver, v, ".")
      minor = v[2] + 0
      patch = v[3] + 0
      if (minor > 10) {
        minor = 10
      }
      if (patch > 400) {
        patch = 400
      }
      score = type_score[type] + (v[1] + 0) * 5000 + minor * 500 + patch
      if (score > best_score) {
        best_score = score
        best_software = software_device
        best = name " (Vulkan " ver ")"
      }
      if (!software_device && score > hardware_score) {
        hardware_score = score
        hardware = name " (Vulkan " ver ")"
      }
    }
    /^GPU[0-9]+:/ {
      finish_device()
      in_device = 1
      software_device = 0
      type = ""
      version = ""
      name = ""
      next
    }
    in_device {
      line = $0
      if (tolower(line) ~ /(llvmpipe|lavapipe|swiftshader|software rasterizer|software device)/) {
        software_device = 1
      }
      if (line ~ /^[ \t]*[A-Za-z]+[ \t]*=/) {
        key = line
        sub(/^[ \t]*/, "", key)
        sub(/[ \t]*=.*/, "", key)
        value = line
        sub(/^[^=]*=[ \t]*/, "", value)
        sub(/[ \t\r]+$/, "", value)
        if (key == "deviceType") {
          type = value
        } else if (key == "apiVersion") {
          version = value
        } else if (key == "deviceName") {
          name = value
        }
      }
    }
    END {
      finish_device()
      if (unknown || hardware == "" || !best_software) {
        exit 1
      }
      print best " over " hardware
    }
  ' <<<"${summary}"
}

# The same for this host, unless ANDROID_EMU_VK_GPU_SELECT tells gfxstream which
# device to use. With a GPU selected on bare metal, which hides llvmpipe, what
# was found for that GPU before (IKA_GPU_PASSED_OVER, apply_gpu_selection).
gfxstream_passes_over_hardware_vulkan() {
  local summary

  [[ -z "${ANDROID_EMU_VK_GPU_SELECT:-}" ]] || return 1
  if [[ -n "${IKA_GPU_PASSED_OVER:-}" ]]; then
    printf '%s\n' "${IKA_GPU_PASSED_OVER}"
    return 0
  fi
  summary="$(vulkaninfo_summary || true)"
  [[ -n "${summary}" ]] || return 1
  vulkan_summary_gfxstream_passes_over_hardware "${summary}"
}

primary_vulkan_device_is_radv() {
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

  grep -Eiq '(^[[:space:]]*(deviceName|driverName|driverID)[[:space:]]*=.*radv|DRIVER_ID_MESA_RADV)' <<<"${primary_device}"
}

vulkan_device_summary_is_radv_vega_or_older() {
  local device_summary="$1"

  grep -Eiq '(^[[:space:]]*(deviceName|driverName|driverID)[[:space:]]*=.*radv|DRIVER_ID_MESA_RADV)' \
    <<<"${device_summary}" || return 1
  grep -Eiq "RADV[[:space:]_-]*${RADV_VEGA_OR_OLDER_FAMILY_REGEX}([^[:alnum:]_]|$)" \
    <<<"${device_summary}"
}

primary_vulkan_device_is_radv_vega_or_older() {
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

  vulkan_device_summary_is_radv_vega_or_older "${primary_device}"
}

