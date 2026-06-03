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
    die "patch does not apply cleanly to $project_label: $patch"
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
