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

  if [[ -x "$repo_install_path" ]]; then
    repo_cmd="$repo_install_path"
    return 0
  fi

  die "repo is not installed; run ./ika-build to install dependencies, or install repo at $repo_install_path"
}

ensure_anonymous_git_config() {
  local git_email

  git_email="$(signing_certificate_email)"
  git_email="${git_email:-$(default_signing_email)}"
  mkdir -p "${anonymous_git_config%/*}"
  cat > "$anonymous_git_config" <<'EOF'
[color]
	ui = auto
[user]
	name = LineageOS Desktop Builder
[url "https://github.com/"]
	insteadOf = git@github.com:
	insteadOf = ssh://git@github.com/
	insteadOf = ssh://git@github.com:22/
	insteadOf = git://github.com/
EOF
  git config --file "$anonymous_git_config" user.email "$git_email"
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

  # On x86 hosts, ensure_linux_x86_clang_prebuilt provisions only the pinned
  # Clang payload (blobless, ~3.5 GB), so drop the full
  # prebuilts/clang/host/linux-x86 project (5 payloads, ~18 GB) from repo sync.
  # ARM64 hosts never use the x86 host Clang and clone arm64 separately, so this
  # is gated to x86 hosts to avoid removing a project an arm64 build might map.
  local x86_clang_manifest_dest="$workspace/.repo/local_manifests/desktop-remove-x86-clang.xml"
  if ! host_is_arm64; then
    cat > "$x86_clang_manifest_dest" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remove-project name="platform/prebuilts/clang/host/linux-x86" />
</manifest>
EOF
  else
    rm -f "$x86_clang_manifest_dest"
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
    if [[ -n "$path" && "$path" != /* && "$path" != *..* ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  fi

  return 1
}

repo_sync_force_sync_paths_from_log() {
  local sync_log="$1"
  awk '
    /hooks is different in .*\.repo\/projects\/.*\.git vs .*\.repo\/project-objects\// {
      line = $0
      sub(/^.*\.repo\/projects\//, "", line)
      sub(/\.git vs .*$/, "", line)
      print line
    }
    /repo sync --force-sync / {
      line = $0
      sub(/^.*repo sync --force-sync /, "", line)
      sub(/`.*/, "", line)
      sub(/[[:space:]]+to proceed\..*/, "", line)
      n = split(line, fields, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (fields[i] != "" && fields[i] !~ /^-/) {
          print fields[i]
        }
      }
    }
  ' "$sync_log" | sort -u
}

