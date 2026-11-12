# ika: installing and removing apps (ika install, ika remove).
# Sourced by src/tools/ika, in its order; see there.

# ============================================================================
# Installing and removing apps (ika install, ika remove)
# ============================================================================

# Prints the package Android installed or updated last, which is the app an
# install has just added or replaced.
last_updated_package() {
  local adb_serial="$1"

  host_adb 30 -s "${adb_serial}" shell \
    "dumpsys package packages | grep -E '^  Package \\[|^    lastUpdateTime='" \
    </dev/null 2>/dev/null \
    | tr -d '\r' \
    | awk '
        /^  Package \[/ {
          package = $0
          sub(/^  Package \[/, "", package)
          sub(/\].*/, "", package)
          next
        }
        /lastUpdateTime=/ {
          updated = $0
          sub(/.*lastUpdateTime=/, "", updated)
          if (updated > newest) {
            newest = updated
            result = package
          }
        }
        END { if (result != "") print result }'
}

run_install_command() {
  local file
  local adb_serial
  local output
  local reason
  local package
  local label
  local failed=0
  local message
  local -a installed=()

  [[ $# -gt 0 ]] || die "usage: ${SCRIPT_NAME} install FILE.apk..."
  # Without a terminal (a file manager's "Ika APK installer"), report progress
  # and errors as notifications.
  if [[ ! -t 0 && ! -t 2 ]]; then
    IKA_NOTIFY="true"
  fi
  for file in "$@"; do
    [[ -f "${file}" ]] || die "${file}: no such file"
  done

  ensure_guest_ready
  adb_serial="$(resolve_adb_serial)"

  for file in "$@"; do
    log "installing ${file}"
    notify_progress "Installing $(basename -- "${file}")…"
    output="$(host_adb "${IKA_INSTALL_TIMEOUT_SEC:-1800}" -s "${adb_serial}" \
      install -r "${file}" </dev/null 2>&1 | tr -d '\r' || true)"
    close_progress_notifications
    if [[ "${output}" != *Success* ]]; then
      reason="$(grep -o 'Failure \[[^]]*\]' <<<"${output}" | head -n1 || true)"
      message="could not install $(basename -- "${file}")${reason:+ (${reason})}"
      log "error: ${message}"
      notify_user "${message}"
      failed=$((failed + 1))
      continue
    fi
    package="$(last_updated_package "${adb_serial}" || true)"
    label=""
    if [[ -n "${package}" ]]; then
      label="$(list_guest_apps "${adb_serial}" \
        | awk -F '\t' -v pkg="${package}" '$2 == pkg { print $1; exit }' || true)"
    fi
    installed+=("${label:-${package:-$(basename -- "${file}")}}")
  done

  if [[ "${#installed[@]}" -eq 1 ]]; then
    message="Installed ${installed[0]}"
  elif [[ "${#installed[@]}" -gt 1 ]]; then
    message="Installed ${#installed[@]} apps: $(printf '%s, ' "${installed[@]}")"
    message="${message%, }"
  fi
  if [[ -n "${message:-}" && "${#installed[@]}" -gt 0 ]]; then
    respond "${message}"
    notify_user "${message}"
  fi
  (( failed == 0 )) || exit 1
}

run_remove_command() {
  local name="$*"
  local adb_serial
  local resolved
  local package
  local label
  local output
  local reason

  [[ -n "${name}" ]] || die "usage: ${SCRIPT_NAME} remove NAME|PACKAGE"
  if [[ ! -t 0 && ! -t 2 ]]; then
    IKA_NOTIFY="true"
  fi

  ensure_guest_ready
  adb_serial="$(resolve_adb_serial)"

  # A package name is used as given; anything else is looked up by label.
  if is_app_package_name "${name}" && app_is_installed "${name}" "${adb_serial}"; then
    package="${name}"
    label="$(app_display_name "${package}")"
  else
    resolved="$(resolve_launchable_app "${name}" "${adb_serial}")" || exit 1
    package="${resolved#*$'\t'}"
    label="${resolved%%$'\t'*}"
  fi
  validate_app_package "${package}"

  if app_window_is_open "${package}"; then
    stop_supervisor_from_file "$(app_supervisor_file "${package}" pid)" __app_supervisor
  fi
  output="$(host_adb 120 -s "${adb_serial}" uninstall "${package}" </dev/null 2>&1 \
    | tr -d '\r' || true)"
  if [[ "${output}" != *Success* ]]; then
    if guest_adb "${adb_serial}" shell pm list packages -s "${package}" </dev/null 2>/dev/null \
        | tr -d '\r' | grep -qxF "package:${package}"; then
      die "${label} comes with Android and cannot be removed"
    fi
    reason="$(grep -o 'Failure \[[^]]*\]' <<<"${output}" | head -n1 || true)"
    die "could not remove ${label}${reason:+ (${reason})}"
  fi

  rm -rf "${IKA_APPS_DIR:?}/${package}"
  respond "Removed ${label}"
  notify_user "Removed ${label}"
}

