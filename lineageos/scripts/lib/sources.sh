#!/usr/bin/env bash
# Source-tree management for the LineageOS Desktop build engine: repo tooling,
# manifest install, repo sync (+ git store/lock repair), patched-project reset,
# local overlay application, source patches, and microG/WebView/native-bridge
# prebuilt refresh. Source only (defines functions); relies on engine globals
# and core primitives at call time.

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
      if enabled "$skip_patch"; then
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
    if patch_series_is_source_root "$project"; then
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

repo_manifest_project_path_for_name() {
  local project_name="$1"
  local manifest path
  local -a manifests=()

  [[ -f "$workspace/.repo/manifest.xml" ]] && manifests+=("$workspace/.repo/manifest.xml")
  if [[ -d "$workspace/.repo/manifests" ]]; then
    while IFS= read -r -d '' manifest; do
      manifests+=("$manifest")
    done < <(find "$workspace/.repo/manifests" -maxdepth 2 -type f -name '*.xml' -print0)
  fi
  if [[ -d "$workspace/.repo/local_manifests" ]]; then
    while IFS= read -r -d '' manifest; do
      manifests+=("$manifest")
    done < <(find "$workspace/.repo/local_manifests" -maxdepth 1 -type f -name '*.xml' -print0)
  fi

  for manifest in "${manifests[@]}"; do
    path="$(
      awk -v want="$project_name" '
        /<project[[:space:]][^>]*name="/ {
          line = $0
          while (line !~ />/ && getline nextline > 0) {
            line = line " " nextline
          }
          name = ""
          project_path = ""
          if (match(line, /name="[^"]+"/)) {
            name = substr(line, RSTART + 6, RLENGTH - 7)
          }
          if (name != want) {
            next
          }
          if (match(line, /path="[^"]+"/)) {
            project_path = substr(line, RSTART + 6, RLENGTH - 7)
          } else {
            project_path = name
          }
          print project_path
          exit
        }
      ' "$manifest"
    )"
    if [[ -n "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  return 1
}

repo_project_checkout_path_for_name() {
  local project_name="$1"
  local path

  path="$(repo_manifest_project_path_for_name "$project_name" 2>/dev/null || true)"
  if [[ -n "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi

  if [[ -e "$workspace/$project_name" || -d "$workspace/.repo/projects/$project_name.git" ]]; then
    printf '%s\n' "$project_name"
    return 0
  fi

  if [[ "$project_name" == platform/* ]]; then
    path="${project_name#platform/}"
    if [[ -e "$workspace/$path" || -d "$workspace/.repo/projects/$path.git" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  fi

  return 1
}

repo_sync_failure_projects_from_log() {
  local sync_log="$1"
  awk '
    /^[^[:space:]]+[[:space:]]+checkout[[:space:]][0-9a-fA-F]+([[:space:]]|$)/ {
      print $1
    }
  ' "$sync_log" | sort -u
}

repair_repo_sync_checkout_failures() {
  local sync_log="$1"
  [[ -f "$sync_log" ]] || return 0

  local -a projects=()
  local project
  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    projects+=("$project")
  done < <(repo_sync_failure_projects_from_log "$sync_log")

  (( ${#projects[@]} > 0 )) || return 0

  local checkout_path checkout_dir project_git_dir object_git_dir
  log "repairing ${#projects[@]} repo checkout failure(s)"
  for project in "${projects[@]}"; do
    checkout_path="$(repo_project_checkout_path_for_name "$project" || true)"
    if [[ -z "$checkout_path" || "$checkout_path" == /* || "$checkout_path" == *..* ]]; then
      log "warning: could not determine safe checkout path for failed repo project $project"
      continue
    fi

    log "repo sync checkout failed for $project; removing checkout path $checkout_path"

    checkout_dir="$workspace/$checkout_path"
    if [[ -e "$checkout_dir" || -L "$checkout_dir" ]]; then
      log "removing ${checkout_dir#$workspace/}"
      rm -rf -- "$checkout_dir"
    fi

    project_git_dir="$workspace/.repo/projects/$checkout_path.git"
    if [[ -e "$project_git_dir" || -L "$project_git_dir" ]]; then
      log "removing ${project_git_dir#$workspace/}"
      rm -rf -- "$project_git_dir"
    fi

    object_git_dir="$workspace/.repo/project-objects/$project.git"
    if [[ -e "$object_git_dir" || -L "$object_git_dir" ]]; then
      log "removing ${object_git_dir#$workspace/}"
      rm -rf -- "$object_git_dir"
    fi
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
  local sync_log
  while :; do
    log "syncing source tree (attempt $attempt/$repo_sync_attempts)"
    sync_log="$(mktemp -t lineage-desktop-repo-sync.XXXXXX.log)"
    if run_anonymous_git_network "$repo_cmd" "${sync_args[@]}" 2>&1 | tee "$sync_log"; then
      rm -f "$sync_log"
      return 0
    fi

    if (( attempt >= repo_sync_attempts )); then
      rm -f "$sync_log"
      return 1
    fi

    repair_repo_sync_checkout_failures "$sync_log"
    rm -f "$sync_log"
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