repo_sync_failure_projects_from_log() {
  local sync_log="$1"
  awk '
    /Cannot checkout [^:[:space:]]+/ {
      line = $0
      sub(/^.*Cannot checkout /, "", line)
      sub(/:.*/, "", line)
      print line
    }
    /Cannot initialize work tree for [^[:space:]]+/ {
      line = $0
      sub(/^.*Cannot initialize work tree for /, "", line)
      sub(/[[:space:]].*/, "", line)
      print line
    }
    /^[^[:space:]]+[[:space:]]+checkout[[:space:]][0-9a-fA-F]+([[:space:]]|$)/ {
      print $1
    }
    /fatal: unable to access .*android\.googlesource\.com\/.*requested URL returned error: 429/ {
      line = $0
      sub(/^.*android\.googlesource\.com\//, "", line)
      sub(/\/.: The requested URL returned error: 429.*$/, "", line)
      print line
    }
  ' "$sync_log" | sort -u
}

repo_sync_output_filter() {
  awk '
    /^Updating files:[[:space:]]+100% \([0-9]+\/[0-9]+\), done\.$/ {
      next
    }
    /^error: RPC failed; HTTP 429 / {
      seen_repo_failure = 1
      next
    }
    /^remote: RESOURCE_EXHAUSTED:/ {
      seen_repo_failure = 1
      in_quota_block = 1
      next
    }
    in_quota_block && /^remote:/ {
      next
    }
    in_quota_block {
      in_quota_block = 0
    }
    /^fatal: unable to access .*android\.googlesource\.com\/.*requested URL returned error: 429$/ {
      seen_repo_failure = 1
      next
    }
    /^fatal: unable to access .*android\.googlesource\.com\/.*(Failed to connect|Could not connect to server)/ {
      seen_repo_failure = 1
      next
    }
    /^fatal: expected .packfile.$/ {
      seen_repo_failure = 1
      next
    }
    /^fatal: could not fetch [0-9a-fA-F]+ from promisor remote$/ {
      seen_repo_failure = 1
      next
    }
    /^error\.GitError: Cannot checkout [^:[:space:]]+: Cannot initialize work tree for / {
      seen_repo_failure = 1
      next
    }
    /^error: hooks is different in .*\.repo\/projects\/.*\.git vs .*\.repo\/project-objects\// {
      seen_repo_failure = 1
      next
    }
    /^error\.GitError: Cannot fetch --force-sync not enabled; cannot overwrite a local work tree\./ {
      seen_repo_failure = 1
      next
    }
    /^--force-sync not enabled; cannot overwrite a local work tree\./ {
      seen_repo_failure = 1
      next
    }
    /^error: Cannot checkout [^[:space:]]+$/ {
      seen_repo_failure = 1
      next
    }
    /^error: Unable to fully sync the tree$/ {
      seen_repo_failure = 1
      next
    }
    /^error: Exited sync due to fetch errors\.$/ {
      seen_repo_failure = 1
      next
    }
    /^Local checkouts \*not\* updated\. Resolve network issues & retry\.$/ {
      seen_repo_failure = 1
      next
    }
    /^`repo sync -l` will update some local checkouts\.$/ {
      seen_repo_failure = 1
      next
    }
    /^error: Checking out local projects failed\.$/ {
      seen_repo_failure = 1
      next
    }
    /^Repo command failed due to the following .* errors:$/ {
      seen_repo_failure = 1
      next
    }
    /^Cannot initialize work tree for [^[:space:]]+$/ {
      seen_repo_failure = 1
      next
    }
    /^[^[:space:]]+[[:space:]]+checkout[[:space:]][0-9a-fA-F]+([[:space:]]|$)/ {
      seen_repo_failure = 1
      next
    }
    /^error: [^:]+: [^[:space:]]+[[:space:]]+checkout[[:space:]][0-9a-fA-F]+/ {
      seen_repo_failure = 1
      next
    }
    /^Failing repos \(checkout\):$/ {
      seen_repo_failure = 1
      in_failing_repos = 1
      next
    }
    in_failing_repos {
      if (/^Try re-running with / || /^=+$/) {
        in_failing_repos = 0
        next
      }
      if (/^[[:space:]]*[^[:space:]]+[[:space:]]*$/) {
        next
      }
      in_failing_repos = 0
    }
    seen_repo_failure && /^Try re-running with / {
      next
    }
    seen_repo_failure && /^=+$/ {
      next
    }
    # Drop "error: ... checkout ..." lines (transient checkout failures) from the
    # live console. The raw sync log (written via tee) still records them, and
    # retry/failure detection works off that raw log, so this only quiets display.
    /^error: .*checkout/ {
      seen_repo_failure = 1
      next
    }
    # Drop any line mentioning a promisor-remote fetch failure (transient, blob:none).
    /promisor remote/ {
      seen_repo_failure = 1
      next
    }
    # Drop transient RPC/sync failure lines from the live console.
    /^error: RPC failed/ {
      seen_repo_failure = 1
      next
    }
    /^error: Unable/ {
      seen_repo_failure = 1
      next
    }
    { print }
  '
}

repo_sync_failure_url_from_log() {
  local sync_log="$1"
  awk '
    /fatal: unable to access .*android\.googlesource\.com\/.*(Failed to connect|Could not connect to server)/ {
      line = $0
      start = index(line, "https://android.googlesource.com/")
      if (start == 0) {
        next
      }
      line = substr(line, start)
      end = index(line, sprintf("%c", 39))
      if (end > 0) {
        line = substr(line, 1, end - 1)
      }
      sub(/\/$/, "", line)
      print line
      exit
    }
  ' "$sync_log"
}

repo_sync_manifest_error_from_log() {
  local sync_log="$1"
  awk '
    {
      start = index($0, "error parsing manifest")
      if (start > 0) {
        print substr($0, start)
        exit
      }
    }
  ' "$sync_log"
}

