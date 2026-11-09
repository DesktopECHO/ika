#!/usr/bin/bash

# The vCPU configuration (--vcpu_config_path) on fake host CPU trees: on
# arm64, crosvm's Virtual Cpufreq panics on a vCPU whose frequency list is
# empty or whose top differs from its host CPU's cpuinfo_max_freq, so every
# list ends at that maximum, with boost on or off, and a driver that lists no
# frequencies (cppc_cpufreq) still gives its minimum and maximum. Without
# cpufreq, the launcher runs without the configuration.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
mkdir -p "${HOME}"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

FAKE_ARCH=arm64
host_is_arm64() { [[ "${FAKE_ARCH}" == arm64 ]]; }

# add_cpu TREE CPU CAPACITY [POLICY MIN MAX AVAILABLE [BOOST]]: a CPU in TREE,
# with cpufreq through POLICY when given, as Linux links cpuN/cpufreq to
# cpufreq/policyM. An empty AVAILABLE leaves out scaling_available_frequencies.
add_cpu() {
  local tree="$1" cpu="$2" capacity="$3" policy="${4:-}"
  local dir="${tree}/cpu${cpu}"

  mkdir -p "${dir}"
  echo "${capacity}" >"${dir}/cpu_capacity"
  [[ "${cpu}" == 0 ]] || echo 1 >"${dir}/online"
  [[ -n "${policy}" ]] || return 0
  mkdir -p "${tree}/cpufreq/${policy}"
  ln -sfn "../cpufreq/${policy}" "${dir}/cpufreq"
  echo "$5" >"${tree}/cpufreq/${policy}/cpuinfo_min_freq"
  echo "$6" >"${tree}/cpufreq/${policy}/cpuinfo_max_freq"
  echo schedutil >"${tree}/cpufreq/${policy}/scaling_governor"
  [[ -z "$7" ]] || echo "$7 " >"${tree}/cpufreq/${policy}/scaling_available_frequencies"
  [[ -z "${8:-}" ]] || echo "$8 " >"${tree}/cpufreq/${policy}/scaling_boost_frequencies"
}

# vcpu_field CONFIG VCPU FIELD
vcpu_field() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["cpus"][sys.argv[2]][sys.argv[3]])' "$@"
}

# Every vCPU's list must end at its host CPU's cpuinfo_max_freq and hold only
# positive frequencies in order.
check_tops() {
  local config="$1" cpus="$2" vcpu cpu freqs top

  for (( vcpu = 0; vcpu < cpus; vcpu++ )); do
    cpu="$(vcpu_field "${config}" "cpu${vcpu}" affinity)"
    freqs="$(vcpu_field "${config}" "cpu${vcpu}" frequencies)"
    [[ -n "${freqs}" ]] || fail "vCPU ${vcpu}: empty frequency list"
    top="${freqs##*,}"
    [[ "${top}" == "$(<"${HOST_CPU_SYSFS}/cpu${cpu}/cpufreq/cpuinfo_max_freq")" ]] \
      || fail "vCPU ${vcpu} (cpu${cpu}): list ${freqs} does not end at cpuinfo_max_freq"
    [[ "$(tr ',' '\n' <<<"${freqs}" | sort -nu | paste -sd,)" == "${freqs}" ]] \
      || fail "vCPU ${vcpu}: list ${freqs} not sorted and unique"
    [[ ",${freqs}," != *,0,* ]] || fail "vCPU ${vcpu}: a zero frequency in ${freqs}"
  done
}

# Apple M1 Pro-like (Asahi): two efficiency cores, two performance cores with
# boost steps
apple="${T}/apple"
E_FREQS="600000 972000 1332000 1704000 2064000"
P_FREQS="600000 828000 1056000 1296000 1524000 1752000 1980000 2208000 2448000 2676000 2904000 3036000"
P_BOOST="3132000 3168000 3228000"
add_cpu "${apple}" 0 485 policy0 600000 2064000 "${E_FREQS}"
add_cpu "${apple}" 1 485 policy0 600000 2064000 "${E_FREQS}"
add_cpu "${apple}" 2 1024 policy2 600000 3228000 "${P_FREQS}" "${P_BOOST}"
add_cpu "${apple}" 3 1024 policy2 600000 3228000 "${P_FREQS}" "${P_BOOST}"
HOST_CPU_SYSFS="${apple}"
host_cpus_have_cpufreq || fail "Apple tree: cpufreq not found"
write_vcpu_config 4 /sys/fs/cgroup/test "${T}/apple.json"
check_tops "${T}/apple.json" 4
[[ "$(vcpu_field "${T}/apple.json" cpu0 frequencies)" == *,3036000,3132000,3168000,3228000 ]] \
  || fail "boost on: the boost steps are missing: $(vcpu_field "${T}/apple.json" cpu0 frequencies)"
