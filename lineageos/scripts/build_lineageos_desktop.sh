#!/usr/bin/env bash
set -euo pipefail

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
resume_build="${RESUME_BUILD:-0}"
force_rebuild="${FORCE_REBUILD:-0}"
if [[ -n "${WORKSPACE+x}" ]]; then
  workspace="$WORKSPACE"
  workspace_defaulted=0
else
  workspace="$overlay_dir/src"
  workspace_defaulted=1
fi
output_dir="${OUTPUT_DIR:-$ika_root}"
buildtime_log_path="${BUILDTIME_LOG_PATH:-$ika_root/buildtime.txt}"
repo_tool_url="${REPO_TOOL_URL:-https://storage.googleapis.com/git-repo-downloads/repo}"
repo_install_path="${REPO_INSTALL_PATH:-/usr/local/bin/repo}"
repo_cmd="repo"
repo_sync_attempts="${REPO_SYNC_ATTEMPTS:-9}"
repo_sync_retry_fetches="${REPO_SYNC_RETRY_FETCHES:-9}"
repo_sync_quiet="${REPO_SYNC_QUIET:-}"
jobs_was_set=0
[[ -n "${JOBS:-}" ]] && jobs_was_set=1
ninja_highmem_jobs_was_set=0
[[ -n "${NINJA_HIGHMEM_NUM_JOBS:-}" ]] && ninja_highmem_jobs_was_set=1
arm64_go_prebuilt_git_url="${ARM64_GO_PREBUILT_GIT_URL:-https://android.googlesource.com/platform/prebuilts/go/linux-arm64}"
arm64_go_prebuilt_git_ref="${ARM64_GO_PREBUILT_GIT_REF:-mirror-goog-llvm-r596125-release}"
clang_prebuilt_git_ref="${CLANG_PREBUILT_GIT_REF:-mirror-goog-llvm-r596125-release}"
clang_prebuilt_version="${CLANG_PREBUILT_VERSION:-clang-r584948b}"
linux_arm64_clang_prebuilt_git_url="${ARM64_CLANG_PREBUILT_GIT_URL:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-arm64}"
linux_arm64_clang_prebuilt_git_ref="${ARM64_CLANG_PREBUILT_GIT_REF:-$clang_prebuilt_git_ref}"
linux_arm64_clang_prebuilt_version="${ARM64_CLANG_PREBUILT_VERSION:-$clang_prebuilt_version}"
linux_x86_clang_prebuilt_git_url="${X86_CLANG_PREBUILT_GIT_URL:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86}"
linux_x86_clang_prebuilt_git_ref="${X86_CLANG_PREBUILT_GIT_REF:-$clang_prebuilt_git_ref}"
linux_x86_clang_prebuilt_version="${X86_CLANG_PREBUILT_VERSION:-$clang_prebuilt_version}"
arm64_cmake_prebuilt_git_url="${ARM64_CMAKE_PREBUILT_GIT_URL:-https://android.googlesource.com/platform/prebuilts/cmake/linux-arm64}"
arm64_cmake_prebuilt_git_ref="${ARM64_CMAKE_PREBUILT_GIT_REF:-mirror-goog-llvm-r596125-release}"
arm64_jdk21_prebuilt_url="${ARM64_JDK21_PREBUILT_URL:-https://api.adoptium.net/v3/binary/latest/21/ga/linux/aarch64/jdk/hotspot/normal/eclipse}"
arm64_jobs="${ARM64_JOBS:-4}"
arm64_job_retry_list="${ARM64_JOB_RETRY_LIST:-}"
arm64_muvm_mem_mib="${ARM64_MUVM_MEM_MIB:-32768}"
arm64_soong_gomemlimit_was_set=0
[[ -n "${ARM64_SOONG_GOMEMLIMIT:-}" ]] && arm64_soong_gomemlimit_was_set=1
arm64_soong_gomemlimit="${ARM64_SOONG_GOMEMLIMIT:-2GiB}"
arm64_soong_gomemlimit_retry_list="${ARM64_SOONG_GOMEMLIMIT_RETRY_LIST:-}"
arm64_soong_gogc="${ARM64_SOONG_GOGC:-25}"
arm64_soong_gomaxprocs_was_set=0
[[ -n "${ARM64_SOONG_GOMAXPROCS:-}" ]] && arm64_soong_gomaxprocs_was_set=1
arm64_soong_gomaxprocs="${ARM64_SOONG_GOMAXPROCS:-4}"
arm64_godebug="${ARM64_GODEBUG:-asyncpreemptoff=1}"
arm64_thinlto_use_mlgo="${ARM64_THINLTO_USE_MLGO:-false}"
arm64_ninja_highmem_jobs="${ARM64_NINJA_HIGHMEM_JOBS:-1}"
arm64_android_java_home="${ARM64_ANDROID_JAVA_HOME:-}"
linux_arm64_llvm_prebuilts_version=""
linux_arm64_llvm_release_version=""
linux_x86_llvm_prebuilts_version=""
linux_x86_llvm_release_version=""
auto_install_deps="${AUTO_INSTALL_DEPS:-1}"
reset_patched_projects="${RESET_PATCHED_PROJECTS:-auto}"
anonymous_git_config_home="$workspace/.lineage-desktop-anonymous-config"
anonymous_git_config="$anonymous_git_config_home/git/config"