repo_sync_failure_summary_from_log() {
  local sync_log="$1"
  local retry_delay="${2:-}"
  local final_attempt="${3:-0}"
  local attempt_label="${4:-}"
  local projects force_sync_paths retry_url subject action
  local attempt_suffix=""

  projects="$(
    repo_sync_failure_projects_from_log "$sync_log" |
      awk 'NF { printf "%s%s", sep, $0; sep=", " } END { if (sep != "") print "" }'
  )"
  force_sync_paths="$(
    repo_sync_force_sync_paths_from_log "$sync_log" |
      awk 'NF { printf "%s%s", sep, $0; sep=", " } END { if (sep != "") print "" }'
  )"
  retry_url="$(repo_sync_failure_url_from_log "$sync_log")"

  if [[ -n "$projects" ]]; then
    subject="on $projects"
  elif [[ -n "$force_sync_paths" ]]; then
    subject="after project metadata changed for $force_sync_paths"
  else
    subject="during repo sync"
  fi

  if [[ -n "$attempt_label" ]]; then
    attempt_suffix=" (attempt $attempt_label)"
  fi

  if [[ "$final_attempt" == "1" ]]; then
    action="no retry attempts remain${attempt_suffix}"
  elif [[ -n "$retry_delay" ]]; then
    action="retrying in ${retry_delay} seconds${attempt_suffix}"
  else
    action="retrying${attempt_suffix}"
  fi

  if [[ -n "$retry_url" && "$final_attempt" != "1" ]]; then
    printf 'retrying %s\n' "$retry_url"
  elif [[ -n "$retry_url" ]]; then
    printf 'failed %s; no retry attempts remain\n' "$retry_url"
  elif grep -q 'HTTP 429\|requested URL returned error: 429\|RESOURCE_EXHAUSTED' "$sync_log"; then
    printf 'HTTP 429 %s; %s\n' "$subject" "$action"
  elif [[ -n "$force_sync_paths" ]]; then
    printf 'repo force-sync required %s; %s\n' "$subject" "$action"
  elif [[ -n "$projects" ]]; then
    printf 'repo checkout failed %s; %s\n' "$subject" "$action"
  else
    printf 'repo sync failed; %s\n' "$action"
  fi
}

repo_workspace_uses_partial_clone() {
  [[ -d "$workspace/.repo/manifests" ]] || return 1
  [[ "$(git -C "$workspace/.repo/manifests" config --bool --get repo.partialclone 2>/dev/null || true)" == "true" ]] && return 0
  [[ -n "$(git -C "$workspace/.repo/manifests" config --get repo.clonefilter 2>/dev/null || true)" ]]
}

repo_workspace_is_managed() {
  [[ -f "$workspace/.lineage-desktop-managed" ]]
}

