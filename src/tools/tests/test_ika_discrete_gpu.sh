#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
mkdir -p "${HOME}"
source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  [[ "${actual}" == "${expected}" ]] || fail "expected '${expected}', got '${actual}'"
}

device() {
  printf 'GPU%s:\n\tapiVersion         = %s\n\tvendorID           = %s\n\tdeviceID           = %s\n' "$1" "$2" "$3" "$4"
  printf '\tdeviceType         = %s\n\tdeviceName         = %s\n\tdriverID           = %s\n' "$5" "$6" "$7"
}

nvidia_dozen="$(device 0 1.3.363 0x10de 0x27a0 PHYSICAL_DEVICE_TYPE_DISCRETE_GPU \
  'Microsoft Direct3D12 (NVIDIA GeForce RTX 4080 Laptop GPU)' DRIVER_ID_MESA_DOZEN)"
intel_dozen="$(device 1 1.3.363 0x8086 0x4688 PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU \
  'Microsoft Direct3D12 (Intel(R) UHD Graphics)' DRIVER_ID_MESA_DOZEN)"
warp_dozen="$(device 0 1.3.363 0x1414 0x008c PHYSICAL_DEVICE_TYPE_CPU \
  'Microsoft Direct3D12 (Microsoft Basic Render Driver)' DRIVER_ID_MESA_DOZEN)"
llvmpipe="$(device 2 1.4.363 0x10005 0x0000 PHYSICAL_DEVICE_TYPE_CPU \
  'llvmpipe (LLVM 19.1.7, 256 bits)' DRIVER_ID_MESA_LLVMPIPE)"
radv_igpu="$(device 0 1.4.335 0x1002 0x1900 PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU \
  'AMD Radeon 780M Graphics (RADV PHOENIX)' DRIVER_ID_MESA_RADV)"
radv_dgpu="$(device 1 1.3.287 0x1002 0x73bf PHYSICAL_DEVICE_TYPE_DISCRETE_GPU \
  'AMD Radeon RX 6800 XT (RADV NAVI21)' DRIVER_ID_MESA_RADV)"
anv_igpu="$(device 0 1.4.335 0x8086 0x9bc4 PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU \
  'Intel(R) UHD Graphics (CML GT2)' DRIVER_ID_INTEL_OPEN_SOURCE_MESA)"
nvidia_blob="$(device 1 1.3.277 0x10de 0x2520 PHYSICAL_DEVICE_TYPE_DISCRETE_GPU \
  'NVIDIA GeForce RTX 3060 Laptop GPU' DRIVER_ID_NVIDIA_PROPRIETARY)"

summary() {
  printf 'Devices:\n========\n'
  printf '%s\n' "$@"
}

# WSL2, both adapters of a hybrid laptop in either order: the discrete one.
msi="$(summary "${nvidia_dozen}" "${intel_dozen}" "${llvmpipe}")"
gpu="$(vulkan_summary_preferred_gpu "${msi}" DRIVER_ID_MESA_DOZEN)"
assert_equal $'10de:27a0\tMicrosoft Direct3D12 (NVIDIA GeForce RTX 4080 Laptop GPU)\tPHYSICAL_DEVICE_TYPE_DISCRETE_GPU\tDRIVER_ID_MESA_DOZEN\t1' "${gpu}"
msi_intel_first="$(summary "${intel_dozen}" "${nvidia_dozen}" "${llvmpipe}")"
gpu="$(vulkan_summary_preferred_gpu "${msi_intel_first}" DRIVER_ID_MESA_DOZEN)"
assert_equal "10de:27a0" "${gpu%%$'\t'*}"
echo "ok: the discrete Dozen GPU wins in either order"

# Hybrid graphics set to the integrated GPU: the only one, never WARP.
intel_only="$(summary "${warp_dozen}" "${intel_dozen}" "${llvmpipe}")"
gpu="$(vulkan_summary_preferred_gpu "${intel_only}" DRIVER_ID_MESA_DOZEN)"
assert_equal $'8086:4688\tMicrosoft Direct3D12 (Intel(R) UHD Graphics)\tPHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\tDRIVER_ID_MESA_DOZEN\t0' "${gpu}"
if vulkan_summary_preferred_gpu "$(summary "${warp_dozen}" "${llvmpipe}")" DRIVER_ID_MESA_DOZEN >/dev/null; then
  fail "WARP was taken for a GPU"
fi
echo "ok: the integrated GPU when it is the only one, never WARP"

# The adapter a user's own MESA_VK_DEVICE_SELECT names, however spelled.
gpu="$(vulkan_summary_preferred_gpu "${msi}" DRIVER_ID_MESA_DOZEN '0x8086:0x4688!')"
assert_equal "Microsoft Direct3D12 (Intel(R) UHD Graphics)" "$(cut -f2 <<<"${gpu}")"
if vulkan_summary_preferred_gpu "${msi}" DRIVER_ID_MESA_DOZEN '1002:73bf!' >/dev/null; then
  fail "a device the summary does not list was found"