usage() {
  cat <<'EOF'
Usage: build_lineageos_desktop.sh [all|arm64|x86_64]...

Build LineageOS Desktop from a clean LineageOS 23.2 checkout and write
Cuttlefish-ready bundles into the directories lineageos-arm64/ and
lineageos-x86_64/ under the ika project root.

Environment:
  WORKSPACE             Android source checkout to create or reuse.
                        Default: ika/lineageos/src
  OUTPUT_DIR            Parent directory for the lineageos-<arch>/ bundle
                        directories. Default: the ika project root.
  BUILDTIME_LOG_PATH    TSV ledger for each ROM build target with start time,
                        finish time, duration, architecture, and success or
                        failure. Default: ika/buildtime.txt.
  JOBS                  Parallel jobs for repo sync and m. Default: reserve
                        4 GiB RAM, then one job per 3.5 GiB physical+virtual
                        RAM, capped at available logical CPU count.
  NINJA_HIGHMEM_NUM_JOBS
                        Soong high-memory pool jobs. Default: same 4 GiB RAM
                        reserve, then one job per 16 GiB physical+virtual RAM,
                        capped by JOBS.
  Temporary zram       Builds get zram swap sized to twice physical RAM, capped
                        at 32 GiB, and prioritized above existing swap devices.
                        Build-created zram is removed
                        automatically when the script exits.
  LINEAGE_BRANCH        LineageOS branch. Default: lineage-23.2
  ANDROID_MANIFEST_URL  Manifest repository. Default: LineageOS/android.git
  MANIFEST_URL          Fallback overlay manifest URL.
  INCLUDE_MICROG        Sync vendor/partner_gms and include microG packages.
                        Default: 1
  UPDATE_MICROG_PREBUILTS
                        Refresh GmsCore, FakeStore, and GsfProxy from official
                        microG GitHub releases before building. Default: 1
  INCLUDE_X86_ARM_NATIVE_BRIDGE
                        Enable ARM64 native bridge support for the x86-64 ROM.
                        Default: 1
  UPDATE_NATIVE_BRIDGE_PREBUILTS
                        Download/extract the Google NDK translation payload for
                        x86-64 builds before building. Default: 1
  VALIDATE_BUILD_INPUTS
                        Run build-time source, prebuilt, userdata, and desktop
                        policy checks before compiling. Default: 1
  STRICT_BUNDLE_VALIDATION
                        Fail the build if package_cvd_bundle has to normalize
                        any etc/cvd_config/*.json preset (empty / unparseable
                        / non-object). Default 0 silently rewrites bad presets
                        to {} with a log line so the bundle is launchable;
                        set to 1 in CI / release builds to surface a corrupt
                        Soong prebuilt instead of papering over it. Default: 0
  SELINUX_WORKSPACE_TYPE
                        SELinux type applied to checkout paths before builds.
                        Use none to disable. Default: src_t
  STRICT_APEX_SIGNING   Fail target-files signing if any shipped APEX lacks a
                        matching container and payload key in ANDROID_CERTS_DIR.
                        Default: 1
  RESUME_BUILD          Reuse checkpointed setup, build, and package phases
                        from an interrupted run when their inputs match. A
                        completed run closes its build/package checkpoints, so
                        a later invocation cannot repackage old product images.
                        Default: 0
  FORCE_REBUILD         Ignore resume checkpoints and rebuild/repackage.
                        Default: 0
  NATIVE_BRIDGE_SOURCE_DIR
                        Use an already-extracted Android system image root for
                        native bridge prebuilts instead of downloading one.
  NATIVE_BRIDGE_SDK_PACKAGE
                        Android SDK system image zip path or URL used for the
                        native bridge payload.
  NATIVE_BRIDGE_SDK_PACKAGE_SHA1
                        Expected SHA1 for the SDK package. Empty skips checking.
  MICROG_GMSCORE_RELEASE
                        microg/GmsCore release tag, or latest. Default: latest
  MICROG_GSFPROXY_RELEASE
                        GsfProxy microG F-Droid version name/code, or latest.
                        Default: latest
  REPO_INSTALL_PATH     Install path used if repo is missing.
                        Default: /usr/local/bin/repo
  REPO_SYNC_ATTEMPTS    Top-level repo sync attempts. Default: 9
  REPO_SYNC_RETRY_FETCHES
                        Per-project repo fetch retries. Default: 9
  REPO_SYNC_QUIET       Pass --quiet to repo sync. Default: auto, enabled on
                        ARM64 hosts to avoid Python progress-output EAGAIN
                        failures seen under emulated host tool setups.
  ARM64_GO_PREBUILT_GIT_URL
                        AOSP Go linux-arm64 prebuilt repo used to bootstrap
                        Soong when this branch lacks prebuilts/go/linux-arm64.
                        Default: platform/prebuilts/go/linux-arm64.
  ARM64_GO_PREBUILT_GIT_REF
                        Branch/tag/ref for ARM64_GO_PREBUILT_GIT_URL.
                        Default: mirror-goog-llvm-r596125-release.
  CLANG_PREBUILT_GIT_REF
                        Shared default Clang prebuilt branch/tag/ref for all
                        ROM targets. Default:
                        mirror-goog-llvm-r596125-release.
  CLANG_PREBUILT_VERSION
                        Shared default clang-r* payload for all ROM targets.
                        Default: clang-r584948b.
  ARM64_CLANG_PREBUILT_GIT_URL
                        AOSP Clang linux-arm64 prebuilt repo used on ARM64
                        hosts. Default:
                        platform/prebuilts/clang/host/linux-arm64.
  ARM64_CLANG_PREBUILT_GIT_REF
                        Branch/tag/ref for ARM64_CLANG_PREBUILT_GIT_URL.
                        Default: CLANG_PREBUILT_GIT_REF.
  ARM64_CLANG_PREBUILT_VERSION
                        clang-r* payload used from ARM64_CLANG_PREBUILT_GIT_URL.
                        Default: CLANG_PREBUILT_VERSION.
  X86_CLANG_PREBUILT_GIT_URL
                        AOSP Clang linux-x86 prebuilt repo used to pin x86
                        builds to the same LLVM release as ARM64 builds.
                        Default: platform/prebuilts/clang/host/linux-x86.
  X86_CLANG_PREBUILT_GIT_REF
                        Branch/tag/ref for X86_CLANG_PREBUILT_GIT_URL.
                        Default: CLANG_PREBUILT_GIT_REF.
  X86_CLANG_PREBUILT_VERSION
                        clang-r* payload used from X86_CLANG_PREBUILT_GIT_URL.
                        Default: CLANG_PREBUILT_VERSION.
  ARM64_CMAKE_PREBUILT_GIT_URL
                        AOSP CMake linux-arm64 prebuilt repo used on ARM64
                        hosts. Default: platform/prebuilts/cmake/linux-arm64.
  ARM64_CMAKE_PREBUILT_GIT_REF
                        Branch/tag/ref for ARM64_CMAKE_PREBUILT_GIT_URL.
                        Default: mirror-goog-llvm-r596125-release.
  ARM64_JDK21_PREBUILT_URL
                        Native Linux ARM64 JDK 21 tarball used when this branch
                        lacks prebuilts/jdk/jdk21/linux-arm64. Default:
                        Adoptium Temurin JDK 21 API URL.
  ARM64_JOBS            Default parallel build jobs on ARM64 hosts when JOBS is
                        unset. Tuned for a 16 GiB M1 Mac. Default: 4
  ARM64_JOB_RETRY_LIST  Space-separated ARM64 job counts to try if a faster
                        attempt fails from memory/process pressure. Default:
                        ARM64_JOBS, then lower counts down to 1.
  ARM64_MUVM_MEM_MIB    Memory passed to muvm on ARM64 hosts. Default: 32768.
                        This intentionally exceeds physical RAM on a 16 GiB
                        M1 Mac; host zram is enabled first and backs the 4 KiB
                        guest when Soong graph generation crosses 16 GiB.
  ARM64_SOONG_GOMEMLIMIT
                        Go memory limit passed into Soong on ARM64 hosts.
                        Default: 3GiB
  ARM64_SOONG_GOMEMLIMIT_RETRY_LIST
                        Space-separated Soong Go memory limits to try after
                        resource-pressure failures. Default: ARM64_SOONG_GOMEMLIMIT,
                        then lower limits down to 1GiB.
  ARM64_SOONG_GOMAXPROCS
                        Go scheduler threads for Soong graph generation on
                        ARM64 hosts. Default: 4, capped to retry job count
                        unless explicitly set.
  ARM64_GODEBUG         Go runtime flags passed into ARM64/muvm builds.
                        Default: asyncpreemptoff=1
  ARM64_THINLTO_USE_MLGO
                        Enables Soong ThinLTO MLGO linker advisors inside
                        ARM64/muvm builds. Default: false, because current
                        Linux ARM64 Clang prebuilts can emit ARM64 code
                        natively here but do not ship every release advisor
                        model expected by this branch.
  ARM64_NINJA_HIGHMEM_JOBS
                        High-memory Ninja pool jobs inside muvm on ARM64.
                        Default: 1
  ARM64_ANDROID_JAVA_HOME
                        System JDK to use when the source tree lacks an ARM64
                        JDK prebuilt. Default: auto-detect from javac.
  AUTO_INSTALL_DEPS     Install missing basic host tools with apt/dnf/pacman
                        when possible. Default: 1
  ARM64 host emulation  Current AOSP/LineageOS branches still rely on
                        some x86-64 Linux host prebuilts and need a 4 KiB page
                        guest for them. On ARM64 Fedora Asahi hosts install:
                        sudo dnf install -y fex-emu fex-emu-rootfs-fedora muvm
                        The script runs the Android build under muvm on ARM64.
  RESET_PATCHED_PROJECTS
                        Reset patched source projects before repo sync.
                        Default: auto for script-managed workspaces
EOF
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
  exit "$status"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

source "$script_dir/build_jobs.sh"
source "$script_dir/signing_common.sh"

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

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' apt
  elif command -v dnf >/dev/null 2>&1; then
    printf '%s\n' dnf
  elif command -v pacman >/dev/null 2>&1; then
    printf '%s\n' pacman
  else
    return 1
  fi
}

package_for_command() {
  local pm="$1"
  local cmd="$2"

  case "$pm:$cmd" in
    apt:awk) printf '%s\n' gawk ;;
    apt:find) printf '%s\n' findutils ;;
    apt:git) printf '%s\n' git ;;
    apt:git-lfs) printf '%s\n' git-lfs ;;
    apt:go) printf '%s\n' golang-go ;;
    apt:javac) printf '%s\n' openjdk-21-jdk ;;
    apt:install|apt:mktemp|apt:readlink) printf '%s\n' coreutils ;;
    apt:modprobe) printf '%s\n' kmod ;;
    apt:prlimit) printf '%s\n' util-linux ;;
    apt:restorecon) printf '%s\n' policycoreutils ;;
    apt:semanage) printf '%s\n' policycoreutils-python-utils ;;
    apt:mkswap|apt:swapoff|apt:swapon|apt:zramctl) printf '%s\n' util-linux ;;
    apt:python3) printf '%s\n' python3 ;;
    apt:rsync) printf '%s\n' rsync ;;
    apt:tar) printf '%s\n' tar ;;
    apt:curl) printf '%s\n' curl ;;
    apt:adb) printf '%s\n' adb ;;
    dnf:awk) printf '%s\n' gawk ;;
    dnf:find) printf '%s\n' findutils ;;
    dnf:git) printf '%s\n' git ;;
    dnf:git-lfs) printf '%s\n' git-lfs ;;
    dnf:go) printf '%s\n' golang ;;
    dnf:javac) printf '%s\n' java-25-openjdk-devel ;;
    dnf:install|dnf:mktemp|dnf:readlink) printf '%s\n' coreutils ;;
    dnf:modprobe) printf '%s\n' kmod ;;
    dnf:prlimit) printf '%s\n' util-linux ;;
    dnf:restorecon) printf '%s\n' policycoreutils ;;
    dnf:semanage) printf '%s\n' policycoreutils-python-utils ;;
    dnf:mkswap|dnf:swapoff|dnf:swapon|dnf:zramctl) printf '%s\n' util-linux ;;
    dnf:python3) printf '%s\n' python3 ;;
    dnf:rsync) printf '%s\n' rsync ;;
    dnf:tar) printf '%s\n' tar ;;
    dnf:curl) printf '%s\n' curl ;;
    dnf:adb) printf '%s\n' android-tools ;;
    dnf:FEXInterpreter) printf '%s\n' fex-emu ;;
    dnf:muvm) printf '%s\n' muvm ;;
    dnf:binfmt-dispatcher) printf '%s\n' binfmt-dispatcher ;;
    dnf:qemu-x86_64) printf '%s\n' qemu-user ;;
    dnf:qemu-x86_64-static) printf '%s\n' qemu-user-static-x86 ;;
    pacman:awk) printf '%s\n' gawk ;;
    pacman:find) printf '%s\n' findutils ;;
    pacman:git) printf '%s\n' git ;;
    pacman:git-lfs) printf '%s\n' git-lfs ;;
    pacman:go) printf '%s\n' go ;;
    pacman:javac) printf '%s\n' jdk-openjdk ;;
    pacman:install|pacman:mktemp|pacman:readlink) printf '%s\n' coreutils ;;
    pacman:modprobe) printf '%s\n' kmod ;;
    pacman:prlimit) printf '%s\n' util-linux ;;
    pacman:restorecon) printf '%s\n' policycoreutils ;;
    pacman:semanage) printf '%s\n' policycoreutils ;;
    pacman:mkswap|pacman:swapoff|pacman:swapon|pacman:zramctl) printf '%s\n' util-linux ;;
    pacman:python3) printf '%s\n' python ;;
    pacman:rsync) printf '%s\n' rsync ;;
    pacman:tar) printf '%s\n' tar ;;
    pacman:curl) printf '%s\n' curl ;;
    pacman:adb) printf '%s\n' android-tools ;;
    pacman:qemu-x86_64) printf '%s\n' qemu-user ;;
    pacman:qemu-x86_64-static) printf '%s\n' qemu-user-static ;;
    *) return 1 ;;
  esac
}

run_privileged() {
  if (( EUID == 0 )); then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    return 1
  fi
}

install_packages() {
  local pm="$1"
  shift
  (( $# > 0 )) || return 0

  [[ "$auto_install_deps" == "1" ]] || return 1

  log "installing missing host tools with $pm: $*"
  case "$pm" in
    apt)
      run_privileged apt-get update
      run_privileged apt-get install -y "$@"
      ;;
    dnf)
      run_privileged dnf install -y "$@"
      ;;
    pacman)
      run_privileged pacman -Sy --needed --noconfirm "$@"
      ;;
    *)
      return 1
      ;;
  esac
}

install_missing_commands() {
  local -a missing=("$@")
  local pm
  pm="$(detect_package_manager)" || return 1

  local -A seen_packages=()
  local -a packages=()
  local cmd package

  for cmd in "${missing[@]}"; do
    package="$(package_for_command "$pm" "$cmd")" || continue
    if [[ -z "${seen_packages[$package]:-}" ]]; then
      packages+=("$package")
      seen_packages["$package"]=1
    fi
  done

  install_packages "$pm" "${packages[@]}"
}

ensure_downloader() {
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    return 0
  fi

  install_missing_commands curl || true

  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
    die "missing curl or wget; install one or set AUTO_INSTALL_DEPS=1 on a supported distro"
}

download_file() {
  local url="$1"
  local dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -L --fail -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url"
  else
    die "missing curl or wget"
  fi
}

ensure_host_commands() {
  local -a required=(git git-lfs python3 tar awk find readlink rsync install mktemp adb)
  local -a missing=()
  local cmd

  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if (( ${#missing[@]} > 0 )); then
    install_missing_commands "${missing[@]}" || true
  fi

  missing=()
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  (( ${#missing[@]} == 0 )) || \
    die "missing required host tools: ${missing[*]}"

  ensure_downloader
}

host_is_arm64() {
  case "$(uname -m)" in
    aarch64|arm64)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

reload_binfmt_misc() {
  if command -v systemctl >/dev/null 2>&1; then
    run_privileged systemctl restart systemd-binfmt.service >/dev/null 2>&1 || true
  fi
}

install_arm64_x86_64_emulation_packages() {
  local pm
  pm="$(detect_package_manager)" || return 1

  case "$pm" in
    dnf)
      install_packages "$pm" binfmt-dispatcher fex-emu fex-emu-rootfs-fedora muvm
      ;;
    apt)
      install_packages "$pm" qemu-user-static binfmt-support
      ;;
    pacman)
      install_packages "$pm" qemu-user-static
      ;;
    *)
      return 1
      ;;
  esac
}

arm64_x86_64_emulation_hint() {
  local pm="${1:-}"

  case "$pm" in
    dnf)
      printf '%s\n' "sudo dnf install -y fex-emu fex-emu-rootfs-fedora muvm"
      ;;
    apt)
      printf '%s\n' "sudo apt-get install -y qemu-user-static binfmt-support"
      ;;
    pacman)
      printf '%s\n' "sudo pacman -Sy --needed qemu-user-static"
      ;;
    *)
      printf '%s\n' "install FEX or qemu-user-static and enable binfmt_misc for x86-64 ELF files"
      ;;
  esac
}

ensure_arm64_host_x86_64_emulation() {
  host_is_arm64 || return 0

  local pm
  pm="$(detect_package_manager 2>/dev/null || true)"

  log "ARM64 build host detected; checking x86-64 host-tool emulation"
  if [[ "$pm" == "dnf" ]] && ! fedora_asahi_fex_ready; then
    if [[ "$auto_install_deps" == "1" ]]; then
      install_arm64_x86_64_emulation_packages || true
      reload_binfmt_misc
      reset_host_x86_64_elf_probe_cache
    fi

    if ! fedora_asahi_fex_ready; then
      local hint
      hint="$(arm64_x86_64_emulation_hint "$pm")"
      die "this ARM64 host is missing Fedora Asahi FEX support for x86-64 Android host prebuilts. Install it and rerun: $hint"
    fi
  fi

  local page_size
  page_size="$(host_page_size)"
  if [[ "$pm" == "dnf" && "$page_size" != "4096" && "$(command -v muvm 2>/dev/null || true)" != "" ]]; then
    log "muvm is available; ARM64 build will run in a 4 KiB-page guest"
    return 0
  fi

  if host_can_run_x86_64_elf; then
    log "x86-64 host-tool emulation is working"
    return 0
  fi

  if [[ "$auto_install_deps" == "1" ]]; then
    install_arm64_x86_64_emulation_packages || true
    reload_binfmt_misc
    reset_host_x86_64_elf_probe_cache
    if host_can_run_x86_64_elf; then
      log "x86-64 host-tool emulation is working"
      return 0
    fi
  fi

  local hint
  hint="$(arm64_x86_64_emulation_hint "$pm")"

  if [[ "$pm" == "dnf" && "$page_size" != "4096" ]]; then
    die "this ARM64 host cannot run x86-64 Android host prebuilts. Install Fedora Asahi FEX support and rerun: $hint"
  fi

  die "this ARM64 host cannot run x86-64 Android host prebuilts. $hint"
}

selinux_label_type() {
  local path="$1"
  [[ -e "$path" ]] || return 1

  ls -Zd "$path" 2>/dev/null | awk '{print $1}' | awk -F: '{print $3}'
}

regex_escape() {
  sed -e 's/[][\\.^$*+?{}|()]/\\&/g' <<<"$1"
}

ensure_selinux_fcontext() {
  local path="$1"
  local type="$2"
  local escaped regex

  command -v semanage >/dev/null 2>&1 || install_missing_commands semanage || true
  if command -v semanage >/dev/null 2>&1; then
    escaped="$(regex_escape "$path")"
    regex="${escaped}(/.*)?"
    run_privileged semanage fcontext -a -t "$type" "$regex" >/dev/null 2>&1 || \
      run_privileged semanage fcontext -m -t "$type" "$regex" >/dev/null 2>&1 || \
      die "failed to configure SELinux fcontext for $path"
  fi
}

ensure_workspace_selinux_contexts() {
  command -v getenforce >/dev/null 2>&1 || return 0
  [[ "$(getenforce 2>/dev/null || true)" != "Disabled" ]] || return 0

  local workspace_type="${SELINUX_WORKSPACE_TYPE:-src_t}"
  [[ -n "$workspace_type" && "$workspace_type" != "none" ]] || return 0
  local -a relabel_paths=()
  local current_type

  current_type="$(selinux_label_type "$ika_root" || true)"
  if [[ "$current_type" != "$workspace_type" ]]; then
    relabel_paths+=("$ika_root")
  fi

  current_type="$(selinux_label_type "$workspace" || true)"
  if [[ -e "$workspace" && "$workspace" != "$ika_root" &&
      "$current_type" != "$workspace_type" ]]; then
    relabel_paths+=("$workspace")
  fi
  (( ${#relabel_paths[@]} > 0 )) || return 0

  log "repairing SELinux labels for workspace access ($workspace_type)"
  local path
  for path in "${relabel_paths[@]}"; do
    ensure_selinux_fcontext "$path" "$workspace_type"
  done
  if command -v semanage >/dev/null 2>&1; then
    command -v restorecon >/dev/null 2>&1 || install_missing_commands restorecon || true
    command -v restorecon >/dev/null 2>&1 || \
      die "SELinux fcontext configured for ${relabel_paths[*]}, but restorecon is missing"
    run_privileged restorecon -R "${relabel_paths[@]}" || \
      die "failed to restore SELinux labels; run: sudo restorecon -R ${relabel_paths[*]}"
  else
    run_privileged chcon -R -t "$workspace_type" "${relabel_paths[@]}" || \
      die "failed to set SELinux labels; run: sudo chcon -R -t $workspace_type ${relabel_paths[*]}"
  fi
}

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
    '(^|[^[:alpha:]])killed([^[:alpha:]]|$)|cannot allocate memory|out of memory|std::bad_alloc|resource temporarily unavailable|failed to create new os thread|fatal error: runtime: out of memory' \
    "$log_file"; then
    return 0
  fi

  if grep -Eq 'FAILED: out/soong/build\..*\.ninja|soong bootstrap failed with: exit status 1' "$log_file" && \
      ! grep -Eqi '(^|[^[:alpha:]])error:' "$log_file"; then
    return 0
  fi

  return 1
}

temp_zram_device=""

ensure_temp_zram_commands() {
  local -a required=(modprobe mkswap swapoff swapon zramctl)
  local -a missing=()
  local cmd

  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if (( ${#missing[@]} > 0 )); then
    install_missing_commands "${missing[@]}" || true
  fi

  missing=()
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  (( ${#missing[@]} == 0 )) || \
    die "missing required zram tools: ${missing[*]}"
}

format_kib_as_gib() {
  local kib="$1"
  awk -v kib="$kib" 'BEGIN { printf "%.1f GiB", kib / 1024 / 1024 }'
}

swap_priority_for_device() {
  local dev="$1"
  awk -v dev="$dev" 'NR > 1 && $1 == dev { print $5; found=1; exit } END { if (!found) print "" }' \
    /proc/swaps 2>/dev/null || true
}

max_swap_priority() {
  awk '
    NR > 1 && $5 ~ /^-?[0-9]+$/ {
      if (!found || $5 > max) {
        max=$5
        found=1
      }
    }
    END {
      if (found) print max
      else print -2
    }
  ' /proc/swaps 2>/dev/null || printf '%s\n' -2
}

max_non_zram_swap_priority() {
  awk '
    NR > 1 && $1 !~ /^\/dev\/zram[0-9]+$/ && $5 ~ /^-?[0-9]+$/ {
      if (!found || $5 > max) {
        max=$5
        found=1
      }
    }
    END {
      if (found) print max
      else print -2
    }
  ' /proc/swaps 2>/dev/null || printf '%s\n' -2
}

next_swap_priority() {
  local max priority
  max="$(max_swap_priority)"
  [[ "$max" =~ ^-?[0-9]+$ ]] || max=-2
  priority=$((max + 1))
  (( priority < 100 )) && priority=100
  (( priority > 32767 )) && priority=32767
  printf '%s\n' "$priority"
}

zram_device_size_kib() {
  local dev="$1"
  local base="${dev##*/}"
  local disksize="/sys/block/$base/disksize"
  local bytes

  [[ -r "$disksize" ]] || return 1
  bytes="$(<"$disksize")"
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' $(((bytes + 1023) / 1024))
}

adequate_zram_swap_device() {
  local target_kib="$1"
  local non_zram_max dev priority size_kib

  non_zram_max="$(max_non_zram_swap_priority)"
  [[ "$non_zram_max" =~ ^-?[0-9]+$ ]] || non_zram_max=-2

  while read -r dev; do
    [[ -n "$dev" ]] || continue
    priority="$(swap_priority_for_device "$dev")"
    size_kib="$(zram_device_size_kib "$dev" || true)"
    [[ "$priority" =~ ^-?[0-9]+$ && "$size_kib" =~ ^[0-9]+$ ]] || continue
    if (( size_kib >= target_kib && priority > non_zram_max )); then
      printf '%s\n' "$dev"
      return 0
    fi
  done < <(awk 'NR > 1 && $1 ~ /^\/dev\/zram[0-9]+$/ { print $1 }' /proc/swaps 2>/dev/null || true)

  return 1
}

setup_temp_zram_if_needed() {
  local mem_kib max_zram_kib zram_kib zram_size dev existing_zram zram_priority

  mem_kib="$(physical_memory_total_kib)"
  if [[ ! "$mem_kib" =~ ^[0-9]+$ || "$mem_kib" -le 0 ]]; then
    log "could not determine host RAM; skipping temporary zram setup"
    return 0
  fi

  max_zram_kib=$((32 * 1024 * 1024))
  zram_kib=$((mem_kib * 2))
  (( zram_kib > max_zram_kib )) && zram_kib="$max_zram_kib"

  existing_zram="$(adequate_zram_swap_device "$zram_kib" || true)"
  if [[ -n "$existing_zram" ]]; then
    log "existing zram swap $existing_zram already matches build sizing and priority"
    return 0
  fi

  ensure_temp_zram_commands

  # Load zram if it is not already available. zramctl will allocate a free
  # device below, so this does not touch any existing system zram swap.
  if [[ ! -e /sys/class/zram-control && ! -d /sys/block/zram0 ]]; then
    run_privileged modprobe zram || \
      die "failed to load zram kernel module"
  fi

  zram_size="${zram_kib}K"
  zram_priority="$(next_swap_priority)"
  dev="$(run_privileged zramctl --find --size "$zram_size")" || \
    die "failed to create temporary zram device"
  temp_zram_device="$dev"

  run_privileged mkswap "$temp_zram_device" >/dev/null || \
    die "failed to initialize temporary zram swap at $temp_zram_device"
  run_privileged swapon --priority "$zram_priority" "$temp_zram_device" || \
    die "failed to enable temporary zram swap at $temp_zram_device"

  log "created temporary zram swap $temp_zram_device ($(format_kib_as_gib "$zram_kib"), twice host RAM capped at 32 GiB, priority $zram_priority)"
}