repair_repo_sync_checkout_failures() {
  local sync_log="$1"
  local quiet="${2:-0}"
  [[ -f "$sync_log" ]] || return 0

  local -a projects=()
  local project
  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    projects+=("$project")
  done < <(repo_sync_failure_projects_from_log "$sync_log")

  (( ${#projects[@]} > 0 )) || return 0

  local checkout_path checkout_dir project_git_dir object_git_dir
  [[ "$quiet" == "1" ]] || log "repairing ${#projects[@]} repo checkout failure(s)"
  for project in "${projects[@]}"; do
    checkout_path="$(repo_project_checkout_path_for_name "$project" || true)"
    if [[ -z "$checkout_path" || "$checkout_path" == /* || "$checkout_path" == *..* ]]; then
      [[ "$quiet" == "1" ]] || log "warning: could not determine safe checkout path for failed repo project $project"
      continue
    fi

    [[ "$quiet" == "1" ]] || log "repo sync checkout failed for $project; removing checkout path $checkout_path"

    checkout_dir="$workspace/$checkout_path"
    if [[ -e "$checkout_dir" || -L "$checkout_dir" ]]; then
      [[ "$quiet" == "1" ]] || log "removing ${checkout_dir#$workspace/}"
      rm -rf -- "$checkout_dir"
    fi

    project_git_dir="$workspace/.repo/projects/$checkout_path.git"
    if [[ -e "$project_git_dir" || -L "$project_git_dir" ]]; then
      [[ "$quiet" == "1" ]] || log "removing ${project_git_dir#$workspace/}"
      rm -rf -- "$project_git_dir"
    fi

    object_git_dir="$workspace/.repo/project-objects/$project.git"
    if [[ -e "$object_git_dir" || -L "$object_git_dir" ]]; then
      [[ "$quiet" == "1" ]] || log "removing ${object_git_dir#$workspace/}"
      rm -rf -- "$object_git_dir"
    fi
  done
}

repair_repo_sync_force_sync_failures() {
  local sync_log="$1"
  local quiet="${2:-0}"
  [[ -f "$sync_log" ]] || return 1

  local -A seen=()
  local -a paths=()
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      /*|*..*|.*)
        [[ "$quiet" == "1" ]] || log "warning: ignoring unsafe repo force-sync path from log: $path"
        continue
        ;;
    esac
    [[ -n "${seen[$path]:-}" ]] && continue
    seen["$path"]=1
    paths+=("$path")
  done < <(repo_sync_force_sync_paths_from_log "$sync_log")

  (( ${#paths[@]} > 0 )) || return 1

  local -a force_sync_args=(sync -c --fail-fast --force-sync --force-checkout -j1)
  if (( repo_sync_retry_fetches > 0 )); then
    force_sync_args+=(--retry-fetches="$repo_sync_retry_fetches")
  fi
  if repo_workspace_uses_partial_clone; then
    force_sync_args+=(--no-interleaved --jobs-network=1 --jobs-checkout=1)
  fi

  [[ "$quiet" == "1" ]] || log "repo project metadata changed; force-syncing ${paths[*]}"
  run_anonymous_git_network "$repo_cmd" "${force_sync_args[@]}" "${paths[@]}"
}

# git reports object/pack corruption with the on-disk path of the bad object or
# pack, which lives under .repo/project-objects/<name>.git/... or
# .repo/projects/<path>.git/... Pull those .git store roots out of the sync log
# and remove them so the next attempt re-fetches the affected project cleanly.
# (Corruption errors with no embedded path -- e.g. "did not receive expected
# object" -- are left to the normal retry/force-sync path.)
remove_corrupt_repo_stores_from_log() {
  local sync_log="$1"
  [[ -f "$sync_log" ]] || return 0

  local -A seen=()
  local -a stores=()
  local line path store

  while IFS= read -r line; do
    case "$line" in
      *"is corrupt"*|*"is empty"*|*"cannot be read"*|*"does not match index"*|\
      *"inflate: data stream error"*|*"object file"*|*"loose object"*) ;;
      *) continue ;;
    esac
    path="$(printf '%s\n' "$line" |
      grep -aoE '[^[:space:]"():]*\.repo/(project-objects|projects)/[^[:space:]"():]*\.git' |
      head -n1)"
    [[ -n "$path" ]] || continue
    case "$path" in
      /*) store="$path" ;;
      *)  store="$workspace/$path" ;;
    esac
    [[ -d "$store" ]] || continue
    [[ -n "${seen[$store]:-}" ]] && continue
    seen["$store"]=1
    stores+=("$store")
  done < "$sync_log"

  (( ${#stores[@]} > 0 )) || return 0

  log "removing ${#stores[@]} corrupt repo git store(s) reported during fetch"
  for store in "${stores[@]}"; do
    log "removing corrupt store ${store#$workspace/}"
    rm -rf -- "$store"
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

repo_manifest_copyfile_sources() {
  python3 - "$workspace" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET

workspace = pathlib.Path(sys.argv[1])
manifest_roots = [
    workspace / ".repo" / "manifests",
    workspace / ".repo" / "local_manifests",
]
seen = set()

for manifest_root in manifest_roots:
    if not manifest_root.is_dir():
        continue
    for manifest in sorted(manifest_root.rglob("*.xml")):
        try:
            root = ET.parse(manifest).getroot()
        except ET.ParseError:
            continue
        for element in list(root.iter("project")) + list(root.iter("extend-project")):
            project_path = element.get("path") or element.get("name")
            if not project_path:
                continue
            for copyfile in element.findall("copyfile"):
                src = copyfile.get("src")
                if not src:
                    continue
                record = (project_path, src)
                if record in seen:
                    continue
                seen.add(record)
                print(f"{project_path}\t{src}")
PY
}

presync_repo_copyfile_sources() {
  local copyfile_jobs="${1:-4}"
  local -a projects=()
  local -A seen_projects=()
  local project_path src

  while IFS=$'\t' read -r project_path src; do
    [[ -n "$project_path" && -n "$src" ]] || continue
    case "$project_path/$src" in
      /*|*../*) continue ;;
    esac
    [[ -e "$workspace/$project_path/$src" ]] && continue
    [[ -n "${seen_projects[$project_path]:-}" ]] && continue
    seen_projects[$project_path]=1
    projects+=("$project_path")
  done < <(repo_manifest_copyfile_sources)

  (( ${#projects[@]} > 0 )) || return 0

  local -a copyfile_fetch_args=(sync -c --fail-fast --network-only -j"$copyfile_jobs")
  if (( repo_sync_retry_fetches > 0 )); then
    copyfile_fetch_args+=(--retry-fetches="$repo_sync_retry_fetches")
  fi
  if repo_workspace_uses_partial_clone; then
    copyfile_fetch_args+=(--no-interleaved --jobs-network="$copyfile_jobs" --jobs-checkout="$copyfile_jobs")
  fi

  log "pre-syncing ${#projects[@]} manifest copyfile source project(s)"
  git_network_retry "pre-sync manifest copyfile sources" \
    run_anonymous_git_network "$repo_cmd" "${copyfile_fetch_args[@]}" "${projects[@]}"

  local -a copyfile_checkout_args=(sync -c --fail-fast --local-only --interleaved -j"$copyfile_jobs")
  if repo_workspace_is_managed; then
    copyfile_checkout_args+=(--force-checkout)
  fi
  run_anonymous_git_network "$repo_cmd" "${copyfile_checkout_args[@]}" "${projects[@]}"
}

# --- source-tree completeness verification ----------------------------------
# A rate-limited or interrupted checkout can leave a project's worktree gutted
# (its tracked files staged-deleted) while `repo sync` still exits 0. The build
# then dies much later with "depends on undefined module". These helpers detect
# such projects after a sync and heal them -- first from already-fetched local
# objects (instant, offline), then by re-syncing the stragglers over the
# network -- and fail loudly if the tree still is not whole, so we never build
# on half-downloaded sources.

list_incomplete_repo_projects() {
  ( cd "$workspace" 2>/dev/null &&
    "$repo_cmd" forall -j8 -c \
      'git status --porcelain 2>/dev/null | grep -q "^D " && printf "%s\n" "$REPO_PATH"' \
      2>/dev/null )
}

# Restore gutted projects from local objects; print the paths that still need a
# network re-fetch (objects not present locally).
restore_incomplete_repo_projects_offline() {
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if git -C "$workspace/$path" reset --hard HEAD >/dev/null 2>&1 &&
       ! git -C "$workspace/$path" status --porcelain 2>/dev/null | grep -q '^D '; then
      log "restored incomplete project from local objects: $path"
    else
      printf '%s\n' "$path"
    fi
  done < <(list_incomplete_repo_projects)
}

verify_repo_sync_complete() {
  local network_jobs="${1:-2}"
  local rounds="${REPO_SYNC_VERIFY_ROUNDS:-20}"
  local round=1
  local -a remaining

  while (( round <= rounds )); do
    remaining=()
    local path
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      remaining+=("$path")
    done < <(restore_incomplete_repo_projects_offline)

    if (( ${#remaining[@]} == 0 )); then
      (( round > 1 )) && log "source tree verified complete after repair"
      return 0
    fi

    log "source tree incomplete: ${#remaining[@]} project(s) need re-fetch (round $round/$rounds): ${remaining[*]}"
    run_anonymous_git_network "$repo_cmd" sync -c -j"$network_jobs" \
      --force-sync --force-checkout "${remaining[@]}" >/dev/null 2>&1 ||
      log "re-sync of incomplete projects reported an error; re-verifying"
    round=$((round + 1))
  done

  # Final check after the last repair round.
  remaining=()
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    remaining+=("$path")
  done < <(list_incomplete_repo_projects)
  (( ${#remaining[@]} == 0 )) && return 0

  log "ERROR: source tree still incomplete after $rounds repair round(s): ${remaining[*]}"
  return 1
}

repo_sync_sources() {
  mkdir -p "$workspace"
  if [[ "$workspace_defaulted" -eq 1 ]]; then
    touch "$workspace/.lineage-desktop-managed"
  fi

  cd "$workspace"

  # A fresh checkout has no .repo yet. Partial-clone flags must only be passed
  # on a fresh init: re-running `repo init --partial-clone` over an existing
  # full clone has caused sync failures. Groups are safe to (re)apply either way.
  local repo_is_fresh=0
  [[ -d "$workspace/.repo" ]] || repo_is_fresh=1

  local -a init_args=(init -u "$android_manifest_url" -b "$lineage_branch")
  if [[ -n "$repo_groups" ]]; then
    init_args+=(-g "$repo_groups")
  fi
  if [[ -n "$repo_clone_filter" && "$repo_is_fresh" -eq 1 ]]; then
    init_args+=(--partial-clone --clone-filter="$repo_clone_filter")
    log "fresh checkout: using blobless partial clone (--clone-filter=$repo_clone_filter)"
  fi
  if [[ -n "$repo_groups" ]]; then
    log "repo groups: $repo_groups"
  fi

  log "initializing LineageOS source at $workspace"
  git_network_retry "repo init LineageOS source" \
    run_anonymous_git_network "$repo_cmd" "${init_args[@]}"

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

  # Use a moderate default for good residential connections. Partial-clone
  # workspaces also use this value for --jobs-network below; REPO_SYNC_JOBS can
  # still override it.
  local sync_jobs
  if [[ -n "$repo_sync_jobs" ]]; then
    [[ "$repo_sync_jobs" =~ ^[0-9]+$ && "$repo_sync_jobs" -gt 0 ]] ||
      die "REPO_SYNC_JOBS must be a positive integer"
    sync_jobs="$repo_sync_jobs"
  else
    sync_jobs=4
  fi

  # Network concurrency is the dominant cause of googlesource HTTP 429s, so keep
  # it lower than checkout concurrency. Default to 2 (override via
  # REPO_SYNC_NETWORK_JOBS), never exceeding sync_jobs.
  local network_jobs
  if [[ -n "${repo_sync_network_jobs:-}" ]]; then
    [[ "$repo_sync_network_jobs" =~ ^[0-9]+$ && "$repo_sync_network_jobs" -gt 0 ]] ||
      die "REPO_SYNC_NETWORK_JOBS must be a positive integer"
    network_jobs="$repo_sync_network_jobs"
  else
    network_jobs=2
    (( network_jobs > sync_jobs )) && network_jobs="$sync_jobs"
  fi

  presync_repo_copyfile_sources "$sync_jobs"

  local -a sync_args=(sync -c --fail-fast -j"$sync_jobs")
  if repo_workspace_is_managed; then
    log "managed source tree detected; using repo --force-checkout for stale checkout files"
    sync_args+=(--force-checkout)
  fi
  if (( repo_sync_retry_fetches > 0 )); then
    sync_args+=(--retry-fetches="$repo_sync_retry_fetches")
  fi
  if repo_workspace_uses_partial_clone; then
    local checkout_jobs
    if [[ -n "$repo_sync_checkout_jobs" ]]; then
      [[ "$repo_sync_checkout_jobs" =~ ^[0-9]+$ && "$repo_sync_checkout_jobs" -gt 0 ]] ||
        die "REPO_SYNC_CHECKOUT_JOBS must be a positive integer"
      checkout_jobs="$repo_sync_checkout_jobs"
    else
      checkout_jobs=4
    fi
    log "repo partial clone detected; using phased sync with $network_jobs network jobs and $checkout_jobs checkout jobs"
    sync_args+=(--no-interleaved --jobs-network="$network_jobs" --jobs-checkout="$checkout_jobs")
  fi
  if enabled "$quiet"; then
    sync_args+=(--quiet)
  fi

  local attempt=1
  local suppress_attempt_log=0
  local force_sync_repairs=0
  local sync_log manifest_error
  while :; do
    if (( suppress_attempt_log == 0 )); then
      log "syncing source tree (attempt $attempt/$repo_sync_attempts)"
    fi
    suppress_attempt_log=0
    sync_log="$(mktemp -t lineage-desktop-repo-sync.XXXXXX.log)"
    if run_anonymous_git_network "$repo_cmd" "${sync_args[@]}" 2>&1 | tee "$sync_log" | repo_sync_output_filter; then
      rm -f "$sync_log"
      # repo can exit 0 while leaving a gutted/incomplete tree; only declare
      # success once every project's worktree is actually whole.
      if verify_repo_sync_complete "$network_jobs"; then
        return 0
      fi
      if (( attempt >= repo_sync_attempts )); then
        log "ERROR: source tree still incomplete after $attempt sync attempt(s); refusing to build on partial sources"
        return 1
      fi
      log "source tree incomplete after a clean sync; retrying (attempt $attempt/$repo_sync_attempts)"
      repair_incomplete_repo_git_stores
      repair_stale_repo_git_locks
      attempt=$((attempt + 1))
      suppress_attempt_log=1
      sleep 30
      continue
    fi

    # A malformed manifest fails every attempt identically, and the console
    # filter can hide repo's top-level error line (it contains the echoed
    # --force-checkout flag), so surface the parser's message from the raw log
    # and stop instead of burning retries.
    manifest_error="$(repo_sync_manifest_error_from_log "$sync_log")"
    if [[ -n "$manifest_error" ]]; then
      log "ERROR: $manifest_error"
      log "ERROR: manifest parse errors are not retryable; fix the manifest and re-run"
      rm -f "$sync_log"
      return 1
    fi

    # Linear backoff for rate limiting: 5s initially, +5s per attempt, capped at
    # 60s (5s, 10s, 15s, ...); flat 5s for other transient failures.
    retry_delay=5
    if grep -q 'HTTP 429\|requested URL returned error: 429\|RESOURCE_EXHAUSTED' "$sync_log"; then
      retry_delay=$(( 5 * attempt ))
      (( retry_delay > 60 )) && retry_delay=60
    fi

    if (( force_sync_repairs < 3 )) && repair_repo_sync_force_sync_failures "$sync_log"; then
      force_sync_repairs=$((force_sync_repairs + 1))
      rm -f "$sync_log"
      repair_incomplete_repo_git_stores
      repair_stale_repo_git_locks
      log "repo force-sync repair completed; retrying source sync"
      continue
    fi

    if (( attempt >= repo_sync_attempts )); then
      log "$(repo_sync_failure_summary_from_log "$sync_log" "" 1 "$attempt/$repo_sync_attempts")"
      repair_repo_sync_checkout_failures "$sync_log" 1
      remove_corrupt_repo_stores_from_log "$sync_log"
      rm -f "$sync_log"
      return 1
    fi

    log "$(repo_sync_failure_summary_from_log "$sync_log" "$retry_delay" 0 "$attempt/$repo_sync_attempts")"
    repair_repo_sync_checkout_failures "$sync_log" 1
    remove_corrupt_repo_stores_from_log "$sync_log"
    rm -f "$sync_log"
    repair_incomplete_repo_git_stores
    repair_stale_repo_git_locks
    attempt=$((attempt + 1))
    suppress_attempt_log=1
    sleep "$retry_delay"
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

  build_host_lpunpack

  local update_script="$workspace/vendor/lineage_desktop/scripts/update_native_bridge_prebuilts.py"
  [[ -x "$update_script" ]] || die "missing native bridge update script: $update_script"

  log "refreshing x86 ARM64 native bridge prebuilts"
  "$update_script" "$workspace"

  # build_host_lpunpack (above) had to parse the x86_64 product config to build
  # the host lpunpack tool, but it runs before the payload exists and with the
  # bridge disabled -- so it caches a Kati/Ninja graph that excludes the native
  # bridge. If the currently generated graph does not install the bridge, drop it
  # so the real ROM build re-parses product config with the now-present payload
  # and actually includes the bridge instead of reusing the bridge-less graph.
  local x86_product product_ninja
  x86_product="$(target_product x86_64)"
  product_ninja="$workspace/out/soong/build.${x86_product}.ninja"
  if [[ -f "$product_ninja" ]] &&
     ! grep -qaE 'system/lib64/libndk_translation' "$product_ninja" 2>/dev/null; then
    remove_generated_ninja_state "$x86_product" \
      "cached product graph predates native bridge payload; forcing re-parse so the bridge is included"
  fi
}
