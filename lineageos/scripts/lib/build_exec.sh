#!/usr/bin/env bash
# Build execution for the LineageOS Desktop build engine: ARM64 job/memory limit
# tuning, active-LLVM env export, muvm guest orchestration (run_build_muvm) and
# native execution (run_build_native), and the lunch+make dispatch. Source only
# (defines functions). Relies on engine globals + core primitives at call time.

configure_arm64_job_limits() {
  host_is_arm64 || return 0

  if (( jobs_was_set == 0 )); then
    if [[ ! "$arm64_jobs" =~ ^[0-9]+$ || "$arm64_jobs" -le 0 ]]; then
      build_jobs_fail "invalid ARM64_JOBS value '$arm64_jobs'; expected a positive integer"
      return 1
    fi
    jobs="$arm64_jobs"
  fi

  if (( ninja_highmem_jobs_was_set == 1 )); then
    arm64_ninja_highmem_jobs="$highmem_jobs"
  else
    if [[ ! "$arm64_ninja_highmem_jobs" =~ ^[0-9]+$ || "$arm64_ninja_highmem_jobs" -le 0 ]]; then
      build_jobs_fail \
        "invalid ARM64_NINJA_HIGHMEM_JOBS value '$arm64_ninja_highmem_jobs'; expected a positive integer"
      return 1
    fi
    highmem_jobs="$arm64_ninja_highmem_jobs"
    export NINJA_HIGHMEM_NUM_JOBS="$highmem_jobs"
  fi

  if [[ ! "$arm64_soong_gomaxprocs" =~ ^[0-9]+$ || "$arm64_soong_gomaxprocs" -le 0 ]]; then
    build_jobs_fail \
      "invalid ARM64_SOONG_GOMAXPROCS value '$arm64_soong_gomaxprocs'; expected a positive integer"
    return 1
  fi

  # Default the muvm guest to all logical host cores. ARM64_JOBS still caps how
  # many memory-hungry compilers run at once, so handing the guest the otherwise
  # idle cores speeds the Soong analysis phase and zram (de)compression threads
  # without raising peak RSS. Set ARM64_MUVM_CPU_LIST to pin (e.g. perf cores
  # "0-3" on an M1, or "" to defer to muvm's own default).
  if (( arm64_muvm_cpu_list_was_set == 0 )) && [[ -z "$arm64_muvm_cpu_list" ]]; then
    local total_cpus
    total_cpus="$(logical_cpu_count)"
    if [[ "$total_cpus" =~ ^[0-9]+$ && "$total_cpus" -gt 0 ]]; then
      arm64_muvm_cpu_list="0-$((total_cpus - 1))"
    fi
  fi
}

configure_ccache() {
  # ccache speeds up incremental and repeat builds (Soong honors USE_CCACHE for
  # C/C++). The first clean build sees ~no benefit; subsequent builds drop a lot
  # of compile time. Optional: a missing ccache only warns, never fails.
  enabled "$ccache_enabled" || { log "ccache disabled (CCACHE_ENABLED=0)"; return 0; }

  command -v ccache >/dev/null 2>&1 || install_missing_commands ccache || true
  if ! command -v ccache >/dev/null 2>&1; then
    log "warning: ccache requested but not found and could not be installed; building without it"
    return 0
  fi

  mkdir -p "$ccache_dir"
  CCACHE_DIR="$ccache_dir" ccache -M "$ccache_max_size" >/dev/null 2>&1 || \
    log "warning: failed to set ccache max size to $ccache_max_size"

  export USE_CCACHE=1
  export CCACHE_DIR="$ccache_dir"
  CCACHE_EXEC="$(command -v ccache)"
  export CCACHE_EXEC
  log "ccache enabled: dir=$ccache_dir max=$ccache_max_size"
}

