# ika: the mount of Android's files and its watcher.
# Sourced by src/tools/ika, in its order; see there.

android_storage_mounted() {
  findmnt -rn -M "${1:-${ANDROID_STORAGE_DIR}}" >/dev/null 2>&1
}

# Whether 'su' gives root in the guest, as after 'ika root'.
guest_is_rooted() {
  local adb_serial="$1"

  [[ "$(guest_adb "${adb_serial}" shell "su -c 'id -u'" 2>/dev/null | tr -d '\r')" == "0" ]]
}

fuse_allows_other() {
  grep -qE '^[[:space:]]*user_allow_other[[:space:]]*$' /etc/fuse.conf 2>/dev/null
}

# Mounts Android's /sdcard on ANDROID_STORAGE_DIR with madbfs, which runs
# madbfs-server from the ROM and goes on in the background. On a rooted ROM
# (ika root) it mounts the whole filesystem, /, with the server run as root.
# Ika's adb comes first on PATH: an adb of another version would restart the
# adb server under the console.
mount_android_storage() {
  local adb_serial="$1"
  local -a root_args=(--root=/sdcard)
  local server_pkill="pkill -x madbfs-server"
  local deadline
  local mount_options

  [[ -x "${PACKAGED_MADBFS_BIN}" ]] || return 0
  if android_storage_mounted; then
    # A start that finds Android running: the shortcut in Explorer is added
    # again, as the one that mounted the storage may have failed to add it.
    edit_windows_android_storage_shortcut add "${ANDROID_STORAGE_DIR}"
    start_storage_watcher
    return 0
  fi
  if [[ "${LEGACY_ANDROID_STORAGE_DIR}" != "${ANDROID_STORAGE_DIR}" ]]; then
    unmount_android_storage_at "${LEGACY_ANDROID_STORAGE_DIR}"
  fi
  mkdir -p "${ANDROID_STORAGE_DIR}"
  if guest_is_rooted "${adb_serial}"; then
    root_args=(--root=/ --su)
    server_pkill="su -c '${server_pkill}'"
  else
    # Android mounts /sdcard some seconds after its first frame, when the
    # console opens: 6 s later on a 2-vCPU guest. madbfs gives up at once on a
    # missing root, so wait for it, for up to 30 s.
    deadline=$((SECONDS + 30))
    until guest_adb "${adb_serial}" shell 'test -d /sdcard/' >/dev/null 2>&1 \
        || (( SECONDS >= deadline )); do
      sleep 0.5
    done
    # Another start may have mounted it during the wait.
    android_storage_mounted && return 0
  fi
  # A madbfs that did not exit cleanly leaves its control socket behind, and
  # its server on Android holding the port.
  rm -f "${XDG_RUNTIME_DIR:-/tmp}/madbfs@${adb_serial}.sock"
  guest_adb "${adb_serial}" shell "${server_pkill}" >/dev/null 2>&1 || true
  trim_log_lines "${MADBFS_LOG_FILE}"
  mount_options="uid=$(id -u),gid=$(id -g),umask=022"
  # WSL serves its files to Windows as root, which FUSE keeps out of another
  # user's mount unless allowed (it needs user_allow_other in /etc/fuse.conf,
  # which ika-wsl-setup sets)
  if [[ "${IKA_ON_WSLG}" == true ]] && fuse_allows_other; then
    mount_options+=",allow_root"
  fi
  # Files show as the user's, as Android's owners mean nothing on the host and
  # file managers would treat the folders as read-only. File details are
  # re-read after 2 seconds instead of 60, so files Android apps add or change
  # show up promptly. madbfs's cache of file pages holds 64 MiB instead of 256
  # (72 MiB of memory with its dirty maps, taken as files are read): 288 MiB
  # was 7% of a 4 GB host.
  if PATH="${CVD_HOST_OUT}/bin:${PATH}" "${PACKAGED_MADBFS_BIN}" --serial="${adb_serial}" \
      "${root_args[@]}" --ttl=2 --cache-size=64 --log-file="${MADBFS_LOG_FILE}" \
      -o "${mount_options}" "${ANDROID_STORAGE_DIR}" \
      </dev/null >>"${MADBFS_LOG_FILE}" 2>&1 3>&-; then
    log "Android storage mounted on ${ANDROID_STORAGE_DIR} (${root_args[0]#--root=})"
    edit_android_storage_place add
    start_storage_watcher
  else
    log "warning: could not mount Android storage on ${ANDROID_STORAGE_DIR}; see ${MADBFS_LOG_FILE}"
  fi
}

kde_places_file() {
  printf '%s\n' "${XDG_DATA_HOME:-${HOST_HOME}/.local/share}/user-places.xbel"
}

