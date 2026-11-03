#!/usr/bin/bash

# The host display's size: the largest current Wayland output mode, read again
# while a Wayland session has none yet; else the DRM connectors; else the size
# found last, which every probe that finds one saves.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_HOME_DIR}" "${CVD_PRODUCT_OUT}" "${T}/bin"

source "${ROOT}/tools/ika"
log() { printf '%s\n' "$*" >>"${T}/log"; }
sleep() { :; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# wayland-info stub: prints the output modes in ${T}/modes after the first
# ${T}/empty_runs runs, which print none; each run is counted in ${T}/runs.
cat >"${T}/bin/wayland-info" <<EOF
#!/usr/bin/bash
runs=\$(( \$(cat "${T}/runs" 2>/dev/null || echo 0) + 1 ))
echo "\${runs}" >"${T}/runs"
printf "interface: 'wl_compositor', version: 6, name: 1\n"
(( runs > \$(cat "${T}/empty_runs") )) && cat "${T}/modes"
exit 0
EOF
chmod +x "${T}/bin/wayland-info"
PATH="${T}/bin:${PATH}"

DRM_SIZE=""
drm_display_size() { [[ -z "${DRM_SIZE}" ]] || printf '%s\n' "${DRM_SIZE}"; }

modes() {
  local mode
  : >"${T}/modes"
  for mode in "$@"; do
    printf "interface: 'wl_output', version: 4, name: 51\n\tmode:\n\t\twidth: %s px, height: %s px, refresh: 60.000 Hz,\n\t\tflags: %s\n" \
      "${mode%%x*}" "${mode#*x}" current >>"${T}/modes"
  done
}

# A new run: nothing probed yet.
probe() {
  _wayland_info_probed=""
  _wayland_info_output=""
  _host_display_size_probed=""
  _host_display_size_value=""
  rm -f "${T}/runs" "${T}/log"
  echo "${1:-0}" >"${T}/empty_runs"
  host_display_size || printf 'none\n'
}

export WAYLAND_DISPLAY=wayland-0

modes 1920x1080 2560x1440
expect_equal "$(probe)" "2560x1440" "largest current mode"
expect_equal "$(cat "${HOST_DISPLAY_SIZE_FILE}")" "2560x1440" "found size saved"

modes 1920x1080
expect_equal "$(probe 3)" "1920x1080" "mode found once the compositor has outputs"
expect_equal "$(cat "${T}/runs")" "4" "wayland-info read until it has a current mode"
expect_equal "$(cat "${HOST_DISPLAY_SIZE_FILE}")" "1920x1080" "new size saved"

modes
expect_equal "$(probe)" "1920x1080" "monitors asleep: size found last"
expect_equal "$(cat "${T}/runs")" "8" "wayland-info read for 2 seconds"
[[ "$(cat "${T}/log")" == *"using the size it had last, 1920x1080"* ]] || fail "cached size not logged"

DRM_SIZE="1280x800"
expect_equal "$(probe)" "1280x800" "DRM connector before the size found last"
expect_equal "$(cat "${HOST_DISPLAY_SIZE_FILE}")" "1280x800" "DRM size saved"
DRM_SIZE=""

unset WAYLAND_DISPLAY
expect_equal "$(probe)" "1280x800" "X11 without a display: size found last"
expect_equal "$(cat "${T}/runs")" "1" "wayland-info read once outside Wayland"

rm -f "${HOST_DISPLAY_SIZE_FILE}"
expect_equal "$(probe)" "none" "nothing found, nothing saved"

echo "PASS: test_ika_host_display_size"