arm64_build_job_attempts() {
  local primary_jobs="$1"
  local candidate seen=" "

  if [[ -n "$arm64_job_retry_list" ]]; then
    for candidate in $arm64_job_retry_list; do
      if [[ ! "$candidate" =~ ^[0-9]+$ || "$candidate" -le 0 ]]; then
        build_jobs_fail "invalid ARM64_JOB_RETRY_LIST value '$candidate'; expected positive integers"
        return 1
      fi
      if [[ "$seen" != *" $candidate "* ]]; then
        printf '%s\n' "$candidate"
        seen+="$candidate "
      fi
    done
    return 0
  fi

  printf '%s\n' "$primary_jobs"
  seen+="$primary_jobs "
  if (( jobs_was_set == 0 )); then
    for candidate in 3 2 1; do
      if (( candidate < primary_jobs )) && [[ "$seen" != *" $candidate "* ]]; then
        printf '%s\n' "$candidate"
        seen+="$candidate "
      fi
    done
  fi
}

arm64_validate_gomemlimit() {
  local value="$1"
  if [[ "$value" == "off" || "$value" =~ ^[0-9]+([KMGTPE]i?B|B)?$ ]]; then
    return 0
  fi

  build_jobs_fail "invalid ARM64_SOONG_GOMEMLIMIT value '$value'; expected e.g. 3GiB, 2048MiB, bytes, or off"
  return 1
}

arm64_soong_gomemlimit_attempts() {
  local primary_limit="$1"
  local candidate seen=" "

  if [[ -n "$arm64_soong_gomemlimit_retry_list" ]]; then
    for candidate in $arm64_soong_gomemlimit_retry_list; do
      arm64_validate_gomemlimit "$candidate" || return 1
      if [[ "$seen" != *" $candidate "* ]]; then
        printf '%s\n' "$candidate"
        seen+="$candidate "
      fi
    done
    return 0
  fi

  arm64_validate_gomemlimit "$primary_limit" || return 1
  printf '%s\n' "$primary_limit"
  seen+="$primary_limit "

  if (( arm64_soong_gomemlimit_was_set == 0 )); then
    for candidate in 2GiB 1536MiB 1GiB; do
      if [[ "$seen" != *" $candidate "* ]]; then
        printf '%s\n' "$candidate"
        seen+="$candidate "
      fi
    done
  fi
}

arm64_build_attempts() {
  local primary_jobs="$1"
  local primary_gomemlimit="$2"
  local -a job_attempts=()
  local -a gomemlimit_attempts=()
  local attempt_jobs attempt_gomemlimit

  mapfile -t job_attempts < <(arm64_build_job_attempts "$primary_jobs")
  mapfile -t gomemlimit_attempts < <(arm64_soong_gomemlimit_attempts "$primary_gomemlimit")

  for attempt_jobs in "${job_attempts[@]}"; do
    for attempt_gomemlimit in "${gomemlimit_attempts[@]}"; do
      printf '%s %s\n' "$attempt_jobs" "$attempt_gomemlimit"
    done
  done
}

arm64_log_looks_resource_limited() {
  local log_file="$1"
  [[ -s "$log_file" ]] || return 1

  if grep -Eqi \
    '(^|[^[:alpha:]])killed([^[:alpha:]]|$)|cannot allocate memory|out of memory|std::bad_alloc|resource temporarily unavailable|too many open files|failed to create new os thread|fatal error: runtime: out of memory' \
    "$log_file"; then
    return 0
  fi

  if grep -Eq 'FAILED: out/soong/build\..*\.ninja|soong bootstrap failed with: exit status 1' "$log_file" && \
      ! grep -Eqi '(^|[^[:alpha:]])error:' "$log_file"; then
    return 0
  fi

  return 1
}

