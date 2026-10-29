#!/usr/bin/bash

# restart parses the start options, then runs start, which parses them again:
# the camera of ika.ini (camera.device) must reach the VM once, not twice, and
# --no-camera must hold across it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

mkdir -p "${T}/home/ika" "${T}/product" "${T}/bin"
: >"${T}/video7"
printf '[camera]\ndevice = auto\n' >"${T}/home/ika/ika.ini"

# Runs one 'ika' process: it loads ika.ini, parses the start options
# "$@" as restart or start does, and prints the arguments it would give cvd,
# then IKA_CAMERA as the next process would get it. A process after it gets
# the arguments in ARGS_IN and the environment in IKA_CAMERA_IN.
parse() {
  # IKA_WSL_GPU_FIX=0: on a WSL2 host the start notes would also have the
  # WSL2 GPU line.
  env -i PATH="${PATH}" HOME="${T}/home" CVD_HOME_DIR="${T}/home/ika" IKA_WSL_GPU_FIX=0 \
      CVD_PRODUCT_OUT="${T}/product" ${IKA_CAMERA_IN:+IKA_CAMERA="${IKA_CAMERA_IN}"} \
      CAMERA="${T}/video7" ROOT="${ROOT}" \
    bash -c '
      source "${ROOT}/tools/ika"
      # The host has one usable camera
      detect_host_camera() { printf "%s\n" "${CAMERA}"; }
      resolve_camera_device() { printf "%s\n" "$1"; }
      apply_camera_power_line_frequency() { log_start_note "camera anti-flicker: test"; }
      args=()
      fullscreen=false
      parse_start_options fullscreen args "$@"
      printf "%s\n" "${args[@]}" | grep -c -- "--media=v4l2_proxy" || true
      printf "IKA_CAMERA=%s\n" "${IKA_CAMERA:-}"
      printf "notes=%s\n" "${#START_LOG_NOTES[@]}"
    ' ika "$@"
}

# start alone: ika.ini's camera, once
out="$(parse)"
expect_equal "$(sed -n 1p <<<"${out}")" 1 "start with camera.device = auto passes one camera"

# restart, then the start it runs: still one, and the environment carries it
first="$(parse)"
expect_equal "$(sed -n 1p <<<"${first}")" 1 "restart passes one camera"
expect_equal "$(sed -n 2p <<<"${first}")" "IKA_CAMERA=off" "and tells start not to add ika.ini's"
second="$(IKA_CAMERA_IN=off parse "--media=v4l2_proxy:device=${T}/video7")"
expect_equal "$(sed -n 1p <<<"${second}")" 1 "start after restart passes the one camera, not two"

# --camera given: one too, through restart and start
first="$(parse --camera)"
expect_equal "$(sed -n 1p <<<"${first}")" 1 "restart --camera passes one camera"
expect_equal "$(sed -n 2p <<<"${first}")" "IKA_CAMERA=off" "and tells start not to add ika.ini's"
second="$(IKA_CAMERA_IN=off parse "--media=v4l2_proxy:device=${T}/video7")"
expect_equal "$(sed -n 1p <<<"${second}")" 1 "start after restart --camera passes one camera"

# --no-camera: none from restart, none from the start after it
first="$(parse --no-camera)"
expect_equal "$(sed -n 1p <<<"${first}")" 0 "restart --no-camera passes no camera"
expect_equal "$(sed -n 2p <<<"${first}")" "IKA_CAMERA=off" "and tells start not to add ika.ini's"
second="$(IKA_CAMERA_IN=off parse)"
expect_equal "$(sed -n 1p <<<"${second}")" 0 "start after restart --no-camera passes none"

# ika.ini's camera off: nothing, and the environment is left alone
printf '[camera]\ndevice = off\n' >"${T}/home/ika/ika.ini"
out="$(parse)"
expect_equal "$(sed -n 1p <<<"${out}")" 0 "camera.device = off passes none"
expect_equal "$(sed -n 2p <<<"${out}")" "IKA_CAMERA=off" "IKA_CAMERA as ika.ini has it"

# The camera and anti-flicker lines are for the start log, not the console:
# parsing the options prints nothing, and the notes are written by flush
out="$(env -i PATH="${PATH}" HOME="${T}/home" CVD_HOME_DIR="${T}/home/ika" IKA_WSL_GPU_FIX=0 \
    CVD_PRODUCT_OUT="${T}/product" CAMERA="${T}/video7" ROOT="${ROOT}" \
  bash -c '
    source "${ROOT}/tools/ika"
    detect_host_camera() { printf "%s\n" "${CAMERA}"; }
    resolve_camera_device() { printf "%s\n" "$1"; }
    apply_camera_power_line_frequency() { log_start_note "camera anti-flicker: test"; }
    IKA_CAMERA=auto
    args=()
    fullscreen=false
    parse_start_options fullscreen args >"${CVD_HOME_DIR}/console" 2>&1
    echo "console: $(cat "${CVD_HOME_DIR}/console")"
    flush_start_log_notes 2>&1
  ' ika)"
expect_equal "$(sed -n 1p <<<"${out}")" "console: " "the camera lines are not on the console"
expect_equal "$(sed -n 2,3p <<<"${out}")" "[ika] camera: ${T}/video7
[ika] camera anti-flicker: test" "and flush writes them"

# restart gives its notes to the start it runs, and prints nothing itself
console="$(env -i PATH="${PATH}" HOME="${T}/home" CVD_HOME_DIR="${T}/home/ika" IKA_WSL_GPU_FIX=0 \
    CVD_PRODUCT_OUT="${T}/product" CAMERA="${T}/video7" ROOT="${ROOT}" HANDOFF="${T}/handoff" \
  bash -c '
    source "${ROOT}/tools/ika"
    detect_host_camera() { printf "%s\n" "${CAMERA}"; }
    resolve_camera_device() { printf "%s\n" "$1"; }
    apply_camera_power_line_frequency() { log_start_note "camera anti-flicker: test"; }
    stop_startup_packaged_scrcpy() { :; }
    stop_app_menu_watcher() { :; }
    unmount_android_storage() { :; }
    protect_overlay_resume() { :; }
    has_live_cvd_processes() { return 1; }
    stop_dnsmasq() { :; }
    respond() { :; }
    exec_start_command() { printf "%s" "${IKA_START_LOG_NOTES:-}" >"${HANDOFF}"; }
    IKA_CAMERA=auto
    main restart 2>&1
  ' ika)"
expect_equal "${console}" "" "restart prints no camera lines"
expect_equal "$(<"${T}/handoff")" "camera: ${T}/video7
camera anti-flicker: test" "restart hands them to start"

# start writes what restart handed it, then its own, once
out="$(env -i PATH="${PATH}" HOME="${T}/home" CVD_HOME_DIR="${T}/home/ika" IKA_WSL_GPU_FIX=0 \
    CVD_PRODUCT_OUT="${T}/product" ROOT="${ROOT}" \
    IKA_START_LOG_NOTES="camera: handed
camera anti-flicker: handed" \
  bash -c '
    source "${ROOT}/tools/ika"
    log_start_note "its own"
    flush_start_log_notes 2>&1
    flush_start_log_notes 2>&1
  ' ika)"
expect_equal "${out}" "[ika] camera: handed
[ika] camera anti-flicker: handed
[ika] its own" "start's flush, handed lines first, once"

printf 'ika restart camera tests passed\n'
