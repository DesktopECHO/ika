#!/usr/bin/env bash
# Build execution for the LineageOS Desktop build engine: ARM64 memory limit
# tuning, active-LLVM env export, native execution, and the lunch+make dispatch.
# Source only (defines functions). Relies on engine globals + core primitives at
# call time.

configure_arm64_soong_limits() {
  host_is_arm64 || return 0

  if [[ ! "$arm64_soong_gomaxprocs" =~ ^[0-9]+$ || "$arm64_soong_gomaxprocs" -le 0 ]]; then
    build_jobs_fail \
      "invalid ARM64_SOONG_GOMAXPROCS value '$arm64_soong_gomaxprocs'; expected a positive integer"
    return 1
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

raise_arm64_open_file_limit() {
  host_is_arm64 || return 0
  [[ -n "$arm64_nofile_limit" ]] || return 0
  [[ "$arm64_nofile_limit" =~ ^[0-9]+$ ]] || \
    die "ARM64_NOFILE_LIMIT must be a numeric limit or empty to skip"

  local current_soft current_hard
  current_soft="$(ulimit -Sn)"
  current_hard="$(ulimit -Hn)"
  if nofile_limit_at_least "$current_soft" "$arm64_nofile_limit" && \
     nofile_limit_at_least "$current_hard" "$arm64_nofile_limit"; then
    log "host open-file limit already ${current_soft}:${current_hard}"
    return 0
  fi

  command -v prlimit >/dev/null 2>&1 || install_missing_commands prlimit || true
  command -v prlimit >/dev/null 2>&1 || \
    die "ARM64 host needs prlimit to raise the open-file limit"

  if run_privileged prlimit --pid "$$" --nofile="${arm64_nofile_limit}:${arm64_nofile_limit}" >/dev/null 2>&1; then
    current_soft="$(ulimit -Sn)"
    current_hard="$(ulimit -Hn)"
    if nofile_limit_at_least "$current_soft" "$arm64_nofile_limit" && \
       nofile_limit_at_least "$current_hard" "$arm64_nofile_limit"; then
      log "raised host open-file limit to ${current_soft}:${current_hard}"
      return 0
    fi
  fi

  die "failed to raise host open-file limit to $arm64_nofile_limit; current limit is ${current_soft}:${current_hard}"
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

configure_arm64_ninja_runner() {
  host_is_arm64 || return 0

  unset ANDROID_BUILD_NINJA
  unset ANDROID_BUILD_CLASSIC_NINJA

  local prebuilt_ninja page_size
  prebuilt_ninja="$workspace/prebuilts/build-tools/linux-arm64/bin/ninja"
  page_size="$(getconf PAGESIZE 2>/dev/null || true)"
  if [[ -n "$page_size" && "$page_size" != "4096" ]]; then
    log "ARM64 host page size is $page_size; using system Ninja fallback without probing the prebuilt Ninja"
  elif [[ -x "$prebuilt_ninja" ]]; then
    return 0
  fi

  command -v ninja >/dev/null 2>&1 || install_missing_commands ninja || true
  command -v ninja >/dev/null 2>&1 || \
    die "ARM64 prebuilt Ninja cannot run on this host; install a system ninja package"

  export ANDROID_BUILD_NINJA="$(command -v ninja)"
  export ANDROID_BUILD_CLASSIC_NINJA=1
  log "ARM64 prebuilt Ninja cannot run on this host; using system Ninja at $ANDROID_BUILD_NINJA"
}

configure_arm64_host_build() {
  host_is_arm64 || return 0

  ensure_arm64_go_prebuilt
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
  raise_arm64_open_file_limit
  configure_arm64_ninja_runner
}

sanitize_build_log_output() {
  sed -u 's/ERROR init_or_kernel] \[missing newline\]/PING/g'
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

run_build_arm64_native() {
  local product="$1"
  shift

  ensure_linux_arm64_clang_ready
  raise_arm64_open_file_limit
  configure_arm64_ninja_runner

  local -a build_attempts=()
  mapfile -t build_attempts < <(arm64_build_attempts "$jobs" "$arm64_soong_gomemlimit")

  local attempt attempt_jobs attempt_gomemlimit attempt_gomaxprocs
  local attempt_gomemlimit_label attempt_log status last_status=1 java_home
  java_home="$(arm64_android_java_home_for_build || true)"

  for attempt in "${build_attempts[@]}"; do
    read -r attempt_jobs attempt_gomemlimit <<< "$attempt"
    attempt_gomaxprocs="$arm64_soong_gomaxprocs"
    if (( arm64_soong_gomaxprocs_was_set == 0 && attempt_jobs < attempt_gomaxprocs )); then
      attempt_gomaxprocs="$attempt_jobs"
    fi

    mkdir -p "$workspace/out/lineage-desktop"
    attempt_gomemlimit_label="${attempt_gomemlimit//[^[:alnum:]._-]/_}"
    attempt_log="$workspace/out/lineage-desktop/build-${product}-native-j${attempt_jobs}-g${attempt_gomemlimit_label}-p${attempt_gomaxprocs}.log"
    log "running $product build natively on ARM64 ($attempt_jobs jobs, $highmem_jobs high-memory jobs, Soong GOMEMLIMIT=$attempt_gomemlimit, GOMAXPROCS=$attempt_gomaxprocs, ThinLTO MLGO=$arm64_thinlto_use_mlgo)"

    export GOMEMLIMIT="$attempt_gomemlimit"
    export GOGC="$arm64_soong_gogc"
    export GOMAXPROCS="$attempt_gomaxprocs"
    export GODEBUG="$arm64_godebug"
    export GOTRACEBACK=all
    export RUSTC_BOOTSTRAP=1
    export ANDROID_BUILD_NINJA="${ANDROID_BUILD_NINJA:-}"
    export ANDROID_BUILD_CLASSIC_NINJA="${ANDROID_BUILD_CLASSIC_NINJA:-}"
    export NINJA_HIGHMEM_NUM_JOBS="$highmem_jobs"
    export THINLTO_USE_MLGO="$arm64_thinlto_use_mlgo"
    export_active_llvm_env
    if [[ -n "$java_home" ]]; then
      export OVERRIDE_ANDROID_JAVA_HOME="$java_home"
    fi

    set +u
    source build/envsetup.sh
    lunch "$product" trunk_staging userdebug || die "lunch $product failed"
    [[ "${TARGET_PRODUCT:-}" == "$product" ]] || \
      die "lunch did not set TARGET_PRODUCT=$product (got '${TARGET_PRODUCT:-}')"
    set -eo pipefail
    set -u

    set +e
    m "$@" -j"$attempt_jobs" 2>&1 | sanitize_build_log_output | tee "$attempt_log"
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
      "failed native ARM64 attempt with $attempt_jobs jobs, Soong GOMEMLIMIT=$attempt_gomemlimit, and GOMAXPROCS=$attempt_gomaxprocs"
    log "$product build failed under ARM64 resource pressure with $attempt_jobs jobs, Soong GOMEMLIMIT=$attempt_gomemlimit, and GOMAXPROCS=$attempt_gomaxprocs; retrying lower if available"
  done

  return "$last_status"
}

run_lunch_and_make() {
  local product="$1"
  shift

  if host_is_arm64; then
    run_build_arm64_native "$product" "$@"
  else
    run_build_native "$product" "$@"
  fi
}