cleanup_temp_zram() {
  [[ -n "$temp_zram_device" ]] || return 0

  log "removing temporary zram swap $temp_zram_device"
  run_privileged swapoff "$temp_zram_device" >/dev/null 2>&1 || true
  run_privileged zramctl --reset "$temp_zram_device" >/dev/null 2>&1 || true
  temp_zram_device=""
}

validate_zip_file() {
  local zip_file="$1"

  python3 - "$zip_file" <<'PY'
from pathlib import Path
import sys
import zipfile

path = Path(sys.argv[1])
try:
    with zipfile.ZipFile(path) as archive:
        bad_member = archive.testzip()
except zipfile.BadZipFile as exc:
    raise SystemExit(f"{path}: {exc}")

if bad_member:
    raise SystemExit(f"{path}: corrupt zip member {bad_member}")
PY
}

desktop_launcher_target_files_exclusive() {
  local target_files_zip="$1"
  [[ -f "$target_files_zip" && -s "$target_files_zip" ]] || return 1

  python3 - "$target_files_zip" <<'PY'
import sys
import zipfile

target_files = sys.argv[1]
required = "SYSTEM_EXT/priv-app/Launcher3QuickStep/Launcher3QuickStep.apk"
stale_prefixes = (
    "SYSTEM_EXT/priv-app/Launcher3/",
    "SYSTEM_EXT/priv-app/Launcher3Go/",
    "SYSTEM_EXT/priv-app/Launcher3QuickStepGo/",
    "SYSTEM_OTHER/system_ext/priv-app/Launcher3/",
    "SYSTEM_OTHER/system_ext/priv-app/Launcher3Go/",
    "SYSTEM_OTHER/system_ext/priv-app/Launcher3QuickStepGo/",
)
stale_product_overlays = (
    "PRODUCT/overlay/Launcher3__",
    "PRODUCT/overlay/Launcher3Go__",
    "PRODUCT/overlay/Launcher3QuickStepGo__",
)

try:
    with zipfile.ZipFile(target_files) as archive:
        names = set(archive.namelist())
except zipfile.BadZipFile:
    raise SystemExit(1)

if required not in names:
    raise SystemExit(1)

for name in names:
    if any(name.startswith(prefix) for prefix in stale_prefixes):
        raise SystemExit(1)
    if any(name.startswith(prefix) for prefix in stale_product_overlays):
        raise SystemExit(1)
PY
}

ensure_repo_command() {
  local found_repo
  if found_repo="$(command -v repo 2>/dev/null)"; then
    repo_cmd="$found_repo"
    return 0
  fi

  ensure_downloader

  local tmp_repo
  tmp_repo="$(mktemp)"
  log "repo is not installed; downloading from $repo_tool_url"
  download_file "$repo_tool_url" "$tmp_repo"

  log "installing repo to $repo_install_path"
  if ! run_privileged install -m 0755 "$tmp_repo" "$repo_install_path"; then
    rm -f "$tmp_repo"
    die "failed to install repo to $repo_install_path"
  fi
  rm -f "$tmp_repo"

  if found_repo="$(command -v repo 2>/dev/null)"; then
    repo_cmd="$found_repo"
  elif [[ -x "$repo_install_path" ]]; then
    repo_cmd="$repo_install_path"
  else
    die "repo was installed but is not executable at $repo_install_path"
  fi
}

ensure_anonymous_git_config() {
  mkdir -p "${anonymous_git_config%/*}"
  cat > "$anonymous_git_config" <<'EOF'
[color]
	ui = auto
[user]
	name = LineageOS Desktop Builder
	email = builder@localhost
[url "https://github.com/"]
	insteadOf = git@github.com:
	insteadOf = ssh://git@github.com/
	insteadOf = ssh://git@github.com:22/
	insteadOf = git://github.com/
EOF
}

run_anonymous_git_network() {
  XDG_CONFIG_HOME="$anonymous_git_config_home" \
    REPO_CONFIG_DIR="$anonymous_git_config_home" \
    GIT_CONFIG_GLOBAL="$anonymous_git_config" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    GCM_INTERACTIVE=never \
    GIT_ASKPASS=/bin/false \
    SSH_ASKPASS=/bin/false \
    GIT_SSH_COMMAND="ssh -o BatchMode=yes" \
    "$@"
}

canonical_workspace_path() {
  mkdir -p "$workspace"
  (cd "$workspace" && pwd -P)
}

cleanup_workspace_path_metadata() {
  local current marker previous
  current="$(canonical_workspace_path)"
  marker="$workspace/.lineage-desktop-workspace-path"
  previous=""

  if [[ -f "$marker" ]]; then
    previous="$(<"$marker")"
  fi

  if [[ -n "$previous" && "$previous" != "$current" ]]; then
    log "workspace moved from $previous to $current; removing stale generated path metadata"
    rm -rf "$workspace/out/soong"
    if [[ -d "$workspace/.repo" ]]; then
      find "$workspace/.repo" -type f -name FETCH_HEAD -delete 2>/dev/null || true
      find "$workspace/.repo" -type d -name logs -prune -exec rm -rf {} + 2>/dev/null || true
    fi
  fi

  printf '%s\n' "$current" > "$marker"
}

normalize_targets() {
  if (( $# == 0 )); then
    printf '%s\n' arm64 x86_64
    return
  fi

  local target
  for target in "$@"; do
    case "$target" in
      all)
        printf '%s\n' arm64 x86_64
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

install_manifest() {
  local manifest_src="$overlay_dir/manifests/lineageos-desktop.xml"
  local manifest_dest="$workspace/.repo/local_manifests/lineageos-desktop.xml"

  mkdir -p "$workspace/.repo/local_manifests"

  if [[ -f "$manifest_src" ]]; then
    install -m 0644 "$manifest_src" "$manifest_dest"
  else
    download_file "$manifest_url" "$manifest_dest"
  fi

  local microg_manifest_src="$overlay_dir/manifests/lineageos4microg.xml"
  local microg_manifest_dest="$workspace/.repo/local_manifests/lineageos4microg.xml"

  if enabled "$include_microg"; then
    [[ -f "$microg_manifest_src" ]] || die "missing microG manifest: $microg_manifest_src"
    install -m 0644 "$microg_manifest_src" "$microg_manifest_dest"
  else
    rm -f "$microg_manifest_dest"
  fi
}

should_reset_patched_projects() {
  case "$reset_patched_projects" in
    1|true|yes)
      return 0
      ;;
    0|false|no)
      return 1
      ;;
    auto)
      if enabled "$resume_build"; then
        return 1
      fi
      [[ -f "$workspace/.lineage-desktop-managed" ]]
      ;;
    *)
      die "invalid RESET_PATCHED_PROJECTS=$reset_patched_projects; use auto, 1, or 0"
      ;;
  esac
}

reset_generated_overlay_project_for_sync() {
  local project_dir="$workspace/vendor/ika"
  [[ -d "$project_dir/.git" ]] || return 0
  [[ -f "$workspace/.lineage-desktop-managed" ]] || return 0

  local project_real overlay_real
  project_real="$(cd "$project_dir" && pwd -P)"
  overlay_real="$(cd "$overlay_dir" && pwd -P)"
  case "$overlay_real" in
    "$project_real"|"$project_real"/*)
      return 0
      ;;
  esac

  safe_reset_project "$project_dir" "vendor/ika"
}

project_has_local_work() {
  local project_dir="$1"
  # The build script's reset path is meant to undo source-patches and prebuilt
  # drops so the next `repo sync` is clean. Untracked files are expected here
  # (microG APKs, native-bridge prebuilts, generated docs) so we DON'T block
  # on them. The only thing we must not silently discard is local *commits*
  # that aren't reachable from the upstream ref or from a stash.
  local upstream
  upstream="$(git -C "$project_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    local ahead
    ahead="$(git -C "$project_dir" rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)"
    [[ "$ahead" != "0" ]] && return 0
  fi
  return 1
}

safe_reset_project() {
  local project_dir="$1"
  local label="$2"
  if project_has_local_work "$project_dir"; then
    if [[ "${RESET_PATCHED_PROJECTS_FORCE:-0}" == "1" ]]; then
      log "warning: $label has local work; resetting anyway because RESET_PATCHED_PROJECTS_FORCE=1"
    else
      die "$label has unpushed commits or untracked files; refusing to reset. Push/stash your work, or set RESET_PATCHED_PROJECTS_FORCE=1 to override."
    fi
  fi
  log "resetting patched project before sync: $label"
  git -C "$project_dir" reset --hard HEAD
  git -C "$project_dir" clean -fd
}

is_source_root_patch_project() {
  [[ "$1" == "." ]]
}

source_root_patch_paths() {
  local patch_file="$1"
  awk '
    /^diff --git / {
      for (i = 3; i <= 4; i++) {
        path = $i
        sub(/^[ab]\//, "", path)
        if (path != "/dev/null") {
          print path
        }
      }
    }
  ' "$patch_file" | sort -u
}

project_dir_for_source_root_patch_path() {
  local path="$1"
  local dir

  [[ -n "$path" && "$path" != /* ]] || return 1

  dir="$workspace/$path"
  [[ -d "$dir" ]] || dir="$(dirname "$dir")"

  while [[ "$dir" != "$workspace" && "$dir" == "$workspace"* ]]; do
    if [[ -d "$dir/.git" || -f "$dir/.git" || -L "$dir/.git" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

reset_projects_touched_by_source_root_patch() {
  local patch_file="$1"
  local path project_dir label
  declare -A seen_project_dirs=()

  [[ -f "$patch_file" ]] || return 0

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    project_dir="$(project_dir_for_source_root_patch_path "$path" || true)"
    [[ -n "$project_dir" && -z "${seen_project_dirs[$project_dir]:-}" ]] || continue
    seen_project_dirs[$project_dir]=1
    label="${project_dir#$workspace/}"
    safe_reset_project "$project_dir" "$label"
  done < <(source_root_patch_paths "$patch_file")
}

reset_patched_projects_for_sync() {
  local series_file="$overlay_dir/patches/series"
  [[ -f "$series_file" ]] || return 0
  should_reset_patched_projects || return 0

  if [[ -d "$workspace/vendor/ika/.git" ]]; then
    local vendor_ika_real overlay_real
    vendor_ika_real="$(cd "$workspace/vendor/ika" && pwd -P)"
    overlay_real="$(cd "$overlay_dir" && pwd -P)"
    case "$overlay_real" in
      "$vendor_ika_real"|"$vendor_ika_real"/*)
        log "skipping reset of vendor/ika because it is the local overlay repository"
        ;;
      *)
        safe_reset_project "$workspace/vendor/ika" "vendor/ika"
        ;;
    esac
  fi

  if enabled "$include_microg" && [[ -d "$workspace/vendor/partner_gms/.git" ]]; then
    safe_reset_project "$workspace/vendor/partner_gms" "vendor/partner_gms"
  fi

  local line project patch extra project_dir patch_file
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    [[ "${line:0:1}" == "#" ]] && continue

    read -r project patch extra <<<"$line"
    [[ -n "${project:-}" && -z "${extra:-}" ]] || continue

    patch_file="$overlay_dir/$patch"
    if is_source_root_patch_project "$project"; then
      reset_projects_touched_by_source_root_patch "$patch_file"
      continue
    fi

    project_dir="$workspace/$project"
    [[ -d "$project_dir/.git" ]] || continue

    safe_reset_project "$project_dir" "$project"
  done < "$series_file"
}

repair_incomplete_repo_git_stores() {
  [[ -d "$workspace/.repo" ]] || return 0

  local -a roots=()
  [[ -d "$workspace/.repo/projects" ]] && roots+=("$workspace/.repo/projects")
  [[ -d "$workspace/.repo/project-objects" ]] && roots+=("$workspace/.repo/project-objects")
  (( ${#roots[@]} > 0 )) || return 0

  local -a broken=()
  local gitdir
  while IFS= read -r -d '' gitdir; do
    if [[ ! -f "$gitdir/HEAD" || ! -e "$gitdir/objects" ]]; then
      broken+=("$gitdir")
    fi
  done < <(find "${roots[@]}" -type d -name '*.git' -print0)

  (( ${#broken[@]} > 0 )) || return 0

  log "removing ${#broken[@]} incomplete repo git store(s) left by an interrupted sync"
  for gitdir in "${broken[@]}"; do
    log "removing ${gitdir#$workspace/}"
    rm -rf -- "$gitdir"
  done
}

repair_stale_repo_git_locks() {
  [[ -d "$workspace/.repo" ]] || return 0

  local -a roots=()
  [[ -d "$workspace/.repo/projects" ]] && roots+=("$workspace/.repo/projects")
  [[ -d "$workspace/.repo/project-objects" ]] && roots+=("$workspace/.repo/project-objects")
  (( ${#roots[@]} > 0 )) || return 0

  local -a locks=()
  local lock
  while IFS= read -r -d '' lock; do
    locks+=("$lock")
  done < <(find "${roots[@]}" -type f -name '*.lock' -print0)

  (( ${#locks[@]} > 0 )) || return 0

  log "removing ${#locks[@]} stale repo git lock file(s) left by an interrupted sync"
  for lock in "${locks[@]}"; do
    log "removing ${lock#$workspace/}"
    rm -f -- "$lock"
  done
}

repo_sync_sources() {
  mkdir -p "$workspace"
  if [[ "$workspace_defaulted" -eq 1 ]]; then
    touch "$workspace/.lineage-desktop-managed"
  fi

  cd "$workspace"

  log "initializing LineageOS source at $workspace"
  run_anonymous_git_network "$repo_cmd" init -u "$android_manifest_url" -b "$lineage_branch"

  install_manifest
  reset_generated_overlay_project_for_sync
  reset_patched_projects_for_sync
  repair_incomplete_repo_git_stores
  repair_stale_repo_git_locks

  [[ "$repo_sync_attempts" =~ ^[0-9]+$ && "$repo_sync_attempts" -gt 0 ]] ||
    die "REPO_SYNC_ATTEMPTS must be a positive integer"
  [[ "$repo_sync_retry_fetches" =~ ^[0-9]+$ ]] ||
    die "REPO_SYNC_RETRY_FETCHES must be a non-negative integer"

  local quiet="$repo_sync_quiet"
  if [[ -z "$quiet" ]]; then
    if host_is_arm64; then
      quiet=1
    else
      quiet=0
    fi
  fi

  local -a sync_args=(sync -c --fail-fast -j"$jobs")
  if (( repo_sync_retry_fetches > 0 )); then
    sync_args+=(--retry-fetches="$repo_sync_retry_fetches")
  fi
  if enabled "$quiet"; then
    sync_args+=(--quiet)
  fi

  local attempt=1
  while :; do
    log "syncing source tree (attempt $attempt/$repo_sync_attempts)"
    if run_anonymous_git_network "$repo_cmd" "${sync_args[@]}"; then
      return 0
    fi

    if (( attempt >= repo_sync_attempts )); then
      return 1
    fi

    repair_incomplete_repo_git_stores
    repair_stale_repo_git_locks
    attempt=$((attempt + 1))
    log "repo sync failed; retrying in 10 seconds"
    sleep 10
  done
}

sync_webview_lfs_prebuilts() {
  local sync_script="$overlay_dir/scripts/sync_webview_lfs_prebuilts.sh"
  [[ -x "$sync_script" ]] || die "missing WebView LFS sync script: $sync_script"
  run_anonymous_git_network "$sync_script" "$workspace" all
}

repair_webview_intermediates() {
  local apk="$workspace/out/soong/.intermediates/external/chromium-webview/webview/android_common/dex-uncompressed/webview.apk"
  [[ -f "$apk" ]] || return 0

  if validate_zip_file "$apk" >/dev/null 2>&1; then
    return 0
  fi

  log "removing corrupt WebView build intermediates"
  rm -rf "$workspace/out/soong/.intermediates/external/chromium-webview/webview"
  find "$workspace/out/target/product" -path '*/obj/APPS/webview_intermediates' -type d -prune -exec rm -rf {} + 2>/dev/null || true
}

