# ika: supervisor pid files, the packaged console's processes, the host's CPUs and memory.
# Sourced by src/tools/ika, in its order; see there.

# Prints the pid recorded in a supervisor pid file if it is still a live
# supervisor of the given kind (__console_supervisor or __app_supervisor).
supervisor_pid_from_file() {
  local pid_file="$1"
  local marker="$2"
  local pid
  local command_line

  [[ -n "${pid_file}" && -f "${pid_file}" ]] || return 1
  pid="$(<"${pid_file}")"
  [[ "${pid}" =~ ^[0-9]+$ && -r "/proc/${pid}/cmdline" ]] || return 1
  [[ "$(stat -c '%u' "/proc/${pid}" 2>/dev/null || true)" == "${UID}" ]] || return 1
  command_line="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  [[ "${command_line}" == *" ${marker} "* ]] || return 1
  printf '%s\n' "${pid}"
}

stop_supervisor_from_file() {
  local pid_file="$1"
  local marker="$2"
  local pid
  local deadline

  pid="$(supervisor_pid_from_file "${pid_file}" "${marker}" || true)"
  if [[ -z "${pid}" ]]; then
    rm -f "${pid_file}"
    return 0
  fi

  kill "${pid}" >/dev/null 2>&1 || true
  deadline=$((SECONDS + 5))
  while kill -0 "${pid}" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      printf '[%s] supervisor pid %s did not exit cleanly; forcing termination\n' "${SCRIPT_NAME}" "${pid}" >&2
      kill -9 "${pid}" >/dev/null 2>&1 || true
      break
    fi
    sleep 0.2
  done
  rm -f "${pid_file}"
}

scrcpy_supervisor_pid() {
  supervisor_pid_from_file "${SCRCPY_SUPERVISOR_PID_FILE:-}" __console_supervisor
}

stop_scrcpy_supervisor() {
  stop_supervisor_from_file "${SCRCPY_SUPERVISOR_PID_FILE:-}" __console_supervisor
}

stop_app_supervisors() {
  local pid_file
  local file

  for pid_file in "${CVD_TMP_DIR}"/app-supervisor-*.pid; do
    [[ -f "${pid_file}" ]] || continue
    stop_supervisor_from_file "${pid_file}" __app_supervisor
  done
  for file in "${CVD_TMP_DIR}"/app-background-*; do
    [[ -f "${file}" ]] || continue
    discard_background_app "${file##*/app-background-}"
  done
}

# Checks if a flag was supplied by the user in the arguments
user_supplied_flag() {
  local flag="$1"
  shift
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --${flag}=*|--${flag}|-${flag}=*|-${flag})
        return 0
        ;;
    esac
  done
  return 1
}

# App windows opened by `ika app` carry IKA_APP_PACKAGE in their environment.
is_app_window_process() {
  tr '\0' '\n' <"$1/environ" 2>/dev/null | grep -q '^IKA_APP_PACKAGE='
}

# Lists packaged scrcpy processes owned by this user. Scope "console" skips
# app windows and app list queries; "all" includes them. Candidates come from
# pgrep by process name, since checking every process costs over a second.
packaged_scrcpy_pids() {
  local scope="${1:-all}"
  local pid
  local proc
  local argv0
  local exe_path
  local matched
  local name
  local -A names=()

  names["$(basename "${SCRCPY_BIN:-${PACKAGED_SCRCPY_BIN}}")"]=1
  names["$(basename "${PACKAGED_SCRCPY_BIN}")"]=1
  for name in "${!names[@]}"; do
    # The kernel keeps only the first 15 characters of a process name.
    pgrep -u "${UID}" -x "${name:0:15}" || true
  done | sort -u | while read -r pid; do
    proc="/proc/${pid}"
    matched="false"
    argv0="$(tr '\0' '\n' <"${proc}/cmdline" 2>/dev/null | head -n1 || true)"
    if [[ "${argv0}" == "${SCRCPY_BIN:-${PACKAGED_SCRCPY_BIN}}" \
        || "${argv0}" == "${PACKAGED_SCRCPY_BIN}" ]]; then
      matched="true"
    else
      exe_path="$(readlink -f "${proc}/exe" 2>/dev/null || true)"
      exe_path="${exe_path% (deleted)}"
      if [[ "${exe_path}" == "${SCRCPY_BIN:-${PACKAGED_SCRCPY_BIN}}" \
          || "${exe_path}" == "${PACKAGED_SCRCPY_BIN}" ]]; then
        matched="true"
      fi
    fi
    [[ "${matched}" == "true" ]] || continue

    if [[ "${scope}" == "console" ]] \
        && { is_app_window_process "${proc}" \
             || tr '\0' '\n' <"${proc}/cmdline" 2>/dev/null | grep -qx -- '--list-apps'; }; then
      continue
    fi
    printf '%s\n' "${pid}"
  done
}