fi
echo "ok: a device named by MESA_VK_DEVICE_SELECT is looked up"

# Bare metal: a discrete GPU of an older Vulkan beside an integrated one.
gpu="$(vulkan_summary_preferred_gpu "$(summary "${radv_igpu}" "${radv_dgpu}" "${llvmpipe}")")"
assert_equal $'1002:73bf\tAMD Radeon RX 6800 XT (RADV NAVI21)\tPHYSICAL_DEVICE_TYPE_DISCRETE_GPU\tDRIVER_ID_MESA_RADV\t1' "${gpu}"
echo "ok: a discrete GPU wins over a newer Vulkan version"

honeykrisp="$(device 0 1.4.335 0x10005 0x0000 PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU \
  'Apple M1 Pro (G13S C0)' DRIVER_ID_MESA_HONEYKRISP)"

# The GPUs "GPU Hardware" offers: the hardware ones in the order listed, each ID
# once, never llvmpipe or WARP; Dozen's alone on WSL2.
expect_gpus="1002:1900	AMD Radeon 780M Graphics (RADV PHOENIX)	PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU	DRIVER_ID_MESA_RADV
1002:73bf	AMD Radeon RX 6800 XT (RADV NAVI21)	PHYSICAL_DEVICE_TYPE_DISCRETE_GPU	DRIVER_ID_MESA_RADV"
assert_equal "${expect_gpus}" \
  "$(vulkan_summary_gpus "$(summary "${radv_igpu}" "${radv_dgpu}" "${llvmpipe}" "${radv_dgpu}")")"
assert_equal $'10de:27a0\n8086:4688' \
  "$(vulkan_summary_gpus "$(summary "${warp_dozen}" "${nvidia_dozen}" "${intel_dozen}" "${llvmpipe}")" DRIVER_ID_MESA_DOZEN | cut -f1)"
assert_equal "Intel(R) UHD Graphics" "$(gpu_display_name "Microsoft Direct3D12 (Intel(R) UHD Graphics)")"
assert_equal "$(cut -f2 <<<"${expect_gpus}" | tail -1)" "$(cut -f2 <<<"$(host_gpus_auto_choice "${expect_gpus}")")"
echo "ok: the GPUs to choose from"

# GPU Hardware as ika.ini or IKA_GPU spells it
assert_equal "auto" "$(normalize_gpu_device AUTO)"
assert_equal "10de:27a0" "$(normalize_gpu_device 0x10DE:0x27A0!)"
assert_equal "10005:0" "$(normalize_gpu_device 10005:0000)"
if normalize_gpu_device "NVIDIA" >/dev/null; then
  fail "a name was taken for a GPU ID"
fi
echo "ok: GPU IDs"

# The Apple GPU and llvmpipe share an ID: the GPU is the one found.
gpu="$(vulkan_summary_preferred_gpu "$(summary "${llvmpipe}" "${honeykrisp}")" "" 10005:0)"
assert_equal "Apple M1 Pro (G13S C0)" "$(cut -f2 <<<"${gpu}")"
echo "ok: a GPU ID that llvmpipe shares"

# setup_gpu_selection, with the summary, the PCI slots, the render nodes, the
# drivers and EGL vendors stubbed. FAKE_ICDS is what the GPU's own Vulkan
# driver is found in; the summary then lists FAKE_ICD_SUMMARY.
FAKE_SUMMARY=""
FAKE_ICDS=""
FAKE_ICD_SUMMARY=""
FAKE_DXG=false
probe_vulkaninfo_summary() {
  if [[ -n "${VK_DRIVER_FILES:-}" && "${VK_DRIVER_FILES}" == "${FAKE_ICDS}" ]]; then
    printf '%s\n' "${FAKE_ICD_SUMMARY}"
  else
    printf '%s\n' "${FAKE_SUMMARY}"
  fi
}
pci_slot_of_gpu() {
  case "$1" in
    1002:73bf) printf '0000:03:00.0\n' ;;
    1002:1900|8086:9bc4) printf '0000:c6:00.0\n' ;;
    *) return 1 ;;
  esac
}
render_node_of_pci_slot() { [[ "$1" == "0000:03:00.0" ]] && printf '/dev/dri/renderD129\n'; }
vulkan_icd_files_for_driver() { [[ -n "${FAKE_ICDS}" ]] && printf '%s\n' "${FAKE_ICDS}"; }
egl_vendor_file() { return 1; }
has_live_cvd_processes() { return 1; }
FAKE_RENDER_GPUS=1
host_render_gpu_count() { printf '%s\n' "${FAKE_RENDER_GPUS}"; }
host_has_dxg() { [[ "${FAKE_DXG}" == "true" ]]; }
show_env() {
  printf '%s|%s|%s|%s|%s\n' "${MESA_VK_DEVICE_SELECT:-}" "${DRI_PRIME:-}" "${VK_DRIVER_FILES:-}" \
    "${IKA_GPU_RENDER_NODE:-}" "${MESA_D3D12_DEFAULT_ADAPTER_NAME:-}"
}
# run_setup SUMMARY [IKA_GPU [NAME=VALUE...]]
run_setup() {
  FAKE_SUMMARY="$1"
  START_LOG_NOTES=()
  (
    unset MESA_VK_DEVICE_SELECT DRI_PRIME VK_DRIVER_FILES VK_ICD_FILENAMES MESA_D3D12_DEFAULT_ADAPTER_NAME \
      IKA_GPU_RENDER_NODE IKA_WSL_GPU_ENV IKA_GPU_ENV
    IKA_GPU="${2:-auto}"
    for assignment in "${@:3}"; do
      export "${assignment}"
    done
    setup_gpu_selection start
    show_env
  )
}

