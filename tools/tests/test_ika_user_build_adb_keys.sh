#!/usr/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export CVD_HOME_DIR="${TEST_ROOT}/ika"
export CVD_PRODUCT_OUT="${TEST_ROOT}/product"
export ADB_TEST_LOG="${TEST_ROOT}/adb.log"
export ADB_TEST_PUBLIC_KEY="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
unset ADB_VENDOR_KEYS
mkdir -p "${CVD_PRODUCT_OUT}"
printf 'user\n' > "${CVD_PRODUCT_OUT}/ika-build-variant"

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

assert_contains() {
  local expected="$1"
  shift
  local value
  for value in "$@"; do
    [[ "${value}" == "${expected}" ]] && return 0
  done
  fail "expected list to contain '${expected}'"
}

fake_adb="${TEST_ROOT}/adb"
printf '%s\n' \
  '#!/bin/bash' \
  'if [[ "$1" == "keygen" ]]; then printf "%s\\n" "$*" >> "$ADB_TEST_LOG"; printf "private-key\\n" > "$2"; printf "%s user@host\\n" "$ADB_TEST_PUBLIC_KEY" > "$2.pub"; exit 0; fi' \
  'if [[ "$1" == "pubkey" ]]; then printf "%s user@host\\n" "$ADB_TEST_PUBLIC_KEY"; exit 0; fi' \
  'printf "%s|%s\\n" "$HOME" "${ADB_VENDOR_KEYS:-}"' > "${fake_adb}"
chmod +x "${fake_adb}"
CVD_ADB_BIN="${fake_adb}"
USER_ADB_PRIVATE_KEY="${HOME}/.android/adbkey"
USER_ADB_PUBLIC_KEY="${USER_ADB_PRIVATE_KEY}.pub"

assert_equal "user" "${CVD_BUILD_VARIANT}"
host_timezone() { printf 'UTC\n'; }
bootconfig_args=()
append_host_timezone_arg bootconfig_args
assert_equal 1 "${#bootconfig_args[@]}"
bootconfig_words=()
read -r -a bootconfig_words <<< "${bootconfig_args[0]#--extra_bootconfig_args=}"
assert_contains 'androidboot.timezone="UTC"' "${bootconfig_words[@]}"
assert_contains 'androidboot.cuttlefish_service_bluetooth_checker=false' "${bootconfig_words[@]}"
assembled_public_key=""
adb_key_chunk_count=0
for bootconfig_word in "${bootconfig_words[@]}"; do
  [[ "${bootconfig_word}" == androidboot.ika.adb_pubkey_* ]] || continue
  adb_key_chunk="${bootconfig_word#*=}"
  [[ "${#adb_key_chunk}" -le 64 ]] || fail "bootconfig key chunk exceeds property limit"
  assembled_public_key+="${adb_key_chunk}"
  adb_key_chunk_count=$((adb_key_chunk_count + 1))
done
assert_equal "${ADB_TEST_PUBLIC_KEY}" "${assembled_public_key}"
assert_equal 3 "${adb_key_chunk_count}"
assert_equal "keygen ${USER_ADB_PRIVATE_KEY}" "$(<"${ADB_TEST_LOG}")"
[[ -s "${USER_ADB_PRIVATE_KEY}" && -s "${USER_ADB_PUBLIC_KEY}" ]] || \
  fail "user ADB keypair was not generated"
assert_equal 'private-key' "$(<"${USER_ADB_PRIVATE_KEY}")"
[[ ! -e "${CVD_HOME_DIR}/adbkey" ]] || fail "private key was copied into CVD_HOME_DIR"
rm "${USER_ADB_PUBLIC_KEY}"
prepare_user_adb_key
assert_equal "${ADB_TEST_PUBLIC_KEY} user@host" "$(<"${USER_ADB_PUBLIC_KEY}")"

assert_equal "${HOME}|" "$(host_adb 5 version)"

cvd_env=()
CVD_GPU_MODE="none"
export ADB_VENDOR_KEYS="/other/adbkey"
append_cvd_env_args cvd_env
assert_contains "ADB_VENDOR_KEYS=${USER_ADB_PRIVATE_KEY}:/other/adbkey" "${cvd_env[@]}"
host_timezone() { return 0; }
user_no_timezone_args=()
append_host_timezone_arg user_no_timezone_args
assert_equal 1 "${#user_no_timezone_args[@]}"
[[ "${user_no_timezone_args[0]}" == *androidboot.ika.adb_pubkey_00=* ]] || \
  fail "user ADB key was omitted when the host timezone was unavailable"

assert_equal "${HOME}|/other/adbkey" "$(host_adb 5 version)"

CVD_BUILD_VARIANT="userdebug"
userdebug_cvd_env=()
append_cvd_env_args userdebug_cvd_env
for env_entry in "${userdebug_cvd_env[@]}"; do
  [[ "${env_entry}" != ADB_VENDOR_KEYS=* ]] || \
    fail "userdebug Cuttlefish had ADB_VENDOR_KEYS overridden"
done
userdebug_bootconfig_args=()
append_host_timezone_arg userdebug_bootconfig_args
[[ "${userdebug_bootconfig_args[*]}" != *androidboot.ika.adb_pubkey=* ]] || \
  fail "userdebug bootconfig trusted the user key"
[[ "$(wc -l < "${ADB_TEST_LOG}")" -eq 1 ]] || \
  fail "userdebug caused another ADB keygen"

printf 'PASS: per-user ADB key provisioning and userdebug remains unchanged\n'
