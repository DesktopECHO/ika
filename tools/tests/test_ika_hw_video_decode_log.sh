#!/usr/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export CVD_HOME_DIR="${TEST_ROOT}/ika"
export CVD_PRODUCT_OUT="${TEST_ROOT}/product"
mkdir -p "${CVD_PRODUCT_OUT}"

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

CONSOLE_FILE="${TEST_ROOT}/console"
WARNING="H.264/HEVC hardware video decoding needs the VA-API driver from RPM Fusion: sudo dnf install mesa-va-drivers-freeworld"

# A Fedora AMD host whose driver decodes only VP8 and VP9.
vaapi_decoder_check() {
  local -n codecs_ref="$1"
  local -n reason_ref="$2"
  local -n node_ref="$3"
  codecs_ref="VP8 VP9"
  reason_ref=""
  node_ref="/dev/dri/renderD128"
}

vaapi_rpmfusion_warning() {
  printf '%s\n' "${WARNING}"
}

# Like 'ika start': the console is fd 3, and the start log is set up before
# start_cvd adds the VM's args.
(
  exec 3>"${CONSOLE_FILE}"
  IKA_HW_VIDEO_DECODE="auto"
  redirect_start_logs
  args=()
  append_hw_video_decode_args args
  printf 'args: %s\n' "${args[*]}"
)

grep -qxF "[${SCRIPT_NAME}] hardware video decoding: VA-API VP8 VP9" "${START_LOG_FILE}" || \
  fail "the decoder choice is not in the start log"
assert_equal 1 "$(grep -cxF "[${SCRIPT_NAME}] ${WARNING}" "${START_LOG_FILE}")"
grep -qxF "args: --crosvm_media_decoder=vaapi" "${START_LOG_FILE}" || \
  fail "the decoder was not attached"
assert_equal "${WARNING}" "$(cat "${CONSOLE_FILE}")"

# hw_video_decode = off, or a decoder named in the start args, adds nothing
# and logs nothing.
: > "${START_LOG_FILE}"
(
  exec 3>"${CONSOLE_FILE}" 2>>"${START_LOG_FILE}"
  args=()
  IKA_HW_VIDEO_DECODE="off" append_hw_video_decode_args args
  IKA_HW_VIDEO_DECODE="auto" append_hw_video_decode_args args \
    --crosvm_media_decoder=none
  assert_equal 0 "${#args[@]}"
)
[[ ! -s "${START_LOG_FILE}" ]] || fail "a skipped check logged output"

printf 'PASS: VA-API decoder messages go to the start log\n'
