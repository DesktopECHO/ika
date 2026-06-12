#!/usr/bin/env bash
set -euo pipefail

# On Debian/Ubuntu, /usr/sbin is absent from the default non-root PATH.
# Add it so system tools (modprobe, mkswap, swapon, zramctl, …) are reachable.
case ":$PATH:" in
  *:/usr/sbin:*) ;;
  *) export PATH="$PATH:/usr/sbin:/sbin" ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
overlay_dir="$(cd "$script_dir/.." && pwd)"
ika_root="$(cd "$overlay_dir/.." && pwd)"

android_manifest_url="${ANDROID_MANIFEST_URL:-https://github.com/LineageOS/android.git}"
lineage_branch="${LINEAGE_BRANCH:-lineage-23.2}"
manifest_url="${MANIFEST_URL:-https://raw.githubusercontent.com/DesktopECHO/ika/main/lineageos/manifests/lineageos-desktop.xml}"
include_microg="${INCLUDE_MICROG:-1}"
update_microg_prebuilts="${UPDATE_MICROG_PREBUILTS:-1}"
include_x86_arm_native_bridge="${INCLUDE_X86_ARM_NATIVE_BRIDGE:-1}"
update_native_bridge_prebuilts="${UPDATE_NATIVE_BRIDGE_PREBUILTS:-1}"
validate_build_inputs="${VALIDATE_BUILD_INPUTS:-1}"
strict_bundle_validation="${STRICT_BUNDLE_VALIDATION:-0}"
ccache_enabled="${CCACHE_ENABLED:-1}"
ccache_dir="${CCACHE_DIR:-$HOME/ika-build/.ccache}"
ccache_max_size="${CCACHE_MAX_SIZE:-50G}"
rebuild="${REBUILD:-0}"
skip_sync="${SKIP_SYNC:-$rebuild}"
skip_patch="${SKIP_PATCH:-$rebuild}"
if [[ -n "${WORKSPACE+x}" ]]; then
  workspace="$WORKSPACE"
  workspace_defaulted=0
else
  workspace="$overlay_dir/src"
  workspace_defaulted=1