raise_open_file_limit_for_muvm() {
  host_is_arm64 || return 0
  [[ -n "$arm64_muvm_nofile_limit" ]] || return 0
  [[ "$arm64_muvm_nofile_limit" =~ ^[0-9]+$ ]] || \
    die "ARM64_MUVM_NOFILE_LIMIT must be a numeric limit or empty to skip"

  local current_soft current_hard
  current_soft="$(ulimit -Sn)"
  current_hard="$(ulimit -Hn)"
  if nofile_limit_at_least "$current_soft" "$arm64_muvm_nofile_limit" && \
     nofile_limit_at_least "$current_hard" "$arm64_muvm_nofile_limit"; then
    log "host open-file limit for muvm already ${current_soft}:${current_hard}"
    return 0
  fi

  command -v prlimit >/dev/null 2>&1 || install_missing_commands prlimit || true
  command -v prlimit >/dev/null 2>&1 || \
    die "ARM64 host needs prlimit to raise the open-file limit for muvm"

  if run_privileged prlimit --pid "$$" --nofile="${arm64_muvm_nofile_limit}:${arm64_muvm_nofile_limit}" >/dev/null 2>&1; then
    current_soft="$(ulimit -Sn)"
    current_hard="$(ulimit -Hn)"
    if nofile_limit_at_least "$current_soft" "$arm64_muvm_nofile_limit" && \
       nofile_limit_at_least "$current_hard" "$arm64_muvm_nofile_limit"; then
      log "raised host open-file limit for muvm to ${current_soft}:${current_hard}"
      return 0
    fi
  fi

  die "failed to raise host open-file limit for muvm to $arm64_muvm_nofile_limit; current limit is ${current_soft}:${current_hard}"
}

active_llvm_prebuilts_version() {
  if host_is_arm64; then
    printf '%s\n' "$linux_arm64_llvm_prebuilts_version"
  else
    printf '%s\n' "$linux_x86_llvm_prebuilts_version"
  fi
}

active_llvm_release_version() {
  if host_is_arm64; then
    printf '%s\n' "$linux_arm64_llvm_release_version"
  else
    printf '%s\n' "$linux_x86_llvm_release_version"
  fi
}

export_active_llvm_env() {
  local prebuilts_version release_version

  prebuilts_version="$(active_llvm_prebuilts_version)"
  release_version="$(active_llvm_release_version)"
  if [[ -n "$prebuilts_version" ]]; then
    export LLVM_PREBUILTS_VERSION="$prebuilts_version"
    export LLVM_BINDGEN_PREBUILTS_VERSION="$prebuilts_version"
  fi
  if [[ -n "$release_version" ]]; then
    export LLVM_RELEASE_VERSION="$release_version"
  fi
}

active_llvm_export_lines() {
  local prebuilts_version release_version value_q

  prebuilts_version="$(active_llvm_prebuilts_version)"
  release_version="$(active_llvm_release_version)"
  if [[ -n "$prebuilts_version" ]]; then
    printf -v value_q '%q' "$prebuilts_version"
    printf 'export LLVM_PREBUILTS_VERSION=%s\n' "$value_q"
    printf 'export LLVM_BINDGEN_PREBUILTS_VERSION=%s\n' "$value_q"
  fi
  if [[ -n "$release_version" ]]; then
    printf -v value_q '%q' "$release_version"
    printf 'export LLVM_RELEASE_VERSION=%s\n' "$value_q"
  fi
}

configure_arm64_host_build() {
  host_is_arm64 || return 0

  ensure_arm64_go_prebuilt
  command -v muvm >/dev/null 2>&1 || \
    die "ARM64 host needs muvm to run the Android build in a 4 KiB-page guest"
  [[ -d "$workspace/prebuilts/build-tools/linux-arm64" ]] || \
    die "missing ARM64 build tools prebuilt: prebuilts/build-tools/linux-arm64"
  require_arm64_prebuilt_executable "$workspace/prebuilts/build-tools/linux-arm64/bin/ninja" "ARM64 Ninja"
  [[ -x "$workspace/prebuilts/go/linux-arm64/bin/go" ]] || \
    die "missing ARM64 Go prebuilt: prebuilts/go/linux-arm64"

  ensure_arm64_rust_prebuilt
  ensure_arm64_rust_tool_bridges
  ensure_linux_arm64_clang_prebuilt
  ensure_linux_arm64_clang_ready
  ensure_linux_arm64_clang_trusty_dirgroup
  ensure_linux_x86_clang_arm64_soong_compat
  ensure_arm64_clang_tools_prebuilt
  ensure_arm64_native_cmake_prebuilt
  ensure_arm64_native_jdk21_prebuilt
  ensure_arm64_jdk8_prebuilt
  ensure_no_arm64_x86_prebuilt_substitutions

  arm64_android_java_home_for_build >/dev/null || true
  raise_open_file_limit_for_muvm
}

