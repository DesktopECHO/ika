logical_cpu_count() {
  local count

  if command -v nproc >/dev/null 2>&1; then
    count="$(nproc 2>/dev/null || true)"
    if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
      printf '%s\n' "$count"
      return 0
    fi
  fi

  if command -v getconf >/dev/null 2>&1; then
    count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
      printf '%s\n' "$count"
      return 0
    fi
  fi

  if [[ -r /proc/cpuinfo ]]; then
    count="$(awk -F: '/^processor[[:space:]]*:/ { n++ } END { print n + 0 }' \
      /proc/cpuinfo 2>/dev/null || true)"
    if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
      printf '%s\n' "$count"
      return 0
    fi
  fi

  printf '%s\n' 1
}

physical_memory_total_kib() {
  awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true
}

memory_total_kib() {
  awk '
    /^MemTotal:/ { mem = $2 }
    /^SwapTotal:/ { swap = $2 }
    END {
      total = mem + swap
      if (total > 0) {
        print total
      }
    }
  ' /proc/meminfo 2>/dev/null || true
}

memory_reserve_kib() {
  local mem_kib="$1"

  if [[ ! "$mem_kib" =~ ^[0-9]+$ || "$mem_kib" -le 0 ]]; then
    printf '%s\n' 0
    return 0
  fi

  printf '%s\n' $((4 * 1024 * 1024))
}

memory_limited_job_count() {
  local mib_per_job="${1:-3584}"
  local mem_kib reserve_kib usable_kib jobs

  mem_kib="$(memory_total_kib)"
  if [[ "$mem_kib" =~ ^[0-9]+$ && "$mem_kib" -gt 0 ]]; then
    reserve_kib="$(memory_reserve_kib "$mem_kib")"
    usable_kib=$((mem_kib - reserve_kib))
    (( usable_kib > 0 )) || usable_kib=0
    jobs=$(( usable_kib / (mib_per_job * 1024) ))
    (( jobs > 0 )) || jobs=1
    printf '%s\n' "$jobs"
  else
    printf '%s\n' 1
  fi
}

default_job_count() {
  local memory_jobs cpu_jobs jobs

  memory_jobs="$(memory_limited_job_count)"
  cpu_jobs="$(logical_cpu_count)"
  jobs="$memory_jobs"
  if (( cpu_jobs < jobs )); then
    jobs="$cpu_jobs"
  fi
  (( jobs > 0 )) || jobs=1
  printf '%s\n' "$jobs"
}

default_highmem_job_count() {
  local max_jobs="$1"
  local mib_per_job="${2:-16384}"
  local memory_jobs

  memory_jobs="$(memory_limited_job_count "$mib_per_job")"
  if (( memory_jobs > max_jobs )); then
    memory_jobs="$max_jobs"
  fi
  (( memory_jobs > 0 )) || memory_jobs=1
  printf '%s\n' "$memory_jobs"
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
    highmem_jobs="$(default_highmem_job_count "$jobs" 16384)"
  fi

  export NINJA_HIGHMEM_NUM_JOBS="$highmem_jobs"
}
