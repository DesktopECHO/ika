#!/usr/bin/bash

# ika-wsl-setup's helpers: the ini editing that writes .wslconfig and
# wsl.conf, the kernel version and branch, the .wslconfig path and command
# line forms, and the report of what is missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

source "${ROOT}/tools/ika-wsl-setup"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# ini_set creates the file, the section and the key
ini_set "${T}/new.conf" wsl2 nestedVirtualization true
expect_equal "$(<"${T}/new.conf")" $'[wsl2]\nnestedVirtualization=true' "a new file"

# ... adds a key to its section, keeping the others, and replaces a key in
# place, whatever its case, spacing and line endings
printf '[boot]\r\nsystemd=false\r\n\r\n[network]\r\ngenerateHosts = true\r\n' > "${T}/wsl.conf"
ini_set "${T}/wsl.conf" boot SystemD true
ini_set "${T}/wsl.conf" boot command "echo hi"
expect_equal "$(<"${T}/wsl.conf")" $'[boot]\nSystemD=true\ncommand=echo hi\n\n[network]\ngenerateHosts = true' \
  "a replaced and an added key, CRLF gone"

# ... appends a missing section after the others
ini_set "${T}/wsl.conf" wsl2 kernel 'C:\\Users\\zero\\ika-wsl\\bzImage'
expect_equal "$(tail -n 2 "${T}/wsl.conf")" $'[wsl2]\nkernel=C:\\\\Users\\\\zero\\\\ika-wsl\\\\bzImage' \
  "an appended section, backslashes intact"
expect_equal "$(ini_get "${T}/wsl.conf" wsl2 kernel)" 'C:\\Users\\zero\\ika-wsl\\bzImage' "ini_get reads it back"
expect_equal "$(ini_get "${T}/wsl.conf" network generateHosts)" "true" "ini_get trims the spaces"
expect_equal "$(ini_get "${T}/wsl.conf" wsl2 memory)" "" "a missing key is empty"
echo "ok: ini editing"

expect_equal "$(wslconfig_path 'C:\Users\zero\bzImage')" 'C:\\Users\\zero\\bzImage' "the .wslconfig path form"
expect_equal "$(command_line_with "" cgroup_no_v1=all)" "cgroup_no_v1=all" "a first command-line word"
expect_equal "$(command_line_with "quiet" cgroup_no_v1=all)" "quiet cgroup_no_v1=all" "an added word"
expect_equal "$(command_line_with "quiet cgroup_no_v1=all" cgroup_no_v1=all)" "quiet cgroup_no_v1=all" "a word already there"
expect_equal "$(wsl_kernel_version 6.6.87.2-microsoft-standard-WSL2)" "6.6.87.2" "the kernel version"
expect_equal "$(wsl_kernel_version 6.6.87.2-microsoft-standard-WSL2-ika)" "6.6.87.2" "the kernel version of a built kernel"
wsl_kernel_version "microsoft-WSL2" && fail "a release without a version was accepted"
expect_equal "$(wsl_kernel_branch 6.6.87.2)" "linux-msft-wsl-6.6.y" "the branch of a version"
echo "ok: paths, command line and versions"

# The report on a host without the devices, the kernel options, systemd or
# cgroup v2; the groups are those the user is not in
kernel_config_has() { return 1; }
cat >"${T}/cpuinfo" <<'EOF'
flags		: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov
EOF
grep() { if [[ "${*: -1}" == /proc/cpuinfo ]]; then command grep "${@:1:$#-1}" "${T}/cpuinfo"; else command grep "$@"; fi; }
ps() { printf 'init\n'; }
# No Hyper-V clock device and no Windows interop: no time checks
HYPERV_PTP_DEVICE="${T}/no-ptp"
clock_offset_ms() { return 1; }
windows_utc_offset_minutes() { return 1; }
report="$(missing_components)"
[[ "${report}" == *$'nested-virtualization\t'* ]] || fail "nested virtualization is not reported: ${report}"
[[ "${report}" == *$'kernel\tthe kernel lacks KVM VHOST_VSOCK VHOST_NET TUN UDMABUF BRIDGE NF_TABLES NFT_NAT NFT_MASQ'* ]] \
  || fail "the kernel options are not reported: ${report}"
