#!/usr/bin/env bash

set -euo pipefail

readonly required_groups=(kvm cvdnetwork render video)

valid_target_user() {
  local user="${1:-}"
  [ -n "${user}" ] || return 1
  [ "${user}" != "root" ] || return 1
  getent passwd "${user}" >/dev/null 2>&1
}

detect_target_user_from_loginctl() {
  local require_local="$1"
  local session user active remote class

  command -v loginctl >/dev/null 2>&1 || return 1

  while read -r session; do
    [ -n "${session}" ] || continue
    user="$(loginctl show-session "${session}" -p Name --value 2>/dev/null || true)"
    active="$(loginctl show-session "${session}" -p Active --value 2>/dev/null || true)"
    remote="$(loginctl show-session "${session}" -p Remote --value 2>/dev/null || true)"
    class="$(loginctl show-session "${session}" -p Class --value 2>/dev/null || true)"

    [ "${active}" = "yes" ] || continue
    [ "${class}" = "user" ] || continue
    valid_target_user "${user}" || continue

    if [ "${require_local}" = "1" ] && [ "${remote}" = "yes" ]; then
      continue
    fi

    printf '%s\n' "${user}"
    return 0
  done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')

  return 1
}

detect_target_user() {
  local user=""

  user="$(logname 2>/dev/null || true)"
  if valid_target_user "${user}"; then
    printf '%s\n' "${user}"
    return 0
  fi

  user="${SUDO_USER:-}"
  if valid_target_user "${user}"; then
    printf '%s\n' "${user}"
    return 0
  fi

  user="$(detect_target_user_from_loginctl 1 || true)"
  if valid_target_user "${user}"; then
    printf '%s\n' "${user}"
    return 0
  fi

  user="$(detect_target_user_from_loginctl 0 || true)"
  if valid_target_user "${user}"; then
    printf '%s\n' "${user}"
    return 0
  fi

  return 1
}

add_user_to_group() {
  local user="$1"
  local group="$2"

  if ! getent group "${group}" >/dev/null 2>&1; then
    echo "Cuttlefish install: group '${group}' does not exist; skipping ${user} membership." >&2
    return 0
  fi

  if id -nG "${user}" 2>/dev/null | grep -qw -- "${group}"; then
    return 0
  fi

  usermod -aG "${group}" "${user}"
  added_any=1
  echo "Cuttlefish install: added ${user} to ${group}." >&2
}

main() {
  local user=""
  local group
  local added_any=0

  user="$(detect_target_user || true)"
  if ! valid_target_user "${user}"; then
    echo "Cuttlefish install: could not detect a logged-in user to add to kvm/cvdnetwork/render/video." >&2
    return 0
  fi

  for group in "${required_groups[@]}"; do
    add_user_to_group "${user}" "${group}"
  done

  if [ "${added_any}" = "1" ]; then
    echo "Cuttlefish install: ${user} may need to log out and back in before the new group membership applies." >&2
  fi
}

main "$@"
