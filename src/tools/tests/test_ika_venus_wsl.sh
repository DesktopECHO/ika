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
  [[ "${actual}" == "${expected}" ]] || \
    fail "expected '${expected}', got '${actual}'"
}

# A fake vulkaninfo with Dozen's GPU as GPU0: Vulkan 1.3, ETC2 and ASTC (which
# Ika's Dozen emulates under vk_require_etc2 and vk_require_astc), but none of the dma-buf extensions
# Venus shares Android's buffers through on Linux.
mkdir -p "${T}/bin"
cat >"${T}/bin/vulkaninfo" <<'STUB'
#!/usr/bin/env bash
[[ "${vk_require_etc2:-}" == "true" && "${vk_require_astc:-}" == "true" ]] || exit 1
printf 'Devices:\n========\nGPU0:\nVkPhysicalDeviceFeatures:\n\ttextureCompressionETC2                  = %s\n\ttextureCompressionASTC_LDR              = true\n' "${TEST_DOZEN_ETC2:-true}"
printf 'Device Extensions: count = 2\n\tVK_KHR_swapchain : extension revision 70\n\tVK_KHR_external_memory_fd : extension revision 1\n'
STUB
chmod +x "${T}/bin/vulkaninfo"
export PATH="${T}/bin:${PATH}"

host_is_wsl2() { false; }
assert_equal "VK_EXT_external_memory_dma_buf VK_EXT_image_drm_format_modifier VK_EXT_queue_family_foreign" \
  "$(primary_vulkan_device_missing_venus_extensions)"
echo "ok: off WSL2, a driver without dma-bufs lacks what Venus needs"

# Under WSL2 Venus shares Android's buffers as Dozen's opaque fds, so the
# dma-buf extensions do not stop --gpu_mode=venus or gpu_mode = venus.
host_is_wsl2() { true; }
assert_equal "" "$(primary_vulkan_device_missing_venus_extensions)"
echo "ok: under WSL2 nothing Venus needs is missing"

# gpu_mode=auto runs Venus under WSL2 where Dozen offers Vulkan 1.3, and keeps
# gfxstream_guest_angle where it offers 1.2 (Kaby Lake's Iris Plus 650), with
# the reason. The host is never the machine the test runs on.
host_is_apple_silicon() { false; }
gfxstream_passes_over_hardware_vulkan() { return 1; }
vulkaninfo_summary() {
  printf 'GPU0:\n  apiVersion = %s\n  deviceName = Microsoft Direct3D12 (Test GPU)\n  driverID = DRIVER_ID_MESA_DOZEN\n' \
    "${TEST_DOZEN_VERSION}"
}
assert_equal "venus" "$(TEST_DOZEN_VERSION=1.3.363 default_gpu_mode_for_start 2>/dev/null)"
echo "ok: under WSL2 auto runs Venus on Dozen with Vulkan 1.3"
assert_equal "gfxstream_guest_angle" "$(TEST_DOZEN_VERSION=1.2.363 default_gpu_mode_for_start 2>/dev/null)"
[[ "$(TEST_DOZEN_VERSION=1.2.363 default_gpu_mode_for_start 2>&1 >/dev/null)" \
    == *"not venus: the GPU's Vulkan is 1.2.363, below 1.3"* ]] \
  || fail "no reason logged for keeping gfxstream_guest_angle on Vulkan 1.2"
echo "ok: under WSL2 auto keeps gfxstream_guest_angle on Dozen with Vulkan 1.2"

# A Dozen without Ika's ETC2 decoding (the distribution's, or an older Ika's)
# keeps gfxstream_guest_angle, which emulates ETC2 itself.
assert_equal "gfxstream_guest_angle" \
  "$(TEST_DOZEN_ETC2=false TEST_DOZEN_VERSION=1.3.363 default_gpu_mode_for_start 2>/dev/null)"
echo "ok: under WSL2 auto keeps gfxstream_guest_angle on a Dozen without ETC2"