[[ "${report}" == *$'systemd\t'* ]] || fail "systemd is not reported: ${report}"
[[ "${report}" != *$'time-sync\t'* && "${report}" != *$'clock\t'* && "${report}" != *$'timezone\t'* ]] \
  || fail "time is reported without the Hyper-V clock or Windows interop: ${report}"
unset -f grep ps kernel_config_has
echo "ok: the report of what is missing"

# This system's UTC offset, in minutes
expect_equal "$(TZ=UTC0 linux_utc_offset_minutes)" "0" "UTC's offset"
expect_equal "$(TZ='<-0330>3:30' linux_utc_offset_minutes)" "-210" "a half-hour offset west of UTC"
expect_equal "$(TZ='<+0545>-5:45' linux_utc_offset_minutes)" "345" "a quarter-hour offset east of UTC"

# The time: chrony not following the Hyper-V clock, a clock 5 s off Windows'
# and another time zone are reported; a clock 0.4 s off is not
kernel_config_has() { return 0; }
: >"${T}/ptp_hyperv"
HYPERV_PTP_DEVICE="${T}/ptp_hyperv"
time_sync_in_place() { return 1; }
clock_offset_ms() { printf '5000\n'; }
windows_utc_offset_minutes() { printf -- '-180\n'; }
linux_utc_offset_minutes() { printf '0\n'; }
report="$(missing_components)"
[[ "${report}" == *$'time-sync\t'* ]] || fail "chrony not following the Hyper-V clock is not reported: ${report}"
[[ "${report}" == *$'clock\tthe clock is +5.0 s off Windows\''* ]] || fail "the clock offset is not reported: ${report}"
[[ "${report}" == *$'timezone\tthe time zone is UTC+0 min, Windows\' UTC-180 min'* ]] \
  || fail "the time zone is not reported: ${report}"
time_sync_in_place() { return 0; }
clock_offset_ms() { printf -- '-400\n'; }
linux_utc_offset_minutes() { printf -- '-180\n'; }
report="$(missing_components)"
[[ "${report}" != *$'time-sync\t'* && "${report}" != *$'clock\t'* && "${report}" != *$'timezone\t'* ]] \
  || fail "a clock that keeps Windows' time is reported: ${report}"
unset -f time_sync_in_place clock_offset_ms windows_utc_offset_minutes linux_utc_offset_minutes kernel_config_has
echo "ok: the time"

# user_allow_other: uncommented where fuse.conf has it commented out, added
# otherwise, and the file created when there is none
run_as_root() { "$@"; }
FUSE_CONF="${T}/fuse.conf"
printf '# mount_max = 1000\n#user_allow_other\n' >"${FUSE_CONF}"
fuse_allows_other && fail "a commented-out user_allow_other counts"
enable_fuse_allow_other >/dev/null
expect_equal "$(<"${FUSE_CONF}")" $'# mount_max = 1000\nuser_allow_other' "the uncommented line"
fuse_allows_other || fail "user_allow_other is not seen"
printf '# mount_max = 1000\n' >"${FUSE_CONF}"
enable_fuse_allow_other >/dev/null
expect_equal "$(<"${FUSE_CONF}")" $'# mount_max = 1000\nuser_allow_other' "the added line"
rm -f "${FUSE_CONF}"
enable_fuse_allow_other >/dev/null
expect_equal "$(<"${FUSE_CONF}")" "user_allow_other" "a new fuse.conf"
unset -f run_as_root
echo "ok: user_allow_other"

printf 'PASS: ika-wsl-setup tests\n'
