#!/usr/bin/env bash
set -euo pipefail

# Validate that every aconfig flag listed in desktop_required_aconfig_flags.txt
# is declared by this source revision and resolves to ENABLED through the
# selected release config's inheritance chain.
#
# Output classifies failures so callers can fix them appropriately:
#   undefined: <pkg>/<flag>    — flag is not declared in this AOSP rev. Action:
#                                 remove from desktop_required_aconfig_flags.txt
#                                 (or pick the renamed flag). Regression class
#                                 from `respect_orientation_request_for_freeform_dialogs`.
#   disabled:  <pkg>/<flag>    — flag exists but its effective value is not
#                                 ENABLED. Action: enable it in the selected
#                                 release or one of its inherited configs.

if (( $# > 2 )); then
  printf 'Usage: %s [ANDROID_ROOT [TARGET_RELEASE]]\n' "${0##*/}" >&2
  exit 2
fi

if (( $# >= 1 )); then
  repo_root="$(cd "$1" && pwd)"
else
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi
flags_file="$repo_root/vendor/lineage_desktop/config/desktop_required_aconfig_flags.txt"
target_release="${2:-${IKA_ANDROID_TARGET_RELEASE:-}}"
if [[ -z "$target_release" && -r "$repo_root/vendor/lineage/vars/aosp_target_release" ]]; then
  # shellcheck disable=SC1091
  source "$repo_root/vendor/lineage/vars/aosp_target_release"
  target_release="${aosp_target_release:-}"
fi
if [[ -z "$target_release" ]]; then
  printf 'could not determine the Lineage Android target release\n' >&2
  exit 2
fi
release_dir="$repo_root/build/release/aconfig/$target_release"
release_configs_dir="$repo_root/build/release/release_configs"

if [[ ! -f "$flags_file" ]]; then
  printf 'missing flag list: %s\n' "$flags_file" >&2
  exit 2
fi
if [[ ! -d "$release_dir" ]]; then
  printf 'missing release aconfig directory: %s\n' "$release_dir" >&2
  exit 2
fi
if [[ ! -d "$release_configs_dir" ]]; then
  printf 'missing release config directory: %s\n' "$release_configs_dir" >&2
  exit 2
fi

# Index actual declarations. A release value file for a flag that no longer
# exists is ignored by aconfig, so checking only value-file presence can turn a
# stale override into a false success.
mapfile -d '' declaration_files < <(
  find "$repo_root" \
    -path "$repo_root/out" -prune -o \
    -path "$repo_root/.repo" -prune -o \
    -type f -name '*.aconfig' -print0
)
if (( ${#declaration_files[@]} == 0 )); then
  printf 'no aconfig declaration files found under %s\n' "$repo_root" >&2
  exit 2
fi

declare -A declared_flags=()
while IFS= read -r entry; do
  declared_flags["$entry"]=1
done < <(
  awk '
    FNR == 1 { package = "" }
    /^[[:space:]]*package:[[:space:]]*"/ {
      value = $0
      sub(/^[[:space:]]*package:[[:space:]]*"/, "", value)
      sub(/".*/, "", value)
      package = value
      next
    }
    package != "" && /^[[:space:]]*name:[[:space:]]*"/ {
      value = $0
      sub(/^[[:space:]]*name:[[:space:]]*"/, "", value)
      sub(/".*/, "", value)
      print package "/" value
    }
  ' "${declaration_files[@]}"
)

# Resolve the release chain from oldest parent to the selected release. Later
# value files override earlier ones, matching release_config inheritance.
release_chain=()
declare -A visited_releases=()
release="$target_release"
while [[ -n "$release" ]]; do
  if [[ -n "${visited_releases[$release]:-}" ]]; then
    printf 'release config inheritance cycle at %s\n' "$release" >&2
    exit 2
  fi
  visited_releases["$release"]=1
  config_file="$release_configs_dir/$release.textproto"
  if [[ ! -f "$config_file" ]]; then
    printf 'missing release config: %s\n' "$config_file" >&2
    exit 2
  fi
  release_chain=("$release" "${release_chain[@]}")
  release="$(sed -n \
    's/^[[:space:]]*inherits:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$config_file" | head -n 1)"
done

undefined=()
disabled=()
while IFS= read -r entry; do
  [[ -z "$entry" || "$entry" == \#* ]] && continue
  if [[ -z "${declared_flags[$entry]:-}" ]]; then
    undefined+=("$entry")
    continue
  fi
  package="${entry%%/*}"
  name="${entry##*/}"
  file=""
  for release in "${release_chain[@]}"; do
    candidate="$repo_root/build/release/aconfig/$release/$package/${name}_flag_values.textproto"
    [[ -f "$candidate" ]] && file="$candidate"
  done
  if [[ -z "$file" ]] || \
      ! grep -Eq '^[[:space:]]*state:[[:space:]]*ENABLED([[:space:]]|$)' "$file"; then
    disabled+=("$entry")
  fi
done < "$flags_file"

rc=0
if (( ${#undefined[@]} > 0 )); then
  rc=1
  printf 'undefined: %s\n' "${undefined[@]}"
fi
if (( ${#disabled[@]} > 0 )); then
  rc=1
  printf 'disabled:  %s\n' "${disabled[@]}"
fi
exit "$rc"