fi
output_dir="${OUTPUT_DIR:-$ika_root}"
buildtime_log_path="${BUILDTIME_LOG_PATH:-$ika_root/buildtimes.log}"
repo_install_path="${REPO_INSTALL_PATH:-/usr/local/bin/repo}"
repo_cmd="repo"
repo_sync_attempts="${REPO_SYNC_ATTEMPTS:-9}"
repo_sync_retry_fetches="${REPO_SYNC_RETRY_FETCHES:-9}"
repo_sync_quiet="${REPO_SYNC_QUIET:-}"
# Bandwidth controls for the initial `repo init`. Blobless partial clone
# downloads commit/tree history but fetches file blobs lazily on checkout; keep
# checkout concurrency conservative below so those lazy fetches do not stampede.
# Set REPO_CLONE_FILTER="" to use full clones, or REPO_GROUPS="" to sync every
# manifest group.
repo_clone_filter="${REPO_CLONE_FILTER-blob:none}"
repo_groups="${REPO_GROUPS-default,-darwin}"
repo_sync_jobs="${REPO_SYNC_JOBS:-}"
repo_sync_checkout_jobs="${REPO_SYNC_CHECKOUT_JOBS:-}"
jobs_was_set=0
[[ -n "${JOBS:-}" ]] && jobs_was_set=1
arm64_go_prebuilt_git_url="${ARM64_GO_PREBUILT_GIT_URL:-https://android.googlesource.com/platform/prebuilts/go/linux-arm64}"
arm64_go_prebuilt_git_ref="${ARM64_GO_PREBUILT_GIT_REF:-mirror-goog-llvm-r596125-release}"
arm64_rust_prebuilt_dir="${ARM64_RUST_PREBUILT_DIR:-}"
arm64_rust_prebuilt_archive="${ARM64_RUST_PREBUILT_ARCHIVE:-}"
arm64_rust_prebuilt_git_url="${ARM64_RUST_PREBUILT_GIT_URL:-}"
arm64_rust_prebuilt_git_ref="${ARM64_RUST_PREBUILT_GIT_REF:-}"
arm64_rust_upstream_base_url="${ARM64_RUST_UPSTREAM_BASE_URL:-https://static.rust-lang.org/dist}"
clang_prebuilt_git_ref="${CLANG_PREBUILT_GIT_REF:-mirror-goog-llvm-r596125-release}"
clang_prebuilt_version="${CLANG_PREBUILT_VERSION:-clang-r584948b}"
linux_arm64_clang_prebuilt_git_url="${ARM64_CLANG_PREBUILT_GIT_URL:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-arm64}"
linux_arm64_clang_prebuilt_git_ref="${ARM64_CLANG_PREBUILT_GIT_REF:-$clang_prebuilt_git_ref}"
linux_arm64_clang_prebuilt_version="${ARM64_CLANG_PREBUILT_VERSION:-$clang_prebuilt_version}"
linux_x86_clang_prebuilt_git_url="${X86_CLANG_PREBUILT_GIT_URL:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86}"
linux_x86_clang_prebuilt_git_ref="${X86_CLANG_PREBUILT_GIT_REF:-$clang_prebuilt_git_ref}"
linux_x86_clang_prebuilt_version="${X86_CLANG_PREBUILT_VERSION:-$clang_prebuilt_version}"
arm64_clang_tools_prebuilt_dir="${ARM64_CLANG_TOOLS_PREBUILT_DIR:-}"
arm64_clang_tools_prebuilt_archive="${ARM64_CLANG_TOOLS_PREBUILT_ARCHIVE:-}"
arm64_clang_tools_prebuilt_git_url="${ARM64_CLANG_TOOLS_PREBUILT_GIT_URL:-https://android.googlesource.com/platform/prebuilts/clang-tools}"
arm64_clang_tools_prebuilt_git_ref="${ARM64_CLANG_TOOLS_PREBUILT_GIT_REF:-mirror-goog-main-prebuilts}"
arm64_cmake_prebuilt_git_url="${ARM64_CMAKE_PREBUILT_GIT_URL:-https://android.googlesource.com/platform/prebuilts/cmake/linux-arm64}"
arm64_cmake_prebuilt_git_ref="${ARM64_CMAKE_PREBUILT_GIT_REF:-mirror-goog-llvm-r596125-release}"
arm64_jdk21_prebuilt_url="${ARM64_JDK21_PREBUILT_URL:-https://api.adoptium.net/v3/binary/latest/21/ga/linux/aarch64/jdk/hotspot/normal/eclipse}"
arm64_jdk8_prebuilt_url="${ARM64_JDK8_PREBUILT_URL:-https://api.adoptium.net/v3/binary/latest/8/ga/linux/aarch64/jdk/hotspot/normal/eclipse}"
arm64_job_retry_list="${ARM64_JOB_RETRY_LIST:-}"
if [[ -n "${NOFILE_LIMIT+x}" ]]; then
  host_nofile_limit="$NOFILE_LIMIT"
else
  host_nofile_limit=4194304
fi
arm64_soong_gomemlimit_was_set=0
[[ -n "${ARM64_SOONG_GOMEMLIMIT:-}" ]] && arm64_soong_gomemlimit_was_set=1
arm64_soong_gomemlimit="${ARM64_SOONG_GOMEMLIMIT:-6GiB}"
arm64_soong_gomemlimit_retry_list="${ARM64_SOONG_GOMEMLIMIT_RETRY_LIST:-}"
arm64_soong_gogc="${ARM64_SOONG_GOGC:-100}"
arm64_soong_gomaxprocs_was_set=0
[[ -n "${ARM64_SOONG_GOMAXPROCS:-}" ]] && arm64_soong_gomaxprocs_was_set=1
arm64_soong_gomaxprocs="${ARM64_SOONG_GOMAXPROCS:-4}"
arm64_godebug="${ARM64_GODEBUG:-asyncpreemptoff=1}"
arm64_thinlto_use_mlgo="${ARM64_THINLTO_USE_MLGO:-false}"
arm64_android_java_home="${ARM64_ANDROID_JAVA_HOME:-}"
linux_arm64_llvm_prebuilts_version=""
linux_arm64_llvm_release_version=""
linux_x86_llvm_prebuilts_version=""
linux_x86_llvm_release_version=""
reset_patched_projects="${RESET_PATCHED_PROJECTS:-auto}"
anonymous_git_config_home="$workspace/.lineage-desktop-anonymous-config"
anonymous_git_config="$anonymous_git_config_home/git/config"