gtk_bookmarks_file() {
  printf '%s\n' "${XDG_CONFIG_HOME:-${HOST_HOME}/.config}/gtk-3.0/bookmarks"
}

# Adds ("add") or removes ("remove") $2, or ANDROID_STORAGE_DIR, named
# "Android", in the file manager's sidebar: Dolphin and GNOME's Files list only
# disks, network shares and mounts in the home folder by themselves. On GNOME
# it goes in GTK's bookmarks. KDE's places file is only edited once it exists:
# creating it would keep KDE from adding its default places. Removing takes the
# entry out of both, whatever the desktop.
edit_android_storage_place() {
  local action="$1"
  local dir="${2:-${ANDROID_STORAGE_DIR}}"
  local places
  local bookmarks
  local kept
  local uri

  edit_windows_android_storage_shortcut "${action}" "${dir}"
  uri="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).as_uri())' \
    "${dir}")" || return 0
  bookmarks="$(gtk_bookmarks_file)"
  if [[ "${action}" == "remove" ]]; then
    if grep -qxF "${uri} Android" "${bookmarks}" 2>/dev/null \
        && kept="$(mktemp "${bookmarks}.XXXXXX")"; then
      # Rewritten in place, keeping the file's mode.
      if grep -vxF "${uri} Android" "${bookmarks}" >"${kept}" || [[ ! -s "${kept}" ]]; then
        cat "${kept}" >"${bookmarks}" || true
      fi
      rm -f "${kept}"
    fi
  elif [[ ":${XDG_CURRENT_DESKTOP:-}:" == *:GNOME:* ]] \
      && ! grep -qxF "${uri} Android" "${bookmarks}" 2>/dev/null; then
    mkdir -p "$(dirname "${bookmarks}")" \
      && printf '%s Android\n' "${uri}" >>"${bookmarks}" || true
  fi

  places="$(kde_places_file)"
  [[ -f "${places}" ]] || return 0
  python3 - "${action}" "${places}" "${uri}" <<'PY' || true
import re
import sys
action, path, uri = sys.argv[1:]
text = open(path, encoding="utf-8").read()
entry_re = re.compile(
    r'[ \t]*<bookmark href="' + re.escape(uri) + r'">.*?</bookmark>\n?', re.DOTALL)
if action == "remove":
    text, count = entry_re.subn("", text)
    if count == 0:
        sys.exit(0)
elif not entry_re.search(text):
    end = text.rindex("</xbel>")
    text = text[:end] + (
        f' <bookmark href="{uri}">\n'
        '  <title>Android</title>\n'
        '  <info>\n'
        '   <metadata owner="http://freedesktop.org">\n'
        '    <bookmark:icon name="smartphone"/>\n'
        '   </metadata>\n'
        '  </info>\n'
        ' </bookmark>\n'
    ) + text[end:]
else:
    sys.exit(0)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY
}

# On WSLg, adds ("add") or removes ("remove") "Android (Ika)" under This PC in
# Windows' Explorer: a network shortcut to $2 as Windows reaches it
# (\\wsl.localhost\DISTRO\...), with Ika's icon. Removing takes it out only
# when it leads to $2. PowerShell runs in the background, as it takes a second
# or two.
edit_windows_android_storage_shortcut() {
  local action="$1"
  local dir="$2"
  local powershell
  local target

  [[ "${IKA_ON_WSLG}" == true ]] || return 0
  powershell="$(windows_powershell)" || return 0
  target="$(wslpath -w "${dir}" 2>/dev/null)" || return 0
  mkdir -p "${CVD_TMP_DIR}"
  (
    detach_background_job 9
    flock -w 30 9 || exit 0
    with_timeout 60 "${powershell}" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -EncodedCommand "$(windows_storage_shortcut_script "${action}" "${target}" \
        | iconv -t UTF-16LE | base64 -w 0)" </dev/null >/dev/null 2>&1
  ) 9>"${CVD_TMP_DIR}/windows-storage-shortcut.lock" &
  disown "$!" 2>/dev/null || true
}

