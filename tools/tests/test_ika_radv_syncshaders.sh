#!/usr/bin/bash

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

assert_env_contains() {
  local expected="$1"
  shift
  local value
  for value in "$@"; do
    [[ "${value}" == "${expected}" ]] && return 0
  done
  fail "environment does not contain '${expected}'"
}

assert_env_omits_prefix() {
  local prefix="$1"
  shift
  local value
  for value in "$@"; do
    [[ "${value}" != "${prefix}"* ]] || \
      fail "environment unexpectedly contains '${value}'"
  done
}

assert_arg_contains() {
  local expected="$1"
  shift
  local value
  for value in "$@"; do
    [[ "${value}" == *"${expected}"* ]] && return 0
  done
  fail "arguments do not contain '${expected}'"
}

assert_arg_omits() {
  local unexpected="$1"
  shift
  local value
  for value in "$@"; do
    [[ "${value}" != *"${unexpected}"* ]] || \
      fail "arguments unexpectedly contain '${unexpected}'"
  done
}

assert_success() {
  "$@" || fail "expected command to succeed: $*"
}

assert_failure() {
  if "$@"; then
    fail "expected command to fail: $*"
  fi
}

fake_vulkaninfo_dir="$(mktemp -d)"
fake_vulkaninfo="${fake_vulkaninfo_dir}/vulkaninfo"
trap 'rm -f -- "${fake_vulkaninfo}"; rmdir -- "${fake_vulkaninfo_dir}"' EXIT
cat >"${fake_vulkaninfo}" <<'EOF'
#!/usr/bin/bash
[[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]] || exit 9
cat <<'SUMMARY'
GPU0:
  deviceName = AMD Radeon RX 480 Graphics (RADV POLARIS10)
  driverID = DRIVER_ID_MESA_RADV
  driverName = radv
SUMMARY
EOF
chmod 0755 "${fake_vulkaninfo}"

PATH="${fake_vulkaninfo_dir}:${PATH}" \
  DISPLAY=:unauthorized WAYLAND_DISPLAY=unavailable \
  assert_success primary_vulkan_device_is_radv
PATH="${fake_vulkaninfo_dir}:${PATH}" \
  DISPLAY=:unauthorized WAYLAND_DISPLAY=unavailable \
  assert_success primary_vulkan_device_is_radv_vega_or_older

assert_equal "syncshaders" "$(append_comma_option "" "syncshaders")"
assert_equal "nodcc,syncshaders" "$(append_comma_option "nodcc" "syncshaders")"
assert_equal "nodcc,syncshaders" "$(append_comma_option "nodcc,syncshaders" "syncshaders")"

CVD_GPU_MODE="gfxstream_guest_angle"
primary_vulkan_device_is_radv() { return 0; }
RADV_DEBUG="nodcc"
env_args=(env)
append_cvd_env_args env_args
assert_env_contains "RADV_DEBUG=nodcc,syncshaders" "${env_args[@]}"

primary_vulkan_device_is_radv() { return 1; }
env_args=(env)
append_cvd_env_args env_args
assert_env_omits_prefix "RADV_DEBUG=" "${env_args[@]}"

polaris_summary=$'deviceName = AMD Radeon RX 480 Graphics (RADV POLARIS10)\ndriverID = DRIVER_ID_MESA_RADV\ndriverName = radv'
vega_summary=$'deviceName = AMD Radeon RX Vega (RADV VEGA10)\ndriverID = DRIVER_ID_MESA_RADV\ndriverName = radv'
non_target_radv_summary=$'deviceName = AMD Radeon Graphics (RADV PHOENIX)\ndriverID = DRIVER_ID_MESA_RADV\ndriverName = radv'
non_radv_summary=$'deviceName = AMD Radeon RX 480 Graphics (POLARIS10)\ndriverID = DRIVER_ID_AMD_PROPRIETARY\ndriverName = AMD proprietary driver'

assert_success vulkan_device_summary_is_radv_vega_or_older "${polaris_summary}"
assert_success vulkan_device_summary_is_radv_vega_or_older "${vega_summary}"
assert_failure vulkan_device_summary_is_radv_vega_or_older "${non_target_radv_summary}"
assert_failure vulkan_device_summary_is_radv_vega_or_older "${non_radv_summary}"

primary_vulkan_device_is_radv_vega_or_older() { return 0; }
renderer_args=(
  "--gpu_renderer_features=MinimalLogging:disabled;VulkanBatchedDescriptorSetUpdate:disabled"
)
append_radv_gfxstream_vulkan_args renderer_args
assert_arg_contains \
  "VulkanAllocateDeviceMemoryOnly:enabled" "${renderer_args[@]}"

primary_vulkan_device_is_radv_vega_or_older() { return 1; }
renderer_args=("--gpu_renderer_features=MinimalLogging:disabled")
append_radv_gfxstream_vulkan_args renderer_args || true
assert_arg_omits \
  "VulkanAllocateDeviceMemoryOnly:enabled" "${renderer_args[@]}"

printf 'PASS: RADV syncshaders launcher tests\n'