has_packaged_scrcpy() {
  local pids

  pids="$(packaged_scrcpy_pids console)"
  [[ -n "${pids}" ]]
}

# Scope "console" closes only the desktop console, leaving app windows open;
# "all" also closes app windows and stops their supervisors first so they do
# not relaunch the windows.
stop_startup_packaged_scrcpy() {
  local scope="${1:-all}"
  local pid
  local deadline

  stop_scrcpy_supervisor
  if [[ "${scope}" == "all" ]]; then
    stop_app_supervisors
  fi

  while read -r pid; do
    [[ -n "${pid}" ]] || continue

    kill "${pid}" >/dev/null 2>&1 || true

    deadline=$((SECONDS + 5))
    while kill -0 "${pid}" >/dev/null 2>&1; do
      if (( SECONDS >= deadline )); then
        printf '[%s] console process pid %s did not exit cleanly; forcing termination\n' "${SCRIPT_NAME}" "${pid}" >&2
        kill -9 "${pid}" >/dev/null 2>&1 || true
        sleep 0.5
        break
      fi
      sleep 0.2
    done
  done < <(packaged_scrcpy_pids "${scope}" | sort -u)
}

# The host's CPUs in sysfs (a test's own tree in the tests)
HOST_CPU_SYSFS="/sys/devices/system/cpu"

# Where Linux lists the efficiency cores of an Intel hybrid CPU (a test's own
# file in the tests)
HOST_CPU_ATOM_LIST="/sys/devices/cpu_atom/cpus"

