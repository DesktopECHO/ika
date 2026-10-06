#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  [[ "${actual}" == "${expected}" ]] || \
    fail "expected '${expected}', got '${actual}'"
}

software_summary=$'GPU0:\n  deviceName = llvmpipe (LLVM 19.1.7, 256 bits)\n  driverID = DRIVER_ID_MESA_LLVMPIPE\n  driverName = llvmpipe'
multiple_software_summary=$'GPU0:\n  deviceName = llvmpipe\nGPU1:\n  deviceName = SwiftShader Device (Subzero)\n  driverName = SwiftShader'
hardware_summary=$'GPU0:\n  deviceName = AMD Radeon RX 7900 XTX\n  driverID = DRIVER_ID_MESA_RADV\n  driverName = radv'
mixed_summary="${software_summary}"$'\nGPU1:\n  deviceName = AMD Radeon RX 7900 XTX\n  driverID = DRIVER_ID_MESA_RADV'
unknown_summary=$'GPU0:\n  deviceName = Vulkan Device\n  driverName = vendor-driver'

vulkan_summary_has_only_software_devices "${software_summary}" || \
  fail "single software Vulkan device was not detected"
vulkan_summary_has_only_software_devices "${multiple_software_summary}" || \
  fail "multiple software Vulkan devices were not detected"
if vulkan_summary_has_only_software_devices "${hardware_summary}"; then
  fail "hardware Vulkan device was classified as software"
fi
if vulkan_summary_has_only_software_devices "${mixed_summary}"; then
  fail "mixed software/hardware Vulkan devices were classified as software-only"
fi
if vulkan_summary_has_only_software_devices "${unknown_summary}"; then
  fail "unknown Vulkan device was classified as software"
fi
if vulkan_summary_has_only_software_devices ""; then
  fail "empty Vulkan summary was classified as software-only"
fi

vulkaninfo_summary() {
  printf '%s\n' "${software_summary}"
}
assert_equal "gfxstream" "$(default_gpu_mode_for_start)"

vulkaninfo_summary() {
  printf '%s\n' "${hardware_summary}"
}
assert_equal "gfxstream_guest_angle" "$(default_gpu_mode_for_start)"

vulkaninfo_summary() {
  printf '%s\n' "${software_summary}"
}
assert_equal "guest_swiftshader" \
  "$(default_gpu_mode_for_start --gpu_mode=guest_swiftshader)"

vulkaninfo_summary() {
  return 1
}
assert_equal "gfxstream_guest_angle" "$(default_gpu_mode_for_start)"

printf 'PASS: software-only Vulkan GPU mode selection\n'