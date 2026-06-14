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

project_has_unpushed_commits() {
  local project_dir="$1"
  local upstream ahead

  upstream="$(git -C "$project_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  [[ -n "$upstream" ]] || return 1

  ahead="$(git -C "$project_dir" rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)"
  [[ "$ahead" != "0" ]]
}

reset_dirty_managed_project() {
  local project="$1"
  local project_label="$2"
  local project_dir

  managed_source_tree || return 1
  patch_series_is_source_root "$project" && return 1

  project_dir="$(patch_series_project_dir "$repo_root" "$project")"
  [[ -n "$(git -C "$project_dir" status --porcelain=v1)" ]] || return 1

  if project_has_unpushed_commits "$project_dir" && [[ "${RESET_PATCHED_PROJECTS_FORCE:-0}" != "1" ]]; then
    die "$project_label has unpushed commits; refusing to reset before patching. Push/stash your work, or set RESET_PATCHED_PROJECTS_FORCE=1 to override."
  fi

  log "resetting dirty project before patching: $project_label"
  git -C "$project_dir" reset --hard HEAD >/dev/null
  git -C "$project_dir" clean -fd >/dev/null
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

declare -a projects=()
declare -A seen_projects=()
declare -A project_patch_count=()
declare -A project_patch_list=()

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

  if [[ -z "${seen_projects[$project]:-}" ]]; then
    projects+=("$project")
    seen_projects[$project]=1
  fi

  project_patch_count[$project]=$(( ${project_patch_count[$project]:-0} + 1 ))
  project_patch_list[$project]+="$patch"$'\n'
done < "$series_file"

for project in "${projects[@]}"; do
  if (( ${project_patch_count[$project]} > 1 )) \
      && patch_series_already_applied "$repo_root" "$overlay_dir" "$project" "${project_patch_list[$project]}"; then
    log "already applied: $project"
    continue
  fi

  while IFS= read -r patch; do
    [[ -n "$patch" ]] || continue
    apply_patch_file "$project" "$patch"
  done <<<"${project_patch_list[$project]}"
done