# Prints the PowerShell program of edit_windows_android_storage_shortcut for
# action $1 and target $2. A network shortcut is a read-only folder holding
# target.lnk and a desktop.ini that makes Explorer show it as the target. Its
# icon is Ika's, which ika-wsl.ps1 puts beside ika.cmd, when it is there.
windows_storage_shortcut_script() {
  local action="$1"
  local target="${2//\'/\'\'}"

  printf "\$action = '%s'\n\$target = '%s'\n" "${action}" "${target}"
  cat <<'EOF'
$dir = Join-Path $env:APPDATA 'Microsoft\Windows\Network Shortcuts\Android (Ika)'
$link = Join-Path $dir 'target.lnk'
$shell = New-Object -ComObject WScript.Shell
if ($action -eq 'remove') {
  if ((Test-Path -LiteralPath $link) -and $shell.CreateShortcut($link).TargetPath -eq $target) {
    Remove-Item -LiteralPath $dir -Recurse -Force
  }
  exit
}
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$icon = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\ika.ico'
$iconLines = ''
if (Test-Path -LiteralPath $icon) {
  $iconLines = "`r`nIconResource=$icon,0`r`nIconFile=$icon`r`nIconIndex=0"
}
$shortcut = $shell.CreateShortcut($link)
$shortcut.TargetPath = $target
if ($iconLines) { $shortcut.IconLocation = "$icon,0" }
$shortcut.Save()
$ini = Join-Path $dir 'desktop.ini'
if (Test-Path -LiteralPath $ini) { (Get-Item -LiteralPath $ini -Force).Attributes = 'Normal' }
Set-Content -LiteralPath $ini -Value "[.ShellClassInfo]`r`nCLSID2={0AFACED1-E828-11D1-9187-B532F1E9575D}`r`nFlags=2$iconLines"
(Get-Item -LiteralPath $ini -Force).Attributes = 'Hidden, System'
(Get-Item -LiteralPath $dir -Force).Attributes = 'ReadOnly, Directory'
EOF
}

# Unmounts Android's storage from $1: lazily when a program still has a file
# open there, so that does not hold the VM up. madbfs then gets a few seconds to
# write out what it has cached and exit; one kept alive by such a program is
# ended, as the device it serves is going away.
unmount_android_storage_at() {
  local dir="$1"
  local pattern="^${PACKAGED_MADBFS_BIN} .* ${dir}\$"
  local deadline

  if android_storage_mounted "${dir}"; then
    fusermount3 -u "${dir}" >/dev/null 2>&1 \
      || fusermount3 -u -z "${dir}" >/dev/null 2>&1 \
      || log "warning: could not unmount ${dir}"
  fi
  deadline="$(make_deadline 5)"
  while pgrep -f "${pattern}" >/dev/null && within_deadline "${deadline}"; do
    sleep 0.2
  done
  pkill -KILL -f "${pattern}" 2>/dev/null || true
  edit_android_storage_place remove "${dir}"
}

# Unmounts Android's storage once the VM has stopped by itself, as when Android
# is turned off from its own menu: otherwise it stays mounted, on a device that
# is gone, until the next ika start or stop. Started with the mount; stop,
# restart and reset end it before they unmount.
run_storage_watcher() {
  local lock_fd

  exec {lock_fd}>"${STORAGE_WATCHER_LOCK_FILE}"
  flock -n "${lock_fd}" || return 0
  printf '%s\n' "$$" >"${STORAGE_WATCHER_PID_FILE}"
  trap 'exit 0' INT TERM HUP
  trap storage_watcher_cleanup EXIT
  while has_live_cvd_processes; do
    sleep "${STORAGE_WATCHER_POLL_SEC}" &
    wait "$!"
  done
  log "the Android virtual device stopped; unmounting Android's files"
  unmount_android_storage_at "${ANDROID_STORAGE_DIR}"
}

storage_watcher_cleanup() {
  if [[ -f "${STORAGE_WATCHER_PID_FILE}" \
      && "$(<"${STORAGE_WATCHER_PID_FILE}")" == "$$" ]]; then
    rm -f "${STORAGE_WATCHER_PID_FILE}"
  fi
}

start_storage_watcher() {
  supervisor_pid_from_file "${STORAGE_WATCHER_PID_FILE}" __storage_watcher >/dev/null && return 0
  mkdir -p "${CVD_TMP_DIR}"
  setsid --fork "${IKA_SCRIPT_PATH}" __storage_watcher \
    </dev/null >>"${MADBFS_LOG_FILE}" 2>&1 3>&- &
  disown || true
}

stop_storage_watcher() {
  stop_supervisor_from_file "${STORAGE_WATCHER_PID_FILE}" __storage_watcher
}

# Also from where an older Ika mounted it, and removes that folder once empty.
unmount_android_storage() {
  stop_storage_watcher
  unmount_android_storage_at "${ANDROID_STORAGE_DIR}"
  if [[ "${LEGACY_ANDROID_STORAGE_DIR}" != "${ANDROID_STORAGE_DIR}" ]]; then
    unmount_android_storage_at "${LEGACY_ANDROID_STORAGE_DIR}"
    rmdir "${LEGACY_ANDROID_STORAGE_DIR}" 2>/dev/null || true
  fi
}