# Prints the CPU numbers of a sysfs CPU list such as "0-3,8,10-11".
expand_cpu_list() {
  local part
  local -a parts
  IFS=',' read -r -a parts <<<"$1"
  for part in "${parts[@]}"; do
    if [[ "${part}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "${part}" =~ ^[0-9]+$ ]]; then
      echo "${part}"
    fi
  done
}

# Prints "<cpu> <performance>" for each online host CPU. The performance is
# the kernel's cpu_capacity, its own measure of each CPU, which its scheduler
# uses, with the difference in work per cycle as well as in frequency (Apple,
# Intel P and E cores without Hyper-Threading, AMD Zen 5 and 5c). An Intel
# hybrid CPU with Hyper-Threading gets the same capacity on every CPU, as the
# kernel ranks its cores another way: where the capacities do not differ, the
# CPUs Linux lists as efficiency cores count half, and without such a list
# each CPU's highest frequency stands in, which an efficiency core's is well
# below.
host_cpu_performance() {
  local path
  local value
  local i
  local same_capacity=true
  local every_khz=true
  local -a cpus=()
  local -a capacities=()
  local -a khzs=()
  local -A atom=()

  for path in "${HOST_CPU_SYSFS}"/cpu[0-9]*; do
    if [[ -r "${path}/online" && "$(<"${path}/online")" != 1 ]]; then
      continue
    fi
    cpus+=("${path##*/cpu}")
    value=0
    [[ ! -r "${path}/cpu_capacity" ]] || value="$(<"${path}/cpu_capacity")"
    [[ "${value}" =~ ^[0-9]+$ ]] || value=0
    capacities+=("${value}")
    value=0
    [[ ! -r "${path}/cpufreq/cpuinfo_max_freq" ]] || value="$(<"${path}/cpufreq/cpuinfo_max_freq")"
    [[ "${value}" =~ ^[0-9]+$ ]] || value=0
    khzs+=("${value}")
  done
  for i in "${!cpus[@]}"; do
    [[ "${capacities[i]}" == "${capacities[0]}" ]] || same_capacity=false
    (( khzs[i] > 0 )) || every_khz=false
  done
  if [[ "${same_capacity}" == true && -r "${HOST_CPU_ATOM_LIST}" ]]; then
    for value in $(expand_cpu_list "$(<"${HOST_CPU_ATOM_LIST}")"); do
      atom["${value}"]=1
    done
  fi
  for i in "${!cpus[@]}"; do
    if [[ "${same_capacity}" != true ]]; then
      value="${capacities[i]}"
    elif (( ${#atom[@]} > 0 )); then
      value=1024
      [[ -z "${atom[${cpus[i]}]:-}" ]] || value=512
    elif [[ "${every_khz}" == true ]]; then
      value="${khzs[i]}"
    else
      value="${capacities[i]}"
    fi
    printf '%s %s\n' "${cpus[i]}" "${value}"
  done
}

# Performance cores are those within 85% of the fastest: a hybrid CPU's
# efficiency cores are well below that, while the few percent between the
# preferred cores of other CPUs are not.
performance_core_ids() {
  host_cpu_performance | awk '
    { cpu[NR] = $1; perf[NR] = $2; if ($2 > max) max = $2 }
    END { for (i = 1; i <= NR; i++) if (perf[i] * 100 >= max * 85) print cpu[i] }' | sort -n
}

count_performance_cores() {
  performance_core_ids | wc -l
}

# Prints what names the core of host CPU $1: the list of its hardware threads.
host_cpu_core() {
  local list="${HOST_CPU_SYSFS}/cpu$1/topology/thread_siblings_list"

  if [[ -r "${list}" ]]; then
    printf '%s\n' "$(<"${list}")"
  else
    printf 'cpu%s\n' "$1"
  fi
}

# The host CPUs the vCPUs are pinned to, in vCPU order: the performance cores
# from the highest CPU number down, then any other CPUs the same way. Of each
# kind, one hardware thread of every core comes before any core's second, so
# vCPUs share a core only once every such core has one, however Linux numbers
# the threads: a core's two next to each other (Intel's hybrid CPUs), or the
# second threads after every core's first. The threads left are the host's.
host_cpus_for_vcpus() {
  local -A performance=()
  local -A seen
  local -a rest
  local -a all
  local cpu
  local core
  local kind

  for cpu in $(performance_core_ids); do
    performance["${cpu}"]=1
  done
  mapfile -t all < <(host_cpu_performance | awk '{ print $1 }' | sort -nr)
  for kind in performance other; do
    seen=()
    rest=()
    for cpu in "${all[@]}"; do
      if [[ "${kind}" == performance ]]; then
        [[ -n "${performance[${cpu}]:-}" ]] || continue
      else
        [[ -z "${performance[${cpu}]:-}" ]] || continue
      fi
      core="$(host_cpu_core "${cpu}")"
      if [[ -z "${seen[${core}]:-}" ]]; then
        seen["${core}"]=1
        echo "${cpu}"
      else
        rest+=("${cpu}")
      fi
    done
    for cpu in "${rest[@]+"${rest[@]}"}"; do
      echo "${cpu}"
    done
  done
}

# Upstream Cuttlefish's Virtual Cpufreq configuration (--vcpu_config_path)
# pins each vCPU to a host CPU (host_cpus_for_vcpus). On arm64 the guest also
# sees that CPU's capacity, frequencies and frequency domain, and its frequency
# requests reach the host scheduler as uclamp on the vCPU threads. crosvm has
# no Virtual Cpufreq on x86, where it only takes the pinning.

# Writes the configuration for CPUS vCPUs, whose cgroup is CGROUP, to OUT.
write_vcpu_config() {
  local cpus="$1"
  local cgroup="$2"
  local out="$3"
  local -a order
  local -A domains=()
  local max_khz
  local cpu
  local vcpu
  local path
  local khz
  local freqs
  local capacity
  local policy
  local domain
  local separator=""

  mapfile -t order < <(host_cpus_for_vcpus)
  if host_is_arm64; then
    max_khz="$(sort -n "${HOST_CPU_SYSFS}"/cpu[0-9]*/cpufreq/cpuinfo_max_freq | tail -n1)"
  fi

  {
    printf '{\n  "guest_soc": "ika",\n  "cgroup_path": "%s",\n  "cpus": {' "${cgroup}"
    for (( vcpu = 0; vcpu < cpus; vcpu++ )); do
      cpu="${order[vcpu % ${#order[@]}]}"
      path="${HOST_CPU_SYSFS}/cpu${cpu}"
      if host_is_arm64; then
        khz="$(<"${path}/cpufreq/cpuinfo_max_freq")"
        policy="$(readlink -f "${path}/cpufreq")"
        [[ -n "${domains[${policy}]:-}" ]] || domains["${policy}"]="${#domains[@]}"
        domain="${domains[${policy}]}"
        # Boost frequencies too, up to cpuinfo_max_freq, which follows the
        # boost state: crosvm throttles a vCPU whose top frequency differs
        # from it, and its throttle thread can panic. cpuinfo_min_freq and
        # cpuinfo_max_freq themselves too, for a driver that lists no
        # frequencies (cppc_cpufreq, on ACPI arm64 servers), whose empty list
        # crosvm panics on.
        freqs="$({ cat "${path}/cpufreq/scaling_available_frequencies" "${path}/cpufreq/scaling_boost_frequencies" 2>/dev/null || true; cat "${path}/cpufreq/cpuinfo_min_freq"; echo "${khz}"; } | tr ' ' '\n' | awk -v max="${khz}" 'NF && $1 > 0 && $1 <= max' | sort -nu | paste -sd,)"
        # crosvm's capacity is per MHz (capacity-dmips-mhz), which the guest
        # scales by the frequencies: take them out of the kernel's capacity.
        capacity="$(( ($(<"${path}/cpu_capacity") * max_khz + khz / 2) / khz ))"
      else
        # Not passed to crosvm on x86, which takes only the pinning.
        freqs=0
        capacity=1024
        domain=0
      fi
      printf '%s\n    "cpu%d": { "affinity": %d, "frequencies": "%s", "capacity": %d, "ipc_ratio": 1024, "freq_domain": %d }' \
        "${separator}" "${vcpu}" "${cpu}" "${freqs}" "${capacity}" "${domain}"
      separator=","
    done
    printf '\n  }\n}\n'
  } > "${out}"
}

# Whether each host CPU a vCPU can be pinned to has the cpufreq files that
# crosvm's Virtual Cpufreq reads. Linux in a virtual machine has none, as on
# an Apple M3 or later, where Linux runs only in one.
host_cpus_have_cpufreq() {
  local cpu
  local path

  for cpu in $(host_cpus_for_vcpus); do
    path="${HOST_CPU_SYSFS}/cpu${cpu}/cpufreq"
    [[ -r "${path}/cpuinfo_max_freq" && -r "${path}/cpuinfo_min_freq" \
       && -r "${path}/scaling_governor" ]] || return 1
  done
}

# Runs in the systemd scope that start_cvd launches Cuttlefish in, with the
# cgroup delegated to the user: moves itself to a leaf, so that the scope can
# give the cpu controller to "android", where the launcher and crosvm run.
# "android" is a threaded domain: crosvm adds a threaded vcpu-domainN for each
# frequency domain, and the launcher moves the other threads to "workers" once
# Android has booted. Then writes the configuration and runs the launcher.
# On arm64 without cpufreq, where Cuttlefish's Virtual Cpufreq would make
# crosvm panic, runs the launcher without the configuration: the vCPUs are
# then not pinned.
launch_in_vcpu_scope() {
  local cpus="$1"
  shift
  local scope
  local cgroup
  local config="${CVD_TMP_DIR}/vcpu-config.json"

  if host_is_arm64 && ! host_cpus_have_cpufreq; then
    exec "$@"
  fi

  scope="/sys/fs/cgroup$(sed -n 's/^0:://p' /proc/self/cgroup)"
  cgroup="${scope}/android"
  mkdir "${scope}/launcher" "${cgroup}" "${cgroup}/workers" \
    && echo "$$" > "${scope}/launcher/cgroup.procs" \
    && echo threaded > "${cgroup}/workers/cgroup.type" \
    && echo +cpu > "${scope}/cgroup.subtree_control" \
    && echo +cpu > "${cgroup}/cgroup.subtree_control" \
    || die "could not set up the vCPU cgroup in ${scope}"
  mkdir -p "${CVD_TMP_DIR}"
  write_vcpu_config "${cpus}" "${cgroup}" "${config}" \
    || die "could not write ${config} from the host's cpufreq"
  exec "$@" "--vcpu_config_path=${config}"
}

# Upper bound on the auto-selected guest vCPU count. The default heuristic
# never exceeds this; pass --cpus= to request more.
ika_ini_get DEFAULT_GUEST_CPU_CAP compute cpu_cap 12 uint
ika_ini_get DEFAULT_GUEST_MEMORY_STEP_MB compute memory_step_mb 2048 uint
ika_ini_get DEFAULT_GUEST_MEMORY_CAP_MB compute memory_cap_mb 32768 uint
ika_ini_get DEFAULT_GUEST_MEMORY_FALLBACK_MB compute memory_fallback_mb 4096 uint
readonly DEFAULT_GUEST_CPU_CAP DEFAULT_GUEST_MEMORY_STEP_MB \
  DEFAULT_GUEST_MEMORY_CAP_MB DEFAULT_GUEST_MEMORY_FALLBACK_MB

default_guest_cpus() {
  local guest_cpus

  # Under WSL the CPUs are already the share Windows gives Linux (processors=
  # in .wslconfig): all of them.
  if [[ "${IKA_ON_WSLG}" == true ]]; then
    nproc
    return
  fi
  # Half the performance cores (counting each hardware thread), the rest for
  # the host; at least 1, at most cpu_cap. --cpus= bypasses this.
  guest_cpus=$(( $(count_performance_cores) / 2 ))
  (( guest_cpus >= 1 )) || guest_cpus=1
  (( guest_cpus <= DEFAULT_GUEST_CPU_CAP )) || guest_cpus=${DEFAULT_GUEST_CPU_CAP}
  echo "${guest_cpus}"
}

host_physical_memory_mb() {
  local block_size_hex block_size_bytes block_count state path
  local mem_kb

  if [[ -r /sys/devices/system/memory/block_size_bytes ]]; then
    block_size_hex="$(</sys/devices/system/memory/block_size_bytes)"
    block_size_hex="${block_size_hex#0x}"
    if [[ "${block_size_hex}" =~ ^[0-9A-Fa-f]+$ ]]; then
      block_size_bytes=$((16#${block_size_hex}))
      block_count=0
      for path in /sys/devices/system/memory/memory[0-9]*; do
        [[ -d "${path}" ]] || continue
        if [[ -r "${path}/state" ]]; then
          state="$(<"${path}/state")"
          [[ "${state}" == "online" ]] || continue
        fi
        ((block_count += 1))
      done
      if (( block_size_bytes > 0 && block_count > 0 )); then
        echo $(((block_size_bytes * block_count) / 1024 / 1024))
        return 0
      fi
    fi
  fi

  mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  mem_kb="${mem_kb//[!0-9]/}"
  if [[ -n "${mem_kb}" ]] && (( mem_kb > 0 )); then
    echo $((mem_kb / 1024))
  fi
}

default_guest_memory_mb() {
  local mem_mb target_mb rounded_mb

  mem_mb="$(host_physical_memory_mb)"
  mem_mb="${mem_mb//[!0-9]/}"
  if [[ -z "${mem_mb}" ]] || (( mem_mb <= 0 )); then
    echo "${DEFAULT_GUEST_MEMORY_FALLBACK_MB}"
    return 0
  fi

  # Under WSL the memory is already the share Windows gives Linux (memory= in
  # .wslconfig): all of it, less 1.5 GB for Linux. That covers what the kernel
  # keeps of the VM's memory and crosvm's own, about 0.5 GB together, and
  # leaves Linux about 1 GB.
  if [[ "${IKA_ON_WSLG}" == true ]] && (( mem_mb > 1536 )); then
    echo $((mem_mb - 1536))
    return 0
  fi

  target_mb=$((mem_mb / 4))
  rounded_mb=$((((target_mb + DEFAULT_GUEST_MEMORY_STEP_MB - 1) / DEFAULT_GUEST_MEMORY_STEP_MB) * DEFAULT_GUEST_MEMORY_STEP_MB))

  (( rounded_mb >= DEFAULT_GUEST_MEMORY_STEP_MB )) || rounded_mb=${DEFAULT_GUEST_MEMORY_STEP_MB}
  (( rounded_mb <= DEFAULT_GUEST_MEMORY_CAP_MB )) || rounded_mb=${DEFAULT_GUEST_MEMORY_CAP_MB}

  echo "${rounded_mb}"
}

