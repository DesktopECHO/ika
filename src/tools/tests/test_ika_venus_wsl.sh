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

# A fake vulkaninfo with Dozen's GPU as GPU0: Vulkan 1.3 and ETC2 (which Ika's
# Dozen emulates under vk_require_etc2), but none of the dma-buf extensions
# Venus shares Android's buffers through on Linux.
mkdir -p "${T}/bin"
cat >"${T}/bin/vulkaninfo" <<'STUB'
#!/usr/bin/env bash
[[ "${vk_require_etc2:-}" == "true" && "${vk_require_astc:-}" == "true" ]] || exit 1
printf 'Devices:\n========\nGPU0:\nVkPhysicalDeviceFeatures:\n\ttextureCompressionETC2                  = true\n'
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

# gpu_mode=auto still keeps gfxstream_guest_angle under WSL2, and says how to
# run Venus.
reason="$(host_suits_venus)" && fail "auto picked Venus under WSL2"
[[ "${reason}" == *"--gpu_mode=venus"* ]] || fail "the reason does not name --gpu_mode=venus: ${reason}"
echo "ok: under WSL2 auto keeps gfxstream_guest_angle"
