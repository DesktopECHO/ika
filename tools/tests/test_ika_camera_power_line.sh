#!/usr/bin/bash

# The anti-flicker of a camera passed with --camera: the mains frequency of the
# country of the host's timezone, or the one ika.ini or the option names.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export CVD_HOME_DIR="${TEST_ROOT}/ika"
export CVD_PRODUCT_OUT="${TEST_ROOT}/product"
mkdir -p "${CVD_PRODUCT_OUT}" "${TEST_ROOT}/bin"

# A camera with a power_line_frequency control; set values are recorded.
cat >"${TEST_ROOT}/bin/v4l2-ctl" <<'EOF'
#!/usr/bin/bash
case "$*" in
  *--list-ctrls*)
    [[ "$2" == /dev/video9 ]] && exit 0
    echo "           power_line_frequency 0x00980918 (menu)   : min=0 max=2 default=3 value=3"
    ;;
  *" -c "*) echo "${@: -1}" >>"${V4L2_SET_LOG}" ;;
esac
EOF
# The host's timezone, as Ika reads it.
cat >"${TEST_ROOT}/bin/timedatectl" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "${FAKE_TIMEZONE}"
EOF
chmod +x "${TEST_ROOT}/bin/v4l2-ctl" "${TEST_ROOT}/bin/timedatectl"
export PATH="${TEST_ROOT}/bin:${PATH}"
export V4L2_SET_LOG="${TEST_ROOT}/set.log"

# tzdata's zone.tab: country code, coordinates, zone.
export IKA_ZONE_TAB="${TEST_ROOT}/zone.tab"
printf '%s\n' '# comment' \
  $'CA\t+4439-06336\tAmerica/Halifax' \
  $'US\t+404251-0740023\tAmerica/New_York' \
  $'GB\t+513030-0000731\tEurope/London' \
  $'JP\t+353916+1394441\tAsia/Tokyo' \
  $'BR\t-2332-04637\tAmerica/Sao_Paulo' >"${IKA_ZONE_TAB}"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Prints what the camera was set to and Ika's log line, for the host's
# timezone and the mode. The log line is a note for the start log: nothing
# reaches the console until the notes are flushed, as start does once its log
# is open.
run() {
  : >"${V4L2_SET_LOG}"
  FAKE_TIMEZONE="$1" IKA_CAMERA_POWER_LINE_FREQUENCY="$2" \
    apply_camera_power_line_frequency "${3:-/dev/video0}" 2>&1
  flush_start_log_notes 2>&1
  printf 'set: %s\n' "$(cat "${V4L2_SET_LOG}")"
}

expect() {
  local output="$1" line="$2" what="$3"
  grep -qxF -- "${line}" <<<"${output}" || fail "${what}: expected '${line}' in:"$'\n'"${output}"
}

# Setting the camera says nothing on the console
FAKE_TIMEZONE=America/Halifax IKA_CAMERA_POWER_LINE_FREQUENCY=auto \
  expect "$(apply_camera_power_line_frequency /dev/video0 2>&1)" "" "nothing on the console"
START_LOG_NOTES=()

out="$(run America/Halifax auto)"
expect "${out}" "set: power_line_frequency=2" "Canada is 60 Hz"
expect "${out}" "[${SCRIPT_NAME}] camera anti-flicker: 60 Hz (timezone America/Halifax)" "log"
expect "$(run America/New_York auto)" "set: power_line_frequency=2" "United States"
expect "$(run America/Sao_Paulo auto)" "set: power_line_frequency=2" "Brazil"
expect "$(run Europe/London auto)" "set: power_line_frequency=1" "United Kingdom is 50 Hz"

# Japan has both: the camera keeps its setting.
out="$(run Asia/Tokyo auto)"
expect "${out}" "set: " "Japan is left alone"
grep -qF "camera anti-flicker: left as the camera has it" <<<"${out}" || fail "Japan: no log line"

# An unknown zone is left alone too.
expect "$(run Mars/Olympus auto)" "set: " "unknown zone"

# A frequency that is named wins over the timezone.
expect "$(run America/Halifax 50)" "set: power_line_frequency=1" "50 named"
expect "$(run Europe/London 60Hz)" "set: power_line_frequency=2" "60Hz named"
out="$(run Europe/London off)"
expect "${out}" "set: power_line_frequency=0" "off"
expect "${out}" "[${SCRIPT_NAME}] camera anti-flicker: off" "off log"

# A camera without the control is left alone.
out="$(run America/Halifax auto /dev/video9)"
expect "${out}" "set: " "no control"
expect "${out}" "[${SCRIPT_NAME}] camera anti-flicker: the camera has no such control" "no control log"

# Bad values stop Ika.
if (normalize_camera_power_line_frequency 55) 2>/dev/null; then
  fail "55 accepted"
fi

printf 'ika camera power line tests passed\n'
