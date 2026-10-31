#!/usr/bin/bash

# Windows-style title bars on WSLg: Windows' display scale comes from the last
# layout WSLg logged for the primary monitor, Windows' font is copied once
# (and again when it changes), and scrcpy gets both only on WSLg.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/fonts"

source "${ROOT}/tools/ika"
log() { printf '%s\n' "$*" >>"${T}/log"; }
host_color_scheme() { printf 'light\n'; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

export IKA_WSLG_WESTON_LOG="${T}/weston.log"
export IKA_WINDOWS_FONTS_DIR="${T}/fonts"

# No log: 100%.
expect_equal "$(wslg_windows_scale)" 100 "scale without a log"

# Weston's startup placeholder (0), then Windows' layout at 150%, then a second
# monitor at 200% and the primary changed to 125%.
cat >"${IKA_WSLG_WESTON_LOG}" <<'LOG'
[00:55:56.422] 	rdpMonitor[0]: x:0, y:0, width:0, height:0, is_primary:1
[00:55:56.422] 	rdpMonitor[0]: physicalWidth:0, physicalHeight:0, orientation:0
[00:55:56.422] 	rdpMonitor[0]: desktopScaleFactor:0, deviceScaleFactor:0
LOG
expect_equal "$(wslg_windows_scale)" 100 "scale with the placeholder only"

cat >>"${IKA_WSLG_WESTON_LOG}" <<'LOG'
[00:55:57.064] disp_monitor_sanity_check_layout:---INPUT---
[00:55:57.064] 	rdpMonitor[0]: x:0, y:0, width:1920, height:1080, is_primary:1
[00:55:57.064] 	rdpMonitor[0]: physicalWidth:1600, physicalHeight:900, orientation:0
[00:55:57.064] 	rdpMonitor[0]: desktopScaleFactor:150, deviceScaleFactor:140
[00:55:57.064] 	rdpMonitor[0]: scale:1, client scale :1.00
LOG
expect_equal "$(wslg_windows_scale)" 150 "scale of the primary monitor"

cat >>"${IKA_WSLG_WESTON_LOG}" <<'LOG'
[01:10:00.000] disp_monitor_sanity_check_layout:---INPUT---
[01:10:00.000] 	rdpMonitor[0]: x:0, y:0, width:1920, height:1080, is_primary:1
[01:10:00.000] 	rdpMonitor[0]: desktopScaleFactor:125, deviceScaleFactor:140
[01:10:00.000] 	rdpMonitor[1]: x:1920, y:0, width:3840, height:2160, is_primary:0
[01:10:00.000] 	rdpMonitor[1]: desktopScaleFactor:200, deviceScaleFactor:180
LOG
expect_equal "$(wslg_windows_scale)" 125 "scale after a change, other monitor ignored"

# Windows has no Segoe UI Variable: no font.
expect_equal "$(wslg_caption_font)" "" "font when Windows has none"

# Copied once, kept, and copied again when Windows' file changes.
printf 'font v1' >"${T}/fonts/SegUIVar.ttf"
copy="${CVD_HOME_DIR}/fonts/SegUIVar.ttf"
expect_equal "$(wslg_caption_font)" "${copy}" "font path"
expect_equal "$(cat "${copy}")" "font v1" "copied font"
touch -d '2000-01-01' "${copy}"
wslg_caption_font >/dev/null
expect_equal "$(stat -c %Y "${copy}")" "$(date -d '2000-01-01' +%s)" \
  "font left alone when unchanged"
printf 'font version 2' >"${T}/fonts/SegUIVar.ttf"
wslg_caption_font >/dev/null
expect_equal "$(cat "${copy}")" "font version 2" "font copied again"
[[ -z "$(find "${CVD_HOME_DIR}/fonts" -name '*.tmp.*')" ]] \
  || fail "temporary font copy left behind"

# scrcpy's environment: both on WSLg, neither elsewhere.
env_of() {
  local -a scrcpy_env=()
  IKA_ON_WSLG="$1"
  append_scrcpy_env scrcpy_env
  printf '%s\n' "${scrcpy_env[@]}"
}
wslg_env="$(env_of true)"
grep -qx 'IKA_WINDOWS_SCALE=125' <<<"${wslg_env}" \
  || fail "no scale on WSLg: ${wslg_env}"
grep -qx "IKA_CAPTION_FONT=${copy}" <<<"${wslg_env}" \
  || fail "no font on WSLg: ${wslg_env}"
other_env="$(env_of false)"
! grep -q -E '^IKA_(WINDOWS_SCALE|CAPTION_FONT)=' <<<"${other_env}" \
  || fail "caption settings outside WSLg: ${other_env}"

echo "PASS: test_ika_wslg_caption"
