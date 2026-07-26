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

printf 'PASS: RADV syncshaders launcher tests\n'