usage() {
  # Full CLI + environment reference lives in docs/ so this engine stays
  # readable. The file is part of the overlay and is rsynced alongside it.
  local help_file="$overlay_dir/docs/build-cli-help.txt"
  if [[ -f "$help_file" ]]; then
    cat "$help_file"
  else
    printf 'Usage: build_lineageos_desktop.sh [all|arm64|x86_64]...\n\n'
    printf 'Build LineageOS Desktop ROMs for arm64 and/or x86_64 Cuttlefish.\n'
    printf 'Full option reference: %s\n' "$help_file"
  fi
}

log() {
  printf '[lineage-desktop] %s\n' "$*"
}

die() {
  printf '[lineage-desktop] error: %s\n' "$*" >&2
  exit 1
}

active_build_arch=""
active_build_start_epoch=""
active_build_start_time=""

buildtime_now() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

ensure_buildtime_log() {
  local log_dir
  log_dir="$(dirname "$buildtime_log_path")" || return 0
  mkdir -p "$log_dir" || return 0
  if [[ ! -s "$buildtime_log_path" ]]; then
    printf '%-24s  %-24s  %10s  %-8s  %s\n' \
      start end duration arch status >>"$buildtime_log_path" || true
  fi
}

record_buildtime_start() {
  local arch="$1"

  active_build_arch="$arch"
  active_build_start_epoch="$(date '+%s')"
  active_build_start_time="$(buildtime_now)"
}

record_buildtime_finish() {
  local status="$1"
  [[ -n "$active_build_arch" ]] || return 0

  local finish_epoch finish_time duration duration_tenths duration_hrs arch start_time
  arch="$active_build_arch"
  start_time="$active_build_start_time"
  finish_epoch="$(date '+%s')"
  finish_time="$(buildtime_now)"
  duration=$(( finish_epoch - active_build_start_epoch ))
  duration_tenths=$(( (duration * 10 + 1800) / 3600 ))
  duration_hrs="$(( duration_tenths / 10 )).$(( duration_tenths % 10 ))"

  ensure_buildtime_log
  printf '%-24s  %-24s  %10s  %-8s  %s\n' \
    "$start_time" \
    "$finish_time" \
    "$duration_hrs" \
    "$arch" \
    "$status" >>"$buildtime_log_path" || true

  active_build_arch=""
  active_build_start_epoch=""
  active_build_start_time=""
}

cleanup_build_tmpdir() {
  [[ -n "${build_tmpdir:-}" && -d "$build_tmpdir" ]] || return 0
  rm -rf "$build_tmpdir"
}

cleanup_on_exit() {
  local status=$?
  if [[ -n "$active_build_arch" ]]; then
    if (( status == 0 )); then
      record_buildtime_finish success || true
    else
      record_buildtime_finish failure || true
    fi
  fi
  cleanup_temp_zram || true
  cleanup_build_tmpdir || true
  exit "$status"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

source "$script_dir/lib/common.sh"
source "$script_dir/lib/patch_series.sh"
source "$script_dir/build_jobs.sh"
source "$script_dir/signing_common.sh"
source "$script_dir/lib/target_common.sh"
source "$script_dir/lib/host_env.sh"
source "$script_dir/lib/sources.sh"
source "$script_dir/lib/prebuilts.sh"
source "$script_dir/lib/build_exec.sh"
source "$script_dir/lib/bundle.sh"
source "$script_dir/lib/build_checks.sh"

enabled() {
  case "$1" in
    1|true|yes|on)
      return 0
      ;;
    0|false|no|off)
      return 1
      ;;
    *)
      die "invalid boolean value '$1'; use 1 or 0"
      ;;
  esac
}

