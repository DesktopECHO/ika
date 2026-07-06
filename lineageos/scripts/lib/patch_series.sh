#!/usr/bin/env bash
# Shared patch-series primitives for the LineageOS Desktop build scripts. Source
# only (defines functions). Dependency-free so it works both sourced into the
# build engine and inside the standalone apply/validate scripts run from
# vendor/lineage_desktop/scripts/ (lib/ is rsynced alongside them).
#
# The series file format is "<project> <patch>" per line (# comments, blanks
# ignored); paths must not contain whitespace. A project of "." means the patch
# targets the source root itself (a checkout that spans several git projects).

# True when the series entry targets the source root rather than a sub-project.
patch_series_is_source_root() {
  [[ "$1" == "." ]]
}

# Absolute directory a series entry applies to, under the given source root.
patch_series_project_dir() {
  local root="$1"
  local project="$2"
  if patch_series_is_source_root "$project"; then
    printf '%s\n' "$root"
  else
    printf '%s/%s\n' "$root" "$project"
  fi
}

# Human-readable label for log/error messages.
patch_series_project_label() {
  if patch_series_is_source_root "$1"; then
    printf '%s\n' "source root"
  else
    printf '%s\n' "$1"
  fi
}

# Run `git apply` for a series entry. Source-root patches run from the root with
# a ceiling so git does not wander into an enclosing repository.
patch_series_git_apply() {
  local root="$1"
  local project="$2"
  shift 2

  if patch_series_is_source_root "$project"; then
    GIT_CEILING_DIRECTORIES="$(dirname "$root")" \
      git -C "$root" apply "$@"
  else
    git -C "$(patch_series_project_dir "$root" "$project")" apply "$@"
  fi
}

# Returns 0 when every patch in a project's list reverse-checks against the live
# tree. This intentionally avoids throwaway worktrees: repo partial clones may
# not have every historical blob needed for `git apply --index`, while the live
# checkout already has the patched files. Source-root entries are checked one by
# one by callers and return non-zero here.
#   patch_series_already_applied <root> <overlay_dir> <project> <patch_list>
patch_series_already_applied() {
  local root="$1"
  local overlay_dir="$2"
  local project="$3"
  local patch_list="$4"
  local patch patch_file

  patch_series_is_source_root "$project" && return 1

  while IFS= read -r patch; do
    [[ -n "$patch" ]] || continue
    patch_file="$overlay_dir/$patch"
    patch_series_git_apply "$root" "$project" --check --reverse --whitespace=nowarn "$patch_file" >/dev/null 2>&1 || \
      return 1
  done <<<"$patch_list"

  return 0
}