precompute_muvm_module_paths() {
  local product="$1"
  host_is_arm64 || return 0

  local java_home
  java_home="$(arm64_android_java_home_for_build || true)"

  log "precomputing Android module path lists for $product"
  (
    cd "$workspace"
    export ANDROID_BUILD_SERIAL_FINDER=1
    export THINLTO_USE_MLGO="$arm64_thinlto_use_mlgo"
    export_active_llvm_env
    if [[ -n "$java_home" ]]; then
      export OVERRIDE_ANDROID_JAVA_HOME="$java_home"
    fi
    set +u
    source build/envsetup.sh
    lunch "$product" trunk_staging userdebug >/dev/null
  )
}

shell_quote_join() {
  local quoted="" part q
  for part in "$@"; do
    printf -v q '%q' "$part"
    quoted+="${quoted:+ }$q"
  done
  printf '%s\n' "$quoted"
}

sanitize_build_log_output() {
  sed -u 's/ERROR init_or_kernel] \[missing newline\]/PING/g'
}

run_build_muvm() {
  local product="$1"
  shift

  local workspace_q product_q highmem_jobs_q thinlto_use_mlgo_q goals_q command nofile_limit_q
  local extra_exports="" value_q java_home
  local llvm_prebuilts_version llvm_release_version
  printf -v workspace_q '%q' "$workspace"
  printf -v product_q '%q' "$product"
  printf -v highmem_jobs_q '%q' "$arm64_ninja_highmem_jobs"
  printf -v thinlto_use_mlgo_q '%q' "$arm64_thinlto_use_mlgo"
  printf -v nofile_limit_q '%q' "$arm64_muvm_nofile_limit"
  goals_q="$(shell_quote_join "$@")"
  java_home="$(arm64_android_java_home_for_build || true)"
  llvm_prebuilts_version="$(active_llvm_prebuilts_version)"
  llvm_release_version="$(active_llvm_release_version)"

  if [[ -n "${LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE+x}" ]]; then
    printf -v value_q '%q' "$LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE"
    extra_exports+="export LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE=$value_q"$'\n'
  fi
  if [[ -n "${USE_NDK_TRANSLATION_BINARY+x}" ]]; then
    printf -v value_q '%q' "$USE_NDK_TRANSLATION_BINARY"
    extra_exports+="export USE_NDK_TRANSLATION_BINARY=$value_q"$'\n'
  fi
  if [[ -n "$java_home" ]]; then
    printf -v value_q '%q' "$java_home"
    extra_exports+="export OVERRIDE_ANDROID_JAVA_HOME=$value_q"$'\n'
  fi
  if [[ "${USE_CCACHE:-}" == "1" ]]; then
    extra_exports+="export USE_CCACHE=1"$'\n'
    printf -v value_q '%q' "${CCACHE_DIR:-}"
    extra_exports+="export CCACHE_DIR=$value_q"$'\n'
    printf -v value_q '%q' "${CCACHE_EXEC:-}"
    extra_exports+="export CCACHE_EXEC=$value_q"$'\n'
  fi
  extra_exports+="$(active_llvm_export_lines)"

  ensure_linux_arm64_clang_ready
  precompute_muvm_module_paths "$product"
  raise_open_file_limit_for_muvm

  local -a build_attempts=()
  mapfile -t build_attempts < <(arm64_build_attempts "$jobs" "$arm64_soong_gomemlimit")

  local attempt attempt_jobs attempt_jobs_q attempt_gomemlimit attempt_gomemlimit_q
  local attempt_gomaxprocs attempt_gomaxprocs_q
  local attempt_gomemlimit_label attempt_log status last_status=1
  local -a muvm_args=(--mem="$arm64_muvm_mem_mib")
  if [[ -n "$arm64_muvm_cpu_list" ]]; then
    muvm_args+=(-c "$arm64_muvm_cpu_list")
  fi
  for attempt in "${build_attempts[@]}"; do
    read -r attempt_jobs attempt_gomemlimit <<< "$attempt"
    printf -v attempt_jobs_q '%q' "$attempt_jobs"
    printf -v attempt_gomemlimit_q '%q' "$attempt_gomemlimit"
    attempt_gomaxprocs="$arm64_soong_gomaxprocs"
    if (( arm64_soong_gomaxprocs_was_set == 0 && attempt_jobs < attempt_gomaxprocs )); then
      attempt_gomaxprocs="$attempt_jobs"
    fi
    printf -v attempt_gomaxprocs_q '%q' "$attempt_gomaxprocs"
    command=$(cat <<EOF
set -eo pipefail
set +u
muvm_nofile_limit=$nofile_limit_q
guest_nofile_limit_at_least() {
  local value="\$1"
  local minimum="\$2"
  [[ "\$value" == "unlimited" ]] && return 0
  [[ "\$value" =~ ^[0-9]+$ ]] || return 1
  [[ "\$minimum" =~ ^[0-9]+$ ]] || return 1
  (( value >= minimum ))
}
if [[ -n "\$muvm_nofile_limit" ]]; then
  guest_nofile_soft="\$(ulimit -Sn)"
  guest_nofile_hard="\$(ulimit -Hn)"
  if guest_nofile_limit_at_least "\$guest_nofile_soft" "\$muvm_nofile_limit" && \
     guest_nofile_limit_at_least "\$guest_nofile_hard" "\$muvm_nofile_limit"; then
    printf '[lineage-desktop] muvm guest open-file limit is %s:%s\n' "\$guest_nofile_soft" "\$guest_nofile_hard"
  elif guest_nofile_limit_at_least "\$guest_nofile_hard" "\$muvm_nofile_limit"; then
    ulimit -Sn "\$muvm_nofile_limit"
    guest_nofile_soft="\$(ulimit -Sn)"
    guest_nofile_hard="\$(ulimit -Hn)"
    if guest_nofile_limit_at_least "\$guest_nofile_soft" "\$muvm_nofile_limit"; then
      printf '[lineage-desktop] raised muvm guest open-file limit to %s:%s\n' "\$guest_nofile_soft" "\$guest_nofile_hard"
    else
      printf '[lineage-desktop] error: failed to raise muvm guest open-file soft limit to %s (got %s:%s)\n' "\$muvm_nofile_limit" "\$guest_nofile_soft" "\$guest_nofile_hard" >&2
      exit 1
    fi
  else
    printf '[lineage-desktop] warning: muvm guest open-file hard limit is %s, below requested %s; host muvm process limit was raised before launch\n' "\$guest_nofile_hard" "\$muvm_nofile_limit" >&2
  fi
fi
export ANDROID_BUILD_SERIAL_FINDER=1
export _SOONG_INTERNAL_NO_FINDER=1
export GOMEMLIMIT=$attempt_gomemlimit_q
export GOGC=$arm64_soong_gogc
export GOMAXPROCS=$attempt_gomaxprocs_q
export GODEBUG=$arm64_godebug
export GOTRACEBACK=all
export RUSTC_BOOTSTRAP=1
export NINJA_HIGHMEM_NUM_JOBS=$highmem_jobs_q
export THINLTO_USE_MLGO=$thinlto_use_mlgo_q
$extra_exports
cd $workspace_q
source build/envsetup.sh
lunch $product_q trunk_staging userdebug
if [[ "\${TARGET_PRODUCT:-}" != $product_q ]]; then
  printf '[lineage-desktop] error: lunch did not set TARGET_PRODUCT=%s (got %s)\n' $product_q "\${TARGET_PRODUCT:-}" >&2
  exit 1
fi
set -eo pipefail
set -u
m $goals_q -j$attempt_jobs_q
EOF
    )

    mkdir -p "$workspace/out/lineage-desktop"
    attempt_gomemlimit_label="${attempt_gomemlimit//[^[:alnum:]._-]/_}"
    attempt_log="$workspace/out/lineage-desktop/build-${product}-j${attempt_jobs}-g${attempt_gomemlimit_label}-p${attempt_gomaxprocs}.log"
    log "running $product build inside muvm (${arm64_muvm_mem_mib} MiB, CPU list ${arm64_muvm_cpu_list:-default}, $attempt_jobs jobs, $arm64_ninja_highmem_jobs high-memory job, Soong GOMEMLIMIT=$attempt_gomemlimit, GOMAXPROCS=$attempt_gomaxprocs, ThinLTO MLGO=$arm64_thinlto_use_mlgo)"
    set +e
    muvm "${muvm_args[@]}" \
      -e ANDROID_BUILD_SERIAL_FINDER=1 \
      -e _SOONG_INTERNAL_NO_FINDER=1 \
      -e GOMEMLIMIT="$attempt_gomemlimit" \
      -e GOGC="$arm64_soong_gogc" \
      -e GOMAXPROCS="$attempt_gomaxprocs" \
      -e GODEBUG="$arm64_godebug" \
      -e GOTRACEBACK=all \
      -e RUSTC_BOOTSTRAP=1 \
      -e THINLTO_USE_MLGO="$arm64_thinlto_use_mlgo" \
      -e LLVM_PREBUILTS_VERSION="$llvm_prebuilts_version" \
      -e LLVM_RELEASE_VERSION="$llvm_release_version" \
      -e LLVM_BINDGEN_PREBUILTS_VERSION="$llvm_prebuilts_version" \
      -- bash -lc "$command" 2>&1 | sanitize_build_log_output | tee "$attempt_log"
    status="${PIPESTATUS[0]}"
    set -e

    if (( status == 0 )); then
      jobs="$attempt_jobs"
      arm64_soong_gomemlimit="$attempt_gomemlimit"
      return 0
    fi

    last_status="$status"
    dump_soong_failure_logs "$product"
    if (( status == 137 )); then
      log "$product build exited with status 137; treating it as ARM64 resource pressure"
    elif ! arm64_log_looks_resource_limited "$attempt_log"; then
      return "$status"
    fi

    remove_soong_graph_state "$product" \
      "failed ARM64 attempt with $attempt_jobs jobs, Soong GOMEMLIMIT=$attempt_gomemlimit, and GOMAXPROCS=$attempt_gomaxprocs"
    log "$product build failed under ARM64 resource pressure with $attempt_jobs jobs, Soong GOMEMLIMIT=$attempt_gomemlimit, and GOMAXPROCS=$attempt_gomaxprocs; retrying lower if available"
  done

  return "$last_status"
}

