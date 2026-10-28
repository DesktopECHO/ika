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
report="$(missing_components)"
[[ "${report}" == *$'nested-virtualization\t'* ]] || fail "nested virtualization is not reported: ${report}"
[[ "${report}" == *$'kernel\tthe kernel lacks KVM VHOST_VSOCK VHOST_NET TUN UDMABUF BRIDGE NF_TABLES NFT_NAT NFT_MASQ'* ]] \
  || fail "the kernel options are not reported: ${report}"
[[ "${report}" == *$'systemd\t'* ]] || fail "systemd is not reported: ${report}"
unset -f grep ps kernel_config_has
echo "ok: the report of what is missing"

printf 'PASS: ika-wsl-setup tests\n'