apply_local_overlay() {
  local dest="$workspace/vendor/lineage_desktop"

  if [[ -L "$dest" ]]; then
    dest="$(readlink -f "$dest")"
  elif [[ -d "$workspace/vendor/ika" && ! -e "$dest" ]]; then
    dest="$workspace/vendor/ika/lineageos"
    mkdir -p "$workspace/vendor"
    ln -sfn ika/lineageos "$workspace/vendor/lineage_desktop"
  fi

  mkdir -p "$dest"

  local src_real dest_real
  src_real="$(cd "$overlay_dir" && pwd -P)"
  dest_real="$(cd "$dest" && pwd -P)"

  if [[ "$src_real" == "$dest_real" ]]; then
    log "overlay is already present at vendor/lineage_desktop"
    return
  fi

  need_cmd rsync
  log "applying local overlay from $overlay_dir"
  rsync -a --delete \
    --exclude='.git' \
    --exclude='out' \
    --exclude='src' \
    --exclude='prebuilts/native_bridge/Android.bp' \
    --exclude='prebuilts/native_bridge/manifest.json' \
    --exclude='prebuilts/native_bridge/system' \
    "$overlay_dir"/ "$dest"/
}

local_overlay_dest_path() {
  local dest="$workspace/vendor/lineage_desktop"

  if [[ -L "$dest" ]]; then
    readlink -f "$dest"
  elif [[ -d "$workspace/vendor/ika" && ! -e "$dest" ]]; then
    printf '%s\n' "$workspace/vendor/ika/lineageos"
  else
    printf '%s\n' "$dest"
  fi
}

local_overlay_rsync_differs() {
  local dest="$1"
  local changes

  command -v rsync >/dev/null 2>&1 || return 0
  [[ -d "$dest" ]] || return 0

  changes="$(
    rsync -ain --delete \
      --exclude='.git' \
      --exclude='out' \
      --exclude='src' \
      --exclude='prebuilts/native_bridge/Android.bp' \
      --exclude='prebuilts/native_bridge/manifest.json' \
      --exclude='prebuilts/native_bridge/system' \
      "$overlay_dir"/ "$dest"/
  )"
  [[ -n "$changes" ]]
}

ensure_vendor_ika_soong_pruning() {
  local marker="$workspace/vendor/ika/base/cvd/.find-ignore"

  [[ -d "$(dirname "$marker")" ]] || return 0

  log "ensuring vendored Cuttlefish host sources are hidden from Soong"
  printf '%s\n' "# Keep vendored Cuttlefish host sources out of Android module discovery." > "$marker"
}

apply_source_patches() {
  local apply_script="$workspace/vendor/lineage_desktop/scripts/apply_source_patches.sh"

  [[ -x "$apply_script" ]] || die "missing patch application script: $apply_script"

  log "applying source-level desktop patches"
  "$apply_script" "$workspace"
}

update_microg_prebuilts() {
  enabled "$include_microg" || return 0
  enabled "$update_microg_prebuilts" || return 0

  local update_script="$workspace/vendor/lineage_desktop/scripts/update_microg_prebuilts.py"
  [[ -x "$update_script" ]] || die "missing microG update script: $update_script"

  log "refreshing microG prebuilts"
  "$update_script" "$workspace"
}

targets_include_x86_64() {
  local target
  for target in "$@"; do
    [[ "$target" == "x86_64" ]] && return 0
  done
  return 1
}

update_native_bridge_prebuilts_for_targets() {
  enabled "$include_x86_arm_native_bridge" || return 0
  enabled "$update_native_bridge_prebuilts" || return 0
  targets_include_x86_64 "$@" || return 0

  local update_script="$workspace/vendor/lineage_desktop/scripts/update_native_bridge_prebuilts.py"
  [[ -x "$update_script" ]] || die "missing native bridge update script: $update_script"

  log "refreshing x86 ARM native bridge prebuilts"
  "$update_script" "$workspace"
}

ensure_arm64_go_prebuilt() {
  host_is_arm64 || return 0
  [[ -x "$workspace/prebuilts/go/linux-arm64/bin/go" ]] && return 0
  [[ -x "$workspace/prebuilts/go/linux-x86/bin/go" ]] || return 0

  local cache_dir tmp_dir dest_dir
  cache_dir="$workspace/out/lineage-desktop/go-prebuilts"
  dest_dir="$workspace/prebuilts/go/linux-arm64"

  mkdir -p "$cache_dir"
  tmp_dir="$(mktemp -d "$cache_dir/linux-arm64.XXXXXX")"
  log "cloning ARM64 Go prebuilt: $arm64_go_prebuilt_git_url ($arm64_go_prebuilt_git_ref)"
  git clone --depth=1 --branch "$arm64_go_prebuilt_git_ref" \
    "$arm64_go_prebuilt_git_url" "$tmp_dir"
  [[ -x "$tmp_dir/bin/go" && -f "$tmp_dir/pkg/linux_arm64/fmt.a" ]] || {
    rm -rf "$tmp_dir"
    die "ARM64 Go prebuilt is incomplete: $arm64_go_prebuilt_git_url@$arm64_go_prebuilt_git_ref"
  }

  rm -rf "$dest_dir.tmp" "$dest_dir"
  mkdir -p "${dest_dir%/*}"
  mv "$tmp_dir" "$dest_dir.tmp"
  mv "$dest_dir.tmp" "$dest_dir"

  log "installed ARM64 Go prebuilt at ${dest_dir#$workspace/}"
}

clang_payload_dir() {
  local dest="$1"
  find "$dest" -maxdepth 1 -mindepth 1 -type d -name 'clang-r*' \
    -exec test -x '{}/bin/clang' ';' -print 2>/dev/null | sort | tail -n 1
}

clang_payload_name_from_metadata() {
  local dest="$1"
  [[ -f "$dest/Android.bp" ]] || return 1
  sed -n 's/.*"\(clang-r[^"]*\)".*/\1/p' "$dest/Android.bp" | sort -V | tail -n 1
}

clang_release_version() {
  local clang_dir="$1"
  find "$clang_dir/lib/clang" -maxdepth 1 -mindepth 1 -type d \
    -printf '%f\n' 2>/dev/null | sort -V | tail -n 1
}

set_clang_version_vars() {
  local host_tag="$1"
  local clang_dir="$2"
  local prebuilt_version release_version

  prebuilt_version="${clang_dir##*/}"
  release_version="$(clang_release_version "$clang_dir")"
  [[ -n "$release_version" ]] || \
    die "failed to detect LLVM release version under ${clang_dir#$workspace/}"

  case "$host_tag" in
    linux-arm64)
      linux_arm64_llvm_prebuilts_version="$prebuilt_version"
      linux_arm64_llvm_release_version="$release_version"
      ;;
    linux-x86)
      linux_x86_llvm_prebuilts_version="$prebuilt_version"
      linux_x86_llvm_release_version="$release_version"
      ;;
    *)
      die "internal error: unsupported Clang host tag $host_tag"
      ;;
  esac
}

clang_marker_file() {
  local dest="$1"
  printf '%s\n' "$dest/.lineage-desktop-clang-prebuilt"
}

clang_marker_value() {
  local marker="$1"
  local key="$2"
  sed -n "s/^$key=//p" "$marker" 2>/dev/null | tail -n 1
}

clang_cached_commit() {
  local dest="$1"
  local payload_name="$2"
  local git_url="$3"
  local git_ref="$4"
  local marker commit

  marker="$(clang_marker_file "$dest")"
  [[ -f "$marker" ]] || return 1
  [[ "$(clang_marker_value "$marker" url)" == "$git_url" ]] || return 1
  [[ "$(clang_marker_value "$marker" ref)" == "$git_ref" ]] || return 1
  [[ "$(clang_marker_value "$marker" payload)" == "$payload_name" ]] || return 1
  commit="$(clang_marker_value "$marker" commit)"
  [[ -n "$commit" ]] || return 1
  git -C "$dest" cat-file -e "$commit^{commit}" 2>/dev/null || return 1
  printf '%s\n' "$commit"
}

