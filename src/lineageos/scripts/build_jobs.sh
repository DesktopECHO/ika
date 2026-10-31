logical_cpu_count() {
  local count
  count="$(nproc 2>/dev/null || true)"
  if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
    printf '%s\n' "$count"
  else
    printf '%s\n' 1
  fi
}

physical_memory_total_kib() {
  awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true
}

default_job_count() {
  # JOBS = (number of logical CPU cores) - 2, floored at 1
  # (build hosts assumed >= 4 cores).
  local jobs
  jobs=$(( $(logical_cpu_count) - 2 ))
  (( jobs > 0 )) || jobs=1
  printf '%s\n' "$jobs"
}

default_highmem_job_count() {
  local max_jobs="$1"
  local memory_kib highmem_jobs
  local kib_per_highmem_job=$((32 * 1024 * 1024))

  if [[ ! "$max_jobs" =~ ^[0-9]+$ || "$max_jobs" -lt 1 ]]; then
    max_jobs=1
  fi

  memory_kib="$(physical_memory_total_kib)"
  if [[ "$memory_kib" =~ ^[0-9]+$ && "$memory_kib" -gt 0 ]]; then
    highmem_jobs=$((memory_kib / kib_per_highmem_job))
  else
    highmem_jobs=1
  fi

  (( highmem_jobs > 0 )) || highmem_jobs=1
  (( highmem_jobs <= max_jobs )) || highmem_jobs="$max_jobs"
  printf '%s\n' "$highmem_jobs"
}

build_jobs_fail() {
  if declare -F die >/dev/null 2>&1; then
    die "$*"
  fi

  printf '[lineage-desktop] error: %s\n' "$*" >&2
  return 1
}

set_build_jobs() {
  if [[ -n "${JOBS:-}" ]]; then
    jobs="$JOBS"
  else
    jobs="$(default_job_count)"
  fi

  if [[ ! "$jobs" =~ ^[0-9]+$ || "$jobs" -le 0 ]]; then
    build_jobs_fail "invalid JOBS value '$jobs'; expected a positive integer"
    return 1
  fi

  if [[ -n "${NINJA_HIGHMEM_NUM_JOBS:-}" ]]; then
    highmem_jobs="$NINJA_HIGHMEM_NUM_JOBS"
    if [[ ! "$highmem_jobs" =~ ^[0-9]+$ || "$highmem_jobs" -le 0 ]]; then
      build_jobs_fail \
        "invalid NINJA_HIGHMEM_NUM_JOBS value '$highmem_jobs'; expected a positive integer"
      return 1
    fi
  else
    highmem_jobs="$(default_highmem_job_count "$jobs")"
  fi

  export NINJA_HIGHMEM_NUM_JOBS="$highmem_jobs"
}
