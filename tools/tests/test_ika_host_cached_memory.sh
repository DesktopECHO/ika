#!/usr/bin/bash
# The host_cached_memory setting (gfxstream's VulkanPreferHostCachedMemory)
# and the gpu_mode=venus checks of tools/ika.

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
  local what="$3"
  [[ "${actual}" == "${expected}" ]] || \
    fail "${what}: expected '${expected}', got '${actual}'"
}

assert_arg_contains() {
  local expected="$1"
  shift
  local value
  for value in "$@"; do
    [[ "${value}" == *"${expected}"* ]] && return 0
  done
  fail "arguments do not contain '${expected}': $*"
}

assert_arg_omits() {
  local unexpected="$1"
  shift
  local value
  for value in "$@"; do
    [[ "${value}" != *"${unexpected}"* ]] || \
      fail "arguments unexpectedly contain '${unexpected}': $*"
  done
}

T="$(mktemp -d)"
trap 'rm -rf -- "${T}"' EXIT

log() { :; }

# The setting's values
assert_equal "on" "$(normalize_host_cached_memory_mode on)" "on"
assert_equal "on" "$(normalize_host_cached_memory_mode YES)" "yes"
assert_equal "off" "$(normalize_host_cached_memory_mode off)" "off"
assert_equal "off" "$(normalize_host_cached_memory_mode "")" "empty"
normalize_host_cached_memory_mode sometimes && fail "'sometimes' was accepted"
IKA_HOST_CACHED_MEMORY="sometimes"
assert_equal "off" "$(host_cached_memory_mode)" "an invalid setting falls back to off"

# Off adds nothing; on adds the renderer feature, merged into the existing ones
IKA_HOST_CACHED_MEMORY="off"
args=("--gpu_renderer_features=MinimalLogging:disabled")
append_host_cached_memory_args args
assert_arg_omits "VulkanPreferHostCachedMemory" "${args[@]}"
assert_equal 1 "${#args[@]}" "off leaves the arguments alone"

IKA_HOST_CACHED_MEMORY="on"
args=("--gpu_renderer_features=MinimalLogging:disabled")
append_host_cached_memory_args args
assert_equal "--gpu_renderer_features=MinimalLogging:disabled;VulkanPreferHostCachedMemory:enabled" \
  "${args[0]}" "on merges the feature into the renderer features"
args=()
append_host_cached_memory_args args
assert_equal "--gpu_renderer_features=VulkanPreferHostCachedMemory:enabled" \
  "${args[0]}" "on adds the renderer features when there were none"

# Through the GPU mode paths: the Vulkan-only mode and gfxstream with Vulkan
# get it, GLES-only gfxstream does not
primary_vulkan_device_is_radv_vega_or_older() { return 1; }
primary_vulkan_device_is_llvmpipe() { return 1; }
is_apple_silicon_16k_host() { return 1; }
user_supplied_flag() { return 1; }
GFXSTREAM_VULKAN_MODE="auto"
args=()
append_gfxstream_vulkan_args args --gpu_mode=gfxstream_guest_angle
assert_arg_contains "VulkanPreferHostCachedMemory:enabled" "${args[@]}"
GFXSTREAM_VULKAN_MODE="on"
args=()
append_gfxstream_vulkan_args args --gpu_mode=gfxstream
assert_arg_contains "VulkanPreferHostCachedMemory:enabled" "${args[@]}"
GFXSTREAM_VULKAN_MODE="off"
args=()
append_gfxstream_vulkan_args args --gpu_mode=gfxstream
assert_arg_omits "VulkanPreferHostCachedMemory" "${args[@]}"

# Venus: what the ROM declares
printf 'config=tablet\ngpu_mode_candidates=gfxstream_guest_angle,venus,guest_swiftshader\n' \
  >"${T}/candidates.txt"
printf 'config=tablet\nvulkan_venus_apex=supported\n' >"${T}/apex.txt"
printf 'config=tablet\ngpu_mode_candidates=gfxstream_guest_angle,gfxstream\n' \
  >"${T}/none.txt"
guest_supports_venus "${T}/candidates.txt" && fail "venus among the candidates alone"
guest_supports_venus "${T}/apex.txt" || fail "the Venus apex"
guest_supports_venus "${T}/none.txt" && fail "a ROM without Venus"
guest_supports_venus "${T}/missing.txt" && fail "a missing android-info.txt"

# gpu_mode=venus fails with a reason on a ROM without Venus, and passes the
# checks on one with it (the host driver only gets a log line)
die() { printf 'die: %s\n' "$*"; exit 7; }
CVD_PRODUCT_OUT="${T}/rom"
mkdir -p "${CVD_PRODUCT_OUT}"
cp "${T}/none.txt" "${CVD_PRODUCT_OUT}/android-info.txt"
output="$( (append_gfxstream_vulkan_args args --gpu_mode=venus) 2>&1 || printf 'status=%s\n' "$?")"
[[ "${output}" == *"does not declare Venus support"*"status=7" ]] \
  || fail "venus on a ROM without it: ${output}"

cp "${T}/apex.txt" "${CVD_PRODUCT_OUT}/android-info.txt"
vulkaninfo_summary() { printf 'GPU0:\n  driverName = radv\n  driverID = DRIVER_ID_MESA_RADV\n'; }
args=()
append_gfxstream_vulkan_args args --gpu_mode=venus
assert_equal "venus (ANGLE over Venus Vulkan)" "${CVD_GRAPHICS_DRIVER_MESSAGE}" "the venus message"
assert_equal 0 "${#args[@]}" "venus adds no gfxstream arguments"

is_apple_silicon_16k_host() { return 0; }
vulkaninfo_summary() { printf 'GPU0:\n  driverName = Honeykrisp\n  driverID = DRIVER_ID_MESA_HONEYKRISP\n'; }
args=()
output="$(append_gfxstream_vulkan_args args --gpu_mode=venus 2>&1)" || fail "venus on Apple Silicon stopped: ${output}"
[[ "${output}" != *"untested"* ]] || fail "Honeykrisp counted as untested for venus: ${output}"

printf 'PASS: host cached memory and venus launcher tests\n'