clang_exclude_payload() {
  local dest="$1"
  local payload_name="$2"
  local git_dir exclude_file pattern

  git_dir="$(git -C "$dest" rev-parse --git-dir 2>/dev/null)" || return 0
  [[ "$git_dir" = /* ]] || git_dir="$dest/$git_dir"
  exclude_file="$git_dir/info/exclude"
  mkdir -p "${exclude_file%/*}"
  touch "$exclude_file"
  for pattern in "/$payload_name/" "/$payload_name.tmp/" "/.lineage-desktop-clang-prebuilt"; do
    grep -qxF "$pattern" "$exclude_file" || printf '%s\n' "$pattern" >>"$exclude_file"
  done
}

clang_write_marker() {
  local dest="$1"
  local payload_name="$2"
  local commit="$3"
  local git_url="$4"
  local git_ref="$5"
  local marker

  marker="$(clang_marker_file "$dest")"
  cat >"$marker" <<EOF
url=$git_url
ref=$git_ref
payload=$payload_name
commit=$commit
EOF
}

clang_payload_name_from_ref() {
  local dest="$1"
  local ref="$2"

  git -C "$dest" ls-tree --name-only "$ref" \
    | grep -E '^clang-r[[:alnum:]_.-]*$' \
    | sort \
    | tail -n 1 || true
}

extract_clang_payload_from_ref() {
  local dest="$1"
  local ref="$2"
  local payload_name="$3"

  rm -rf "$dest/$payload_name.tmp" "$dest/$payload_name"
  mkdir -p "$dest/$payload_name.tmp"
  git -C "$dest" archive "$ref" "$payload_name" \
    | tar -x -C "$dest/$payload_name.tmp" --strip-components=1
  mv "$dest/$payload_name.tmp" "$dest/$payload_name"
}

clone_clang_prebuilt_repo() {
  local host_tag="$1"
  local dest="$2"
  local git_url="$3"
  local git_ref="$4"
  local payload_name="${5:-}"
  local cache_dir tmp_dir clang_dir

  cache_dir="$workspace/out/lineage-desktop/clang-prebuilts"
  mkdir -p "$cache_dir"
  tmp_dir="$(mktemp -d "$cache_dir/$host_tag.XXXXXX")"
  log "cloning $host_tag Clang prebuilt: $git_url ($git_ref)"
  git clone --depth=1 --branch "$git_ref" "$git_url" "$tmp_dir"

  if [[ -n "$payload_name" ]]; then
    clang_dir="$tmp_dir/$payload_name"
  else
    clang_dir="$(clang_payload_dir "$tmp_dir")"
  fi
  [[ -n "$clang_dir" ]] || {
    rm -rf "$tmp_dir"
    die "$host_tag Clang prebuilt is incomplete: $git_url@$git_ref"
  }
  [[ -x "$clang_dir/bin/clang" ]] || {
    rm -rf "$tmp_dir"
    die "$host_tag Clang prebuilt branch is missing requested payload: $git_url@$git_ref:$payload_name"
  }

  rm -rf "$dest.tmp" "$dest"
  mkdir -p "${dest%/*}"
  mv "$tmp_dir" "$dest.tmp"
  mv "$dest.tmp" "$dest"
  printf '%s\n' "$dest/${clang_dir##*/}"
}

linux_arm64_clang_payload_dir() {
  clang_payload_dir "$workspace/prebuilts/clang/host/linux-arm64"
}

set_linux_arm64_clang_version_vars() {
  local clang_dir="$1"
  set_clang_version_vars linux-arm64 "$clang_dir"
}

ensure_linux_arm64_clang_prebuilt() {
  host_is_arm64 || return 0

  local dest="$workspace/prebuilts/clang/host/linux-arm64"
  local clang_dir

  if [[ -f "$dest/.lineage-desktop-clang-overlay" || -L "$dest" ]]; then
    rm -rf "$dest"
  fi

  if [[ -x "$dest/$linux_arm64_clang_prebuilt_version/bin/clang" ]]; then
    clang_dir="$dest/$linux_arm64_clang_prebuilt_version"
  fi
  if [[ -n "$clang_dir" ]]; then
    set_linux_arm64_clang_version_vars "$clang_dir"
    log "using ARM64 Clang prebuilt ${dest#$workspace/}/$linux_arm64_llvm_prebuilts_version"
    return 0
  fi

  clang_dir="$(clone_clang_prebuilt_repo linux-arm64 "$dest" \
    "$linux_arm64_clang_prebuilt_git_url" \
    "$linux_arm64_clang_prebuilt_git_ref" \
    "$linux_arm64_clang_prebuilt_version")"
  set_linux_arm64_clang_version_vars "$clang_dir"

  log "installed ARM64 Clang prebuilt at ${dest#$workspace/}/$linux_arm64_llvm_prebuilts_version"
}

linux_x86_clang_payload_dir() {
  clang_payload_dir "$workspace/prebuilts/clang/host/linux-x86"
}

linux_x86_clang_payload_name_from_metadata() {
  local dest="$1"
  clang_payload_name_from_metadata "$dest"
}

linux_x86_clang_marker_file() {
  local dest="$1"
  clang_marker_file "$dest"
}

linux_x86_clang_marker_value() {
  local marker="$1"
  local key="$2"
  clang_marker_value "$marker" "$key"
}

linux_x86_clang_cached_commit() {
  local dest="$1"
  local payload_name="$2"
  clang_cached_commit "$dest" "$payload_name" \
    "$linux_x86_clang_prebuilt_git_url" \
    "$linux_x86_clang_prebuilt_git_ref"
}

linux_x86_clang_exclude_payload() {
  local dest="$1"
  local payload_name="$2"
  clang_exclude_payload "$dest" "$payload_name"
}

linux_x86_clang_write_marker() {
  local dest="$1"
  local payload_name="$2"
  local commit="$3"
  clang_write_marker "$dest" "$payload_name" "$commit" \
    "$linux_x86_clang_prebuilt_git_url" \
    "$linux_x86_clang_prebuilt_git_ref"
}

set_linux_x86_clang_version_vars() {
  local clang_dir="$1"
  set_clang_version_vars linux-x86 "$clang_dir"
}

ensure_linux_x86_clang_soong_compat() {
  local clang_dir="$1"
  local lib_dir="$clang_dir/lib"

  if [[ ! -e "$lib_dir/libc++.so" ]]; then
    [[ -f "$lib_dir/x86_64-unknown-linux-gnu/libc++.so" ]] || \
      die "missing x86_64 glibc libc++ in ${clang_dir#$workspace/}"
    ln -s "x86_64-unknown-linux-gnu/libc++.so" "$lib_dir/libc++.so"
  fi
}

linux_x86_clang_soong_metadata_is_compatible() {
  local dest="$1"

  grep -Fq '../i386-unknown-linux-gnu' "$dest/soong/clangprebuilts.go" && \
    grep -Fq '../x86_64-unknown-linux-gnu' "$dest/soong/clangprebuilts.go"
}

sync_linux_x86_clang_soong_metadata() {
  local dest="$1"
  local ref="$2"

  mkdir -p "$dest/soong"
  git -C "$dest" show "$ref:Android.bp" >"$dest/Android.bp"
  git -C "$dest" show "$ref:soong/clangprebuilts.go" >"$dest/soong/clangprebuilts.go"
  if linux_x86_clang_soong_metadata_is_compatible "$dest"; then
    return 0
  fi

  die "x86 Clang metadata from $ref is incompatible with the pinned Clang prebuilt"
}

ensure_linux_x86_clang_prebuilt() {
  host_is_arm64 && return 0

  local dest="$workspace/prebuilts/clang/host/linux-x86"
  local clang_dir payload_name cached_commit fetched_commit

  if git -C "$dest" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    payload_name="$linux_x86_clang_prebuilt_version"
    [[ -n "$payload_name" ]] || \
      payload_name="$(linux_x86_clang_marker_value "$(linux_x86_clang_marker_file "$dest")" payload || true)"
    [[ -n "$payload_name" ]] || payload_name="$(linux_x86_clang_payload_name_from_metadata "$dest" || true)"
    if [[ -n "$payload_name" && -x "$dest/$payload_name/bin/clang" ]]; then
      cached_commit="$(linux_x86_clang_cached_commit "$dest" "$payload_name" || true)"
      if [[ -n "$cached_commit" ]] && git -C "$dest" cat-file -e "$cached_commit^{commit}" 2>/dev/null; then
        log "using cached x86 Clang prebuilt ${dest#$workspace/}/$payload_name"
        sync_linux_x86_clang_soong_metadata "$dest" "$cached_commit"
        linux_x86_clang_exclude_payload "$dest" "$payload_name"
        linux_x86_clang_write_marker "$dest" "$payload_name" "$cached_commit"
        clang_dir="$dest/$payload_name"
        set_linux_x86_clang_version_vars "$clang_dir"
        ensure_linux_x86_clang_soong_compat "$clang_dir"
        return 0
      fi
    fi

    log "syncing x86 Clang prebuilt: $linux_x86_clang_prebuilt_git_url ($linux_x86_clang_prebuilt_git_ref)"
    git -C "$dest" fetch --depth=1 "$linux_x86_clang_prebuilt_git_url" "$linux_x86_clang_prebuilt_git_ref"
    fetched_commit="$(git -C "$dest" rev-parse FETCH_HEAD)"
    if [[ -z "$payload_name" ]]; then
      payload_name="$(clang_payload_name_from_ref "$dest" FETCH_HEAD)"
    elif ! git -C "$dest" cat-file -e "FETCH_HEAD:$payload_name/bin/clang" 2>/dev/null; then
      die "x86 Clang prebuilt branch is missing requested payload: $linux_x86_clang_prebuilt_git_url@$linux_x86_clang_prebuilt_git_ref:$payload_name"
    fi
    [[ -n "$payload_name" ]] || \
      die "x86 Clang prebuilt branch has no clang-r* payload: $linux_x86_clang_prebuilt_git_url@$linux_x86_clang_prebuilt_git_ref"
    extract_clang_payload_from_ref "$dest" FETCH_HEAD "$payload_name"
    sync_linux_x86_clang_soong_metadata "$dest" FETCH_HEAD
    clang_dir="$dest/$payload_name"
  elif [[ ! -e "$dest" ]]; then
    clang_dir="$(clone_clang_prebuilt_repo linux-x86 "$dest" \
      "$linux_x86_clang_prebuilt_git_url" \
      "$linux_x86_clang_prebuilt_git_ref" \
      "$linux_x86_clang_prebuilt_version")"
    fetched_commit="$(git -C "$dest" rev-parse HEAD)"
    sync_linux_x86_clang_soong_metadata "$dest" HEAD
  else
    die "cannot install pinned x86 Clang prebuilt over existing non-git path: ${dest#$workspace/}"
  fi

  [[ -n "$clang_dir" ]] || \
    die "x86 Clang prebuilt is incomplete: $linux_x86_clang_prebuilt_git_url@$linux_x86_clang_prebuilt_git_ref"
  set_linux_x86_clang_version_vars "$clang_dir"
  ensure_linux_x86_clang_soong_compat "$clang_dir"
  if [[ -n "${fetched_commit:-}" ]]; then
    linux_x86_clang_exclude_payload "$dest" "$linux_x86_llvm_prebuilts_version"
    linux_x86_clang_write_marker "$dest" "$linux_x86_llvm_prebuilts_version" "$fetched_commit"
  fi

  log "using x86 Clang prebuilt ${dest#$workspace/}/$linux_x86_llvm_prebuilts_version"
}

ensure_linux_arm64_clang_soong_compat() {
  host_is_arm64 || return 0
  [[ -n "$linux_arm64_llvm_prebuilts_version" ]] || die "ARM64 Clang version has not been detected"

  local arm64_dir="$workspace/prebuilts/clang/host/linux-arm64/$linux_arm64_llvm_prebuilts_version"
  local compat_dir="$workspace/prebuilts/clang/host/linux-x86/$linux_arm64_llvm_prebuilts_version"
  local expected_target="../linux-arm64/$linux_arm64_llvm_prebuilts_version"
  local lib_dir="$arm64_dir/lib"

  [[ -x "$arm64_dir/bin/clang" ]] || \
    die "missing ARM64 Clang payload: ${arm64_dir#$workspace/}"

  mkdir -p "${compat_dir%/*}"
  if [[ -L "$compat_dir" ]]; then
    if [[ "$(readlink "$compat_dir")" != "$expected_target" ]]; then
      rm -f "$compat_dir"
    fi
  elif [[ -e "$compat_dir" ]]; then
    die "cannot create ARM64 Clang Soong compatibility link over existing path: ${compat_dir#$workspace/}"
  fi
  [[ -e "$compat_dir" ]] || ln -s "$expected_target" "$compat_dir"
  [[ -f "$compat_dir/include/c++/v1/string" ]] || \
    die "ARM64 Clang Soong compatibility path is missing libc++ headers: ${compat_dir#$workspace/}/include/c++/v1/string"
  [[ -f "$compat_dir/android_libc++/platform/aarch64/include/c++/v1/__config_site" ]] || \
    die "ARM64 Clang Soong compatibility path is missing Android libc++ headers: ${compat_dir#$workspace/}/android_libc++/platform/aarch64/include/c++/v1/__config_site"

  if [[ ! -e "$lib_dir/libc++.so" ]]; then
    [[ -f "$lib_dir/aarch64-unknown-linux-musl/libc++.so" ]] || \
      die "missing ARM64 libc++ in ${arm64_dir#$workspace/}"
    ln -s "aarch64-unknown-linux-musl/libc++.so" "$lib_dir/libc++.so"
  fi

  mkdir -p "$lib_dir/x86_64-unknown-linux-gnu"
  if [[ ! -e "$lib_dir/x86_64-unknown-linux-gnu/libc++.so" ]]; then
    [[ -f "$lib_dir/x86_64-unknown-linux-musl/libc++.so" ]] || \
      die "missing x86_64 musl libc++ in ${arm64_dir#$workspace/}"
    ln -s "../x86_64-unknown-linux-musl/libc++.so" \
      "$lib_dir/x86_64-unknown-linux-gnu/libc++.so"
  fi

  log "linked ARM64 Clang Soong compatibility path ${compat_dir#$workspace/} -> $expected_target"
}

ensure_arm64_native_cmake_prebuilt() {
  host_is_arm64 || return 0

  local dest="$workspace/prebuilts/cmake/linux-arm64"
  local cache_dir tmp_dir

  if [[ -L "$dest" ]]; then
    rm -f "$dest"
  fi

  if [[ -x "$dest/bin/cmake" ]]; then
    log "using ARM64 CMake prebuilt at ${dest#$workspace/}"
    return 0
  fi

  cache_dir="$workspace/out/lineage-desktop/cmake-prebuilts"
  mkdir -p "$cache_dir"
  tmp_dir="$(mktemp -d "$cache_dir/linux-arm64.XXXXXX")"
  log "cloning ARM64 CMake prebuilt: $arm64_cmake_prebuilt_git_url ($arm64_cmake_prebuilt_git_ref)"
  git clone --depth=1 --branch "$arm64_cmake_prebuilt_git_ref" \
    "$arm64_cmake_prebuilt_git_url" "$tmp_dir" || {
      rm -rf "$tmp_dir"
      log "warning: failed to clone ARM64 CMake prebuilt; falling back to x86-64 CMake under emulation"
      return 0
    }

  if [[ ! -x "$tmp_dir/bin/cmake" ]]; then
    rm -rf "$tmp_dir"
    log "warning: ARM64 CMake prebuilt is incomplete; falling back to x86-64 CMake under emulation"
    return 0
  fi

  rm -rf "$dest.tmp" "$dest"
  mkdir -p "${dest%/*}"
  mv "$tmp_dir" "$dest.tmp"
  mv "$dest.tmp" "$dest"

  log "installed ARM64 CMake prebuilt at ${dest#$workspace/}"
}

ensure_arm64_native_jdk21_prebuilt() {
  host_is_arm64 || return 0

  local dest="$workspace/prebuilts/jdk/jdk21/linux-arm64"
  local cache_dir archive tmp_dir extract_dir version

  if [[ -x "$dest/bin/javac" && -x "$dest/bin/jlink" && -f "$dest/jmods/java.base.jmod" ]]; then
    version="$("$dest/bin/jlink" --version 2>/dev/null || true)"
    if [[ "$version" == 21.* ]]; then
      log "using ARM64 JDK 21 prebuilt at ${dest#$workspace/} ($version)"
      return 0
    fi
    log "warning: ignoring ARM64 JDK prebuilt with unexpected jlink version '$version'"
  fi

  cache_dir="$workspace/out/lineage-desktop/jdk21-prebuilts"
  archive="$cache_dir/jdk21-linux-arm64.tar.gz"
  mkdir -p "$cache_dir"

  if [[ ! -s "$archive" ]]; then
    log "downloading ARM64 JDK 21 prebuilt: $arm64_jdk21_prebuilt_url"
    curl -fL --retry 5 --retry-delay 5 \
      "$arm64_jdk21_prebuilt_url" -o "$archive.tmp"
    mv "$archive.tmp" "$archive"
  fi

  tmp_dir="$(mktemp -d "$cache_dir/linux-arm64.XXXXXX")"
  extract_dir="$tmp_dir/extract"
  mkdir -p "$extract_dir"
  tar -xzf "$archive" -C "$extract_dir" --strip-components=1 || {
    rm -rf "$tmp_dir" "$archive"
    die "failed to extract ARM64 JDK 21 prebuilt archive"
  }

  [[ -x "$extract_dir/bin/javac" && -x "$extract_dir/bin/jlink" && -f "$extract_dir/jmods/java.base.jmod" ]] || {
    rm -rf "$tmp_dir" "$archive"
    die "ARM64 JDK 21 prebuilt archive is incomplete: $arm64_jdk21_prebuilt_url"
  }

  version="$("$extract_dir/bin/jlink" --version 2>/dev/null || true)"
  [[ "$version" == 21.* ]] || {
    rm -rf "$tmp_dir" "$archive"
    die "ARM64 JDK prebuilt has unexpected jlink version '$version'; expected 21.x"
  }

  rm -rf "$dest.tmp" "$dest"
  mkdir -p "${dest%/*}"
  touch "$extract_dir/.lineage-desktop-jdk-overlay"
  mv "$extract_dir" "$dest.tmp"
  mv "$dest.tmp" "$dest"
  rm -rf "$tmp_dir"

  log "installed ARM64 JDK 21 prebuilt at ${dest#$workspace/} ($version)"
}

ensure_arm64_prebuilt_link() {
  local dest="$1"
  local src="$2"

  host_is_arm64 || return 0
  [[ -e "$dest" ]] && return 0
  [[ -e "$src" ]] || die "missing source prebuilt for ARM64 host link: ${src#$workspace/}"

  mkdir -p "${dest%/*}"
  ln -sfn "$(basename "$src")" "$dest"
  log "linked ARM64 host prebuilt ${dest#$workspace/} -> $(basename "$src")"
}

ensure_optional_arm64_prebuilt_link() {
  local dest="$1"
  local src="$2"

  host_is_arm64 || return 0
  [[ -e "$src" ]] || return 0
  ensure_arm64_prebuilt_link "$dest" "$src"
}

ensure_arm64_clang_prebuilt_overlay() {
  host_is_arm64 || return 0

  local dest="$workspace/prebuilts/clang/host/linux-arm64"
  local src="$workspace/prebuilts/clang/host/linux-x86"
  [[ -d "$src" ]] || die "missing source prebuilt for ARM64 host clang overlay: ${src#$workspace/}"

  if [[ -f "$dest/.lineage-desktop-clang-overlay" ]]; then
    rm -rf "$dest"
  elif [[ -L "$dest" ]]; then
    rm -f "$dest"
  elif [[ -e "$dest" ]]; then
    return 0
  fi

  mkdir -p "$dest"
  touch "$dest/.lineage-desktop-clang-overlay"

  local entry item name base configured=0
  for entry in "$src"/*; do
    [[ -e "$entry" ]] || continue
    name="${entry##*/}"
    if [[ "$name" == clang-r* && -d "$entry/bin" ]]; then
      configured=1
      mkdir -p "$dest/$name/bin"

      for item in "$entry"/*; do
        base="${item##*/}"
        [[ "$base" == "bin" ]] && continue
        ln -s "../../linux-x86/$name/$base" "$dest/$name/$base"
      done

      for item in "$entry/bin"/*; do
        base="${item##*/}"
        ln -s "../../../linux-x86/$name/bin/$base" "$dest/$name/bin/$base"
      done

      rm -f "$dest/$name/bin/clang" "$dest/$name/bin/clang++"
      ln -s clang-real "$dest/$name/bin/clang"
      ln -s clang-real "$dest/$name/bin/clang++"
    else
      ln -s "../linux-x86/$name" "$dest/$name"
    fi
  done

  (( configured > 0 )) || die "failed to find clang-r* payloads under ${src#$workspace/}"
  log "created ARM64 clang prebuilt overlay at ${dest#$workspace/}"
}

detect_arm64_android_java_home() {
  if [[ -n "$arm64_android_java_home" ]]; then
    printf '%s\n' "$arm64_android_java_home"
    return 0
  fi

  if [[ -n "${OVERRIDE_ANDROID_JAVA_HOME:-}" ]]; then
    printf '%s\n' "$OVERRIDE_ANDROID_JAVA_HOME"
    return 0
  fi

  if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/javac" ]]; then
    printf '%s\n' "$JAVA_HOME"
    return 0
  fi

  local javac_path
  javac_path="$(command -v javac 2>/dev/null || true)"
  [[ -n "$javac_path" ]] || return 1
  javac_path="$(readlink -f "$javac_path")"
  printf '%s\n' "$(cd "$(dirname "$javac_path")/.." && pwd -P)"
}

arm64_android_java_home_for_build() {
  host_is_arm64 || return 1
  if [[ -x "$workspace/prebuilts/jdk/jdk21/linux-arm64/bin/javac" ]]; then
    return 1
  fi

  if ! command -v javac >/dev/null 2>&1 && [[ -z "$arm64_android_java_home" && -z "${OVERRIDE_ANDROID_JAVA_HOME:-}" ]]; then
    install_missing_commands javac || true
  fi

  detect_arm64_android_java_home || \
    die "ARM64 host needs JDK 21 because this branch lacks an ARM64 JDK prebuilt; set ARM64_JDK21_PREBUILT_URL or ARM64_ANDROID_JAVA_HOME"
}

raise_open_file_limit_for_muvm() {
  host_is_arm64 || return 0
  command -v prlimit >/dev/null 2>&1 || install_missing_commands prlimit || true
  command -v prlimit >/dev/null 2>&1 || {
    log "warning: prlimit not found; continuing with the current open-file limit"
    return 0
  }

  if run_privileged prlimit --pid "$$" --nofile=1048576:1048576 >/dev/null 2>&1; then
    log "raised host open-file limit for muvm"
  else
    log "warning: failed to raise host open-file limit for muvm; continuing"
  fi
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
  [[ -x "$workspace/prebuilts/go/linux-arm64/bin/go" ]] || \
    die "missing ARM64 Go prebuilt: prebuilts/go/linux-arm64"

  ensure_arm64_prebuilt_link \
    "$workspace/prebuilts/rust/linux-arm64" \
    "$workspace/prebuilts/rust/linux-x86"
  ensure_linux_arm64_clang_prebuilt
  ensure_linux_arm64_clang_soong_compat
  ensure_arm64_prebuilt_link \
    "$workspace/prebuilts/clang-tools/linux-arm64" \
    "$workspace/prebuilts/clang-tools/linux-x86"
  ensure_arm64_native_cmake_prebuilt
  ensure_arm64_native_jdk21_prebuilt

  local rel
  for rel in \
    prebuilts/asuite/acloud \
    prebuilts/asuite/aidegen \
    prebuilts/asuite/atest \
    prebuilts/clang/kernel \
    prebuilts/extract-tools \
    prebuilts/gcc \
    prebuilts/kernel-build-tools \
    prebuilts/misc \
    prebuilts/tools-lineage; do
    ensure_optional_arm64_prebuilt_link \
      "$workspace/$rel/linux-arm64" \
      "$workspace/$rel/linux-x86"
  done

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
    export ANDROID_RUST_X86_PROC_MACRO_FALLBACK=1
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
  sed -u \
    -e 's/ERROR init_or_kernel//g' \
    -e 's/\[missing newline\] //g' \
    -e 's/\[missing newline\]//g'
}

