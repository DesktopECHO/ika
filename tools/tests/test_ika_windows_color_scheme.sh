#!/usr/bin/bash

# The color scheme on WSLg comes from Windows' app mode (AppsUseLightTheme);
# outside WSLg, or without an answer from Windows, from the Linux desktop.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"

# A reg.exe stub that answers with LIGHT_THEME (0x0 or 0x1, empty for no value)
# and records that it was asked.
cat >"${T}/bin/reg.exe" <<STUB
#!/usr/bin/env bash
printf 'asked\n' >>"${T}/reg.calls"
[[ -n "\${LIGHT_THEME:-}" ]] || exit 1
printf '\r\nHKEY_CURRENT_USER\\\\Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Themes\\\\Personalize\r\n'
printf '    AppsUseLightTheme    REG_DWORD    %s\r\n\r\n' "\${LIGHT_THEME}"
STUB
chmod +x "${T}/bin/reg.exe"
# Linux desktops without a color scheme preference
printf '#!/bin/sh\nexit 1\n' >"${T}/bin/gdbus"
printf '#!/bin/sh\nexit 1\n' >"${T}/bin/gsettings"
chmod +x "${T}/bin/gdbus" "${T}/bin/gsettings"
export PATH="${T}/bin:${PATH}"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

IKA_ON_WSLG=true
expect_equal "$(LIGHT_THEME=0x0 host_color_scheme)" "dark" "Windows' dark app mode"
expect_equal "$(LIGHT_THEME=0x1 host_color_scheme)" "light" "Windows' light app mode"
expect_equal "$(LIGHT_THEME= host_color_scheme)" "" "no answer from Windows, and no Linux preference"
echo "ok: on WSLg, Windows' app mode"

IKA_ON_WSLG=false
rm -f "${T}/reg.calls"
expect_equal "$(LIGHT_THEME=0x0 host_color_scheme)" "" "outside WSLg, the Linux desktop's preference"
[[ ! -e "${T}/reg.calls" ]] || fail "reg.exe was asked outside WSLg"
echo "ok: outside WSLg, the Linux desktop"

printf 'PASS: Windows color scheme\n'
