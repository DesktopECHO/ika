#!/usr/bin/env bash
# Compare local package artifacts with installed package versions and construct
# a state-aware, one-line manual install command. Source only.

_package_shell_join() {
  local joined
  printf -v joined '%q ' "$@"
  printf '%s' "${joined% }"
}

rpm_file_install_state() {
  local path="$1"
  local state_name="$2"
  local -n state_ref="$state_name"
  local identity name local_evr arch extra installed
  local installed_name installed_evr installed_evr_candidate installed_arch comparison_status

  state_ref=""
  identity="$(
    rpm -qp --queryformat '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
      -- "$path" 2>/dev/null
  )" || return 1
  IFS=$'\t' read -r name local_evr arch extra <<<"$identity"
  [[ -n "$name" && -n "$local_evr" && -n "$arch" && -z "${extra:-}" ]] || return 1

  installed="$(
    rpm -q --queryformat '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
      -- "$name" 2>/dev/null
  )" || {
    state_ref="missing"
    return 0
  }

  installed_evr=""
  while IFS=$'\t' read -r installed_name installed_evr_candidate installed_arch; do
    if [[ "$installed_name" == "$name" && "$installed_arch" == "$arch" ]]; then
      installed_evr="$installed_evr_candidate"
      break
    fi
  done <<<"$installed"
  if [[ -z "$installed_evr" ]]; then
    state_ref="missing"
    return 0
  fi

  if rpmdev-vercmp "$local_evr" "$installed_evr" >/dev/null 2>&1; then
    comparison_status=0
  else
    comparison_status=$?
  fi
  case "$comparison_status" in
    0)  state_ref="same" ;;
    11) state_ref="upgrade" ;;
    12) state_ref="downgrade" ;;
    *)  return 1 ;;
  esac
}

deb_file_install_state() {
  local path="$1"
  local state_name="$2"
  local -n state_ref="$state_name"
  local name version arch installed status installed_version installed_arch

  state_ref=""
  name="$(dpkg-deb --field "$path" Package 2>/dev/null)" || return 1
  version="$(dpkg-deb --field "$path" Version 2>/dev/null)" || return 1
  arch="$(dpkg-deb --field "$path" Architecture 2>/dev/null)" || return 1
  [[ -n "$name" && -n "$version" && -n "$arch" ]] || return 1

  installed="$(
    dpkg-query -W -f='${db:Status-Abbrev}\t${Version}\t${Architecture}\n' \
      "$name" 2>/dev/null
  )" || {
    state_ref="missing"
    return 0
  }
  IFS=$'\t' read -r status installed_version installed_arch <<<"$installed"
  if [[ "$status" != ii* || "$installed_arch" != "$arch" ]]; then
    state_ref="missing"
  elif dpkg --compare-versions "$version" eq "$installed_version"; then
    state_ref="same"
  elif dpkg --compare-versions "$version" gt "$installed_version"; then
    state_ref="upgrade"
  elif dpkg --compare-versions "$version" lt "$installed_version"; then
    state_ref="downgrade"
  else
    return 1
  fi
}

arch_file_install_state() {
  local path="$1"
  local state_name="$2"
  local -n state_ref="$state_name"
  local packaged name version extra installed installed_name installed_version comparison

  state_ref=""
  packaged="$(pacman -Qp -- "$path" 2>/dev/null)" || return 1
  read -r name version extra <<<"$packaged"
  [[ -n "$name" && -n "$version" && -z "${extra:-}" ]] || return 1

  installed="$(pacman -Q -- "$name" 2>/dev/null)" || {
    state_ref="missing"
    return 0
  }
  read -r installed_name installed_version extra <<<"$installed"
  [[ "$installed_name" == "$name" && -n "$installed_version" && -z "${extra:-}" ]] || return 1

  comparison="$(vercmp "$version" "$installed_version")" || return 1
  case "$comparison" in
    0)  state_ref="same" ;;
    1)  state_ref="upgrade" ;;
    -1) state_ref="downgrade" ;;
    *)  return 1 ;;
  esac
}

package_file_install_state() {
  local family="$1"
  local path="$2"
  local state_name="$3"

  case "$family" in
    rpm)    rpm_file_install_state "$path" "$state_name" ;;
    debian) deb_file_install_state "$path" "$state_name" ;;
    arch)   arch_file_install_state "$path" "$state_name" ;;
    *)      return 1 ;;
  esac
}

_manual_package_command_for_action() {
  local family="$1"
  local action="$2"
  shift 2
  local -a words=()

  case "$family:$action" in
    rpm:missing)      words=(sudo dnf install "$@") ;;
    rpm:upgrade)      words=(sudo dnf upgrade "$@") ;;
    rpm:same)         words=(sudo dnf reinstall "$@") ;;
    rpm:downgrade)    words=(sudo dnf downgrade "$@") ;;
    debian:missing)   words=(sudo apt install "$@") ;;
    debian:upgrade)   words=(sudo apt install --only-upgrade "$@") ;;
    debian:same)      words=(sudo apt install --reinstall "$@") ;;
    debian:downgrade) words=(sudo apt install --allow-downgrades "$@") ;;
    arch:apply)       words=(sudo pacman -U "$@") ;;
    *)                return 1 ;;
  esac

  _package_shell_join "${words[@]}"
}

build_manual_package_install_command() {
  local family="$1"
  local command_name="$2"
  shift 2

  local -n command_ref="$command_name"
  local path state action group_action segment
  local -a group_paths=()

  command_ref=""
  (( $# > 0 )) || return 1

  for path in "$@"; do
    state=""
    package_file_install_state "$family" "$path" state || return 1
    if [[ "$family" == "arch" ]]; then
      # pacman -U applies a local package whether it is absent, older, equal,
      # or newer, so one transaction safely handles mixed package states.
      action="apply"
    else
      action="$state"
    fi

    if [[ -n "${group_action:-}" && "$action" != "$group_action" ]]; then
      segment="$(_manual_package_command_for_action \
        "$family" "$group_action" "${group_paths[@]}")" || return 1
      command_ref+="${command_ref:+ && }${segment}"
      group_paths=()
    fi
    group_action="$action"
    group_paths+=("$path")
  done

  segment="$(_manual_package_command_for_action \
    "$family" "$group_action" "${group_paths[@]}")" || return 1
  command_ref+="${command_ref:+ && }${segment}"
}