run_build_muvm() {
  local product="$1"
  shift

  local workspace_q product_q highmem_jobs_q thinlto_use_mlgo_q goals_q command
  local extra_exports="" value_q java_home
  local llvm_prebuilts_version llvm_release_version
  printf -v workspace_q '%q' "$workspace"
  printf -v product_q '%q' "$product"
  printf -v highmem_jobs_q '%q' "$arm64_ninja_highmem_jobs"
  printf -v thinlto_use_mlgo_q '%q' "$arm64_thinlto_use_mlgo"
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
  extra_exports+="$(active_llvm_export_lines)"

  ensure_linux_arm64_clang_soong_compat
  precompute_muvm_module_paths "$product"
  raise_open_file_limit_for_muvm

  local -a build_attempts=()
  mapfile -t build_attempts < <(arm64_build_attempts "$jobs" "$arm64_soong_gomemlimit")

  local attempt attempt_jobs attempt_jobs_q attempt_gomemlimit attempt_gomemlimit_q
  local attempt_gomaxprocs attempt_gomaxprocs_q
  local attempt_gomemlimit_label attempt_log status last_status=1
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
export ANDROID_BUILD_SERIAL_FINDER=1
export _SOONG_INTERNAL_NO_FINDER=1
export ANDROID_RUST_X86_PROC_MACRO_FALLBACK=1
export GOMEMLIMIT=$attempt_gomemlimit_q
export GOGC=$arm64_soong_gogc
export GOMAXPROCS=$attempt_gomaxprocs_q
export GODEBUG=$arm64_godebug
export GOTRACEBACK=all
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
    log "running $product build inside muvm (${arm64_muvm_mem_mib} MiB, $attempt_jobs jobs, $arm64_ninja_highmem_jobs high-memory job, Soong GOMEMLIMIT=$attempt_gomemlimit, GOMAXPROCS=$attempt_gomaxprocs, ThinLTO MLGO=$arm64_thinlto_use_mlgo)"
    set +e
    muvm --mem="$arm64_muvm_mem_mib" \
      -e ANDROID_BUILD_SERIAL_FINDER=1 \
      -e _SOONG_INTERNAL_NO_FINDER=1 \
      -e ANDROID_RUST_X86_PROC_MACRO_FALLBACK=1 \
      -e GOMEMLIMIT="$attempt_gomemlimit" \
      -e GOGC="$arm64_soong_gogc" \
      -e GOMAXPROCS="$attempt_gomaxprocs" \
      -e GODEBUG="$arm64_godebug" \
      -e GOTRACEBACK=all \
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

validate_build_inputs_for_targets() {
  enabled "$validate_build_inputs" || return 0

  local validate_script="$workspace/vendor/lineage_desktop/scripts/validate_build_inputs.sh"
  [[ -x "$validate_script" ]] || die "missing build input validator: $validate_script"

  log "validating build inputs"
  "$validate_script" "$workspace" "$@"
}

repair_soong_zero_byte_objects() {
  local intermediates="$workspace/out/soong/.intermediates"
  [[ -d "$intermediates" ]] || return 0

  local -a bad_key_outputs=()
  mapfile -t bad_key_outputs < <(
    find "$intermediates/device/google/cuttlefish/build" \
      -type f \
      -name 'cvd_avb_testkey_rsa*.pem' \
      -size 0 \
      -print 2>/dev/null || true
  )
  if (( ${#bad_key_outputs[@]} > 0 )); then
    log "removing ${#bad_key_outputs[@]} zero-size AVB key intermediate(s)"
    rm -f "${bad_key_outputs[@]}"
  fi

  local -a bad_objects
  mapfile -t bad_objects < <(find "$intermediates" -type f -name '*.o' -size 0 -print)
  (( ${#bad_objects[@]} == 0 )) && return 0

  local -A prune_dirs=()
  local obj module_dir
  for obj in "${bad_objects[@]}"; do
    module_dir="${obj%/obj/*}"
    [[ "$module_dir" == "$obj" || -z "$module_dir" || ! -d "$module_dir" ]] && continue
    prune_dirs["$module_dir"]=1
  done

  local dir
  for dir in "${!prune_dirs[@]}"; do
    log "removing stale Soong module output: $dir"
    rm -rf "$dir"
  done
}

remove_soong_graph_state() {
  local product="$1"
  local reason="$2"
  local out_soong="$workspace/out/soong"
  local prefix="build.${product}"

  [[ -d "$out_soong" ]] || return 0

  log "removing stale Soong graph state for $product: $reason"
  find "$out_soong" -maxdepth 1 -type f \( \
    -name "${prefix}.ninja" -o \
    -name "${prefix}.ninja.*" -o \
    -name "${prefix}.*.ninja" \
  \) -delete 2>/dev/null || true
}

repair_stale_soong_graph_state() {
  local product="$1"
  local out_soong="$workspace/out/soong"
  local prefix="build.${product}"
  local final_ninja="$out_soong/${prefix}.ninja"
  local globs="$final_ninja.globs"
  local globs_time="$final_ninja.globs_time"
  local -a graph_parts=()

  [[ -d "$out_soong" ]] || return 0

  mapfile -t graph_parts < <(
    find "$out_soong" -maxdepth 1 -type f \( \
      -name "${prefix}.ninja" -o \
      -name "${prefix}.ninja.*" -o \
      -name "${prefix}.*.ninja" \
    \) -print 2>/dev/null || true
  )

  if [[ -e "$globs" && ! -e "$globs_time" ]]; then
    remove_soong_graph_state "$product" "missing glob timestamp"
  elif [[ -f "$final_ninja" && -f "$globs_time" && "$globs_time" -nt "$final_ninja" ]]; then
    remove_soong_graph_state "$product" "interrupted graph regeneration"
  elif [[ -f "$final_ninja" && ! -s "$final_ninja" ]]; then
    remove_soong_graph_state "$product" "zero-size generated ninja"
  elif [[ ! -f "$final_ninja" && ${#graph_parts[@]} -gt 0 ]]; then
    remove_soong_graph_state "$product" "incomplete generated ninja"
  fi
}

repair_zero_size_host_outputs() {
  local host_out="$workspace/out/host"
  [[ -d "$host_out" ]] || return 0

  local -a bad_outputs=()
  local dir path
  for dir in "$host_out"/*; do
    [[ -d "$dir" ]] || continue
    for path in \
      "$dir"/bin/* \
      "$dir"/lib/*.so \
      "$dir"/lib64/*.so \
      "$dir"/etc/cvd_avb_testkey_rsa*.pem \
      "$dir"/cvd-host_package/bin/* \
      "$dir"/cvd-host_package/lib/*.so \
      "$dir"/cvd-host_package/lib64/*.so \
      "$dir"/cvd-host_package/etc/cvd_avb_testkey_rsa*.pem; do
      [[ -f "$path" && ! -s "$path" ]] || continue
      bad_outputs+=("$path")
    done
  done

  (( ${#bad_outputs[@]} == 0 )) && return 0

  log "removing ${#bad_outputs[@]} zero-size host output(s)"
  rm -f "${bad_outputs[@]}"
}

repair_zero_size_host_script_output() {
  local module_subdir="$1"
  local artifact="$2"
  local module_dir="$workspace/out/soong/.intermediates/$module_subdir"

  [[ -d "$module_dir" ]] || return 0

  local -a bad_outputs=()
  mapfile -t bad_outputs < <(
    find "$module_dir" -type f -name "$artifact" -size 0 -print 2>/dev/null || true
  )
  (( ${#bad_outputs[@]} == 0 )) && return 0

  log "removing stale zero-size host script output: $artifact"
  rm -rf "$module_dir"
}

is_elf_file() {
  local path="$1"
  local magic

  [[ -f "$path" ]] || return 1
  magic="$(od -An -N4 -tx1 "$path" 2>/dev/null | tr -d '[:space:]')"
  [[ "$magic" == "7f454c46" ]]
}

repair_corrupt_host_elf() {
  local artifact="$1"
  local module_subdir="$2"
  local intermediates="$workspace/out/soong/.intermediates"
  local host_out="$workspace/out/host"
  local module_dir="$intermediates/$module_subdir"

  [[ -d "$module_dir" || -d "$host_out" ]] || return 0

  local -a candidates=()
  if [[ -d "$module_dir" ]]; then
    mapfile -t candidates < <(find "$module_dir" -type f -name "$artifact" -print)
  fi
  if [[ -d "$host_out" ]]; then
    mapfile -t candidates < <(
      printf '%s\n' "${candidates[@]}"
      find "$host_out" -type f -name "$artifact" -print
    )
  fi

  local -a bad_candidates=()
  local candidate remove_module=0
  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate" ]] || continue
    if ! is_elf_file "$candidate"; then
      bad_candidates+=("$candidate")
      [[ "$candidate" == "$module_dir"/* ]] && remove_module=1
    fi
  done

  (( ${#bad_candidates[@]} > 0 )) || return 0

  log "removing corrupt host ELF output: $artifact"
  (( remove_module == 0 )) || rm -rf "$module_dir"
  for candidate in "${bad_candidates[@]}"; do
    [[ "$candidate" == "$host_out"/* && -e "$candidate" ]] || continue
    rm -f "$candidate"
  done
}

repair_corrupt_host_tools() {
  repair_zero_size_host_outputs
  repair_zero_size_host_script_output external/crosvm/cuttlefish/common_crosvm crosvm
  repair_zero_size_host_script_output device/google/cuttlefish_prebuilts/extract-ikconfig extract-ikconfig
  repair_zero_size_host_script_output device/google/cuttlefish_prebuilts/extract-vmlinux extract-vmlinux
  repair_corrupt_host_elf lpmake system/extras/partition_tools/lpmake
  repair_corrupt_host_elf fs_config build/make/tools/fs_config/fs_config
  repair_corrupt_host_elf care_map_generator bootable/recovery/update_verifier/care_map_generator
  repair_corrupt_host_elf liblp.so system/core/fs_mgr/liblp/liblp
  repair_corrupt_host_elf libcrypto_utils.so system/core/libcrypto_utils/libcrypto_utils
  repair_corrupt_host_elf libcrypto-host.so external/boringssl/libcrypto
  repair_corrupt_host_elf libsparse-host.so system/core/libsparse/libsparse
  repair_corrupt_host_elf libext4_utils.so system/extras/ext4_utils/libext4_utils
  repair_corrupt_host_elf libz-host.so external/zlib/libz
  repair_corrupt_host_elf libbase.so system/libbase/libbase
  repair_corrupt_host_elf liblog.so system/logging/liblog/liblog
  repair_corrupt_host_elf libcutils.so system/core/libcutils/libcutils
  repair_corrupt_host_elf libc++.so prebuilts/clang/host/linux-x86/libc++
}

repair_zero_size_fstab_outputs() {
  local product="$1"
  local product_out="$2"
  [[ -d "$product_out" ]] || return 0

  local -a bad_fstabs=()
  mapfile -t bad_fstabs < <(
    find "$product_out" \
      \( -path '*/vendor_ramdisk/first_stage_ramdisk/system/etc/fstab.cf.*' \
         -o -path '*/VENDOR_BOOT/RAMDISK/first_stage_ramdisk/system/etc/fstab.cf.*' \
      \) \
      -type f \
      -size 0 \
      -print 2>/dev/null || true
  )
  (( ${#bad_fstabs[@]} == 0 )) && return 0

  log "removing ${#bad_fstabs[@]} zero-size vendor-ramdisk fstab output(s)"
  rm -f "${bad_fstabs[@]}"
  rm -f "$product_out/vendor_boot.img"
  rm -f \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip" \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip.list" \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip.list.list"
  rm -rf "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files"
}

remove_stale_launcher3_outputs() {
  local product="$1"
  local product_out="$2"
  [[ -d "$product_out" ]] || return 0

  local -a stale_paths=(
    "$product_out/system_ext/priv-app/Launcher3"
    "$product_out/system_ext/priv-app/Launcher3Go"
    "$product_out/system_ext/priv-app/Launcher3QuickStepGo"
    "$product_out/system_other/system_ext/priv-app/Launcher3"
    "$product_out/system_other/system_ext/priv-app/Launcher3Go"
    "$product_out/system_other/system_ext/priv-app/Launcher3QuickStepGo"
    "$product_out/product/overlay/Launcher3__${product}__auto_generated_rro_product.apk"
    "$product_out/product/overlay/Launcher3Go__${product}__auto_generated_rro_product.apk"
    "$product_out/product/overlay/Launcher3QuickStepGo__${product}__auto_generated_rro_product.apk"
    "$product_out/dexpreopt_config/Launcher3_dexpreopt.config"
    "$product_out/dexpreopt_config/Launcher3Go_dexpreopt.config"
    "$product_out/dexpreopt_config/Launcher3QuickStepGo_dexpreopt.config"
  )
  local -a found=()
  local path

  for path in "${stale_paths[@]}"; do
    [[ -e "$path" ]] && found+=("$path")
  done

  (( ${#found[@]} == 0 )) && return 0

  log "removing stale non-QuickStep Launcher3 output(s)"
  rm -rf "${found[@]}"
  rm -f \
    "$product_out/system_ext.img" \
    "$product_out/super.img" \
    "$product_out/vbmeta.img" \
    "$product_out/vbmeta_system.img" \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip" \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip.list" \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip.list.list" \
    "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files-signed.zip"
  rm -rf "$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files"
  rm -rf "$product_out/obj/PACKAGING/signed_images"
}

desktop_launcher_outputs_exclusive() {
  local product_out="$1"
  local target_files_zip="$2"

  [[ -f "$product_out/system_ext/priv-app/Launcher3QuickStep/Launcher3QuickStep.apk" ]] || return 1
  [[ ! -e "$product_out/system_ext/priv-app/Launcher3/Launcher3.apk" ]] || return 1
  [[ ! -e "$product_out/system_ext/priv-app/Launcher3Go/Launcher3Go.apk" ]] || return 1
  [[ ! -e "$product_out/system_ext/priv-app/Launcher3QuickStepGo/Launcher3QuickStepGo.apk" ]] || return 1
  desktop_launcher_target_files_exclusive "$target_files_zip"
}

desktop_android_info_selects_tablet() {
  local android_info="$1"

  [[ -f "$android_info" ]] || return 1
  grep -Eq '^[[:space:]]*config=tablet[[:space:]]*$' "$android_info"
}

validate_fstab_file() {
  local path="$1"

  [[ -s "$path" ]] || die "missing or empty fstab: $path"
  grep -q '/data f2fs' "$path" || die "fstab does not mount /data as f2fs: $path"
  grep -q 'fileencryption=aes-256-xts:aes-256-hctr2' "$path" || \
    die "fstab does not use HCTR2 filename encryption: $path"
}

validate_cvd_target_fstabs() {
  local product_out="$1"

  validate_fstab_file "$product_out/vendor/etc/fstab.cf.f2fs.hctr2"
  validate_fstab_file \
    "$product_out/vendor_ramdisk/first_stage_ramdisk/system/etc/fstab.cf.f2fs.hctr2"
}

resume_enabled() {
  enabled "$resume_build" && ! enabled "$force_rebuild"
}

resume_signature_for_targets() {
  python3 - "$script_dir" "$overlay_dir" "$workspace" "$@" <<'PY'
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import sys

script_dir = Path(sys.argv[1])
overlay_dir = Path(sys.argv[2])
workspace = Path(sys.argv[3])
targets = sys.argv[4:]

digest = hashlib.sha256()

def add(label: str, value: str) -> None:
    digest.update(label.encode())
    digest.update(b"\0")
    digest.update(value.encode())
    digest.update(b"\0")

for name in (
    "ANDROID_MANIFEST_URL",
    "LINEAGE_BRANCH",
    "MANIFEST_URL",
    "INCLUDE_MICROG",
    "UPDATE_MICROG_PREBUILTS",
    "INCLUDE_X86_ARM_NATIVE_BRIDGE",
    "UPDATE_NATIVE_BRIDGE_PREBUILTS",
    "VALIDATE_BUILD_INPUTS",
    "RESET_PATCHED_PROJECTS",
    "CLANG_PREBUILT_GIT_REF",
    "ARM64_CLANG_PREBUILT_GIT_URL",
    "ARM64_CLANG_PREBUILT_GIT_REF",
    "X86_CLANG_PREBUILT_GIT_URL",
    "X86_CLANG_PREBUILT_GIT_REF",
    "NATIVE_BRIDGE_SOURCE_DIR",
    "NATIVE_BRIDGE_SDK_PACKAGE",
    "NATIVE_BRIDGE_SDK_PACKAGE_SHA1",
    "MICROG_GMSCORE_RELEASE",
    "MICROG_GSFPROXY_RELEASE",
    "MICROG_FDROID_RELEASE",
    "MICROG_FDROID_PRIVILEGED_RELEASE",
):
    add(name, os.environ.get(name, ""))

add("workspace", str(workspace))
add("targets", "\n".join(targets))

excluded_dirs = {".git", "out", "src", "__pycache__"}
excluded_prefixes = {
    Path("prebuilts/native_bridge/system"),
}

for root, dirs, files in os.walk(overlay_dir):
    root_path = Path(root)
    rel_root = root_path.relative_to(overlay_dir)
    dirs[:] = [
        d
        for d in sorted(dirs)
        if d not in excluded_dirs
        and not any((rel_root / d).is_relative_to(prefix) for prefix in excluded_prefixes)
    ]
    for filename in sorted(files):
        path = root_path / filename
        rel_path = path.relative_to(overlay_dir)
        if any(rel_path.is_relative_to(prefix) for prefix in excluded_prefixes):
            continue
        add("overlay-file", rel_path.as_posix())
        if path.is_symlink():
            add("overlay-symlink", os.readlink(path))
            continue
        if not path.is_file():
            continue
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)

for path in sorted(script_dir.glob("*.sh")):
    if not path.is_file():
        continue
    add("script-file", path.name)
    with path.open("rb") as handle:
        digest.update(handle.read())

print(digest.hexdigest())
PY
}

resume_signature=""

set_resume_signature() {
  resume_signature="$(resume_signature_for_targets "$@")"
}

resume_checkpoint_dir() {
  [[ -n "$resume_signature" ]] || die "resume signature has not been initialized"
  printf '%s\n' "$workspace/out/lineage_desktop_resume/$resume_signature"
}

resume_checkpoint_path() {
  local name="$1"
  printf '%s/%s.done\n' "$(resume_checkpoint_dir)" "$name"
}

resume_checkpoint_done() {
  local name="$1"
  resume_enabled || return 1
  [[ -f "$(resume_checkpoint_path "$name")" ]]
}

mark_resume_checkpoint() {
  local name="$1"
  local checkpoint_dir
  checkpoint_dir="$(resume_checkpoint_dir)"
  mkdir -p "$checkpoint_dir"
  printf '%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$(resume_checkpoint_path "$name")"
}

signing_inputs_signature() {
  local target_files_zip="$1"

  python3 - "$overlay_dir" "$ANDROID_CERTS_DIR" "$target_files_zip" "${STRICT_APEX_SIGNING:-1}" <<'PY'
from __future__ import annotations

import hashlib
from pathlib import Path
import sys

overlay_dir = Path(sys.argv[1])
cert_dir = Path(sys.argv[2])
target_files = Path(sys.argv[3])
strict_apex_signing = sys.argv[4]

digest = hashlib.sha256()

def add(label: str, value: str) -> None:
    digest.update(label.encode())
    digest.update(b"\0")
    digest.update(value.encode())
    digest.update(b"\0")

def add_file(label: str, path: Path) -> None:
    add(label, str(path))
    if not path.exists():
        add(label + "-missing", "1")
        return
    if path.is_symlink():
        add(label + "-symlink", path.readlink().as_posix())
        return
    if not path.is_file():
        add(label + "-non-file", "1")
        return
    stat = path.stat()
    add(label + "-size", str(stat.st_size))
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)

add("strict-apex-signing", strict_apex_signing)
add("android-certs-dir", str(cert_dir))

for rel in (
    "scripts/sign_target_files.sh",
    "scripts/signing_common.sh",
    "scripts/generate_signing_keys.sh",
    "patches/build-make-releasetools.patch",
    "patches/series",
):
    add_file("signing-input", overlay_dir / rel)

if target_files.exists():
    stat = target_files.stat()
    add("target-files", str(target_files))
    add("target-files-size", str(stat.st_size))
    add("target-files-mtime-ns", str(stat.st_mtime_ns))
else:
    add("target-files-missing", str(target_files))

if cert_dir.exists():
    for path in sorted(cert_dir.iterdir()):
        name = path.name
        if name.endswith(".pk8") or name.endswith(".pem"):
            add_file("signing-key", path)
else:
    add("android-certs-missing", str(cert_dir))

print(digest.hexdigest())
PY
}

signing_stamp_path() {
  local signed_images_dir="$1"
  printf '%s/.lineage_desktop_signing_inputs.sha256\n' "$signed_images_dir"
}

signing_outputs_current() {
  local signed_target_files_zip="$1"
  local signed_images_dir="$2"
  local target_files_zip="$3"
  local expected_signature="$4"
  local stamp

  [[ -n "$expected_signature" ]] || return 1
  [[ -f "$target_files_zip" ]] || return 1
  [[ -f "$signed_target_files_zip" && -d "$signed_images_dir" ]] || return 1
  [[ "$signed_target_files_zip" -nt "$target_files_zip" ]] || return 1
  [[ -f "$signed_images_dir/vbmeta.img" ]] || return 1
  [[ -f "$signed_images_dir/super.img" ]] || return 1
  [[ -f "$signed_images_dir/misc_info.txt" ]] || return 1
  desktop_launcher_target_files_exclusive "$signed_target_files_zip" || return 1

  stamp="$(signing_stamp_path "$signed_images_dir")"
  [[ -f "$stamp" ]] || return 1
  [[ "$(<"$stamp")" == "$expected_signature" ]]
}

write_signing_inputs_stamp() {
  local signed_images_dir="$1"
  local signature="$2"
  printf '%s\n' "$signature" > "$(signing_stamp_path "$signed_images_dir")"
}

bundle_images_current() {
  local bundle_dir="$1"
  local product_out="$2"
  local signed_images_dir="$3"
  shift 3

  local f src dest
  for f in "$@"; do
    dest="$bundle_dir/$f"
    [[ -f "$dest" ]] || return 1
    src="$signed_images_dir/$f"
    [[ -f "$src" ]] || src="$product_out/$f"
    [[ -f "$src" ]] || continue
    [[ ! "$src" -nt "$dest" ]] || return 1
  done
}

reset_closed_or_legacy_target_checkpoints() {
  local checkpoint_dir
  checkpoint_dir="$(resume_checkpoint_dir)"
  mkdir -p "$checkpoint_dir"

  if enabled "$force_rebuild"; then
    rm -f "$checkpoint_dir"/build-*.done "$checkpoint_dir"/sign-*.done \
      "$checkpoint_dir"/package-*.done \
      "$checkpoint_dir/complete.done" "$checkpoint_dir/run.started"
  elif [[ -f "$checkpoint_dir/complete.done" ]]; then
    log "resume: previous build/package checkpoint session completed; starting a fresh one"
    rm -f "$checkpoint_dir"/build-*.done "$checkpoint_dir"/sign-*.done \
      "$checkpoint_dir"/package-*.done \
      "$checkpoint_dir/complete.done" "$checkpoint_dir/run.started"
  elif [[ ! -f "$checkpoint_dir/run.started" ]]; then
    # Older checkpoint directories did not track session lifetime, so build and
    # package checkpoints from them may point at arbitrarily old product images.
    rm -f "$checkpoint_dir"/build-*.done "$checkpoint_dir"/sign-*.done \
      "$checkpoint_dir"/package-*.done
  fi

  [[ -f "$checkpoint_dir/run.started" ]] || \
    printf '%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$checkpoint_dir/run.started"
}

run_checkpointed_step() {
  local name="$1"
  local description="$2"
  shift 2
  local -a command=("$@")
  local -a validator_args=()

  if (( ${#command[@]} > 1 )); then
    validator_args=("${command[@]:1}")
  fi

  if resume_checkpoint_done "$name"; then
    if resume_checkpoint_still_valid "$name" "${validator_args[@]}"; then
      log "resume: skipping $description"
      return 0
    fi
    log "resume: checkpoint for $description is stale; rerunning"
  fi

  "${command[@]}"
  mark_resume_checkpoint "$name"
}

repo_sources_ready() {
  [[ -d "$workspace/.repo" ]] || return 1
  [[ -f "$workspace/.repo/local_manifests/lineageos-desktop.xml" ]] || return 1
  if enabled "$include_microg"; then
    [[ -f "$workspace/.repo/local_manifests/lineageos4microg.xml" ]] || return 1
  else
    [[ ! -e "$workspace/.repo/local_manifests/lineageos4microg.xml" ]] || return 1
  fi
}

webview_lfs_prebuilts_ready() {
  local -a webview_projects=(
    external/chromium-webview/prebuilt/arm
    external/chromium-webview/prebuilt/arm64
    external/chromium-webview/prebuilt/x86
    external/chromium-webview/prebuilt/x86_64
  )

  local project apk
  for project in "${webview_projects[@]}"; do
    apk="$workspace/$project/webview.apk"
    [[ -f "$apk" && -s "$apk" ]] || return 1
    if head -c 128 "$apk" | grep -q 'git-lfs.github.com/spec'; then
      return 1
    fi
    validate_zip_file "$apk" >/dev/null 2>&1 || return 1
  done
}

local_overlay_ready() {
  local dest
  dest="$(local_overlay_dest_path)"

  [[ -e "$workspace/vendor/lineage_desktop" ]] || return 1
  [[ -e "$workspace/vendor/lineage_desktop/scripts/apply_source_patches.sh" ]] || return 1
  [[ -e "$workspace/vendor/lineage_desktop/patches/series" ]] || return 1

  local src_real dest_real
  src_real="$(cd "$overlay_dir" && pwd -P)"
  dest_real="$(cd "$dest" && pwd -P)" || return 1
  [[ "$src_real" == "$dest_real" ]] && return 0

  ! local_overlay_rsync_differs "$dest"
}

vendor_ika_soong_pruning_ready() {
  local marker="$workspace/vendor/ika/base/cvd/.find-ignore"
  [[ -d "$(dirname "$marker")" ]] || return 0
  [[ -f "$marker" ]]
}

source_patches_applied() {
  local series_file="$workspace/vendor/lineage_desktop/patches/series"
  [[ -f "$series_file" ]] || return 1

  local line project patch extra project_dir patch_file
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    [[ "${line:0:1}" == "#" ]] && continue

    read -r project patch extra <<<"$line"
    [[ -n "${project:-}" && -n "${patch:-}" && -z "${extra:-}" ]] || return 1

    project_dir="$workspace/$project"
    patch_file="$workspace/vendor/lineage_desktop/$patch"
    if is_source_root_patch_project "$project"; then
      project_dir="$workspace"
      [[ -d "$project_dir" && -f "$patch_file" ]] || return 1
    else
      [[ -d "$project_dir/.git" && -f "$patch_file" ]] || return 1
    fi
    git -C "$project_dir" apply --reverse --check --whitespace=nowarn "$patch_file" >/dev/null 2>&1 || return 1
  done < "$series_file"
}

microg_prebuilts_ready() {
  enabled "$include_microg" || return 0

  local base="$workspace/vendor/partner_gms"
  local -a apks=(
    "$base/GmsCore/GmsCore.apk"
    "$base/GsfProxy/GsfProxy.apk"
    "$base/FakeStore/FakeStore.apk"
    "$base/FDroid/FDroid.apk"
    "$base/FDroidPrivilegedExtension/FDroidPrivilegedExtension.apk"
  )

  local apk
  for apk in "${apks[@]}"; do
    [[ -f "$apk" && -s "$apk" ]] || return 1
    validate_zip_file "$apk" >/dev/null 2>&1 || return 1
  done
}

native_bridge_prebuilts_ready_for_targets() {
  enabled "$include_x86_arm_native_bridge" || return 0
  targets_include_x86_64 "$@" || return 0

  local base="$workspace/vendor/lineage_desktop/prebuilts/native_bridge"
  local -a required=(
    Android.bp
    manifest.json
    system/bin/ndk_translation_program_runner_binfmt_misc_arm64
    system/etc/binfmt_misc/arm64_dyn
    system/etc/binfmt_misc/arm64_exe
    system/etc/init/ndk_translation.rc
    system/etc/ld.config.arm.txt
    system/etc/ld.config.arm64.txt
    system/lib64/libndk_translation.so
  )

  local f
  for f in "${required[@]}"; do
    [[ -f "$base/$f" && -s "$base/$f" ]] || return 1
  done
}

resume_checkpoint_still_valid() {
  local name="$1"
  shift

  case "$name" in
    repo-sync)
      repo_sources_ready
      ;;
    webview-lfs)
      webview_lfs_prebuilts_ready
      ;;
    local-overlay)
      local_overlay_ready
      ;;
    vendor-ika-soong-pruning)
      vendor_ika_soong_pruning_ready
      ;;
    source-patches)
      source_patches_applied
      ;;
    microg-prebuilts)
      microg_prebuilts_ready
      ;;
    native-bridge-prebuilts)
      native_bridge_prebuilts_ready_for_targets "$@"
      ;;
    build-input-validation|build-input-validation-*)
      validate_build_inputs_for_targets "$@"
      ;;
    *)
      return 0
      ;;
  esac
}

valid_targz_archive() {
  local path="$1"
  [[ -f "$path" && -s "$path" ]] || return 1
  tar -tzf "$path" >/dev/null 2>&1
}

critical_host_package_zero_entries() {
  local host_package="$1"

  tar -tzvf "$host_package" 2>/dev/null | awk '
    $1 ~ /^-/ && $3 == 0 {
      name = $6
      sub(/^\.\//, "", name)
      if (name == "bin/crosvm" ||
          name == "bin/extract-ikconfig" ||
          name == "bin/extract-vmlinux") {
        print name
      }
    }
  '
}

cvd_host_package_critical_tools_complete() {
  local host_package="$1"
  [[ -f "$host_package" && -s "$host_package" ]] || return 1

  local bad_entries
  bad_entries="$(critical_host_package_zero_entries "$host_package")" || return 1
  [[ -z "$bad_entries" ]]
}

repair_zero_size_cvd_host_package() {
  local host_package="$1"
  [[ -f "$host_package" ]] || return 0

  local bad_entries
  bad_entries="$(critical_host_package_zero_entries "$host_package")" || return 0
  [[ -n "$bad_entries" ]] || return 0

  log "removing Cuttlefish host package with zero-size critical tool(s): ${bad_entries//$'\n'/, }"
  rm -f "$host_package" "${host_package%.tar.gz}.stamp"
  rm -rf "${host_package%.tar.gz}"
}

valid_pem_private_key() {
  local path="$1"
  [[ -s "$path" ]] && grep -q 'BEGIN RSA PRIVATE KEY' "$path"
}

rom_avb_private_key() {
  local bits="$1"
  local key="$workspace/external/avb/test/data/testkey_rsa${bits}.pem"

  [[ -f "$key" ]] || die "missing ROM AVB test private key: $key"
  valid_pem_private_key "$key" || die "invalid ROM AVB test private key: $key"
  printf '%s\n' "$key"
}

repair_cvd_host_package_avb_keys() {
  local host_package="$1"
  local tmp_dir tmp_package bits src dest repaired=0

  valid_targz_archive "$host_package" || \
    die "invalid Cuttlefish host package: $host_package"

  tmp_dir="$(mktemp -d)"
  if ! tar -xzf "$host_package" -C "$tmp_dir"; then
    rm -rf "$tmp_dir"
    die "failed to extract Cuttlefish host package: $host_package"
  fi

  mkdir -p "$tmp_dir/etc"
  for bits in 2048 4096; do
    src="$(rom_avb_private_key "$bits")"
    dest="$tmp_dir/etc/cvd_avb_testkey_rsa${bits}.pem"
    if valid_pem_private_key "$dest"; then
      continue
    fi
    log "repairing $(basename "$host_package"): etc/cvd_avb_testkey_rsa${bits}.pem"
    install -m 0644 "$src" "$dest"
    repaired=1
  done

  if (( repaired )); then
    tmp_package="${host_package}.tmp"
    if ! tar -czf "$tmp_package" -C "$tmp_dir" .; then
      rm -rf "$tmp_dir"
      rm -f "$tmp_package"
      die "failed to rewrite Cuttlefish host package: $host_package"
    fi
    mv "$tmp_package" "$host_package"
  fi

  for bits in 2048 4096; do
    dest="$tmp_dir/etc/cvd_avb_testkey_rsa${bits}.pem"
    valid_pem_private_key "$dest" || {
      rm -rf "$tmp_dir"
      die "Cuttlefish host package still has an invalid AVB key: $host_package:etc/cvd_avb_testkey_rsa${bits}.pem"
    }
  done
  rm -rf "$tmp_dir"
}

valid_zip_container() {
  local path="$1"
  [[ -f "$path" && -s "$path" ]] || return 1
  python3 - "$path" <<'PY'
from pathlib import Path
import sys
import zipfile

path = Path(sys.argv[1])
try:
    with zipfile.ZipFile(path) as archive:
        if not archive.namelist():
            raise SystemExit(1)
except zipfile.BadZipFile:
    raise SystemExit(1)
PY
}

bundle_dir_complete() {
  local bundle_dir="$1"
  shift

  [[ -d "$bundle_dir" ]] || return 1

  local member
  for member in "build-info.json" "build-info.txt" "$@"; do
    [[ -e "$bundle_dir/$member" ]] || return 1
  done

  desktop_android_info_selects_tablet "$bundle_dir/android-info.txt"
}

built_target_outputs_complete() {
  local product="$1"
  local product_out="$2"
  local host_package="$3"
  shift 3

  [[ -d "$product_out" ]] || return 1
  valid_targz_archive "$host_package" || return 1
  cvd_host_package_critical_tools_complete "$host_package" || return 1

  local target_files="$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip"
  valid_zip_container "$target_files" || return 1
  desktop_launcher_outputs_exclusive "$product_out" "$target_files" || return 1
  desktop_android_info_selects_tablet "$product_out/android-info.txt" || return 1

  local f
  for f in "$@"; do
    [[ -f "$product_out/$f" && -s "$product_out/$f" ]] || return 1
  done
}

remove_packaged_target_outputs() {
  local product="$1"
  local product_out="$2"
  local host_package="$3"
  shift 3

  local target_files_dir="$product_out/obj/PACKAGING/target_files_intermediates"
  rm -f \
    "$host_package" \
    "$target_files_dir/${product}-target_files.zip" \
    "$target_files_dir/${product}-target_files.zip.list" \
    "$target_files_dir/${product}-target_files.zip.list.list" \
    "$target_files_dir/${product}-target_files-signed.zip"
  rm -rf "$target_files_dir/${product}-target_files"
  rm -rf "$product_out/obj/PACKAGING/signed_images"

  local f
  for f in "$@"; do
    rm -f "$product_out/$f"
  done
}

write_fetcher_config() {
  local bundle_dir="$1"
  shift

  local f first=1
  {
    printf '{\n  "cvd_files": {'
    for f in "$@"; do
      [[ -f "$bundle_dir/$f" ]] || continue
      if [[ "$first" -eq 0 ]]; then
        printf ','
      fi
      printf '\n    "%s": { "source": "local_file", "build_id": "", "build_target": "" }' "$f"
      first=0
    done
    printf '\n  }\n}\n'
  } > "$bundle_dir/fetcher_config.json"
}

write_release_metadata() {
  local bundle_dir="$1"
  local arch="$2"
  local product="$3"
  local product_out="$4"
  shift 4

  local metadata_script="$workspace/vendor/lineage_desktop/scripts/write_release_metadata.py"
  [[ -x "$metadata_script" ]] || die "missing release metadata writer: $metadata_script"

  local -a metadata_args=(
    --android-root "$workspace"
    --overlay-dir "$workspace/vendor/lineage_desktop"
    --product-out "$product_out"
    --bundle-dir "$bundle_dir"
    --arch "$arch"
    --product "$product"
    --lineage-branch "$lineage_branch"
  )

  local image
  for image in "$@"; do
    metadata_args+=(--image "$image")
  done

  "$metadata_script" "${metadata_args[@]}"
}

package_cvd_bundle() {
  local arch="$1"
  local product="$2"
  local product_out="$3"
  local host_package="$4"
  local signed_images_dir="$5"
  local bundle_name="$6"
  shift 6

  local bundle_dir="$output_dir/$bundle_name"
  local -a thin_files=("$@")

  [[ -d "$product_out" ]] || die "missing product output: $product_out"
  [[ -f "$host_package" ]] || die "missing Cuttlefish host package: $host_package"

  log "packaging $bundle_name"
  rm -rf "$bundle_dir"
  mkdir -p "$bundle_dir"

  # For each bundle file prefer the release-key-signed image emitted into
  # $signed_images_dir by sign_target_files.sh. Files that aren't shipped
  # inside the target-files.zip IMAGES/ tree (kernel binaries, dtb.img,
  # vendor-bootconfig.img, android-info.txt, misc_info.txt, ...) fall back
  # to the original $product_out path so the bundle still includes them.
  local f src copied=0
  for f in "${thin_files[@]}"; do
    src="$signed_images_dir/$f"
    if [[ "$f" == "super.img" && -f "$signed_images_dir/vbmeta.img" && ! -f "$src" ]]; then
      die "signed vbmeta exists but signed super.img is missing in $signed_images_dir"
    fi
    [[ -f "$src" ]] || src="$product_out/$f"
    if [[ -f "$src" ]]; then
      install -m 0644 "$src" "$bundle_dir/$f"
      copied=$((copied + 1))
    fi
  done

  (( copied > 0 )) || die "no image files were copied from $product_out"
  desktop_android_info_selects_tablet "$bundle_dir/android-info.txt" || \
    die "$bundle_name/android-info.txt does not select config=tablet"

  tar -xzf "$host_package" -C "$bundle_dir" --exclude='bin' --exclude='lib64'

  # assemble_cvd requires every etc/cvd_config/*.json preset it might select
  # (via --config=... or via android-info.txt) to be a JSON object; it aborts
  # on the first preset that is empty, unparseable, or non-object. Upstream's
  # cvd-host_package.tar.gz ships several of these as zero-byte stubs.
  # Normalize anything that is not a valid object to {} so the launcher
  # treats it as "no overrides", and log each replacement so future bundle
  # issues surface in the build log instead of going silently.
  if [[ -d "$bundle_dir/etc/cvd_config" ]]; then
    local normalize_status=0
    STRICT_BUNDLE_VALIDATION="$strict_bundle_validation" \
      python3 - "$bundle_dir/etc/cvd_config" <<'PY' || normalize_status=$?
import json, os, pathlib, sys
cfg_dir = pathlib.Path(sys.argv[1])
strict = os.environ.get("STRICT_BUNDLE_VALIDATION", "0") == "1"
rewritten = []
for p in sorted(cfg_dir.glob("*.json")):
    try:
        ok = isinstance(json.loads(p.read_text(encoding="utf-8")), dict)
    except (json.JSONDecodeError, OSError, UnicodeDecodeError):
        ok = False
    if ok:
        continue
    p.write_text("{}\n", encoding="utf-8")
    rewritten.append(p.name)
    print(f"[lineage-desktop] normalized cvd_config preset to {{}}: {p.name}",
          file=sys.stderr)
if rewritten and strict:
    print(
        "[lineage-desktop] STRICT_BUNDLE_VALIDATION=1: refusing to ship a bundle "
        f"with {len(rewritten)} corrupt cvd_config preset(s): "
        + ", ".join(rewritten),
        file=sys.stderr,
    )
    sys.exit(1)
PY
    if (( normalize_status != 0 )); then
      die "etc/cvd_config normalization failed in strict mode for $bundle_name"
    fi
  fi
  write_fetcher_config "$bundle_dir" "${thin_files[@]}"
  write_release_metadata "$bundle_dir" "$arch" "$product" "$product_out" "${thin_files[@]}"

  du -sh "$bundle_dir"
}

host_output_tag() {
  if host_is_arm64; then
    printf '%s\n' linux-arm64
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s\n' darwin-x86
  else
    printf '%s\n' linux-x86
  fi
}

target_product() {
  case "$1" in
    arm64) printf '%s\n' lineage_desktop_cf_arm64_pgagnostic ;;
    x86_64) printf '%s\n' lineage_desktop_cf_x86_64 ;;
    *) die "internal error: unsupported target $1" ;;
  esac
}

target_product_out() {
  case "$1" in
    arm64) printf '%s\n' "$workspace/out/target/product/vsoc_arm64_pgagnostic" ;;
    x86_64) printf '%s\n' "$workspace/out/target/product/vsoc_x86_64_sandybridge" ;;
    *) die "internal error: unsupported target $1" ;;
  esac
}

target_bundle_name() {
  case "$1" in
    arm64) printf '%s\n' lineageos-arm64 ;;
    x86_64) printf '%s\n' lineageos-x86_64 ;;
    *) die "internal error: unsupported target $1" ;;
  esac
}

