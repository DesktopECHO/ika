#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
# No ika.ini: the host's own gpu_mode would decide the cases below.
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
  [[ "${actual}" == "${expected}" ]] || \
    fail "expected '${expected}', got '${actual}'"
}

# The real ETC2 probe, kept under another name, reads a fake vulkaninfo: GPU0
# with ETC2 as given by FAKE_ETC2, GPU1 the opposite, then a long tail that
# would end vulkaninfo with SIGPIPE if the parser stopped reading early.
eval "real_$(declare -f primary_vulkan_device_has_venus_etc2)"
mkdir -p "${T}/bin"
cat >"${T}/bin/vulkaninfo" <<'STUB'
#!/usr/bin/env bash
[[ "${vk_require_etc2:-}" == "true" && "${vk_require_astc:-}" == "true" ]] || exit 1
other=true; [[ "${FAKE_ETC2}" == "true" ]] && other=false
printf 'Devices:\n========\nGPU0:\nVkPhysicalDeviceFeatures:\n\ttextureCompressionETC2                  = %s\n' "${FAKE_ETC2}"
printf 'GPU1:\nVkPhysicalDeviceFeatures:\n\ttextureCompressionETC2                  = %s\n' "${other}"
for i in $(seq 20000); do printf '\tsome feature %d = true\n' "${i}"; done
STUB
chmod +x "${T}/bin/vulkaninfo"
PATH="${T}/bin:${PATH}" FAKE_ETC2=true real_primary_vulkan_device_has_venus_etc2 || \
  fail "GPU0's ETC2 under vk_require_etc2 was not found"
if PATH="${T}/bin:${PATH}" FAKE_ETC2=false real_primary_vulkan_device_has_venus_etc2; then
  fail "GPU1's ETC2 was taken for GPU0's"
fi
echo "ok: the ETC2 probe reads GPU0 as Venus's render server runs"

# Elsewhere ETC2 as Venus's guest sees it is what the test says
# (TEST_VENUS_ETC2=1), never the machine it runs on.
primary_vulkan_device_has_venus_etc2() {
  [[ "${TEST_VENUS_ETC2:-0}" == "1" ]]
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
echo "ok: software-only and passed-over Vulkan"

# auto is venus on any GPU with Vulkan 1.3 or newer and ETC2 as Venus sees it
# (ryzen9's RADV emulates it, mb11's Broadwell and mbp16's M1 have it): the
# summaries of those hosts, and an NVIDIA GPU's.
broadwell_summary=$'GPU0:\n\tapiVersion         = 1.3.354\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\n\tdeviceName         = Intel(R) HD Graphics 6000 (BDW GT3)\n\tdriverID           = DRIVER_ID_INTEL_OPEN_SOURCE_MESA\nGPU1:\n\tapiVersion         = 1.4.354\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_CPU\n\tdeviceName         = llvmpipe (LLVM 22.1.8, 256 bits)\n\tdriverID           = DRIVER_ID_MESA_LLVMPIPE'
honeykrisp_summary=$'GPU0:\n\tapiVersion         = 1.4.354\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\n\tdeviceName         = Apple M1 Pro (G13S C0)\n\tdriverName         = Honeykrisp'
nvidia_summary=$'GPU0:\n\tapiVersion         = 1.4.312\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\n\tdeviceName         = NVIDIA GeForce RTX 4070\n\tdriverID           = DRIVER_ID_NVIDIA_PROPRIETARY'
# (case_summary: default_gpu_mode_for_start has a local "summary" of its own)
for case_summary in "${radv_summary}" "${broadwell_summary}" "${honeykrisp_summary}" "${nvidia_summary}"; do
  vulkaninfo_summary() {
    printf '%s\n' "${case_summary}"
  }
  assert_equal "venus" "$(TEST_VENUS_ETC2=1 default_gpu_mode_for_start)"
  # No ETC2, even emulated: gfxstream_guest_angle, and the reason
  assert_equal "gfxstream_guest_angle" "$(TEST_VENUS_ETC2=0 default_gpu_mode_for_start)"
  assert_equal "the GPU has no ETC2 textures, even emulated" "$(TEST_VENUS_ETC2=0 host_suits_venus || true)"
  # --gpu_mode= still wins
  assert_equal "gfxstream_guest_angle" \
    "$(TEST_VENUS_ETC2=1 default_gpu_mode_for_start --gpu_mode=gfxstream_guest_angle)"
done

# A mode set in ika.ini stands, even the built-in one; "Auto" is auto.
IKA_INI[gpu.gpu_mode]="gfxstream_guest_angle"
assert_equal "gfxstream_guest_angle" "$(TEST_VENUS_ETC2=1 default_gpu_mode_for_start)"
IKA_INI[gpu.gpu_mode]="Auto"
assert_equal "venus" "$(TEST_VENUS_ETC2=1 default_gpu_mode_for_start)"
unset 'IKA_INI[gpu.gpu_mode]'

# A GPU below Vulkan 1.3 that gfxstream keeps (the GPU listed first in a tie)
# stays on gfxstream_guest_angle; so does one whose version is unknown.
vulkaninfo_summary() {
  printf '%s\n' "${tie_gpu_first}"
}
assert_equal "gfxstream_guest_angle" "$(TEST_VENUS_ETC2=1 default_gpu_mode_for_start)"
assert_equal "the GPU's Vulkan is 1.2.100, below 1.3" "$(TEST_VENUS_ETC2=1 host_suits_venus || true)"
vulkaninfo_summary() {
  printf '%s\n' "${hardware_summary}"
}
assert_equal "gfxstream_guest_angle" "$(TEST_VENUS_ETC2=1 default_gpu_mode_for_start)"
assert_equal "the GPU's Vulkan version is unknown" "$(TEST_VENUS_ETC2=1 host_suits_venus || true)"

# Haswell (mb13) is passed over for llvmpipe before Venus is considered, and a
# software first device never gets Venus.
vulkaninfo_summary() {
  printf '%s\n' "${haswell_summary}"
}
assert_equal "gfxstream" "$(TEST_VENUS_ETC2=1 default_gpu_mode_for_start)"
vulkaninfo_summary() {
  printf '%s\n' "${tie_llvmpipe_first}"
}
assert_equal "the first Vulkan device is a software one" "$(TEST_VENUS_ETC2=1 host_suits_venus || true)"
vulkaninfo_summary() {
  return 1
}
assert_equal "no Vulkan device found" "$(TEST_VENUS_ETC2=1 host_suits_venus || true)"
echo "ok: auto is venus on a Vulkan 1.3 GPU with ETC2"

printf 'PASS: software-only, passed-over and Venus GPU mode selection\n'