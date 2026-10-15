#!/usr/bin/bash

# ika.ini: the generated file holds exactly the built-in defaults, edits
# override them (an environment variable still wins), and mistakes are
# reported without stopping Ika.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_line() {
  grep -qxF -- "$2" <<<"$1" || fail "$3: expected line '$2' in:"$'\n'"$1"
}

reject_line() {
  ! grep -qxF -- "$2" <<<"$1" || fail "$3: unexpected line '$2'"
}

# Prints the effective settings, one per line, after loading Ika with
# CVD_HOME_DIR=$1 and the remaining arguments as environment variables.
settings() {
  local home_dir="$1"
  shift
  env -i PATH="${PATH}" HOME="${T}/home" CVD_HOME_DIR="${home_dir}" \
      CVD_PRODUCT_OUT="${T}/product" "$@" \
    bash -c '
      source "$1/tools/ika"
      ika_ini_warn_unknown
      for map in CVD_COMPUTE_DEFAULTS CVD_GPU_DEFAULTS CVD_NETWORK_DEFAULTS \
          CVD_REPORT_DEFAULTS CVD_LOGGING_DEFAULTS CVD_OVERLAY_DEFAULTS \
          CVD_LAUNCHER_DEFAULTS; do
        declare -n m="${map}"
        for key in $(printf "%s\n" "${!m[@]}" | sort); do
          printf "%s.%s=%s\n" "${map}" "${key}" "${m[${key}]}"
        done
        unset -n m
      done
      for var in DEFAULT_GUEST_CPU_CAP DEFAULT_GUEST_MEMORY_STEP_MB \
          DEFAULT_GUEST_MEMORY_CAP_MB DEFAULT_GUEST_MEMORY_FALLBACK_MB \
          DEFAULT_DATA_GB CVD_BOOT_TIMEOUT_SEC IKA_STOP_GRACE_SEC \
          IKA_SCRCPY_REBOOT_TIMEOUT_SEC IKA_MIN_OPEN_FILES \
          IKA_KERNEL_PAGE_SIZE IKADPI IKA_SCRCPY IKA_INSTALL_TIMEOUT_SEC \
          IKA_APP_MENU_POLL_SEC IKA_GSF_ID_TIMEOUT_SEC GFXSTREAM_VULKAN \
          BACKUP_LIST_ADB_TIMEOUT_SEC BACKUP_COPY_ADB_TIMEOUT_SEC; do
        printf "%s=%s\n" "${var}" "${!var}"
      done
      printf "IKA_HIDDEN_APPS=%s\n" "${IKA_HIDDEN_APPS[*]}"
      printf "IKA_GAME_APPS=%s\n" "${IKA_GAME_APPS[*]:-}"
    ' ika "${ROOT}" 2>&1
}

mkdir -p "${T}/home" "${T}/product" "${T}/none" "${T}/generated" "${T}/edited"

# An empty file exists, so Ika generates nothing and uses its built-in defaults.
: >"${T}/none/ika.ini"
builtin_settings="$(settings "${T}/none")"

# Without a file, Ika writes one that holds the same defaults, without warnings.
[[ ! -e "${T}/generated/ika.ini" ]] || fail "ika.ini exists before the first run"
generated_settings="$(settings "${T}/generated")"
[[ -s "${T}/generated/ika.ini" ]] || fail "Ika did not generate ika.ini"
compgen -G "${T}/generated/ika.ini.*" >/dev/null && fail "a temporary file was left behind"
[[ "${generated_settings}" == "${builtin_settings}" ]] || \
  fail "the generated ika.ini differs from the built-in defaults:"$'\n'"$(diff <(printf '%s\n' "${builtin_settings}") <(printf '%s\n' "${generated_settings}") || true)"
generated_file="$(<"${T}/generated/ika.ini")"

# A second run keeps the file, edits included.
printf '[system]\nstop_grace_sec = 7\n' >"${T}/generated/ika.ini"
[[ "$(settings "${T}/generated")" == *$'\nIKA_STOP_GRACE_SEC=7\n'* ]] || fail "an existing ika.ini was replaced"

# Deleting the file gives a fresh copy.
rm "${T}/generated/ika.ini"
settings "${T}/generated" >/dev/null
[[ "$(<"${T}/generated/ika.ini")" == "${generated_file}" ]] || fail "the regenerated ika.ini differs"
expect_line "${builtin_settings}" "CVD_GPU_DEFAULTS.gpu_mode=gfxstream_guest_angle" "built-in gpu_mode"

