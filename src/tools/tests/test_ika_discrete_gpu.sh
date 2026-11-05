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

# setup_discrete_gpu_env, with the summary and the PCI slot stubbed.
FAKE_SUMMARY=""
probe_vulkaninfo_summary() { printf '%s\n' "${FAKE_SUMMARY}"; }
pci_slot_of_gpu() { [[ "$1" == "1002:73bf" ]] && printf '0000:03:00.0\n'; }
run_setup() {
  FAKE_SUMMARY="$1"
  START_LOG_NOTES=()
  (
    unset MESA_VK_DEVICE_SELECT DRI_PRIME
    [[ -z "${2:-}" ]] || export "$2"
    setup_discrete_gpu_env
    printf '%s|%s\n' "${MESA_VK_DEVICE_SELECT:-}" "${DRI_PRIME:-}"
  )
}
if [[ ! -e /dev/dxg ]]; then
  assert_equal "1002:73bf!|pci-0000_03_00_0" \
    "$(run_setup "$(summary "${radv_igpu}" "${radv_dgpu}" "${llvmpipe}")")"
  assert_equal "10de:2520!|" "$(run_setup "$(summary "${anv_igpu}" "${nvidia_blob}" "${llvmpipe}")")"
  assert_equal "|" "$(run_setup "$(summary "${radv_igpu}" "${llvmpipe}")")"
  assert_equal "|" "$(run_setup "$(summary "$(device 0 1.3.277 0x10de 0x2520 \
    PHYSICAL_DEVICE_TYPE_DISCRETE_GPU 'NVIDIA GeForce RTX 3060' DRIVER_ID_NVIDIA_PROPRIETARY)" "${llvmpipe}")")"
  assert_equal "8086:9bc4|" \
    "$(run_setup "$(summary "${anv_igpu}" "${radv_dgpu}")" MESA_VK_DEVICE_SELECT=8086:9bc4)"
  assert_equal "|1" "$(run_setup "$(summary "${anv_igpu}" "${radv_dgpu}")" DRI_PRIME=1)"
  echo "ok: bare metal renders on the discrete GPU only beside another GPU, the user's choice wins"
fi
