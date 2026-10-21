#!/usr/bin/bash

# Low-CPU mode: on by hand, or by itself on a host without a hardware
# Vulkan driver, with 2 vCPUs or fewer, or with little memory; the display
# keeps its size and density but refreshes at the mode's rate; the guest's
# blurs and animations are set when it is on and put back when it is off.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"

source "${ROOT}/tools/ika"
log() { printf '%s\n' "$*" >&2; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

expect_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in: $1"
}

# The host, as the stubs describe it.
HOST_DISPLAY="1920x1200"
HOST_MEMORY_MB=16000
VULKAN_SUMMARY=$'GPU0:\n\tdeviceName = Radeon'
GPU_MODE="gfxstream_guest_angle"

host_display_size() { printf '%s\n' "${HOST_DISPLAY}"; }
HOST_REFRESH_HZ=60
host_display_refresh_hz() { printf '%s\n' "${HOST_REFRESH_HZ}"; }
host_physical_memory_mb() { printf '%s\n' "${HOST_MEMORY_MB}"; }
vulkaninfo_summary() { [[ -n "${VULKAN_SUMMARY}" ]] && printf '%s\n' "${VULKAN_SUMMARY}"; }
start_gpu_mode_value() { printf '%s\n' "${GPU_MODE}"; }
CVD_COMPUTE_DEFAULTS[cpus]=4

expect_equal "$(normalize_lowcpu_mode "")" "auto" "empty mode"
expect_equal "$(normalize_lowcpu_mode ON)" "on" "on"
expect_equal "$(normalize_lowcpu_mode false)" "off" "off"
(normalize_lowcpu_mode dim >/dev/null 2>&1) && fail "an invalid mode was accepted"

# The decision, from IKA_LOWCPU and the host.
decide() {
  IKA_LOWCPU="$1" resolve_lowcpu_mode "${@:2}" 2>"${T}/log"
  printf '%s|%s|%s\n' "${LOWCPU_MODE_ACTIVE}" "${LOWCPU_MODE_REASON}" "$(cat "${T}/log")"
}
expect_equal "$(decide auto)" "false||" "a fast host"
expect_equal "$(decide on)" "true|requested|low-CPU mode: on (requested)" "--lowcpu"
expect_equal "$(decide off)" "false||" "--no-lowcpu"
VULKAN_SUMMARY=$'GPU0:\n\tdeviceName = llvmpipe (LLVM 18.1.8, 256 bits)'
expect_equal "$(decide auto)" "true|no hardware Vulkan driver|low-CPU mode: on (no hardware Vulkan driver)" "software Vulkan"
expect_equal "$(decide off)" "false||" "--no-lowcpu wins over the host"
VULKAN_SUMMARY=$'GPU0:\n\tdeviceName = Radeon'
GPU_MODE="guest_swiftshader"
expect_equal "$(decide auto)" "true|software rendering|low-CPU mode: on (software rendering)" "guest_swiftshader"
GPU_MODE="gfxstream_guest_angle"
expect_equal "$(decide auto --cpus=2)" "true|2 vCPUs|low-CPU mode: on (2 vCPUs)" "two vCPUs"
CVD_COMPUTE_DEFAULTS[cpus]=1
expect_equal "$(decide auto)" "true|1 vCPU|low-CPU mode: on (1 vCPU)" "one vCPU by default"
CVD_COMPUTE_DEFAULTS[cpus]=4
HOST_MEMORY_MB=4000
expect_equal "$(decide auto)" "true|4000 MB of host memory|low-CPU mode: on (4000 MB of host memory)" "little memory"
HOST_MEMORY_MB=16000
expect_equal "$(decide auto)" "false||" "a fast host again"


