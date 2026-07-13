#!/usr/bin/env bash
# Build execution for the LineageOS Desktop build engine: active-LLVM env
# export, native execution, and the lunch+make dispatch.
# Source only (defines functions). Relies on engine globals + core primitives at
# call time.

configure_ccache() {
  # ccache speeds up incremental and repeat builds (Soong honors USE_CCACHE for
  # C/C++). The first clean build sees ~no benefit; subsequent builds drop a lot
  # of compile time. Optional: a missing ccache only warns, never fails.
  enabled "$ccache_enabled" || { log "ccache disabled (CCACHE_ENABLED=0)"; return 0; }

  if ! command -v ccache >/dev/null 2>&1; then
    log "warning: ccache requested but not found; building without it"
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

raise_host_open_file_limit() {
  [[ -n "$host_nofile_limit" ]] || return 0
  [[ "$host_nofile_limit" =~ ^[0-9]+$ ]] || \
    die "NOFILE_LIMIT must be a numeric limit or empty to skip"

  local current_soft current_hard
  current_soft="$(ulimit -Sn)"
  current_hard="$(ulimit -Hn)"
  if nofile_limit_at_least "$current_soft" "$host_nofile_limit" && \
     nofile_limit_at_least "$current_hard" "$host_nofile_limit"; then
    log "host open-file limit already ${current_soft}:${current_hard}"
    return 0
  fi

  command -v prlimit >/dev/null 2>&1 || \
    die "host needs prlimit (util-linux) to raise the open-file limit"

  if [[ "${IKA_PRIVILEGED_PREFLIGHT_DONE:-0}" == "1" ]]; then
    die "host open-file limit is ${current_soft}:${current_hard}; privileged preflight should have raised it to $host_nofile_limit"
  fi

  if run_privileged prlimit --pid "$$" --nofile="${host_nofile_limit}:${host_nofile_limit}" >/dev/null 2>&1; then
    current_soft="$(ulimit -Sn)"
    current_hard="$(ulimit -Hn)"
    if nofile_limit_at_least "$current_soft" "$host_nofile_limit" && \
       nofile_limit_at_least "$current_hard" "$host_nofile_limit"; then
      log "raised host open-file limit to ${current_soft}:${current_hard}"
      return 0
    fi
  fi

  die "failed to raise host open-file limit to $host_nofile_limit; current limit is ${current_soft}:${current_hard}"
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

  command -v ninja >/dev/null 2>&1 || \
    die "ARM64 prebuilt Ninja cannot run on this host; install a system ninja package"

  export ANDROID_BUILD_NINJA="$(command -v ninja)"
  export ANDROID_BUILD_CLASSIC_NINJA=1
  log "ARM64 prebuilt Ninja cannot run on this host; using system Ninja at $ANDROID_BUILD_NINJA"
}

configure_arm64_host_build() {
  host_is_arm64 || return 0

  log "using ARM64 prebuilt download cache: ${arm64_prebuilt_cache_dir:-$HOME/ika-build/arm64-prebuilts}"
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
  raise_host_open_file_limit
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
  local java_home status
  shift

  export_active_llvm_env
  if host_is_arm64; then
    java_home="$(arm64_android_java_home_for_build || true)"
    [[ -n "$java_home" ]] && export OVERRIDE_ANDROID_JAVA_HOME="$java_home"
    export THINLTO_USE_MLGO="$arm64_thinlto_use_mlgo"
  fi

  set +u
  source build/envsetup.sh
  log "lunching $product trunk_staging $build_variant"
  lunch "$product" trunk_staging "$build_variant" || die "lunch $product failed"
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

  run_build_native "$product" "$@"
}

build_host_lpunpack() {
  local lpunpack_bin="$workspace/out/host/linux-x86/bin/lpunpack"
  [[ -x "$lpunpack_bin" ]] && return 0
  log "lpunpack not found; building from LineageOS tree..."
  (cd "$workspace" && run_build_native "$(target_product x86_64)" \
    LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE=false lpunpack)
  [[ -x "$lpunpack_bin" ]] || die "lpunpack build succeeded but binary not found at $lpunpack_bin"
  log "lpunpack built: $lpunpack_bin"
}

build_host_microg_tools() {
  enabled "$include_microg" || return 0
  enabled "$update_microg_prebuilts" || return 0
  [[ "${MICROG_GMSCORE_RELEASE:-main}" == "main" ]] || return 0

  local host_tag build_target host_bin
  if host_is_arm64; then
    host_tag="linux-arm64"
  else
    host_tag="linux-x86"
  fi
  build_target="${1:-}"
  [[ -n "$build_target" ]] || die "internal error: no target available for GmsCore host-tool bootstrap"
  host_bin="$workspace/out/host/$host_tag/bin"
  local -a tools=(aapt2 aidl apksigner d8 zipalign adb)
  local tool missing=0
  for tool in "${tools[@]}"; do
    if [[ ! -x "$host_bin/$tool" ]]; then
      missing=1
      break
    fi
  done
  (( missing == 0 )) && return 0

  log "building native $host_tag Android SDK tools for GmsCore"
  (cd "$workspace" && run_build_native "$(target_product "$build_target")" "${tools[@]}")
  for tool in "${tools[@]}"; do
    [[ -x "$host_bin/$tool" ]] || \
      die "GmsCore host-tool build succeeded but $host_bin/$tool is missing"
  done
}
