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

is_source_root_project() {
  [[ "$1" == "." ]]
}

project_dir_for_series_entry() {
  local project="$1"
  if is_source_root_project "$project"; then
    printf '%s\n' "$repo_root"
  else
    printf '%s/%s\n' "$repo_root" "$project"
  fi
}

project_label_for_series_entry() {
  local project="$1"
  if is_source_root_project "$project"; then
    printf '%s\n' "source root"
  else
    printf '%s\n' "$project"
  fi
}

git_apply_for_series_entry() {
  local project="$1"
  shift

  if is_source_root_project "$project"; then
    GIT_CEILING_DIRECTORIES="$(dirname "$repo_root")" \
      git -C "$repo_root" apply "$@"
  else
    git -C "$(project_dir_for_series_entry "$project")" apply "$@"
  fi
}

patch_series_already_applied() {
  local project="$1"
  local patch_list="$2"
  local project_dir
  local tmp_dir tmp_worktree combined_patch patch patch_file
  local applied=1

  is_source_root_project "$project" && return 1
  project_dir="$(project_dir_for_series_entry "$project")"

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lineage-patch-apply.XXXXXX")" || return 1
  tmp_worktree="$tmp_dir/worktree"
  combined_patch="$tmp_dir/combined.patch"

  if ! git -C "$project_dir" worktree add --detach --quiet "$tmp_worktree" HEAD >/dev/null 2>&1; then
    rm -rf "$tmp_dir"
    return 1
  fi

  while IFS= read -r patch; do
    [[ -n "$patch" ]] || continue
    patch_file="$overlay_dir/$patch"
    if ! git -C "$tmp_worktree" apply --index --whitespace=nowarn "$patch_file" >/dev/null 2>&1; then
      applied=0
      break
    fi
  done <<<"$patch_list"

  if (( applied )); then
    git -C "$tmp_worktree" diff --cached --binary HEAD -- > "$combined_patch"
    if [[ ! -s "$combined_patch" ]] \
        || ! git -C "$project_dir" apply --check --reverse "$combined_patch" >/dev/null 2>&1; then
      applied=0
    fi
  fi

  git -C "$project_dir" worktree remove --force "$tmp_worktree" >/dev/null 2>&1 || rm -rf "$tmp_worktree"
  rm -rf "$tmp_dir"
  (( applied ))
}

apply_patch_file() {
  local project="$1"
  local patch="$2"
  local patch_file="$overlay_dir/$patch"
  local project_label

  project_label="$(project_label_for_series_entry "$project")"

  if git_apply_for_series_entry "$project" --reverse --check --whitespace=nowarn "$patch_file" >/dev/null 2>&1; then
    log "already applied: $project_label"
    return
  fi

  if ! git_apply_for_series_entry "$project" --check --whitespace=nowarn "$patch_file" >/dev/null; then
    die "patch does not apply cleanly to $project_label: $patch"
  fi

  log "applying: $project_label"
  git_apply_for_series_entry "$project" --whitespace=nowarn "$patch_file"
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

  project_dir="$(project_dir_for_series_entry "$project")"
  patch_file="$overlay_dir/$patch"

  if is_source_root_project "$project"; then
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
      && patch_series_already_applied "$project" "${project_patch_list[$project]}"; then
    log "already applied: $project"
    continue
  fi

  while IFS= read -r patch; do
    [[ -n "$patch" ]] || continue
    apply_patch_file "$project" "$patch"
  done <<<"${project_patch_list[$project]}"
done