args=()
LOWCPU_MODE_ACTIVE="false"
append_default_display_arg args 168 2>"${T}/log"
expect_equal "${args[*]}" "--display=width=1920,height=1200,dpi=168,refresh_rate_hz=60" "the full display without the profile"
expect_contains "$(cat "${T}/log")" "at 60 Hz (the host display's)" "the host's rate is logged"
# The refresh rate follows the host display, unless set
args=()
HOST_REFRESH_HZ=120
append_default_display_arg args 168 2>/dev/null
expect_equal "${args[*]}" "--display=width=1920,height=1200,dpi=168,refresh_rate_hz=120" "a 120 Hz host display"
args=()
IKA_REFRESH_RATE_HZ=75 append_default_display_arg args 168 2>"${T}/log"
expect_equal "${args[*]}" "--display=width=1920,height=1200,dpi=168,refresh_rate_hz=75" "refresh_rate_hz set"
expect_contains "$(cat "${T}/log")" "at 75 Hz (set by refresh_rate_hz)" "the setting is logged"
args=()
IKA_REFRESH_RATE_HZ=fast append_default_display_arg args 168 2>"${T}/log"
expect_equal "${args[*]}" "--display=width=1920,height=1200,dpi=168,refresh_rate_hz=120" "a bad setting falls back to auto"
expect_contains "$(cat "${T}/log")" "refresh_rate_hz must be auto or a positive whole number, not 'fast'; using auto" "the bad setting is reported"
args=()
host_display_refresh_hz() { return 1; }
append_default_display_arg args 168 2>"${T}/log"
expect_equal "${args[*]}" "--display=width=1920,height=1200,dpi=168,refresh_rate_hz=60" "60 Hz when the host's rate is unknown"
host_display_refresh_hz() { printf '%s\n' "${HOST_REFRESH_HZ}"; }
HOST_REFRESH_HZ=60
args=()
LOWCPU_MODE_ACTIVE="true"
IKA_LOWCPU_REFRESH_RATE_HZ=30
append_default_display_arg args 168 2>"${T}/log"
expect_equal "${args[*]}" "--display=width=1920,height=1200,dpi=168,refresh_rate_hz=30" "the same display at 30 Hz in low-CPU mode"
expect_contains "$(cat "${T}/log")" "display ceiling: 1920x1200/168 at 30 Hz" "the refresh rate is logged"
args=()
append_default_display_arg args 168 --display=width=800,height=600 2>/dev/null
expect_equal "${args[*]}" "" "a --display= option wins"

# The start options.
IKA_LOWCPU="auto"
fullscreen_mode=""; start_args=()
parse_start_options fullscreen_mode start_args --lowcpu -f
expect_equal "${IKA_LOWCPU}" "on" "--lowcpu"
parse_start_options fullscreen_mode start_args --no-lowcpu
expect_equal "${IKA_LOWCPU}" "off" "--no-lowcpu"
# restart runs start in a new process
expect_equal "$(bash -c 'printf %s "${IKA_LOWCPU:-unset}"')" "off" "--no-lowcpu reaches the start that restart runs"
parse_start_options fullscreen_mode start_args --lowcpu=auto
expect_equal "${IKA_LOWCPU}" "auto" "--lowcpu=auto"

# The guest settings, through a stubbed adb that records the shell commands.
GUEST_SAVED="null"
host_adb() {
  shift 3
  [[ "$1" == shell ]] || return 0
  shift
  case "$*" in
    "settings get global ika_lowcpu_mode") printf '%s\r\n' "${GUEST_SAVED}" ;;
    "echo \$(settings get global disable_window_blurs)"*) printf 'null,1.0,1.0,1.0\r\n' ;;
    *) printf '%s\n' "$*" >> "${T}/shell" ;;
  esac
}
: > "${T}/shell"
LOWCPU_MODE_ACTIVE="true"
apply_lowcpu_mode_guest_settings serial 2>"${T}/log"
expect_contains "$(cat "${T}/shell")" "settings put global ika_lowcpu_mode 'null,1.0,1.0,1.0'" "the previous values are kept"
expect_contains "$(cat "${T}/shell")" "settings put global disable_window_blurs 1" "blurs off"
expect_contains "$(cat "${T}/shell")" "settings put global window_animation_scale 0.5" "shorter animations"
expect_contains "$(cat "${T}/log")" "window blurs off" "applying is logged"

: > "${T}/shell"
LOWCPU_MODE_ACTIVE="false"
apply_lowcpu_mode_guest_settings serial 2>/dev/null
expect_equal "$(cat "${T}/shell")" "" "a guest never in the profile is left alone"

GUEST_SAVED="1,1.0,0.5,null"
apply_lowcpu_mode_guest_settings serial 2>"${T}/log"
expect_contains "$(cat "${T}/shell")" "settings put global disable_window_blurs '1'" "blurs back as they were"
expect_contains "$(cat "${T}/shell")" "settings put global transition_animation_scale '0.5'" "a scale back as it was"
expect_contains "$(cat "${T}/shell")" "settings delete global animator_duration_scale" "an unset scale is unset again"
expect_contains "$(cat "${T}/shell")" "settings delete global ika_lowcpu_mode" "the saved values are removed"
expect_contains "$(cat "${T}/log")" "restored" "restoring is logged"

# A guest already in the profile keeps the values it saved first.
: > "${T}/shell"
LOWCPU_MODE_ACTIVE="true"
apply_lowcpu_mode_guest_settings serial 2>/dev/null
expect_contains "$(cat "${T}/shell")" "settings put global ika_lowcpu_mode '1,1.0,0.5,null'" "saved values are kept across starts"

printf 'ok\n'
