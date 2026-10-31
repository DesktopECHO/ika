#!/usr/bin/bash

# Repairing task bar pins of WSLg windows: nothing runs outside WSLg, and on
# WSLg PowerShell gets the repair program, whose output lines are logged.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"

# A powershell.exe stub: it records its arguments, and reports one repaired pin
# and one removed shortcut.
cat >"${T}/bin/powershell.exe" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${T}/powershell.args"
printf 'repaired the task bar pin Files (Ubuntu)\r\n'
printf 'removed the task bar shortcut Ika (Ubuntu) of the removed WSL distribution Ubuntu\r\n'
STUB
chmod +x "${T}/bin/powershell.exe"
export PATH="${T}/bin:${PATH}"

source "${ROOT}/tools/ika"
log() { printf '%s\n' "$*" >>"${T}/log"; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

IKA_ON_WSLG=false
repair_wslg_taskbar_pins
wait
[[ ! -e "${T}/powershell.args" ]] || fail "PowerShell ran outside WSLg"
echo "ok: nothing runs outside WSLg"

IKA_ON_WSLG=true
repair_wslg_taskbar_pins
for _ in $(seq 1 50); do
  [[ -s "${T}/log" ]] && break
  sleep 0.1
done
[[ -s "${T}/powershell.args" ]] || fail "PowerShell did not run on WSLg"
encoded="$(grep -A1 -x -- '-EncodedCommand' "${T}/powershell.args" | tail -n 1)"
script="$(base64 -d <<<"${encoded}" | iconv -f UTF-16LE)"
[[ "${script}" == *'IkaPin'* && "${script}" == *'User Pinned'* ]] \
  || fail "PowerShell got another program: ${script:0:200}"
[[ "${script}" == *'\Lxss'* && "${script}" == *'\ImplicitAppShortcuts\'* ]] \
  || fail "the program does not remove shortcuts of removed distributions"
for _ in $(seq 1 50); do
  [[ "$(wc -l <"${T}/log")" -ge 2 ]] && break
  sleep 0.1
done
grep -qxF "repaired the task bar pin Files (Ubuntu)" "${T}/log" \
  || fail "the repaired pin was not logged: $(cat "${T}/log")"
grep -qxF "removed the task bar shortcut Ika (Ubuntu) of the removed WSL distribution Ubuntu" "${T}/log" \
  || fail "the removed shortcut was not logged: $(cat "${T}/log")"
echo "ok: on WSLg PowerShell gets the repair program, and repaired pins and removed shortcuts are logged"