assert_equal "1002:73bf!|pci-0000_03_00_0||/dev/dri/renderD129|" \
  "$(run_setup "$(summary "${radv_igpu}" "${radv_dgpu}" "${llvmpipe}")")"
assert_equal "10de:2520!||||" "$(run_setup "$(summary "${anv_igpu}" "${nvidia_blob}" "${llvmpipe}")")"
assert_equal "||||" "$(run_setup "$(summary "${radv_igpu}" "${llvmpipe}")")"
assert_equal "8086:9bc4||||" \
  "$(run_setup "$(summary "${anv_igpu}" "${radv_dgpu}")" auto MESA_VK_DEVICE_SELECT=8086:9bc4)"
assert_equal "|1|||" "$(run_setup "$(summary "${anv_igpu}" "${radv_dgpu}")" 1002:73bf DRI_PRIME=1)"
# A discrete GPU beside an integrated one without a Vulkan driver, which only
# its render node shows; alone, it is left as it is.
FAKE_RENDER_GPUS=2
assert_equal "1002:73bf!|pci-0000_03_00_0||/dev/dri/renderD129|" "$(run_setup "$(summary "${radv_dgpu}" "${llvmpipe}")")"
assert_equal "||||" "$(run_setup "$(summary "${radv_igpu}" "${llvmpipe}")")"
FAKE_RENDER_GPUS=1
assert_equal "||||" "$(run_setup "$(summary "${radv_dgpu}" "${llvmpipe}")")"
echo "ok: auto renders on the discrete GPU only beside another GPU, the user's environment wins"

# A GPU chosen: the integrated one beside a discrete one; the only GPU, which
# auto leaves alone; a GPU the host lacks is taken as auto.
assert_equal "1002:1900!|pci-0000_c6_00_0|||" \
  "$(run_setup "$(summary "${radv_igpu}" "${radv_dgpu}" "${llvmpipe}")" 0x1002:0x1900)"
assert_equal "1002:1900!|pci-0000_c6_00_0|||" "$(run_setup "$(summary "${radv_igpu}" "${llvmpipe}")" 1002:1900)"
assert_equal "1002:73bf!|pci-0000_03_00_0||/dev/dri/renderD129|" \
  "$(run_setup "$(summary "${radv_igpu}" "${radv_dgpu}" "${llvmpipe}")" 10de:2704)"
echo "ok: the GPU chosen"

# Only the GPU's own Vulkan driver loads, when it lists the GPU on its own;
# the Apple GPU then without llvmpipe, which shares its ID.
FAKE_ICDS="/usr/share/vulkan/icd.d/asahi_icd.json"
FAKE_ICD_SUMMARY="$(summary "${honeykrisp}")"
assert_equal "10005:0!||/usr/share/vulkan/icd.d/asahi_icd.json||" \
  "$(run_setup "$(summary "${honeykrisp}" "${llvmpipe}")" 10005:0)"
FAKE_ICD_SUMMARY="$(summary "${llvmpipe}")"
assert_equal "10005:0!||||" "$(run_setup "$(summary "${honeykrisp}" "${llvmpipe}")" 10005:0)"
FAKE_ICDS=""
FAKE_ICD_SUMMARY=""
echo "ok: only the GPU's own Vulkan driver"

# WSL2, with Ika's GPU setup: Dozen's discrete GPU by default, the GPU
# chosen, the OpenGL adapter of the user's MESA_VK_DEVICE_SELECT; nothing
# without Ika's setup.
FAKE_DXG=true
assert_equal "10de:27a0!||||NVIDIA GeForce RTX 4080 Laptop GPU" \
  "$(run_setup "${msi_intel_first}" auto IKA_WSL_GPU_ENV=1)"
