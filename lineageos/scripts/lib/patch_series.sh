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

# Returns 0 when a project's whole patch list is already applied to the live
# tree: apply the list to a throwaway worktree of HEAD, snapshot the combined
# diff, and confirm it reverse-applies cleanly to the project. Quiet by design
# (no logging) so each caller phrases its own messages. Source-root entries are
# never grouped this way and return non-zero.
#   patch_series_already_applied <root> <overlay_dir> <project> <patch_list>
patch_series_already_applied() {
  local root="$1"
  local overlay_dir="$2"
  local project="$3"
  local patch_list="$4"
  local project_dir tmp_dir tmp_worktree combined_patch patch patch_file
  local applied=1

  patch_series_is_source_root "$project" && return 1
  project_dir="$(patch_series_project_dir "$root" "$project")"

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lineage-patch-series.XXXXXX")" || return 1
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
