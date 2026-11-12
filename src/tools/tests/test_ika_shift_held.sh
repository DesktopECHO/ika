#!/usr/bin/env bash

# Shift held as Ika or an app is launched from a menu (no terminal) opens its
# Startup Options instead. On Linux ika-shift-held reads the keyboards, at the
# launch; on WSLg PowerShell asks Windows. The answer is kept. The login
# session that runs only Ika never asks. ika-shift-held compiles cleanly and
# answers by its exit status.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export HOME="${T}/home" CVD_HOME_DIR="${T}/ika" CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"
source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

reset_probe() {
  SHIFT_PROBE_STARTED=""
  SHIFT_PROBE_FD=""
  SHIFT_HELD=""
}

# A stand-in for ika-shift-held: exits with the status in $T/shift, and
# records each run.
cat >"${T}/bin/ika-shift-held" <<EOF
#!/bin/sh
echo run >>"${T}/runs"
exit "\$(cat "${T}/shift")"
EOF
chmod +x "${T}/bin/ika-shift-held"
PACKAGED_SHIFT_HELD_BIN="${T}/bin/ika-shift-held"

# Linux: the keyboards answer, at the probe, and the answer is kept
IKA_ON_WSLG=false
reset_probe
echo 0 >"${T}/shift"
: >"${T}/runs"
start_shift_probe
[[ "$(wc -l <"${T}/runs")" -eq 1 ]] || fail "the probe did not ask the keyboards at once"
echo 1 >"${T}/shift"
shift_held || fail "Shift held at the probe was not kept"
[[ "$(wc -l <"${T}/runs")" -eq 1 ]] || fail "the kept answer was asked again"
[[ "${SHIFT_PROBE_STARTED}" == true ]] || fail "the probe was not marked as started"
reset_probe
! shift_held || fail "Shift not held read as held"
reset_probe
echo 2 >"${T}/shift"
! shift_held || fail "no readable keyboard read as Shift held"
reset_probe
PACKAGED_SHIFT_HELD_BIN="${T}/bin/missing"
! shift_held || fail "without ika-shift-held, Shift read as held"
PACKAGED_SHIFT_HELD_BIN="${T}/bin/ika-shift-held"
echo "ok: Linux asks the keyboards at the launch and keeps the answer"

# WSLg: Windows answers (Keys.Shift = 0x10000), in the background or on the spot
IKA_ON_WSLG=true
cat >"${T}/bin/powershell.exe" <<EOF
#!/bin/sh
cat "${T}/modifiers"
EOF
chmod +x "${T}/bin/powershell.exe"
PATH="${T}/bin:${PATH}"
reset_probe
printf '65536\r\n' >"${T}/modifiers"
start_shift_probe
[[ -n "${SHIFT_PROBE_FD}" ]] || fail "WSLg: no background probe"
shift_held || fail "WSLg: Shift held read as not held"
reset_probe
printf '131072\r\n' >"${T}/modifiers"
! shift_held || fail "WSLg: Ctrl alone read as Shift"
reset_probe
printf '196608\r\n' >"${T}/modifiers"
shift_held || fail "WSLg: Shift with Ctrl read as not held"
echo "ok: WSLg asks Windows"

# main: "ika start" from a menu with Shift held opens Ika's Startup Options;
# in the login session it starts as usual
IKA_ON_WSLG=false
echo 0 >"${T}/shift"
edit_ika_settings() { echo options >>"${T}/main"; }
ika_ini_warn_unknown() { echo started >>"${T}/main"; exit 0; }
: >"${T}/main"
( reset_probe; main start </dev/null 2>/dev/null )
[[ "$(<"${T}/main")" == options ]] || fail "Shift at a menu start: $(<"${T}/main")"
: >"${T}/main"
( reset_probe; IKA_SESSION_IN_CAGE=true main start </dev/null 2>/dev/null )
[[ "$(<"${T}/main")" == started ]] || fail "the login session asked for Shift: $(<"${T}/main")"
echo "ok: a menu start with Shift opens the Startup Options, the session does not ask"

# ika-shift-held itself, where a C compiler is
if command -v cc >/dev/null 2>&1; then
  cc -Wall -Wextra -Werror -O2 -o "${T}/ika-shift-held" "${ROOT}/tools/ika-shift-held.c" \
    || fail "ika-shift-held does not compile cleanly"
  status=0
  "${T}/ika-shift-held" || status=$?
  [[ "${status}" =~ ^[012]$ ]] || fail "ika-shift-held exited ${status}"
  echo "ok: ika-shift-held compiles and answers (${status})"
else
  echo "skip: no C compiler for ika-shift-held"
fi

echo PASS
