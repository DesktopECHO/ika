#!/usr/bin/bash

# The Explorer shortcut to Android's storage on WSLg: nothing runs outside
# WSLg, and on WSLg PowerShell gets the program for the action and the target
# as Windows names it, quotes and all.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"

# Stubs: powershell.exe records its arguments, and wslpath names the path as
# Windows would.
cat >"${T}/bin/powershell.exe" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${T}/powershell.args"
STUB
cat >"${T}/bin/wslpath" <<'STUB'
#!/usr/bin/env bash
printf '\\\\wsl.localhost\\Ubuntu%s\n' "${2//\//\\}"
STUB
chmod +x "${T}/bin/powershell.exe" "${T}/bin/wslpath"
export PATH="${T}/bin:${PATH}"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# The program PowerShell got, once it has run
powershell_program() {
  local encoded
  for _ in $(seq 1 50); do
    [[ -s "${T}/powershell.args" ]] && break
    sleep 0.1
  done
  [[ -s "${T}/powershell.args" ]] || fail "PowerShell did not run"
  encoded="$(grep -A1 -x -- '-EncodedCommand' "${T}/powershell.args" | tail -n 1)"
  base64 -d <<<"${encoded}" | iconv -f UTF-16LE
}

IKA_ON_WSLG=false
edit_windows_android_storage_shortcut add /run/user/1000/ika/Android
wait
[[ ! -e "${T}/powershell.args" ]] || fail "PowerShell ran outside WSLg"
echo "ok: nothing runs outside WSLg"

IKA_ON_WSLG=true
edit_windows_android_storage_shortcut add "/run/user/1000/it's/Android"
script="$(powershell_program)"
[[ "${script}" == *"\$action = 'add'"* ]] || fail "the action is missing: ${script:0:200}"
[[ "${script}" == *"\$target = '\\\\wsl.localhost\\Ubuntu\\run\\user\\1000\\it''s\\Android'"* ]] \
  || fail "the target is not Windows' path, quoted: ${script:0:200}"
[[ "${script}" == *'Network Shortcuts\Android (Ika)'* && "${script}" == *'0AFACED1-E828-11D1-9187-B532F1E9575D'* ]] \
  || fail "PowerShell got another program: ${script:0:300}"
rm -f "${T}/powershell.args"
edit_windows_android_storage_shortcut remove /run/user/1000/ika/Android
[[ "$(powershell_program)" == *"\$action = 'remove'"* ]] || fail "the removal is not asked for"
echo "ok: on WSLg PowerShell gets the shortcut program for the action and target"
