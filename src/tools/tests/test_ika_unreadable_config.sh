#!/usr/bin/bash

# A host crash while assemble_cvd writes cuttlefish_config.json leaves an
# empty or truncated file behind, on which cvd_internal_start aborts at every
# start. ika start removes such a file; a readable one stays.

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

mkdir -p "${CVD_ASSEMBLY_DIR}" "${CVD_INSTANCE_DIR}"
[[ "${CVD_ASSEMBLY_CONFIG_PATH}" == "${CVD_HOME_DIR}/cuttlefish/assembly/cuttlefish_config.json" ]] || \
  fail "unexpected assembly config path ${CVD_ASSEMBLY_CONFIG_PATH}"

valid_config='{
  "instances" : { "1" : { "instance_dir" : "/x" } },
  "root_dir" : "/x"
}'

# Readable: a JSON object, with or without a trailing newline.
printf '%s\n' "${valid_config}" > "${CVD_ASSEMBLY_CONFIG_PATH}"
cvd_config_is_readable "${CVD_ASSEMBLY_CONFIG_PATH}" || fail "a valid config reads as unreadable"
printf '%s' "${valid_config}" > "${CVD_ASSEMBLY_CONFIG_PATH}"
cvd_config_is_readable "${CVD_ASSEMBLY_CONFIG_PATH}" || fail "a valid config without a newline reads as unreadable"

# Unreadable: empty, NUL-filled (size reached the disk, data did not), or cut
# short.
: > "${CVD_CONFIG_PATH}"
cvd_config_is_readable "${CVD_CONFIG_PATH}" && fail "an empty config reads as readable"
head -c 4096 /dev/zero > "${CVD_CONFIG_PATH}"
cvd_config_is_readable "${CVD_CONFIG_PATH}" && fail "a NUL-filled config reads as readable"
printf '%s' "${valid_config}" | head -c 40 > "${CVD_CONFIG_PATH}"
cvd_config_is_readable "${CVD_CONFIG_PATH}" && fail "a truncated config reads as readable"

# The start-time check removes the unreadable copies and keeps readable ones.
printf '%s\n' "${valid_config}" > "${CVD_ASSEMBLY_CONFIG_PATH}"
: > "${CVD_CONFIG_PATH}"
remove_unreadable_cvd_config
[[ -s "${CVD_ASSEMBLY_CONFIG_PATH}" ]] || fail "the readable assembly config was removed"
[[ -e "${CVD_CONFIG_PATH}" ]] && fail "the empty instance config was kept"

: > "${CVD_ASSEMBLY_CONFIG_PATH}"
head -c 4096 /dev/zero > "${CVD_CONFIG_PATH}"
remove_unreadable_cvd_config
[[ -e "${CVD_ASSEMBLY_CONFIG_PATH}" ]] && fail "the empty assembly config was kept"
[[ -e "${CVD_CONFIG_PATH}" ]] && fail "the NUL-filled instance config was kept"

# Nothing to do without the files.
remove_unreadable_cvd_config

# The same decisions without python3: a PATH with only the tools the fallback
# needs.
mkdir -p "${TEST_ROOT}/nopython"
for tool in tr tail head; do
  ln -s "$(command -v "${tool}")" "${TEST_ROOT}/nopython/${tool}"
done
(
  PATH="${TEST_ROOT}/nopython"
  command -v python3 >/dev/null 2>&1 && fail "python3 is still on the test PATH"
  printf '%s' "${valid_config}" > "${CVD_ASSEMBLY_CONFIG_PATH}"
  cvd_config_is_readable "${CVD_ASSEMBLY_CONFIG_PATH}" || fail "without python3 a valid config reads as unreadable"
  printf '%s' "${valid_config}" | head -c 40 > "${CVD_ASSEMBLY_CONFIG_PATH}"
  cvd_config_is_readable "${CVD_ASSEMBLY_CONFIG_PATH}" && fail "without python3 a truncated config reads as readable"
  head -c 4096 /dev/zero > "${CVD_ASSEMBLY_CONFIG_PATH}"
  cvd_config_is_readable "${CVD_ASSEMBLY_CONFIG_PATH}" && fail "without python3 a NUL-filled config reads as readable"
  : > "${CVD_ASSEMBLY_CONFIG_PATH}"
  cvd_config_is_readable "${CVD_ASSEMBLY_CONFIG_PATH}" && fail "without python3 an empty config reads as readable"
  exit 0
)

echo "PASS: ika start removes an empty or truncated cuttlefish_config.json"