# On a build failure, Soong/Ninja write the concise failed-action detail to
# out/error.log (full output goes to out/soong.log and out/verbose.log.gz). The
# build's own stdout can stay nearly silent through the long Soong analysis
# phase, so a failure that lives only in error.log is invisible in our build
# log. Surface (a capped tail of) error.log so failures are diagnosable
# immediately instead of requiring a post-mortem dig into the tree.
dump_soong_failure_logs() {
  local product="$1"
  local error_log="$workspace/out/error.log"

  if [[ -s "$error_log" ]]; then
    log "----- out/error.log (failed-action detail for $product) -----"
    tail -n 300 "$error_log" | sed 's/^/[error.log] /'
    log "----- end out/error.log -----"
  else
    log "$product build failed but out/error.log is empty; see out/soong.log and out/verbose.log.gz"
  fi
}

run_build_native() {
  local product="$1"
  local status
  shift

  export_active_llvm_env

  set +u
  source build/envsetup.sh
  lunch "$product" trunk_staging userdebug || die "lunch $product failed"
  [[ "${TARGET_PRODUCT:-}" == "$product" ]] || \
    die "lunch did not set TARGET_PRODUCT=$product (got '${TARGET_PRODUCT:-}')"
  # envsetup.sh and lunch both call `set +u` and may toggle other -o options;
  # re-assert the strict shell flags before running the long build.
  set -eo pipefail
  set -u

  set +e
  m "$@" -j"$jobs" 2>&1 | sanitize_build_log_output
  status="${PIPESTATUS[0]}"
  set -e
  (( status == 0 )) || dump_soong_failure_logs "$product"
  return "$status"
}

run_lunch_and_make() {
  local product="$1"
  shift

  if host_is_arm64; then
    run_build_muvm "$product" "$@"
  else
    run_build_native "$product" "$@"
  fi
}