assert_equal "8086:4688!||||Intel(R) UHD Graphics" \
  "$(run_setup "${msi}" 8086:4688 IKA_WSL_GPU_ENV=1)"
assert_equal "10de:27a0!||||NVIDIA GeForce RTX 4080 Laptop GPU" \
  "$(run_setup "${msi}" 1002:73bf IKA_WSL_GPU_ENV=1)"
assert_equal "8086:4688!||||Intel(R) UHD Graphics" \
  "$(run_setup "${msi}" auto IKA_WSL_GPU_ENV=1 MESA_VK_DEVICE_SELECT=8086:4688!)"
assert_equal "||||" "$(run_setup "${msi}" 8086:4688)"
FAKE_DXG=false
echo "ok: WSL2"

# An ika run by one that selected a GPU (restart) undoes that selection, and
# selects again from ika.ini as it is then; what the user set stays.
FAKE_SUMMARY="$(summary "${radv_igpu}" "${radv_dgpu}" "${llvmpipe}")"
result="$(
  unset MESA_VK_DEVICE_SELECT DRI_PRIME VK_DRIVER_FILES IKA_GPU_RENDER_NODE
  export RADV_DEBUG=mine
  IKA_GPU=1002:1900
  setup_gpu_selection start
  first="$(show_env)"
  IKA_GPU=auto
  setup_gpu_selection restart
  printf '%s\n%s\n%s\n' "${first}" "$(show_env)" "${RADV_DEBUG}"
  restore_gpu_env
  show_env
)"
assert_equal "1002:1900!|pci-0000_c6_00_0|||
1002:73bf!|pci-0000_03_00_0||/dev/dri/renderD129|
mine
||||" "${result}"
echo "ok: a restart selects again"

# A GPU gfxstream would rank below llvmpipe, chosen on bare metal, which
# hides llvmpipe: the GPU mode is chosen as before, gfxstream with OpenGL ES
# on that GPU; a newer GPU, or WSL2's Dozen GPU of Vulkan 1.2, is unaffected.
haswell="$(device 0 1.2.311 0x8086 0x0416 PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU \
  'Intel(R) HD Graphics 4600 (HSW GT2)' DRIVER_ID_INTEL_OPEN_SOURCE_MESA)"
passed_over_of() {
  FAKE_SUMMARY="$1"
  START_LOG_NOTES=()
  (
    unset MESA_VK_DEVICE_SELECT DRI_PRIME VK_DRIVER_FILES IKA_GPU_PASSED_OVER IKA_GPU_ENV IKA_WSL_GPU_ENV
    IKA_GPU="$2"
    for assignment in "${@:3}"; do
      export "${assignment}"
    done
    setup_gpu_selection start
    printf '%s\n' "${IKA_GPU_PASSED_OVER:-}"
    # what gfxstream ranks now: the GPU alone
    vulkaninfo_summary() { summary "${haswell}"; }
    gfxstream_passes_over_hardware_vulkan >/dev/null && default_gpu_mode_for_start
  )
}
assert_equal "llvmpipe (LLVM 19.1.7, 256 bits) (Vulkan 1.4.363) over Intel(R) HD Graphics 4600 (HSW GT2) (Vulkan 1.2.311)
gfxstream" "$(passed_over_of "$(summary "${haswell}" "${llvmpipe}")" 8086:416 2>/dev/null)"
assert_equal "" "$(passed_over_of "$(summary "${radv_igpu}" "${llvmpipe}")" 1002:1900 2>/dev/null)"
assert_equal "" "$(passed_over_of "$(summary "${radv_igpu}" "${radv_dgpu}" "${llvmpipe}")" auto 2>/dev/null)"
dozen_12="$(device 0 1.2.363 0x8086 0x5927 PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU \
  'Microsoft Direct3D12 (Intel(R) Iris(R) Plus Graphics 650)' DRIVER_ID_MESA_DOZEN)"
FAKE_DXG=true
assert_equal "" "$(passed_over_of "$(summary "${dozen_12}" "${llvmpipe}")" auto IKA_WSL_GPU_ENV=1 2>/dev/null)"
FAKE_DXG=false
echo "ok: an older GPU chosen keeps the GPU mode auto chose for it"

# The running VM's GPU stands for a console or app window opened while it
# runs, but not for a restart.
mkdir -p "${CVD_TMP_DIR}"
printf '1002:1900\n' >"${GPU_IN_USE_FILE}"
has_live_cvd_processes() { return 0; }
IKA_GPU=auto
assert_equal "1002:1900" "$(gpu_device_setting app)"
assert_equal "auto" "$(gpu_device_setting restart)"
has_live_cvd_processes() { return 1; }
assert_equal "auto" "$(gpu_device_setting start)"
echo "ok: the running VM's GPU"
