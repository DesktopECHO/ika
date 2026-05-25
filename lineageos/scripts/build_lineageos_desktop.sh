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
repo_tool_url="${REPO_TOOL_URL:-https://storage.googleapis.com/git-repo-downloads/repo}"
repo_install_path="${REPO_INSTALL_PATH:-/usr/local/bin/repo}"
repo_cmd="repo"
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
  JOBS                  Parallel jobs for repo sync and m. Default: reserve
                        4 GiB RAM, then one job per 3.5 GiB physical+virtual
                        RAM, capped at available logical CPU count.
  NINJA_HIGHMEM_NUM_JOBS
                        Soong high-memory pool jobs. Default: same 4 GiB RAM
                        reserve, then one job per 16 GiB physical+virtual RAM,
                        capped by JOBS.
  Temporary zram       Hosts with less than 48 GiB RAM get a build-scoped zram
                        swap device sized to 75% of physical RAM. It is removed
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
  AUTO_INSTALL_DEPS     Install missing basic host tools with apt/dnf/pacman
                        when possible. Default: 1
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
    apt:install|apt:mktemp|apt:readlink) printf '%s\n' coreutils ;;
    apt:modprobe) printf '%s\n' kmod ;;
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
    dnf:install|dnf:mktemp|dnf:readlink) printf '%s\n' coreutils ;;
    dnf:modprobe) printf '%s\n' kmod ;;
    dnf:mkswap|dnf:swapoff|dnf:swapon|dnf:zramctl) printf '%s\n' util-linux ;;
    dnf:python3) printf '%s\n' python3 ;;
    dnf:rsync) printf '%s\n' rsync ;;
    dnf:tar) printf '%s\n' tar ;;
    dnf:curl) printf '%s\n' curl ;;
    dnf:adb) printf '%s\n' android-tools ;;
    pacman:awk) printf '%s\n' gawk ;;
    pacman:find) printf '%s\n' findutils ;;
    pacman:git) printf '%s\n' git ;;
    pacman:git-lfs) printf '%s\n' git-lfs ;;
    pacman:install|pacman:mktemp|pacman:readlink) printf '%s\n' coreutils ;;
    pacman:modprobe) printf '%s\n' kmod ;;
    pacman:mkswap|pacman:swapoff|pacman:swapon|pacman:zramctl) printf '%s\n' util-linux ;;
    pacman:python3) printf '%s\n' python ;;
    pacman:rsync) printf '%s\n' rsync ;;
    pacman:tar) printf '%s\n' tar ;;
    pacman:curl) printf '%s\n' curl ;;
    pacman:adb) printf '%s\n' android-tools ;;
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

setup_temp_zram_if_needed() {
  local mem_kib threshold_kib zram_kib zram_size dev

  mem_kib="$(physical_memory_total_kib)"
  if [[ ! "$mem_kib" =~ ^[0-9]+$ || "$mem_kib" -le 0 ]]; then
    log "could not determine host RAM; skipping temporary zram setup"
    return 0
  fi

  threshold_kib=$((48 * 1024 * 1024))
  if (( mem_kib >= threshold_kib )); then
    log "host RAM is $(format_kib_as_gib "$mem_kib"); temporary zram not needed"
    return 0
  fi

  ensure_temp_zram_commands

  # Load zram if it is not already available. zramctl will allocate a free
  # device below, so this does not touch any existing system zram swap.
  if [[ ! -e /sys/class/zram-control && ! -d /sys/block/zram0 ]]; then
    run_privileged modprobe zram || \
      die "failed to load zram kernel module"
  fi

  zram_kib=$((mem_kib * 3 / 4))
  zram_size="${zram_kib}K"
  dev="$(run_privileged zramctl --find --size "$zram_size")" || \
    die "failed to create temporary zram device"
  temp_zram_device="$dev"

  run_privileged mkswap "$temp_zram_device" >/dev/null || \
    die "failed to initialize temporary zram swap at $temp_zram_device"
  run_privileged swapon "$temp_zram_device" || \
    die "failed to enable temporary zram swap at $temp_zram_device"

  log "created temporary zram swap $temp_zram_device ($(format_kib_as_gib "$zram_kib"), 75% of host RAM)"
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
      [[ -f "$workspace/.lineage-desktop-managed" ]]
      ;;
    *)
      die "invalid RESET_PATCHED_PROJECTS=$reset_patched_projects; use auto, 1, or 0"
      ;;
  esac
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