target_thin_files() {
  case "$1" in
    arm64)
      printf '%s\n' \
        android-info.txt \
        misc_info.txt \
        super.img \
        boot.img \
        boot_16k.img \
        init_boot.img \
        vendor_boot.img \
        vbmeta.img \
        vbmeta_system.img \
        vbmeta_vendor_dlkm.img \
        vbmeta_system_dlkm.img \
        userdata.img \
        kernel_16k \
        ramdisk_16k.img \
        dtb.img \
        vendor-bootconfig.img
      ;;
    x86_64)
      printf '%s\n' \
        android-info.txt \
        misc_info.txt \
        super.img \
        boot.img \
        init_boot.img \
        vendor_boot.img \
        vbmeta.img \
        vbmeta_system.img \
        vbmeta_vendor_dlkm.img \
        vbmeta_system_dlkm.img \
        userdata.img \
        kernel \
        ramdisk.img \
        vendor-bootconfig.img
      ;;
    *)
      die "internal error: unsupported target $1"
      ;;
  esac
}

build_target() {
  local arch="$1"
  local product product_out host_package bundle_name host_tag
  local -a thin_files

  host_tag="$(host_output_tag)"
  product="$(target_product "$arch")"
  product_out="$(target_product_out "$arch")"
  host_package="$workspace/out/host/$host_tag/cvd-host_package.tar.gz"
  bundle_name="$(target_bundle_name "$arch")"
  mapfile -t thin_files < <(target_thin_files "$arch")

  cd "$workspace"
  log "building $product"
  repair_soong_zero_byte_objects
  repair_stale_soong_graph_state "$product"
  repair_corrupt_host_tools
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
  local signed_target_files_zip="${target_files_zip%.zip}-signed.zip"
  local signed_images_dir="$product_out/obj/PACKAGING/signed_images"
  local signing_signature=""
  if [[ -f "$target_files_zip" ]]; then
    signing_signature="$(signing_inputs_signature "$target_files_zip")"
  fi

  if resume_checkpoint_done "package-$arch" && \
      signing_outputs_current "$signed_target_files_zip" "$signed_images_dir" "$target_files_zip" "$signing_signature" && \
      bundle_images_current "$output_dir/$bundle_name" "$product_out" "$signed_images_dir" "${thin_files[@]}" && \
      bundle_dir_complete "$output_dir/$bundle_name" "${thin_files[@]}"; then
    log "resume: skipping $product; $bundle_name/ is already complete"
    return 0
  fi

  if resume_checkpoint_done "build-$arch" && \
      built_target_outputs_complete "$product" "$product_out" "$host_package" "${thin_files[@]}"; then
    log "resume: using existing build outputs for $product"
  else
    remove_packaged_target_outputs "$product" "$product_out" "$host_package" "${thin_files[@]}"

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
      otatools \
      -j"$jobs"
    built_target_outputs_complete "$product" "$product_out" "$host_package" "${thin_files[@]}" || \
      die "build completed but expected outputs are missing for $product"
    desktop_launcher_outputs_exclusive "$product_out" "$target_files_zip" || \
      die "$product target-files still include non-QuickStep Launcher3 artifacts"
    validate_cvd_target_fstabs "$product_out"
    mark_resume_checkpoint "build-$arch"
  fi

  validate_cvd_target_fstabs "$product_out"
  desktop_launcher_outputs_exclusive "$product_out" "$target_files_zip" || \
    die "$product target-files still include non-QuickStep Launcher3 artifacts"
  repair_cvd_host_package_avb_keys "$host_package"

  signing_signature="$(signing_inputs_signature "$target_files_zip")"

  if resume_checkpoint_done "sign-$arch" \
      && signing_outputs_current "$signed_target_files_zip" "$signed_images_dir" "$target_files_zip" "$signing_signature"; then
    log "resume: using existing signed target-files for $product"
  else
    log "signing $product target-files"
    "$script_dir/sign_target_files.sh" \
      "$target_files_zip" \
      "$signed_target_files_zip" \
      "$signed_images_dir"
    write_signing_inputs_stamp "$signed_images_dir" "$signing_signature"
    mark_resume_checkpoint "sign-$arch"
  fi

  package_cvd_bundle "$arch" "$product" "$product_out" "$host_package" "$signed_images_dir" "$bundle_name" "${thin_files[@]}"
  bundle_dir_complete "$output_dir/$bundle_name" "${thin_files[@]}" || \
    die "packaging completed but $bundle_name/ is incomplete"
  mark_resume_checkpoint "package-$arch"
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
  ensure_arm64_host_x86_64_emulation
  ensure_signing_keys
  setup_temp_zram_if_needed
  set_build_jobs
  configure_arm64_job_limits
  log "using $jobs parallel build jobs ($highmem_jobs high-memory jobs)"
  ensure_repo_command
  ensure_anonymous_git_config
  cleanup_workspace_path_metadata
  ensure_workspace_selinux_contexts

  local -a targets
  mapfile -t targets < <(normalize_targets "$@")
  set_resume_signature "${targets[@]}"
  reset_closed_or_legacy_target_checkpoints

  mkdir -p "$output_dir"
  run_checkpointed_step repo-sync "source sync" repo_sync_sources
  run_checkpointed_step webview-lfs "WebView LFS sync" sync_webview_lfs_prebuilts
  repair_webview_intermediates
  run_checkpointed_step local-overlay "local overlay application" apply_local_overlay
  run_checkpointed_step vendor-ika-soong-pruning "vendored Cuttlefish Soong pruning" ensure_vendor_ika_soong_pruning
  ensure_linux_x86_clang_prebuilt
  run_checkpointed_step source-patches "source patches" apply_source_patches
  run_checkpointed_step microg-prebuilts "microG prebuilt refresh" update_microg_prebuilts
  configure_arm64_host_build

  local target
  for target in "${targets[@]}"; do
    if [[ "$target" == "x86_64" ]]; then
      run_checkpointed_step native-bridge-prebuilts \
        "x86-64 native bridge prebuilt refresh" \
        update_native_bridge_prebuilts_for_targets x86_64
    fi
    run_checkpointed_step "build-input-validation-$target" \
      "build input validation for $target" \
      validate_build_inputs_for_targets "$target"
    record_buildtime_start "$target"
    build_target "$target"
    record_buildtime_finish success
  done

  mark_resume_checkpoint complete

  log "done"
  log "output directory: $output_dir"
  for target in "${targets[@]}"; do
    log "  -> $output_dir/$(target_bundle_name "$target")/"
  done
}

main "$@"
