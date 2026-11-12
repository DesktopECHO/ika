# ika: the GSF ID, and backups (ika gsf, ika backup, ika restore).
# Sourced by src/tools/ika, in its order; see there.

# ============================================================================
# GSF ID (ika gsf)
# ============================================================================
#
# Google may block sign-in on devices that are not Play Protect certified until
# their Google Services Framework (GSF) Android ID is registered on Google's
# uncertified device page. IkaGsfId publishes that ID, in decimal, as
# sys.ika.gsf_android_id once GMS check-in has assigned it. In older images,
# IkaGsfId only finds it on userdebug builds, so when the property is not set
# 'gsf' reads it here from the dump of GMS's GCM service, as IkaGsfId now does.

readonly GSF_REGISTRATION_URL="https://www.google.com/android/uncertified"
readonly GCM_SERVICE="com.google.android.gms/.gcm.GcmService"
ika_ini_default IKA_GSF_ID_TIMEOUT_SEC timeouts gsf_id_timeout_sec 120 uint

# Copies stdin to the desktop clipboard. Returns 1 without a graphical session
# or a clipboard tool. The tools stay in the background to serve the clipboard,
# so their output goes to /dev/null rather than to a pipe a caller may read.
copy_to_clipboard() {
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then
    wl-copy >/dev/null 2>&1
  elif [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard >/dev/null 2>&1
  elif [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input >/dev/null 2>&1
  else
    return 1
  fi
}

# Opens a URL in the default browser, detached: xdg-open can wait for a browser
# it starts until the browser exits.
open_in_browser() {
  [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]] || return 1
  command -v xdg-open >/dev/null 2>&1 || return 1
  setsid xdg-open "$1" </dev/null >/dev/null 2>&1 &
}

run_gsf_id_command() {
  local adb_serial
  local deadline
  local gsf_id=""
  local waited="false"

  ensure_guest_ready
  adb_serial="$(resolve_adb_serial)"

  if ! app_is_installed com.google.android.gms "${adb_serial}"; then
    die "this Android image has no Google Play Services, so it has no GSF ID"
  fi

  # GMS check-in assigns the ID shortly after Android first reaches the network.
  deadline="$(make_deadline "${IKA_GSF_ID_TIMEOUT_SEC}")"
  while true; do
    gsf_id="$(guest_adb "${adb_serial}" shell getprop sys.ika.gsf_android_id 2>/dev/null \
      | tr -d '\r' || true)"
    if ! [[ "${gsf_id}" =~ ^[1-9][0-9]*$ ]]; then
      gsf_id="$(guest_adb "${adb_serial}" shell dumpsys activity service "${GCM_SERVICE}" 2>/dev/null \
        | tr -d '\r' | sed -n 's/^[[:space:]]*DeviceID:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1 || true)"
    fi
    [[ "${gsf_id}" =~ ^[1-9][0-9]*$ ]] && break
    within_deadline "${deadline}" \
      || die "Google Play Services has not assigned a GSF ID yet; check that Android is online and try again"
    if [[ "${waited}" != "true" ]]; then
      printf 'Waiting for Google Play Services to assign the GSF ID...\n' >&2
      waited="true"
    fi
    sleep 2
  done

  if printf '%s' "${gsf_id}" | copy_to_clipboard; then
    respond "Copied GSF ID ${gsf_id} to the clipboard."
  else
    respond "GSF ID ${gsf_id}"
  fi
  if open_in_browser "${GSF_REGISTRATION_URL}"; then
    printf 'Paste it on the registration page opened in your browser:\n' >&2
  else
    printf 'Register it on:\n' >&2
  fi
  printf '  %s\n' "${GSF_REGISTRATION_URL}" >&2
  printf "Then wait a few minutes and run '%s restart'.\n" "${SCRIPT_NAME}" >&2
}

# ============================================================================
# Backup (ika backup / ika restore)
# ============================================================================
#
# 'backup' copies what adb can reach: the APKs of the apps the user installed
# (with the installer that installed them), each app's files in
# /sdcard/Android/data and game downloads in /sdcard/Android/obb, the shared
# storage folders, and the user's choices: granted app permissions, special
# app access, default apps, apps the user disabled, the dark theme and a
# curated list of settings. App-private data in /data/data is out of adb's
# reach and left out. Because it holds APKs, files and settings rather than
# disk images, a backup survives 'reset' and ROM updates.

# Backups are named by when they were made, so the latest sorts last.
readonly BACKUP_FILE_GLOB="${CVD_HOME_DIR}/ika-backup-*.tgz"
readonly BACKUP_INFO_FILE="backup-info"
readonly -a BACKUP_STORAGE_DIRS=(DCIM Pictures Download Documents Music Movies Recordings)
# Apps not carried over: Ika installs Chromium on every new device, so a
# backed-up copy would only replace a newer one, and Magisk's app is not
# carried over to the restored device.
readonly -a BACKUP_SKIPPED_PACKAGES=(org.chromium.chrome com.topjohnwu.magisk)
# Special app access saved when an app is allowed it.
readonly -a BACKUP_APP_OPS=(
  SYSTEM_ALERT_WINDOW GET_USAGE_STATS REQUEST_INSTALL_PACKAGES
  MANAGE_EXTERNAL_STORAGE WRITE_SETTINGS SCHEDULE_EXACT_ALARM
)
readonly -a BACKUP_ROLES=(BROWSER HOME ASSISTANT DIALER SMS)
# The user's preferences, as namespace:key. Device state, IDs, timestamps and
# the desktop settings Ika applies at every boot are left out on purpose.
readonly -a BACKUP_SETTINGS=(
  system:font_scale system:time_12_24 system:pointer_speed system:screen_off_timeout
  secure:default_input_method secure:enabled_input_methods
  secure:selected_spell_checker secure:spell_checker_enabled
  secure:show_ime_with_hard_keyboard secure:long_press_timeout
  secure:accessibility_enabled secure:enabled_accessibility_services
  secure:enabled_notification_listeners
  global:window_animation_scale global:transition_animation_scale
  global:animator_duration_scale
)
# Listing and dumping every package is slow on small hosts; copies of large
# games take minutes.
ika_ini_get BACKUP_LIST_ADB_TIMEOUT_SEC timeouts backup_list_timeout_sec 120 uint
ika_ini_get BACKUP_COPY_ADB_TIMEOUT_SEC timeouts backup_copy_timeout_sec 3600 uint
readonly BACKUP_LIST_ADB_TIMEOUT_SEC BACKUP_COPY_ADB_TIMEOUT_SEC

# Prints COUNT with the singular or plural NOUN, e.g. "1 app", "3 apps".
count_noun() {
  if [[ "$1" == 1 ]]; then
    printf '%s %s\n' "$1" "$2"
  else
    printf '%s %s\n' "$1" "$3"
  fi
}

backup_adb() {
  local adb_serial="$1"
  shift
  host_adb "${BACKUP_COPY_ADB_TIMEOUT_SEC}" -s "${adb_serial}" "$@"
}

# Prints WORD quoted for a POSIX shell.
shell_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

# True when PATH is a non-empty directory on the device.
guest_dir_has_files() {
  local adb_serial="$1"
  local path="$2"

  [[ -n "$(guest_adb "${adb_serial}" shell "ls -A '${path}' 2>/dev/null" | tr -d '\r')" ]]
}

# Appends the device path PARENT/NAME to ARCHIVE as PREFIX/NAME: the device's
# tar streams it, renaming as it goes, and pigz adds it as one more gzip
# member. Files an app keeps readable only to itself are skipped, each
# reported; on any other error ARCHIVE is cut back to where it was and the
# copy fails. Adds the files copied, other than APKs, to BACKUP_FILE_COUNT.
append_guest_path() {
  local adb_serial="$1"
  local archive="$2"
  local prefix="$3"
  local parent="$4"
  local name="$5"
  local remote_err="/data/local/tmp/ika-backup-tar.err"
  local size
  local errors=""
  local skipped

  size="$(stat -c '%s' -- "${archive}")"
  if backup_adb "${adb_serial}" exec-out \
      "tar -cvf - -C '${parent}' --xform 's,^,${prefix}/,' '${name}' 2>${remote_err}; echo \"exit \$?\" >>${remote_err}" \
      </dev/null | pigz -1 >>"${archive}"; then
    errors="$(guest_adb "${adb_serial}" shell "cat ${remote_err}; rm -f ${remote_err}" \
      </dev/null | tr -d '\r')" || errors=""
  fi
  # The device's tar lists what it copied, then its exit status: 1 when it
  # skipped files, saying why.
  if ! grep -qx 'exit [01]' <<<"${errors}" \
      || grep -v -e "^${prefix}/" -e ": Permission denied$" -e "^tar: had errors$" \
        -e "^exit [01]$" <<<"${errors}" | grep -q .; then
    truncate -s "${size}" -- "${archive}"
    return 1
  fi
  while IFS= read -r skipped; do
    log "skipping ${parent}/${skipped}"
  done < <(sed -n "s/^tar: can't open '\(.*\)': Permission denied$/\1/p" <<<"${errors}")
  [[ "${prefix}" == apps/* || "${prefix}" == libs/* ]] \
    || BACKUP_FILE_COUNT=$((BACKUP_FILE_COUNT + $(grep -c "^${prefix}/.*[^/]$" <<<"${errors}" || true)))
}

# Appends DIR/NAME, written on the host, to ARCHIVE as NAME.
append_host_path() {
  local archive="$1"
  local dir="$2"
  local name="$3"

  tar -cf - -C "${dir}" "${name}" | pigz -1 >>"${archive}"
}

# Removes the temporary folder and archive of a backup or restore, however the
# command ends.
cleanup_backup_temp() {
  [[ -n "${BACKUP_STAGING_DIR:-}" ]] && rm -rf -- "${BACKUP_STAGING_DIR}"
  [[ -n "${BACKUP_ARCHIVE_TMP:-}" ]] && rm -f -- "${BACKUP_ARCHIVE_TMP}"
  return 0
}

# Prints the device's package dump: every package's state, permissions and the
# libraries it uses.
guest_package_dump() {
  local adb_serial="$1"
  local dump

  dump="$(GUEST_ADB_TIMEOUT="${BACKUP_LIST_ADB_TIMEOUT_SEC}" guest_adb "${adb_serial}" \
    shell dumpsys package packages | tr -d '\r')" || return 1
  [[ "${dump}" == *"Package ["* ]] || return 1
  printf '%s\n' "${dump}"
}

# Prints "LIBRARY<TAB>CODE_PATH" for each static shared library the packages
# in APPS (space-separated) use, from DUMP, the output of guest_package_dump.
# Android keeps such a library, Trichrome's for Chrome, as the package
# NAME_VERSION, which 'pm list packages' leaves out, and refuses to install an
# app without it.
static_libraries_used() {
  local dump="$1"
  local apps="$2"

  awk -v apps=" ${apps} " '
    /^Hidden system packages:/ { exit }
    /^  Package \[/ { pkg = $2; gsub(/[][]/, "", pkg); libs = 0; next }
    /^    codePath=/ { path[pkg] = $0; sub(/^ *codePath=/, "", path[pkg]); next }
    /^    usesStaticLibraries:/ { libs = index(apps, " " pkg " "); next }
    libs && /^      [^ ]+ version:[0-9]+$/ {
      version = $2; sub(/^version:/, "", version); used[$1 "_" version] = 1; next
    }
    { libs = 0 }
    END { for (lib in used) if (lib in path) print lib "\t" path[lib] }
  ' <<<"${dump}" | sort
}

# Writes the user's Android choices into DEST: runtime permissions granted to
# the backed-up apps (any) and to built-in apps (only those the user set),
# special app access, default apps, apps the user disabled, the dark theme and
# BACKUP_SETTINGS. APPS lists the backed-up packages, space-separated; DUMP is
# the output of guest_package_dump.
backup_device_settings() {
  local adb_serial="$1"
  local dest="$2"
  local apps="$3"
  local dump="$4"
  local op
  local pkg
  local role
  local entry
  local value

  mkdir -p "${dest}"

  awk -v apps=" ${apps} " '
    /^  Package \[/ { pkg = $2; gsub(/[][]/, "", pkg); runtime = 0; next }
    /runtime permissions:/ { runtime = 1; next }
    runtime && /^ +[A-Za-z0-9_.]+: granted=/ {
      perm = $1; sub(/:$/, "", perm)
      if ($0 !~ /granted=true/ || $0 ~ /SYSTEM_FIXED|POLICY_FIXED/) next
      if (index(apps, " " pkg " ") || $0 ~ /USER_SET/) print pkg "\t" perm
      next
    }
    runtime { runtime = 0 }
  ' <<<"${dump}" | sort -u > "${dest}/permissions.tsv"

  # Only what the user disabled (enabled=3); packages the ROM ships disabled
  # are left to the ROM.
  awk '
    /^  Package \[/ { pkg = $2; gsub(/[][]/, "", pkg); next }
    /^    User 0: / && / enabled=3 / { print pkg }
  ' <<<"${dump}" | sort -u > "${dest}/disabled.txt"

  : > "${dest}/appops.tsv"
  for op in "${BACKUP_APP_OPS[@]}"; do
    while IFS= read -r pkg; do
      [[ "${pkg}" =~ ^[A-Za-z0-9_.]+$ ]] && printf '%s\t%s\n' "${pkg}" "${op}"
    done < <(guest_adb "${adb_serial}" shell appops query-op "${op}" allow 2>/dev/null | tr -d '\r')
  done >> "${dest}/appops.tsv"

  : > "${dest}/roles.tsv"
  for role in "${BACKUP_ROLES[@]}"; do
    while IFS= read -r pkg; do
      [[ "${pkg}" =~ ^[A-Za-z0-9_.]+$ ]] && printf 'android.app.role.%s\t%s\n' "${role}" "${pkg}"
    done < <(guest_adb "${adb_serial}" shell cmd role get-role-holders "android.app.role.${role}" \
      2>/dev/null | tr -d '\r' | tr ';' '\n')
  done >> "${dest}/roles.tsv"

  guest_adb "${adb_serial}" shell cmd uimode night 2>/dev/null | tr -d '\r' \
    | sed -n 's/^Night mode: //p' > "${dest}/night-mode"

  : > "${dest}/settings.tsv"
  for entry in "${BACKUP_SETTINGS[@]}"; do
    value="$(guest_adb "${adb_serial}" shell settings get "${entry%%:*}" "${entry#*:}" | tr -d '\r')"
    [[ -n "${value}" && "${value}" != "null" ]] || continue
    printf '%s\t%s\t%s\n' "${entry%%:*}" "${entry#*:}" "${value}"
  done >> "${dest}/settings.tsv"
}

# Applies the choices saved by backup_device_settings from SRC in one adb
# shell: the commands go to a script on the device, so every value is quoted
# once and there is no round trip per entry. Entries for apps that are not
# installed, or that Android refuses, are skipped.
restore_device_settings() {
  local adb_serial="$1"
  local src="$2"
  local script
  local remote_script="/data/local/tmp/ika-restore-settings.sh"
  local pkg
  local perm
  local op
  local role
  local namespace
  local key
  local value
  local night=""

  script="${BACKUP_STAGING_DIR}/restore-settings.sh"
  {
    while IFS=$'\t' read -r role pkg; do
      printf 'cmd role add-role-holder %s %s\n' "$(shell_quote "${role}")" "$(shell_quote "${pkg}")"
    done < "${src}/roles.tsv"
    while IFS=$'\t' read -r pkg perm; do
      printf 'pm grant %s %s\n' "$(shell_quote "${pkg}")" "$(shell_quote "${perm}")"
    done < "${src}/permissions.tsv"
    while IFS=$'\t' read -r pkg op; do
      printf 'appops set %s %s allow\n' "$(shell_quote "${pkg}")" "$(shell_quote "${op}")"
    done < "${src}/appops.tsv"
    while IFS= read -r pkg; do
      printf 'pm disable-user --user 0 %s\n' "$(shell_quote "${pkg}")"
    done < "${src}/disabled.txt"
    while IFS=$'\t' read -r namespace key value; do
      printf 'settings put %s %s %s\n' \
        "$(shell_quote "${namespace}")" "$(shell_quote "${key}")" "$(shell_quote "${value}")"
    done < "${src}/settings.tsv"
    IFS= read -r night < "${src}/night-mode" || true
    case "${night}" in
      yes|no|auto) printf 'cmd uimode night %s\n' "${night}" ;;
    esac
  } | sed 's/$/ >\/dev\/null 2>\&1/' > "${script}"

  guest_adb "${adb_serial}" push "${script}" "${remote_script}" >/dev/null 2>&1 \
    && backup_adb "${adb_serial}" shell "sh ${remote_script}; rm -f ${remote_script}" >/dev/null 2>&1 \
    || log "warning: could not restore permissions and settings"
}

run_backup_command() {
  local file="${1:-${CVD_HOME_DIR}/ika-backup-$(date +%Y%m%d%H%M%S).tgz}"
  local adb_serial
  local staging
  local archive
  local listing
  local dump
  local pkg
  local installer
  local apk
  local area
  local name
  local lib
  local path
  local backed_up=0
  local -a apks=()
  local -a saved=()

  ensure_guest_ready
  adb_serial="$(resolve_adb_serial)"

  listing="$(GUEST_ADB_TIMEOUT="${BACKUP_LIST_ADB_TIMEOUT_SEC}" guest_adb "${adb_serial}" \
    shell pm list packages -3 -i | tr -d '\r')" \
    || die "could not list the installed apps"

  # Everything streams straight into the archive, one gzip member per piece,
  # each holding a tar stream; only the small files written here are staged.
  # The archive gets its name once it is complete.
  BACKUP_STAGING_DIR="$(mktemp -d "${CVD_TMP_DIR}/ika-backup.XXXXXX")"
  BACKUP_ARCHIVE_TMP="${file}.partial"
  trap cleanup_backup_temp EXIT
  staging="${BACKUP_STAGING_DIR}"
  archive="${BACKUP_ARCHIVE_TMP}"
  BACKUP_FILE_COUNT=0

  # BACKUP_INFO_FILE first, so the archive identifies itself at its start.
  {
    printf 'created\t%s\n' "$(date -Is)"
    printf 'build\t%s\n' "$(guest_adb "${adb_serial}" shell getprop ro.build.fingerprint | tr -d '\r')"
  } > "${staging}/${BACKUP_INFO_FILE}"
  : > "${archive}"
  append_host_path "${archive}" "${staging}" "${BACKUP_INFO_FILE}"

  while read -r pkg installer; do
    pkg="${pkg#package:}"
    installer="${installer#installer=}"
    [[ " ${BACKUP_SKIPPED_PACKAGES[*]} " == *" ${pkg} "* ]] && continue
    log "backing up ${pkg}"
    mapfile -t apks < <(guest_adb "${adb_serial}" shell pm path "${pkg}" </dev/null \
      | tr -d '\r' | sed -n 's/^package://p')
    (( ${#apks[@]} > 0 )) || die "could not find the APKs of ${pkg}"
    for apk in "${apks[@]}"; do
      append_guest_path "${adb_serial}" "${archive}" "apps/${pkg}" "${apk%/*}" "${apk##*/}" \
        || die "could not copy ${pkg}"
    done
    if [[ "${installer}" != "null" ]]; then
      mkdir -p "${staging}/apps/${pkg}"
      printf '%s\n' "${installer}" > "${staging}/apps/${pkg}/installer"
      append_host_path "${archive}" "${staging}" "apps/${pkg}/installer"
    fi
    for area in data obb; do
      guest_dir_has_files "${adb_serial}" "/sdcard/Android/${area}/${pkg}" </dev/null || continue
      # A running app may be writing these files; stop it so they are copied
      # whole.
      guest_adb "${adb_serial}" shell am force-stop "${pkg}" </dev/null >/dev/null 2>&1 || true
      append_guest_path "${adb_serial}" "${archive}" "${area}" "/sdcard/Android/${area}" "${pkg}" \
        && continue
      # An app's own files are a nice-to-have: the app recreates them. Game
      # downloads in obb are large to fetch again.
      [[ "${area}" == data ]] || die "could not copy /sdcard/Android/${area}/${pkg}"
      log "skipping /sdcard/Android/data/${pkg}"
    done
    saved+=("${pkg}")
    backed_up=$((backed_up + 1))
  done <<<"$(sort <<<"${listing}")"

  dump="$(guest_package_dump "${adb_serial}")" \
    || die "could not read the installed packages"

  # Saved apart from the apps, as libs/LIBRARY, so a restore installs them
  # first.
  while IFS=$'\t' read -r lib path; do
    [[ -n "${lib}" ]] || continue
    log "backing up ${lib}"
    mapfile -t apks < <(guest_adb "${adb_serial}" shell "ls $(shell_quote "${path}")" </dev/null \
      | tr -d '\r' | grep '\.apk$')
    (( ${#apks[@]} > 0 )) || die "could not find the APKs of ${lib}"
    for apk in "${apks[@]}"; do
      append_guest_path "${adb_serial}" "${archive}" "libs/${lib}" "${path}" "${apk}" \
        || die "could not copy ${lib}"
    done
  done <<<"$(static_libraries_used "${dump}" "${saved[*]}")"

  for name in "${BACKUP_STORAGE_DIRS[@]}"; do
    guest_dir_has_files "${adb_serial}" "/sdcard/${name}" || continue
    log "backing up /sdcard/${name}"
    append_guest_path "${adb_serial}" "${archive}" storage /sdcard "${name}" \
      || die "could not copy /sdcard/${name}"
  done

  log "backing up permissions and settings"
  backup_device_settings "${adb_serial}" "${staging}/settings" "${saved[*]}" "${dump}" \
    || die "could not read the permissions and settings"
  append_host_path "${archive}" "${staging}" settings

  mv -f -- "${archive}" "${file}"
  BACKUP_ARCHIVE_TMP=""

  respond "Backed up $(count_noun "${backed_up}" app apps) and $(count_noun "${BACKUP_FILE_COUNT}" file files) to ${file}."
}

run_restore_command() {
  local source="${1:-}"
  local dir
  local files
  local adb_serial
  local pkg_dir
  local pkg
  local lib_dir
  local lib
  local installer
  local area
  local src
  local installed=0
  local -a install_args=()

  if [[ -z "${source}" ]]; then
    source="$(ls -1 ${BACKUP_FILE_GLOB} 2>/dev/null | tail -n1)" || true
    [[ -n "${source}" ]] || die "no backup in ${CVD_HOME_DIR}; create one with '${SCRIPT_NAME} backup'"
  fi
  confirm "This will restore ${source}, replacing the apps, files and settings it holds on your Android virtual device" \
    "Restore aborted." || exit 1

  BACKUP_STAGING_DIR="$(mktemp -d "${CVD_TMP_DIR}/ika-restore.XXXXXX")"
  trap cleanup_backup_temp EXIT
  dir="${BACKUP_STAGING_DIR}"
  log "unpacking ${source}"
  # --ignore-zeros reads on past the end of each tar stream in the archive.
  tar -xizf "${source}" -C "${dir}" && [[ -f "${dir}/${BACKUP_INFO_FILE}" ]] \
    || die "${source} is not an Ika backup"
  # A backup has only the folders it found files for.
  files="$( { find "${dir}/data" "${dir}/obb" "${dir}/storage" -type f 2>/dev/null || true; } | wc -l)"

  ensure_guest_ready
  adb_serial="$(resolve_adb_serial)"

  # The static libraries first: Android refuses an app whose library is
  # missing. Backups made before these were saved have none.
  for lib_dir in "${dir}"/libs/*/; do
    [[ -d "${lib_dir}" ]] || continue
    lib="$(basename -- "${lib_dir}")"
    log "installing ${lib}"
    backup_adb "${adb_serial}" install-multiple -r "${lib_dir}"*.apk >/dev/null 2>&1 \
      || log "warning: could not install ${lib}"
  done

  for pkg_dir in "${dir}"/apps/*/; do
    [[ -d "${pkg_dir}" ]] || continue
    pkg="$(basename -- "${pkg_dir}")"
    # Keep the app's installer, so the store that installed it keeps updating it.
    install_args=(-r)
    installer=""
    [[ -f "${pkg_dir}installer" ]] && IFS= read -r installer < "${pkg_dir}installer"
    if [[ -n "${installer}" ]] && app_is_installed "${installer}" "${adb_serial}"; then
      install_args+=(-i "${installer}")
    fi
    log "installing ${pkg}"
    if backup_adb "${adb_serial}" install-multiple "${install_args[@]}" "${pkg_dir}"*.apk >/dev/null 2>&1; then
      installed=$((installed + 1))
    else
      log "warning: could not install ${pkg}"
    fi
  done

  # After the apps are installed, so their folders already exist.
  for area in data obb; do
    for src in "${dir}/${area}"/*/; do
      [[ -d "${src}" ]] || continue
      backup_adb "${adb_serial}" push "${src%/}" "/sdcard/Android/${area}/" >/dev/null 2>&1 \
        || log "warning: could not restore /sdcard/Android/${area}/$(basename -- "${src}")"
    done
  done
  for src in "${dir}/storage"/*/; do
    [[ -d "${src}" ]] || continue
    log "restoring /sdcard/$(basename -- "${src}")"
    backup_adb "${adb_serial}" push "${src%/}" /sdcard/ >/dev/null 2>&1 \
      || log "warning: could not restore /sdcard/$(basename -- "${src}")"
  done
  log "restoring permissions and settings"
  restore_device_settings "${adb_serial}" "${dir}/settings"
  # Let Gallery and other media apps see the restored files.
  guest_adb "${adb_serial}" shell content call --uri content://media --method scan_volume \
    --arg external_primary >/dev/null 2>&1 || true

  respond "Restored $(count_noun "${installed}" app apps) and $(count_noun "${files}" file files) from ${source}."
}