# Edits override the defaults; "auto" keeps the calculated value.
cat >"${T}/edited/ika.ini" <<'EOF'
# A comment
; another comment
stray = outside any section

[ Compute ]
cpus = 3
memory_mb = auto
cpu_cap = 6

[gpu]
gpu_mode   =   guest_swiftshader
gpu_renderer_features = A:enabled;B:disabled

[network]
adb_mode = native_vsock

[storage]
data_gb = 128

[apps]
menu_poll_sec = 9
bit_rate = 40M
codec_options =
hidden_apps = com.example.one, com.example.two
game_apps = com.example.game

[timeouts]
install_timeout_sec = 90
gsf_id_timeout_sec = soon

[system]
stop_grace_sec = 10
EOF
edited="$(settings "${T}/edited")"
expect_line "${edited}" "CVD_COMPUTE_DEFAULTS.cpus=3" "cpus"
expect_line "${edited}" "DEFAULT_GUEST_CPU_CAP=6" "cpu cap"
expect_line "${edited}" "CVD_GPU_DEFAULTS.gpu_mode=guest_swiftshader" "gpu_mode with padding"
expect_line "${edited}" "CVD_GPU_DEFAULTS.gpu_renderer_features=A:enabled;B:disabled" "value containing semicolons"
expect_line "${edited}" "CVD_NETWORK_DEFAULTS.adb_mode=native_vsock" "adb_mode"
expect_line "${edited}" "DEFAULT_DATA_GB=128" "data_gb"
expect_line "${edited}" "IKA_APP_MENU_POLL_SEC=9" "menu poll"
# Settings of the former H.264 app windows are ignored without a warning.
reject_line "${edited}" "[ika] ${T}/edited/ika.ini: unknown setting 'apps.bit_rate'; ignored" "former bit rate"
reject_line "${edited}" "[ika] ${T}/edited/ika.ini: unknown setting 'apps.codec_options'; ignored" "former codec options"
expect_line "${edited}" "IKA_HIDDEN_APPS=com.example.one com.example.two" "hidden apps"
expect_line "${edited}" "IKA_GAME_APPS=com.example.game" "game apps"
expect_line "${edited}" "IKA_INSTALL_TIMEOUT_SEC=90" "install timeout"
expect_line "${edited}" "IKA_STOP_GRACE_SEC=10" "stop grace"
# Untouched settings keep their defaults.
expect_line "${edited}" "CVD_LAUNCHER_DEFAULTS.start_webrtc=false" "untouched default"
expect_line "${edited}" "$(grep '^CVD_COMPUTE_DEFAULTS.memory_mb=' <<<"${builtin_settings}")" "auto memory"

# Mistakes are reported, not fatal.
expect_line "${edited}" "[ika] ${T}/edited/ika.ini:3: setting outside a [section]; ignored" "setting outside a section"
expect_line "${edited}" "[ika] ${T}/edited/ika.ini: timeouts.gsf_id_timeout_sec must be a positive whole number, not 'soon'; using 120" "bad number"
expect_line "${edited}" "IKA_GSF_ID_TIMEOUT_SEC=120" "bad number falls back"

printf '[gpu]\ngpu_mod = oops\n[compute]\ncpus = many\n' >"${T}/edited/ika.ini"
mistakes="$(settings "${T}/edited")"
expect_line "${mistakes}" "[ika] ${T}/edited/ika.ini: unknown setting 'gpu.gpu_mod'; ignored" "unknown key"
expect_line "${mistakes}" "[ika] ${T}/edited/ika.ini: compute.cpus must be auto or a positive whole number, not 'many'; using auto" "bad cpus"
expect_line "${mistakes}" "$(grep '^CVD_COMPUTE_DEFAULTS.cpus=' <<<"${builtin_settings}")" "bad cpus keeps the calculated value"

# An environment variable wins over the file.
printf '[apps]\nmenu_poll_sec = 9\n[system]\nstop_grace_sec = 10\n' >"${T}/edited/ika.ini"
from_env="$(settings "${T}/edited" IKA_APP_MENU_POLL_SEC=3 IKA_STOP_GRACE_SEC=5)"
expect_line "${from_env}" "IKA_APP_MENU_POLL_SEC=3" "env menu poll"
expect_line "${from_env}" "IKA_STOP_GRACE_SEC=5" "env stop grace"
reject_line "${from_env}" "IKA_APP_MENU_POLL_SEC=9" "env beats file"

printf 'ika settings tests passed\n'