# Route all build/signing temp to a dedicated disk-backed dir in $HOME, never
# the host's default /tmp. On stock Asahi/ARM64 hosts /tmp is a small RAM-backed
# tmpfs; the signing step (sign_target_files_apks) extracts the multi-GB
# target-files zip into TMPDIR and otherwise exhausts it (and host RAM), dying
# with "OSError: [Errno 122] Quota exceeded". The dir is removed on exit by
# cleanup_on_exit.
configure_tmpdir() {
  build_tmpdir="$HOME/ika-build/tmp"
  export TMPDIR="$build_tmpdir"
  mkdir -p "$TMPDIR" || die "could not create build TMPDIR: $TMPDIR"
  log "using disk-backed TMPDIR=$TMPDIR (removed on exit)"
}

temp_zram_device=""
build_tmpdir=""

normalize_targets() {
  # Support matrix: arm64 ROMs build on x86_64 and arm64 hosts; x86_64 ROMs
  # build on x86_64 hosts only. A bare invocation builds only the ROM matching
  # the build host. The `all` target expands to every ROM supported by that
  # host. An explicit x86_64 request on an arm64 host is rejected in main()
  # (die inside this subshell would not halt the script).
  if (( $# == 0 )); then
    if host_is_arm64; then
      printf '%s\n' arm64
    else
      printf '%s\n' x86_64
    fi
    return
  fi

  local target
  for target in "$@"; do
    case "$target" in
      all)
        if host_is_arm64; then
          printf '%s\n' arm64
        else
          printf '%s\n' arm64 x86_64
        fi
        ;;
      arm64|aarch64)
        printf '%s\n' arm64
        ;;
      x86_64|x86-64|amd64)
        printf '%s\n' x86_64
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        die "unknown target '$target'; expected all, arm64, or x86_64"
        ;;
    esac
  done | awk '!seen[$0]++'
}

# target_host_tag / target_product / target_product_out / target_bundle_name /
# target_thin_files are defined in lib/target_common.sh (sourced near the top),
# shared with the standalone rebuild helpers.

prepare_target_output_headroom() {
  local arch="$1"
  local product product_out host_package host_tag
  local -a thin_files

  host_tag="$(target_host_tag "$arch")"
  product="$(target_product "$arch")"
  product_out="$(target_product_out "$arch")"
  host_package="$workspace/out/host/$host_tag/cvd-host_package.tar.gz"
  mapfile -t thin_files < <(target_thin_files "$arch")

  remove_generated_ninja_state "$product" "pre-build headroom cleanup"
  remove_packaged_target_outputs "$product" "$product_out" "$host_package" "${thin_files[@]}"
  remove_target_image_outputs_for_headroom "$product_out"
}