reset_patched_projects_for_sync() {
  local series_file="$overlay_dir/patches/series"
  [[ -f "$series_file" ]] || return 0
  should_reset_patched_projects || return 0

  if [[ -d "$workspace/vendor/ika/.git" ]]; then
    safe_reset_project "$workspace/vendor/ika" "vendor/ika"
  fi

  if enabled "$include_microg" && [[ -d "$workspace/vendor/partner_gms/.git" ]]; then
    safe_reset_project "$workspace/vendor/partner_gms" "vendor/partner_gms"
  fi

  local line project patch extra project_dir
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    [[ "${line:0:1}" == "#" ]] && continue

    read -r project patch extra <<<"$line"
    [[ -n "${project:-}" && -z "${extra:-}" ]] || continue

    project_dir="$workspace/$project"
    [[ -d "$project_dir/.git" ]] || continue

    safe_reset_project "$project_dir" "$project"
  done < "$series_file"
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
  reset_patched_projects_for_sync

  log "syncing source tree"
  run_anonymous_git_network "$repo_cmd" sync -c --fail-fast -j"$jobs"
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
  [[ -e "$workspace/vendor/lineage_desktop/scripts/apply_source_patches.sh" ]] || return 1
  [[ -e "$workspace/vendor/lineage_desktop/patches/series" ]] || return 1
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
    [[ -d "$project_dir/.git" && -f "$patch_file" ]] || return 1
    git -C "$project_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1 || return 1
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
    build-input-validation)
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

build_target() {
  local arch="$1"
  local product product_out host_package bundle_name
  local -a thin_files

  case "$arch" in
    arm64)
      product="lineage_desktop_cf_arm64_pgagnostic"
      product_out="$workspace/out/target/product/vsoc_arm64_pgagnostic"
      host_package="$workspace/out/host/linux_musl-arm64/cvd-host_package.tar.gz"
      bundle_name="lineageos-arm64"
      thin_files=(
        android-info.txt
        misc_info.txt
        super.img
        boot.img
        boot_16k.img
        init_boot.img
        vendor_boot.img
        vbmeta.img
        vbmeta_system.img
        vbmeta_vendor_dlkm.img
        vbmeta_system_dlkm.img
        userdata.img
        kernel_16k
        ramdisk_16k.img
        dtb.img
        vendor-bootconfig.img
      )
      ;;
    x86_64)
      product="lineage_desktop_cf_x86_64"
      product_out="$workspace/out/target/product/vsoc_x86_64_sandybridge"
      host_package="$workspace/out/host/linux-x86/cvd-host_package.tar.gz"
      bundle_name="lineageos-x86_64"
      thin_files=(
        android-info.txt
        misc_info.txt
        super.img
        boot.img
        init_boot.img
        vendor_boot.img
        vbmeta.img
        vbmeta_system.img
        vbmeta_vendor_dlkm.img
        vbmeta_system_dlkm.img
        userdata.img
        kernel
        ramdisk.img
        vendor-bootconfig.img
      )
      ;;
    *)
      die "internal error: unsupported arch $arch"
      ;;
  esac

  cd "$workspace"
  log "building $product"
  repair_soong_zero_byte_objects
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

    set +u
    source build/envsetup.sh
    lunch "$product" trunk_staging userdebug || die "lunch $product failed"
    [[ "${TARGET_PRODUCT:-}" == "$product" ]] || \
      die "lunch did not set TARGET_PRODUCT=$product (got '${TARGET_PRODUCT:-}')"
    # envsetup.sh and lunch both call `set +u` and may toggle other -o options;
    # re-assert the strict shell flags before running the long build.
    set -eo pipefail
    set -u

    m hosttar \
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
  trap 'status=$?; cleanup_temp_zram; exit "$status"' EXIT

  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  ensure_host_commands
  ensure_signing_keys
  setup_temp_zram_if_needed
  set_build_jobs
  log "using $jobs parallel build jobs ($highmem_jobs high-memory jobs)"
  ensure_repo_command
  ensure_anonymous_git_config
  cleanup_workspace_path_metadata

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
  run_checkpointed_step source-patches "source patches" apply_source_patches
  run_checkpointed_step microg-prebuilts "microG prebuilt refresh" update_microg_prebuilts
  run_checkpointed_step native-bridge-prebuilts "native bridge prebuilt refresh" update_native_bridge_prebuilts_for_targets "${targets[@]}"
  run_checkpointed_step build-input-validation "build input validation" validate_build_inputs_for_targets "${targets[@]}"

  local target
  for target in "${targets[@]}"; do
    build_target "$target"
  done

  mark_resume_checkpoint complete

  log "done"
  log "output directory: $output_dir"
  for target in "${targets[@]}"; do
    case "$target" in
      arm64)  log "  -> $output_dir/lineageos-arm64/" ;;
      x86_64) log "  -> $output_dir/lineageos-x86_64/" ;;
    esac
  done
}

main "$@"
