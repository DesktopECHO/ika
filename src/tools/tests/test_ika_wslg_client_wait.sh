#!/usr/bin/bash

# On WSLg, ika's window waits until Windows' Remote Desktop client has
# connected to WSLg's compositor (its handshake in weston.log): a window made
# before then is shown but takes no input, as the Startup Options opened from
# the Start menu right after wsl --shutdown were.

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

log() { printf '%s\n' "$*" >>"${T}/log"; }

export IKA_WSLG_WESTON_LOG="${T}/weston.log"
IKA_ON_WSLG=true

# Connected already: no wait
printf '[13:45:05.168] weston 9.0.0\n[13:45:10.307] Client HandShake buildNumber:26300\n' >"${IKA_WSLG_WESTON_LOG}"
start=${EPOCHREALTIME/./}
wait_for_wslg_client
(( ${EPOCHREALTIME/./} - start < 500000 )) || fail "waited with the client connected"

# Not yet: it waits for the handshake, then goes on
printf '[13:45:05.168] weston 9.0.0\n[13:45:09.382] CreateWndow(): rdp_peer is not initalized\n' >"${IKA_WSLG_WESTON_LOG}"
(sleep 1; printf '[13:45:10.307] Client HandShake buildNumber:26300\n' >>"${IKA_WSLG_WESTON_LOG}") &
start=${EPOCHREALTIME/./}
wait_for_wslg_client
elapsed=$(( ${EPOCHREALTIME/./} - start ))
wait
(( elapsed >= 900000 )) || fail "did not wait for the client: ${elapsed} us"
(( elapsed < 3000000 )) || fail "waited on after the handshake: ${elapsed} us"

# Outside WSLg, or without WSLg's log, nothing waits
: >"${IKA_WSLG_WESTON_LOG}"
IKA_ON_WSLG=false
start=${EPOCHREALTIME/./}
wait_for_wslg_client
(( ${EPOCHREALTIME/./} - start < 500000 )) || fail "waited outside WSLg"
IKA_ON_WSLG=true
IKA_WSLG_WESTON_LOG="${T}/missing.log"
start=${EPOCHREALTIME/./}
wait_for_wslg_client
(( ${EPOCHREALTIME/./} - start < 500000 )) || fail "waited without weston.log"
[[ ! -s "${T}/log" ]] || fail "logged: $(<"${T}/log")"

printf 'PASS: the window waits for WSLg'"'"'s Remote Desktop client\n'
