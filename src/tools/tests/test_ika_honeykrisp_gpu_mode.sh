#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
# No ika.ini: the host's own gpu_mode would decide the cases below.
export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/rom"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"
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

# The ROM declares Mesa's Apple Vulkan driver in android-info.txt, as the
# arm64 ROM does; the x86-64 ROM does not.
android_info="${CVD_PRODUCT_OUT}/android-info.txt"
printf 'config=tablet\nvulkan_venus_apex=supported\n' >"${android_info}"
if guest_supports_honeykrisp "${android_info}"; then
  fail "a ROM without vulkan_asahi_apex was taken for one with the driver"
fi
printf 'vulkan_asahi_apex=supported\n' >>"${android_info}"
guest_supports_honeykrisp "${android_info}" || \
  fail "vulkan_asahi_apex=supported was not found"
echo "ok: the ROM's declaration of the Apple Vulkan driver is read"

# The host's GPU is what the test says (TEST_ASAHI=1), never the machine the
# test runs on.
host_has_asahi_render_node() {
  [[ "${TEST_ASAHI:-0}" == "1" ]]
}

assert_equal "" "$(TEST_ASAHI=1 honeykrisp_blocker || true)"
assert_equal "the host has no Apple GPU under the asahi kernel driver" \
  "$(TEST_ASAHI=0 honeykrisp_blocker)"
printf 'config=tablet\n' >"${android_info}"
[[ "$(TEST_ASAHI=1 honeykrisp_blocker)" == *"does not ship Mesa's Apple Vulkan driver"* ]] || \
  fail "a ROM without the driver was not named as the reason"
printf 'vulkan_asahi_apex=supported\n' >"${android_info}"
echo "ok: honeykrisp needs an Apple GPU and a ROM with its driver"

# --gpu_mode=honeykrisp is checked at the start and stops with the reason.
if (TEST_ASAHI=0 check_honeykrisp_gpu_mode) 2>/dev/null; then
  fail "--gpu_mode=honeykrisp went on without an Apple GPU"
fi
(TEST_ASAHI=1 check_honeykrisp_gpu_mode) || fail "--gpu_mode=honeykrisp stopped on an Apple host"
echo "ok: --gpu_mode=honeykrisp stops where it cannot run"

# The GPU is a hardware one with Vulkan, so the software-device rules do not
# decide; honeykrisp in ika.ini stands on an Apple GPU and gives way to the
# built-in mode elsewhere (an ika.ini that came to another host with its
# drive), with the reason.
vulkaninfo_summary() {
  printf 'GPU0:\n  deviceName = Apple M1 Pro (G13S C0)\n  driverID = DRIVER_ID_MESA_HONEYKRISP\n  driverName = Honeykrisp\n'
}
gfxstream_passes_over_hardware_vulkan() {
  return 1
}
IKA_INI[gpu.gpu_mode]="honeykrisp"
CVD_GPU_DEFAULTS[gpu_mode]="honeykrisp"
assert_equal "honeykrisp" "$(TEST_ASAHI=1 default_gpu_mode_for_start)"
assert_equal "gfxstream_guest_angle" "$(TEST_ASAHI=0 default_gpu_mode_for_start 2>/dev/null)"
[[ "$(TEST_ASAHI=0 default_gpu_mode_for_start 2>&1 >/dev/null)" \
    == *"gpu_mode=honeykrisp in ika.ini: the host has no Apple GPU"*"using gfxstream_guest_angle" ]] \
  || fail "no reason logged for leaving ika.ini's honeykrisp"
CVD_GPU_DEFAULTS[gpu_mode]="${CVD_GPU_MODE_AUTO_BASE}"
unset 'IKA_INI[gpu.gpu_mode]'
echo "ok: honeykrisp in ika.ini stands only on an Apple GPU"

# gpu_mode = auto picks honeykrisp on Apple Silicon where the GPU is under the
# asahi kernel driver and the ROM has the driver, and gfxstream_guest_angle
# there otherwise, never venus, with the reason.
host_is_apple_silicon() { true; }
assert_equal "honeykrisp" "$(TEST_ASAHI=1 default_gpu_mode_for_start 2>/dev/null)"
assert_equal "gfxstream_guest_angle" "$(TEST_ASAHI=0 default_gpu_mode_for_start 2>/dev/null)"
[[ "$(TEST_ASAHI=0 default_gpu_mode_for_start 2>&1 >/dev/null)" \
    == *"not honeykrisp: the host has no Apple GPU under the asahi kernel driver"* ]] \
  || fail "no reason logged for auto leaving honeykrisp out"
printf 'config=tablet\nvulkan_venus_apex=supported\n' >"${android_info}"
assert_equal "gfxstream_guest_angle" "$(TEST_ASAHI=1 default_gpu_mode_for_start 2>/dev/null)"
printf 'vulkan_asahi_apex=supported\n' >"${android_info}"
echo "ok: auto picks honeykrisp on Apple Silicon with the driver, gfxstream_guest_angle without"

# --gpu_mode= on the command line still wins over auto's choice.
assert_equal "gfxstream_guest_angle" \
  "$(TEST_ASAHI=1 default_gpu_mode_for_start --gpu_mode=gfxstream_guest_angle 2>/dev/null)"
echo "ok: --gpu_mode= wins over honeykrisp on Apple Silicon"