[[ "$(vcpu_field "${T}/apple.json" cpu2 frequencies)" == 600000,972000,1332000,1704000,2064000 ]] \
  || fail "efficiency core list changed: $(vcpu_field "${T}/apple.json" cpu2 frequencies)"
[[ "$(vcpu_field "${T}/apple.json" cpu0 freq_domain)" != "$(vcpu_field "${T}/apple.json" cpu2 freq_domain)" ]] \
  || fail "performance and efficiency cores share a frequency domain"

# Boost off: cpuinfo_max_freq drops to the top normal step, the boost file
# stays
echo 3036000 >"${apple}/cpufreq/policy2/cpuinfo_max_freq"
write_vcpu_config 4 /sys/fs/cgroup/test "${T}/apple-noboost.json"
check_tops "${T}/apple-noboost.json" 4
[[ "$(vcpu_field "${T}/apple-noboost.json" cpu0 frequencies)" == *,2904000,3036000 ]] \
  || fail "boost off: $(vcpu_field "${T}/apple-noboost.json" cpu0 frequencies)"

# cppc_cpufreq (Ampere Altra, NVIDIA Grace): a policy per CPU, no frequency
# list, no boost file
cppc="${T}/cppc"
for cpu in 0 1 2 3; do
  add_cpu "${cppc}" "${cpu}" 1024 "policy${cpu}" 1000000 3000000 ""
done
HOST_CPU_SYSFS="${cppc}"
host_cpus_have_cpufreq || fail "cppc tree: cpufreq not found"
write_vcpu_config 4 /sys/fs/cgroup/test "${T}/cppc.json"
check_tops "${T}/cppc.json" 4
[[ "$(vcpu_field "${T}/cppc.json" cpu0 frequencies)" == 1000000,3000000 ]] \
  || fail "cppc: $(vcpu_field "${T}/cppc.json" cpu0 frequencies)"
[[ "$(vcpu_field "${T}/cppc.json" cpu0 capacity)" == 1024 ]] \
  || fail "cppc capacity: $(vcpu_field "${T}/cppc.json" cpu0 capacity)"

# A minimum of 0, as a driver without a lowest frequency reports it, is left
# out
echo 0 >"${cppc}/cpufreq/policy3/cpuinfo_min_freq"
write_vcpu_config 4 /sys/fs/cgroup/test "${T}/cppc-zero.json"
check_tops "${T}/cppc-zero.json" 4
[[ "$(vcpu_field "${T}/cppc-zero.json" cpu0 frequencies)" == 3000000 ]] \
  || fail "zero minimum: $(vcpu_field "${T}/cppc-zero.json" cpu0 frequencies)"

# No cpufreq (Linux in a virtual machine): the launcher runs without the
# configuration on arm64
vm="${T}/vm"
for cpu in 0 1 2 3; do
  add_cpu "${vm}" "${cpu}" 1024
done
HOST_CPU_SYSFS="${vm}"
! host_cpus_have_cpufreq || fail "VM tree: cpufreq found"
out="$(launch_in_vcpu_scope 4 echo launcher)"
[[ "${out}" == launcher ]] || fail "without cpufreq the launcher got: ${out}"

# One CPU without cpufreq is enough to leave the configuration out
HOST_CPU_SYSFS="${apple}"
rm "${apple}/cpu1/cpufreq"
! host_cpus_have_cpufreq || fail "Apple tree with cpu1 lacking cpufreq: cpufreq found"

# x86 takes only the pinning
FAKE_ARCH=x86_64
HOST_CPU_SYSFS="${vm}"
write_vcpu_config 2 /sys/fs/cgroup/test "${T}/x86.json"
[[ "$(vcpu_field "${T}/x86.json" cpu0 frequencies)" == 0 ]] \
  || fail "x86: $(vcpu_field "${T}/x86.json" cpu0 frequencies)"

printf 'PASS: every vCPU frequency list ends at its host CPU'"'"'s cpuinfo_max_freq\n'
