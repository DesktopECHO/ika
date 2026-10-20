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

# Returns 0 when a project's patch stack is applied to the live tree: the stack
# can be taken off again, last patch first. Each patch is reversed on a scratch
# copy of the files the stack touches, so a patch that edits lines an earlier
# one also edits is checked against the tree as that earlier patch left it.
# Reverse-checking every patch alone against the live tree fails for such
# overlapping patches, because a later patch has already changed the earlier
# one's context. The scratch copy avoids throwaway worktrees: repo partial
# clones may not have every historical blob needed for `git apply --index`,
# while the live checkout already has the patched files. The live tree is not
# touched. Source-root entries are checked one by one by callers and return
# non-zero here.
#   patch_series_already_applied <root> <overlay_dir> <project> <patch_list>
patch_series_already_applied() {
  local root="$1"
  local overlay_dir="$2"
  local project="$3"
  local patch_list="$4"
  local project_dir patch patch_file scratch file field path
  local -a patches=() files=()
  local -A seen_file=()
  local status=0

  patch_series_is_source_root "$project" && return 1
  project_dir="$(patch_series_project_dir "$root" "$project")"

  while IFS= read -r patch; do
    [[ -n "$patch" ]] || continue
    patches+=("$patch")
  done <<<"$patch_list"
  (( ${#patches[@]} > 0 )) || return 0

  # The files each patch touches, from git's NUL-separated numstat: a line
  # "added<TAB>deleted<TAB>path", or "added<TAB>deleted<TAB>" followed by the
  # old and new path of a rename.
  for patch in "${patches[@]}"; do
    patch_file="$overlay_dir/$patch"
    while IFS= read -r -d '' field; do
      if [[ "$field" == *$'\t'*$'\t'* ]]; then
        path="${field#*$'\t'}"
        path="${path#*$'\t'}"
        if [[ -n "$path" ]]; then
          files+=("$path")
        else
          IFS= read -r -d '' path && files+=("$path")
          IFS= read -r -d '' path && files+=("$path")
        fi
      fi
    done < <(git -C "$project_dir" apply --numstat -z "$patch_file" 2>/dev/null)
  done

  scratch="$(mktemp -d)" || return 1
  for file in "${files[@]}"; do
    [[ -z "${seen_file[$file]:-}" ]] || continue
    seen_file[$file]=1
    [[ -e "$project_dir/$file" ]] || continue
    mkdir -p "$scratch/$(dirname "$file")" && cp -p "$project_dir/$file" "$scratch/$file" || status=1
  done

  # git apply outside a repository patches plain files; the ceiling keeps it
  # from finding one above the scratch directory.
  local i
  if (( status == 0 )); then
    for (( i = ${#patches[@]} - 1; i >= 0; i-- )); do
      GIT_CEILING_DIRECTORIES="$(dirname "$scratch")" \
        git -C "$scratch" apply --reverse --whitespace=nowarn "$overlay_dir/${patches[i]}" >/dev/null 2>&1 || {
        status=1
        break
      }
    done
  fi

  rm -rf "$scratch"
  return "$status"
}
