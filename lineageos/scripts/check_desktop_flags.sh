#!/usr/bin/env bash
set -euo pipefail

# Validate that every aconfig flag listed in desktop_required_aconfig_flags.txt
# is both defined for the current release config AND set to ENABLED.
#
# Output classifies failures so callers can fix them appropriately:
#   undefined: <pkg>/<flag>    — flag is not declared in this AOSP rev. Action:
#                                 remove from desktop_required_aconfig_flags.txt
#                                 (or pick the renamed flag). Regression class
#                                 from `respect_orientation_request_for_freeform_dialogs`.
#   disabled:  <pkg>/<flag>    — flag exists but is not ENABLED. Action: enable
#                                 it in build/release/aconfig/trunk_staging/<pkg>/
#                                 <flag>_flag_values.textproto.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
flags_file="$repo_root/vendor/lineage_desktop/config/desktop_required_aconfig_flags.txt"
release_dir="$repo_root/build/release/aconfig/trunk_staging"

if [[ ! -f "$flags_file" ]]; then
  printf 'missing flag list: %s\n' "$flags_file" >&2
  exit 2
fi

undefined=()
disabled=()
while IFS= read -r entry; do
  [[ -z "$entry" || "$entry" == \#* ]] && continue
  package="${entry%%/*}"
  name="${entry##*/}"
  file="$release_dir/$package/${name}_flag_values.textproto"
  if [[ ! -f "$file" ]]; then
    undefined+=("$entry")
    continue
  fi
  if ! grep -q 'state: ENABLED' "$file"; then
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
