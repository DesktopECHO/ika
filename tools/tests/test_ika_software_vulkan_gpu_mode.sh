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

# gfxstream's own pick (vulkaninfo --summary of mb13, a Haswell MacBook Air, and
# of ryzen9, a Radeon 780M): Vulkan 1.2 loses to llvmpipe's 1.4, 1.4 does not.
haswell_summary=$'GPU0:\n\tapiVersion         = 1.2.354\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\n\tdeviceName         = Intel(R) HD Graphics 5000 (HSW GT3)\n\tdriverID           = DRIVER_ID_INTEL_OPEN_SOURCE_MESA\nGPU1:\n\tapiVersion         = 1.4.354\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_CPU\n\tdeviceName         = llvmpipe (LLVM 22.1.8, 256 bits)\n\tdriverID           = DRIVER_ID_MESA_LLVMPIPE'
radv_summary=$'GPU0:\n\tapiVersion         = 1.4.354\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\n\tdeviceName         = AMD Radeon 780M Graphics (RADV PHOENIX)\n\tdriverID           = DRIVER_ID_MESA_RADV\nGPU1:\n\tapiVersion         = 1.4.354\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_CPU\n\tdeviceName         = llvmpipe (LLVM 22.1.8, 256 bits)\n\tdriverID           = DRIVER_ID_MESA_LLVMPIPE'
# Equal scores (7600): gfxstream keeps the first device listed.
tie_llvmpipe_first=$'GPU0:\n  apiVersion = 1.4.0\n  deviceType = PHYSICAL_DEVICE_TYPE_CPU\n  deviceName = llvmpipe\nGPU1:\n  apiVersion = 1.2.100\n  deviceType = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\n  deviceName = GPU'
tie_gpu_first=$'GPU0:\n  apiVersion = 1.2.100\n  deviceType = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\n  deviceName = GPU\nGPU1:\n  apiVersion = 1.4.0\n  deviceType = PHYSICAL_DEVICE_TYPE_CPU\n  deviceName = llvmpipe'
untyped_summary=$'GPU0:\n  apiVersion = 1.2.354\n  deviceName = GPU\nGPU1:\n  apiVersion = 1.4.354\n  deviceType = PHYSICAL_DEVICE_TYPE_CPU\n  deviceName = llvmpipe'

assert_equal \
  "llvmpipe (LLVM 22.1.8, 256 bits) (Vulkan 1.4.354) over Intel(R) HD Graphics 5000 (HSW GT3) (Vulkan 1.2.354)" \
  "$(vulkan_summary_gfxstream_passes_over_hardware "${haswell_summary}")"
if vulkan_summary_gfxstream_passes_over_hardware "${radv_summary}" >/dev/null; then
  fail "a Vulkan 1.4 GPU was taken as passed over for llvmpipe"
fi
vulkan_summary_gfxstream_passes_over_hardware "${tie_llvmpipe_first}" >/dev/null || \
  fail "a tie with llvmpipe listed first did not pick llvmpipe"
if vulkan_summary_gfxstream_passes_over_hardware "${tie_gpu_first}" >/dev/null; then
  fail "a tie with the GPU listed first picked llvmpipe"
fi
if vulkan_summary_gfxstream_passes_over_hardware "${untyped_summary}" >/dev/null; then
  fail "a device without a type was scored"
fi
if vulkan_summary_gfxstream_passes_over_hardware "${software_summary}" >/dev/null; then
  fail "a host without a GPU was taken as passing over one"
fi

vulkaninfo_summary() {
  printf '%s\n' "${haswell_summary}"
}
assert_equal "gfxstream" "$(default_gpu_mode_for_start)"
assert_equal "gfxstream_guest_angle" \
  "$(default_gpu_mode_for_start --gpu_mode=gfxstream_guest_angle)"
if ANDROID_EMU_VK_GPU_SELECT=0 gfxstream_passes_over_hardware_vulkan >/dev/null; then
  fail "ANDROID_EMU_VK_GPU_SELECT did not leave the choice to gfxstream"
fi

vulkaninfo_summary() {
  printf '%s\n' "${radv_summary}"
}
assert_equal "gfxstream_guest_angle" "$(default_gpu_mode_for_start)"

printf 'PASS: software-only and passed-over Vulkan GPU mode selection\n'