build_target() {
  local arch="$1"
  local product product_out host_package bundle_name host_tag
  local -a thin_files

  host_tag="$(target_host_tag "$arch")"
  product="$(target_product "$arch")"
  product_out="$(target_product_out "$arch")"
  host_package="$workspace/out/host/$host_tag/cvd-host_package.tar.gz"
  bundle_name="$(target_bundle_name "$arch")"
  mapfile -t thin_files < <(target_thin_files "$arch")

  cd "$workspace"
  log "building $product"
  repair_soong_zero_byte_objects
  repair_stale_soong_graph_state "$product"
  repair_zero_size_fstab_outputs "$product" "$product_out"
  remove_stale_launcher3_outputs "$product" "$product_out"
  repair_zero_size_cvd_host_package "$host_package"

  if [[ "$arch" == "x86_64" ]]; then
    if enabled "$include_x86_arm_native_bridge"; then
      export LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE=true
      export USE_NDK_TRANSLATION_BINARY=true
    else
      export LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE=false
      unset USE_NDK_TRANSLATION_BINARY || true
    fi
  fi

  local target_files_zip="$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip"
  local signed_artifacts_dir="$HOME/ika-build/lineageos/signed/$product"
  local signed_target_files_zip="$signed_artifacts_dir/${product}-target_files-signed.zip"
  local signed_images_dir="$signed_artifacts_dir/signed_images"
  remove_packaged_target_outputs "$product" "$product_out" "$host_package" "${thin_files[@]}"
  rm -rf "$signed_artifacts_dir"

  run_lunch_and_make "$product" \
    hosttar \
    bootimage \
    vendorbootimage \
    initbootimage \
    systemimage \
    systemextimage \
    productimage \
    vendorimage \
    userdataimage \
    superimage \
    vbmetaimage \
    vbmetasystemimage \
    target-files-package \
    otatools
  built_target_outputs_complete "$product" "$product_out" "$host_package" "${thin_files[@]}" || \
    die "build completed but expected outputs are missing for $product"
  validate_cvd_target_fstabs "$product_out"
  desktop_launcher_outputs_exclusive "$product_out" "$target_files_zip" || \
    die "$product target-files still include non-QuickStep Launcher3 artifacts"
  repair_cvd_host_package_avb_keys "$host_package"

  log "signing $product target-files"
  "$script_dir/sign_target_files.sh" \
    "$target_files_zip" \
    "$signed_target_files_zip" \
    "$signed_images_dir"

  package_cvd_bundle "$arch" "$product" "$product_out" "$host_package" "$signed_images_dir" "$bundle_name" "${thin_files[@]}"
  bundle_dir_complete "$output_dir/$bundle_name" "${thin_files[@]}" || \
    die "packaging completed but $bundle_name/ is incomplete"
}

main() {
  trap cleanup_on_exit EXIT

  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  ensure_host_commands
  ensure_arm64_native_host
  configure_tmpdir
  ensure_signing_keys
  raise_host_open_file_limit
  if [[ "${IKA_PRIVILEGED_PREFLIGHT_DONE:-0}" != "1" ]]; then
    setup_temp_zram_if_needed
  fi
  set_build_jobs
  configure_arm64_soong_limits
  log "using $jobs parallel build jobs ($highmem_jobs high-memory jobs)"
  configure_ccache
  ensure_repo_command
  ensure_anonymous_git_config
  cleanup_workspace_path_metadata
  if [[ "${IKA_PRIVILEGED_PREFLIGHT_DONE:-0}" != "1" ]]; then
    ensure_workspace_selinux_contexts
  fi

  local -a targets
  mapfile -t targets < <(normalize_targets "$@")
  if host_is_arm64; then
    local requested_target
    for requested_target in "${targets[@]}"; do
      [[ "$requested_target" == "x86_64" ]] && \
        die "x86_64 ROMs can only be built on an x86_64 host (current host: $(uname -m))"
    done
  fi
  mkdir -p "$output_dir"
  for target in "${targets[@]}"; do
    prepare_target_output_headroom "$target"
  done

  if enabled "$skip_sync"; then
    log "skipping repo sync (REBUILD/SKIP_SYNC); reusing existing source tree"
  else
    repo_sync_sources
  fi
  sync_webview_lfs_prebuilts
  repair_webview_intermediates
  apply_local_overlay
  ensure_vendor_ika_soong_pruning
  restore_android_rust_tool_bridges
  ensure_linux_x86_clang_prebuilt
  if enabled "$skip_patch"; then
    log "skipping source patches (REBUILD/SKIP_PATCH); reusing patched tree"
  else
    apply_source_patches
  fi
  update_microg_prebuilts
  configure_arm64_host_build
  cleanup_arm64_prebuilt_download_caches

  local target
  for target in "${targets[@]}"; do
    if [[ "$target" == "x86_64" ]]; then
      update_native_bridge_prebuilts_for_targets x86_64
    fi
    validate_build_inputs_for_targets "$target"
    record_buildtime_start "$target"
    build_target "$target"
    record_buildtime_finish success
  done

  log "done"
  log "output directory: $output_dir"
  for target in "${targets[@]}"; do
    log "  -> $output_dir/$(target_bundle_name "$target")/"
  done
}

main "$@"
