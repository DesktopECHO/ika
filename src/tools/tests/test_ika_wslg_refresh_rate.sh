#!/usr/bin/bash

# WSLg's presentation rate follows Ika's: refresh_rate_hz as set, or with auto
# the slowest Windows display, capped at 144, written to .wslgconfig's
# [system-distro-env] without disturbing the rest of the file.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"

source "${ROOT}/tools/ika"
log() { printf '%s\n' "$*" >>"${T}/log"; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# The rate: a number as set, capped at 144; auto takes Windows' rate.
expect_equal "$(wslg_wanted_refresh_hz 90 144)" 90 "a set rate"
expect_equal "$(wslg_wanted_refresh_hz 240 144)" 144 "a set rate above WSLg's ceiling"
expect_equal "$(wslg_wanted_refresh_hz auto 144)" 144 "auto on a 144 Hz display"
expect_equal "$(wslg_wanted_refresh_hz auto 165)" 144 "auto on a 165 Hz display"
expect_equal "$(wslg_wanted_refresh_hz auto 60)" 60 "auto on a 60 Hz display"
if wslg_wanted_refresh_hz auto "" >/dev/null; then
  fail "auto without Windows' rate should give no rate"
fi

crlf() { sed 's/$/\r/'; }

# No file: the section and the key.
expect_equal "$(printf '' | wslgconfig_with_refresh_rate 144)" \
  "$(printf '[system-distro-env]\nWESTON_RDP_MONITOR_REFRESH_RATE=144\n' | crlf)" \
  "a new file"

# Other sections and keys stay; the key is added to an existing section,
# before the next one.
input="$(printf '[system]\nWSLG_DEBUG=1\n\n[system-distro-env]\nFOO=bar\n[other]\nx=1\n' | crlf)"
expect_equal "$(printf '%s' "${input}" | wslgconfig_with_refresh_rate 120)" \
  "$(printf '[system]\nWSLG_DEBUG=1\n\n[system-distro-env]\nFOO=bar\nWESTON_RDP_MONITOR_REFRESH_RATE=120\n[other]\nx=1\n' | crlf)" \
  "a key added to an existing section"

# An existing key is replaced in place; one in another section is not touched.
input="$(printf '[other]\nWESTON_RDP_MONITOR_REFRESH_RATE=30\n[system-distro-env]\nWESTON_RDP_MONITOR_REFRESH_RATE = 60\nFOO=bar\n')"
expect_equal "$(printf '%s' "${input}" | wslgconfig_with_refresh_rate 144)" \
  "$(printf '[other]\nWESTON_RDP_MONITOR_REFRESH_RATE=30\n[system-distro-env]\nWESTON_RDP_MONITOR_REFRESH_RATE=144\nFOO=bar\n' | crlf)" \
  "an existing key replaced"

# A file without the section gets it at the end.
expect_equal "$(printf '[system]\nWSLG_DEBUG=1\n' | wslgconfig_with_refresh_rate 144)" \
  "$(printf '[system]\nWSLG_DEBUG=1\n\n[system-distro-env]\nWESTON_RDP_MONITOR_REFRESH_RATE=144\n' | crlf)" \
  "a section added to a file without it"

# Running it again changes nothing.
once="$(printf '[system]\nWSLG_DEBUG=1\n' | wslgconfig_with_refresh_rate 144)"
expect_equal "$(printf '%s' "${once}" | wslgconfig_with_refresh_rate 144)" "${once}" "a second run"

printf 'ok\n'
