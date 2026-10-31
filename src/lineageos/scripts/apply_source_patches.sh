#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -gt 1 ]]; then
  printf 'Usage: apply_source_patches.sh [android-source-root]\n' >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  repo_root="$(cd "$1" && pwd)"
else
  repo_root="$(cd "$script_dir/../../.." && pwd)"
fi

overlay_dir="$repo_root/vendor/lineage_desktop"
series_file="$overlay_dir/patches/series"

log() {
  printf '[lineage-desktop] %s\n' "$*"
}

die() {
  printf '[lineage-desktop] error: %s\n' "$*" >&2
  exit 1
}

[[ -f "$series_file" ]] || die "missing patch series: $series_file"

source "$script_dir/lib/patch_series.sh"

managed_source_tree() {
  [[ -f "$repo_root/.lineage-desktop-managed" ]]
}

project_is_git_checkout() {
  local project_dir="$1"
  [[ -d "$project_dir/.git" || -f "$project_dir/.git" || -L "$project_dir/.git" ]]
}

project_has_unpushed_commits() {
  local project_dir="$1"
  local upstream ahead

  upstream="$(git -C "$project_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  [[ -n "$upstream" ]] || return 1

  ahead="$(git -C "$project_dir" rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)"
  [[ "$ahead" != "0" ]]
}

reset_dirty_managed_project_dir() {
  local project_dir="$1"
  local project_label="$2"

  managed_source_tree || return 1
  project_is_git_checkout "$project_dir" || return 1
  [[ -n "$(git -C "$project_dir" status --porcelain=v1)" ]] || return 1

  if project_has_unpushed_commits "$project_dir" && [[ "${RESET_PATCHED_PROJECTS_FORCE:-0}" != "1" ]]; then
    die "$project_label has unpushed commits; refusing to reset before patching. Push/stash your work, or set RESET_PATCHED_PROJECTS_FORCE=1 to override."
  fi

  log "resetting dirty project before patching: $project_label"
  git -C "$project_dir" reset --hard HEAD >/dev/null
  git -C "$project_dir" clean -fd >/dev/null
}

reset_dirty_managed_project() {
  local project="$1"
  local project_label="$2"

  patch_series_is_source_root "$project" && return 1
  reset_dirty_managed_project_dir "$(patch_series_project_dir "$repo_root" "$project")" "$project_label"
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

  dir="$repo_root/$path"
  [[ -d "$dir" ]] || dir="$(dirname "$dir")"

  while [[ "$dir" != "$repo_root" && "$dir" == "$repo_root"* ]]; do
    if project_is_git_checkout "$dir"; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

reset_dirty_managed_patch_series_projects() {
  local i project patch patch_file path project_dir label
  declare -A seen_project_dirs=()

  managed_source_tree || return 1

  for i in "${!series_projects[@]}"; do
    project="${series_projects[$i]}"
    patch="${series_patches[$i]}"
    patch_file="$overlay_dir/$patch"

    if patch_series_is_source_root "$project"; then
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        project_dir="$(project_dir_for_source_root_patch_path "$path" || true)"
        [[ -n "$project_dir" ]] || continue
        [[ -z "${seen_project_dirs[$project_dir]:-}" ]] || continue

        seen_project_dirs[$project_dir]=1
        label="${project_dir#$repo_root/}"
        reset_dirty_managed_project_dir "$project_dir" "$label" || true
      done < <(source_root_patch_paths "$patch_file")
      continue
    fi

    project_dir="$(patch_series_project_dir "$repo_root" "$project")"
    [[ -z "${seen_project_dirs[$project_dir]:-}" ]] || continue

    seen_project_dirs[$project_dir]=1
    reset_dirty_managed_project_dir "$project_dir" "$(patch_series_project_label "$project")" || true
  done
}

apply_patch_file() {
  local project="$1"
  local patch="$2"
  local patch_file="$overlay_dir/$patch"
  local project_label

  project_label="$(patch_series_project_label "$project")"

  if patch_series_git_apply "$repo_root" "$project" --reverse --check --whitespace=nowarn "$patch_file" >/dev/null 2>&1; then
    log "already applied: $project_label"
    return
  fi

  if ! patch_series_git_apply "$repo_root" "$project" --check --whitespace=nowarn "$patch_file" >/dev/null; then
    if reset_dirty_managed_project "$project" "$project_label" \
        && patch_series_git_apply "$repo_root" "$project" --check --whitespace=nowarn "$patch_file" >/dev/null; then
      :
    else
      die "patch does not apply cleanly to $project_label: $patch"
    fi
  fi

  log "applying: $project_label"
  patch_series_git_apply "$repo_root" "$project" --whitespace=nowarn "$patch_file"
}

declare -a series_projects=()
declare -a series_patches=()

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "${line//[[:space:]]/}" ]] || continue
  [[ "${line:0:1}" == "#" ]] && continue

  # `read project patch extra` rejects lines with a third whitespace-separated
  # token. We require exactly "<project> <patch>" — paths must not contain
  # whitespace. This is also why apply_source_patches.sh, validate_build_inputs.sh,
  # and build_lineageos_desktop.sh all parse `series` the same way.
  read -r project patch extra <<<"$line"
  [[ -n "${project:-}" && -n "${patch:-}" && -z "${extra:-}" ]] || \
    die "invalid patch series line: $line"

  project_dir="$(patch_series_project_dir "$repo_root" "$project")"
  patch_file="$overlay_dir/$patch"

  if patch_series_is_source_root "$project"; then
    [[ -d "$project_dir" ]] || die "missing source root: $project_dir"
  else
    [[ -d "$project_dir/.git" ]] || die "missing git project: $project"
  fi
  [[ -f "$patch_file" ]] || die "missing patch file: $patch"

  series_projects+=("$project")
  series_patches+=("$patch")
done < "$series_file"

reset_dirty_managed_patch_series_projects || true

for i in "${!series_projects[@]}"; do
  apply_patch_file "${series_projects[$i]}" "${series_patches[$i]}"
done
