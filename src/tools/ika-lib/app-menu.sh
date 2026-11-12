# ika: the desktop menu entries of Android apps and their watcher.
# Sourced by src/tools/ika, in its order; see there.

# ============================================================================
# Desktop menu entries for guest apps (ika app sync)
# ============================================================================
#
# Each launchable app gets ~/.local/share/applications/ika-PACKAGE.desktop.
# Its file name matches the app window's Wayland app ID (SDL_APP_ID), so
# GNOME Shell and KWin associate open app windows with their launcher. The
# launchers are grouped as "Android Apps (Ika)": KDE Plasma, XFCE, Cinnamon
# and MATE read a freedesktop menu-merge file, while GNOME Shell, which
# ignores menu files, gets an app-grid folder matching the same category.

IKA_MENU_NAME="Android Apps (Ika)"
IKA_MENU_ID="ika-android-apps"
IKA_MENU_CATEGORY="X-Ika-Android"
IKA_MENU_ICON="ika-scrcpy"
# 256 pixels, the largest image a Windows icon holds: WSLg gives the Start menu
# an app's icon at the size of its file, and Windows scales it down from there
IKA_MENU_ICON_SIZE="256"
IKA_MENU_VERSION="5"

app_menu_icon_dir() {
  printf '%s/icons\n' "${IKA_APPS_DIR}"
}

# Renders every launchable app's icon inside the guest with the IkaAppIcons
# helper in the scrcpy-server jar, and stores them as ICON_DIR/PACKAGE-HASH.png.
# The content hash changes the launcher's Icon path whenever an app's icon
# changes, so desktop icon caches never show a stale one. On success, icons of
# apps that are no longer launchable are removed.
export_app_icons() {
  local adb_serial="$1"
  local icon_dir
  local server_jar="${SCRCPY_SERVER_PATH_OVERRIDE:-${PACKAGED_SCRCPY_SERVER}}"
  local remote_jar="/data/local/tmp/ika-app-icons.jar"
  local remote_dir="/data/local/tmp/ika-app-icons"
  local staging
  local png
  local package
  local hash
  local dest
  local -A keep=()

  if [[ ! -f "${server_jar}" ]]; then
    log "scrcpy-server not found at ${server_jar}; keeping existing app icons"
    return 1
  fi

  icon_dir="$(app_menu_icon_dir)"
  staging="$(mktemp -d "${CVD_TMP_DIR}/app-icons.XXXXXX")"
  if ! guest_adb "${adb_serial}" push -q "${server_jar}" "${remote_jar}" >/dev/null \
      || ! GUEST_ADB_TIMEOUT=60 guest_adb "${adb_serial}" shell \
          "rm -rf ${remote_dir} && CLASSPATH=${remote_jar} app_process / com.genymobile.scrcpy.IkaAppIcons ${remote_dir} ${IKA_MENU_ICON_SIZE}" >/dev/null \
      || ! GUEST_ADB_TIMEOUT=60 guest_adb "${adb_serial}" pull -q "${remote_dir}" "${staging}/icons" >/dev/null; then
    guest_adb "${adb_serial}" shell "rm -rf ${remote_dir} ${remote_jar}" >/dev/null 2>&1 || true
    rm -rf "${staging}"
    log "could not render app icons in the guest; keeping existing app icons"
    return 1
  fi
  guest_adb "${adb_serial}" shell "rm -rf ${remote_dir} ${remote_jar}" >/dev/null 2>&1 || true

  if [[ -f "${staging}/icons/games.list" ]]; then
    mkdir -p "${IKA_APPS_DIR}"
    mv -f "${staging}/icons/games.list" "${APP_GAMES_FILE}"
  fi

  mkdir -p "${icon_dir}"
  for png in "${staging}/icons"/*.png; do
    [[ -f "${png}" ]] || continue
    package="$(basename "${png}" .png)"
    is_app_package_name "${package}" || continue
    is_hidden_app "${package}" && continue
    hash="$(sha256sum < "${png}" | cut -c1-12)"
    dest="${icon_dir}/${package}-${hash}.png"
    if [[ ! -f "${dest}" ]]; then
      mv -f "${png}" "${dest}"
    fi
    keep["${dest}"]=1
  done
  rm -rf "${staging}"

  for png in "${icon_dir}"/*.png; do
    [[ -f "${png}" && -z "${keep[${png}]:-}" ]] && rm -f "${png}"
  done
  return 0
}

# Prints the icon for PACKAGE: its rendered PNG when there is one, otherwise
# the generic Ika icon.
app_menu_icon() {
  local package="$1"
  local -a icons=("$(app_menu_icon_dir)/${package}"-*.png)

  if [[ -f "${icons[0]}" ]]; then
    printf '%s\n' "${icons[0]}"
  else
    printf '%s\n' "${IKA_MENU_ICON}"
  fi
}

app_menu_data_dir() {
  printf '%s\n' "${XDG_DATA_HOME:-${HOME}/.local/share}"
}

app_menu_config_dir() {
  printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}"
}

# Writes stdin to PATH only when the content differs, so menus that watch
# these directories are not refreshed needlessly.
write_file_if_changed() {
  local path="$1"
  local content

  content="$(cat)"
  if [[ -f "${path}" ]] && [[ "$(<"${path}")" == "${content}" ]]; then
    return 1
  fi
  mkdir -p "$(dirname "${path}")"
  printf '%s\n' "${content}" > "${path}"
}

# On WSLg, gives the console the desktop entry of its app ID (see
# console_app_id), ika-DISTRIBUTION.desktop, a copy of ika.desktop, in the
# user's applications directory, where WSLg reads it once ika-wsl-setup has
# linked it. An ika.desktop there with Hidden=true takes ika.desktop's own out
# of the Windows Start menu, which WSLg reads first; both are named Ika
# Console, and WSLg names a Start menu shortcut after the entry's Name. When
# ika-base is installed again, WSLg reads ika.desktop anew, and its shortcut
# takes the console entry's place: hiding it again removes that shortcut, so
# the console entry is written again after it. An entry for another name of
# the distribution, since renamed, goes first. WSLg looks an icon given by name
# up at 128 pixels at most, so the entry names the console's icon by the path
# of its 256-pixel one. Does nothing outside WSLg, or when WSLg does not read
# the user's entries.
IKA_WSLG_CONSOLE_ICON="/usr/share/icons/hicolor/256x256/apps/ika-scrcpy.png"

write_wslg_console_entry() {
  local system_entry="${IKA_DESKTOP_ENTRY}"
  local dir="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
  local distro
  local entry
  local hidden
  local file
  local -a icon_edit=()

  distro="$(wslg_distro_id)"
  [[ -n "${distro}" && -f "${system_entry}" ]] || return 0
  wslg_reads_user_applications || return 0
  entry="${dir}/ika-${distro}.desktop"
  hidden="${dir}/ika.desktop"
  mkdir -p "${dir}"

  for file in "${dir}"/ika-*.desktop; do
    if [[ "${file}" != "${entry}" ]] && grep -qx 'X-Ika-Console=true' "${file}" 2>/dev/null; then
      rm -f "${file}"
    fi
  done
  # dpkg gives an installed file the time it has in the package; the time of
  # its last change of status is that of its installation.
  if [[ ! -f "${hidden}" ]] \
      || (( $(stat -c %Z "${system_entry}") > $(stat -c %Y "${hidden}") )); then
    printf '[Desktop Entry]\nType=Application\nName=Ika Console\nHidden=true\n' > "${hidden}"
    rm -f "${entry}"
  fi
  if [[ -f "${IKA_WSLG_CONSOLE_ICON}" ]]; then
    icon_edit=(-e "s|^Icon=ika-scrcpy\$|Icon=${IKA_WSLG_CONSOLE_ICON}|")
  fi
  sed -e "s/^StartupWMClass=.*/StartupWMClass=ika-${distro}\nX-Ika-Console=true/" \
      ${icon_edit[@]+"${icon_edit[@]}"} "${system_entry}" \
    | write_file_if_changed "${entry}" || true
}

# Rewrites APP_GAMES_FILE from the guest's game mode service, for the apps in
# LIST (LABEL<TAB>PACKAGE lines). Keeps the old file if the guest can't answer.
refresh_app_games_file() {
  local adb_serial="$1"
  local list="$2"
  local label
  local package
  local packages=""
  local output

  while IFS=$'\t' read -r label package; do
    is_app_package_name "${package}" && packages+=" ${package}"
  done <<<"${list}"
  [[ -n "${packages}" ]] || return 0

  output="$(GUEST_ADB_TIMEOUT=60 guest_adb "${adb_serial}" shell \
    "for p in${packages}; do cmd game list-modes \$p 2>/dev/null | grep -q 'current mode' && echo \$p; done; echo ika-games-done" \
    </dev/null 2>/dev/null)" || return 0
  [[ "${output}" == *ika-games-done* ]] || return 0
  mkdir -p "${IKA_APPS_DIR}"
  grep -v '^ika-games-done' <<<"${output//$'\r'/}" | grep -v '^$' > "${APP_GAMES_FILE}" || true
}

# Prints the launcher's menu name: the app label, marked as a game or an app.
# On WSLg the name becomes a Windows Start menu shortcut's file name, which
# cannot hold \ / : * ? " < > |; WSLg skips the app then (Destiny: Rising,
# Desktop/TV). There each takes a look-alike character instead.
app_launcher_name() {
  local label="$1"
  local package="$2"

  if [[ "${IKA_ON_WSLG}" == true ]]; then
    label="${label//\\/⧵}"
    label="${label//\//∕}"
    label="${label//:/꞉}"
    label="${label//\*/∗}"
    label="${label//\?/？}"
    label="${label//\"/＂}"
    label="${label//</‹}"
    label="${label//>/›}"
    label="${label//|/∣}"
  fi
  if is_game_app "${package}"; then
    printf '🎮 ∙ %s\n' "${label}"
  else
    printf '∙ %s\n' "${label}"
  fi
}

# Prints a desktop entry string value as desktop-file-edit writes it: with each
# backslash doubled. Launcher keys are compared in that form.
desktop_entry_escape() {
  printf '%s\n' "${1//\\/\\\\}"
}

# Prints the value of KEY in the [Desktop Action ID] group of the launcher
# FILE, if it has one.
launcher_action_value() {
  awk -v group="[Desktop Action $2]" -v key="$3" '
    /^\[/ { in_group = ($0 == group); next }
    in_group && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$1"
}

# Whether the launcher of PACKAGE in APPS_DIR is as write_app_launcher writes
# it for LABEL and ICON.
app_launcher_is_current() {
  local apps_dir="$1"
  local label="$2"
  local package="$3"
  local icon="$4"
  local file="${apps_dir}/$(app_window_id "${package}").desktop"

  [[ -f "${file}" ]] \
    && grep -qxF "Name=$(desktop_entry_escape "$(app_launcher_name "${label}" "${package}")")" "${file}" \
    && grep -qxF "Icon=${icon}" "${file}" \
    && grep -qxF "Actions=$(app_launcher_actions "${package}")" "${file}" \
    && ! grep -qxF "[Desktop Action controller]" "${file}" \
    && grep -qxF "SingleMainWindow=true" "${file}" \
    && grep -qxF "[Desktop Action new-window]" "${file}" \
    && grep -qxF "Name=Launch app" "${file}" \
    && grep -qxF "Name=Startup options" "${file}" \
    && grep -qxF "Name=App info" "${file}" \
    && grep -qxF "Exec=ika app --options ${package}" "${file}" \
    && grep -qxF "Exec=ika app --info ${package}" "${file}" \
    && grep -qxF "Icon=$(app_menu_icon com.android.settings)" "${file}" \
    && [[ "$(launcher_action_value "${file}" new-window Icon)" == "${IKA_MENU_ICON}" ]] \
    && [[ "$(launcher_action_value "${file}" options Icon)" == "${IKA_MENU_ICON}" ]] \
    && grep -qxF "X-Ika-Package=${package}" "${file}" \
    && grep -qxF "X-Ika-Version=${IKA_MENU_VERSION}" "${file}" \
    && grep -qE "^Categories=(.*;)?${IKA_MENU_CATEGORY}(;|$)" "${file}"
}

# The launcher's actions, the same for games and other apps.
app_launcher_actions() {
  printf 'new-window;options;app-settings;\n'
}

# Creates or updates one launcher and returns 1 when it was already current.
# Existing launchers are edited in place, keeping any keys the user added.
write_app_launcher() {
  local apps_dir="$1"
  local label="$2"
  local package="$3"
  local icon="$4"
  local file="${apps_dir}/$(app_window_id "${package}").desktop"
  local name
  local keywords="${label//;/ };${package};Android;Ika;"
  local settings_icon
  local actions

  actions="$(app_launcher_actions "${package}")"

  if app_launcher_is_current "${apps_dir}" "${label}" "${package}" "${icon}"; then
    return 1
  fi
  name="$(app_launcher_name "${label}" "${package}")"
  settings_icon="$(app_menu_icon com.android.settings)"

  if command -v desktop-file-edit >/dev/null 2>&1; then
    if [[ ! -f "${file}" ]]; then
      printf '[Desktop Entry]\nType=Application\n' > "${file}"
    fi
    # The action groups must exist before desktop-file-edit validates the
    # Actions key.
    set_launcher_actions "${file}" "${package}" "${settings_icon}"
    desktop-file-edit \
      --set-name="${name}" \
      --set-key=Exec --set-value="ika app ${package}" \
      --set-icon="${icon}" \
      --set-key=Terminal --set-value=false \
      --set-key=StartupWMClass --set-value="$(app_window_id "${package}")" \
      --set-key=SingleMainWindow --set-value=true \
      --set-key=Keywords --set-value="${keywords}" \
      --set-key=Actions --set-value="${actions}" \
      --add-category="${IKA_MENU_CATEGORY}" \
      --set-key=X-Ika-Package --set-value="${package}" \
      --set-key=X-Ika-Version --set-value="${IKA_MENU_VERSION}" \
      "${file}"
  else
    cat > "${file}" <<EOF
[Desktop Entry]
Type=Application
Name=$(desktop_entry_escape "${name}")
Exec=ika app ${package}
Icon=${icon}
Terminal=false
StartupWMClass=$(app_window_id "${package}")
SingleMainWindow=true
Keywords=$(desktop_entry_escape "${keywords}")
Actions=${actions}
Categories=${IKA_MENU_CATEGORY};
X-Ika-Package=${package}
X-Ika-Version=${IKA_MENU_VERSION}
EOF
    set_launcher_actions "${file}" "${package}" "${settings_icon}"
  fi
}

# Writes the launcher's right-click actions: "Launch app", which opens the
# app, "Startup options", which opens the app's start options window, both
# with the Ika icon, and "App info", which opens Android's App info page for
# the app, with the Settings app's (KDE Plasma's menu shows an action's icon
# beside it, GNOME Shell's none). An app has one
# window (SingleMainWindow), and GNOME Shell offers "New Window" for an app
# that is not running whatever the launcher says, unless it has an action of
# its own with that ID: "Launch app" is that action. It also removes the
# "touch" action, since touch input is a start option, and the "Controller
# mapping..." action games had ('ika app --controller NAME' opens it).
set_launcher_actions() {
  local file="$1"
  local package="$2"
  local settings_icon="$3"

  set_launcher_action "${file}" touch "" ""
  set_launcher_action "${file}" controller "" ""
  set_launcher_action "${file}" new-window "Launch app" "ika app ${package}" \
    "${IKA_MENU_ICON}"
  set_launcher_action "${file}" options "Startup options" \
    "ika app --options ${package}" "${IKA_MENU_ICON}"
  set_launcher_action "${file}" app-settings "App info" \
    "ika app --info ${package}" "${settings_icon}"
}

# Writes the launcher's action ID, named NAME, running EXEC, with ICON if given,
# or removes it when EXEC is empty. desktop-file-edit only edits the main
# group, so the action group is replaced here, at the end of the file, without
# leaving blank lines behind.
set_launcher_action() {
  local file="$1"
  local id="$2"
  local name="$3"
  local exec="$4"
  local icon="${5:-}"

  {
    awk -v group="[Desktop Action ${id}]" '
      /^\[/ { skip = ($0 == group) }
      skip { next }
      /^[[:space:]]*$/ { blanks = blanks $0 "\n"; next }
      { printf "%s", blanks; blanks = ""; print }' "${file}"
    if [[ -n "${exec}" ]]; then
      printf '\n[Desktop Action %s]\nName=%s\nExec=%s\n' "${id}" "${name}" "${exec}"
      if [[ -n "${icon}" ]]; then
        printf 'Icon=%s\n' "${icon}"
      fi
    fi
  } > "${file}.tmp"
  mv -f "${file}.tmp" "${file}"
}

# Prints the launchers created by ika, identified by their X-Ika-Version key.
list_app_launchers() {
  local file

  for file in "$(app_menu_data_dir)"/applications/ika-*.desktop; do
    [[ -f "${file}" ]] || continue
    grep -q '^X-Ika-Version=' "${file}" && printf '%s\n' "${file}"
  done
  return 0
}

app_menu_merge_file() {
  printf '%s/menus/applications-merged/%s.menu\n' "$(app_menu_config_dir)" "${IKA_MENU_ID}"
}

app_menu_directory_file() {
  printf '%s/desktop-directories/%s.directory\n' "$(app_menu_data_dir)" "${IKA_MENU_ID}"
}

install_xdg_app_menu() {
  write_file_if_changed "$(app_menu_directory_file)" <<EOF || true
[Desktop Entry]
Type=Directory
Name=${IKA_MENU_NAME}
Icon=${IKA_MENU_ICON}
EOF

  write_file_if_changed "$(app_menu_merge_file)" <<EOF || true
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
 "http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">
<Menu>
  <Name>Applications</Name>
  <Menu>
    <Name>${IKA_MENU_NAME}</Name>
    <Directory>${IKA_MENU_ID}.directory</Directory>
    <Include>
      <Category>${IKA_MENU_CATEGORY}</Category>
    </Include>
  </Menu>
</Menu>
EOF
}

# Prints the desktop session's bus. The app menu watcher and commands run over
# SSH lack DBUS_SESSION_BUS_ADDRESS, so fall back to the user bus socket.
app_menu_session_bus() {
  local socket="${XDG_RUNTIME_DIR:-/run/user/${UID}}/bus"

  if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    printf '%s\n' "${DBUS_SESSION_BUS_ADDRESS}"
  elif [[ -S "${socket}" ]]; then
    printf 'unix:path=%s\n' "${socket}"
  else
    return 1
  fi
}

# GNOME Shell settings are only usable inside a desktop session. grep reads
# the whole schema list: with -q it could exit first, and gsettings' SIGPIPE
# would fail the pipeline under pipefail, skipping the folder setup.
gnome_app_folders_available() {
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || return 1
  command -v gsettings >/dev/null 2>&1 || return 1
  gsettings list-schemas 2>/dev/null | grep -x 'org.gnome.desktop.app-folders' >/dev/null
}

gnome_app_folder_schema() {
  printf 'org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/%s/\n' \
    "${1:-${IKA_MENU_ID}}"
}

# Prints the items of a gsettings string array ("['a', 'b']" or "@as []"), one
# per line. Desktop file IDs contain neither quotes nor commas.
gsettings_strv_items() {
  local value="$1"
  local item
  local -a items=()

  value="${value#@as }"
  value="${value#[}"
  value="${value%]}"
  IFS=',' read -r -a items <<<"${value}"
  for item in "${items[@]+"${items[@]}"}"; do
    item="${item# }"
    item="${item#\'}"
    item="${item%\'}"
    [[ -z "${item}" ]] || printf '%s\n' "${item}"
  done
}

# Formats the lines read from stdin as a gsettings string array.
gsettings_strv() {
  local item
  local value=""

  while IFS= read -r item; do
    [[ -n "${item}" ]] && value+="${value:+, }'${item}'"
  done
  if [[ -n "${value}" ]]; then
    printf '[%s]\n' "${value}"
  else
    printf '@as []\n'
  fi
}

# Prints a folder's string array key without the Ika launchers in it.
gsettings_strv_without_launchers() {
  gsettings_strv_items "$(gsettings get "$1" "$2")" \
    | { grep -v '^ika-.*\.desktop$' || true; }
}

# Creates the GNOME Shell app-grid folder and puts the given launchers
# (desktop file IDs) in it. Matching on the category alone is not enough:
# when an app is installed, GNOME Shell refreshes its folders from the app
# list it had before the install (js/ui/appDisplay.js, AppDisplay._redisplay),
# so a new launcher would appear in the main grid. Listing the launchers in the
# folder's 'apps' key, before they are written, avoids that. Launchers dragged
# out of the folder, or into another folder, are moved back.
install_gnome_app_folder() {
  local bus
  local schema
  local children
  local folder
  local folder_schema
  local current
  local wanted

  bus="$(app_menu_session_bus)" || return 0
  local -x DBUS_SESSION_BUS_ADDRESS="${bus}"
  gnome_app_folders_available || return 0
  schema="$(gnome_app_folder_schema)"

  if [[ "$(gsettings get "${schema}" name)" != "'${IKA_MENU_NAME}'" ]]; then
    gsettings set "${schema}" name "'${IKA_MENU_NAME}'"
  fi
  if [[ "$(gsettings get "${schema}" categories)" != "['${IKA_MENU_CATEGORY}']" ]]; then
    gsettings set "${schema}" categories "['${IKA_MENU_CATEGORY}']"
  fi
  if [[ "$(gsettings get "${schema}" translate)" != "false" ]]; then
    gsettings set "${schema}" translate false
  fi

  children="$(gsettings get org.gnome.desktop.app-folders folder-children)"
  if [[ "${children}" != *"'${IKA_MENU_ID}'"* ]]; then
    if [[ "${children}" == "@as []" || "${children}" == "[]" ]]; then
      children="['${IKA_MENU_ID}']"
    else
      children="${children%]}, '${IKA_MENU_ID}']"
    fi
    gsettings set org.gnome.desktop.app-folders folder-children "${children}"
  fi

  current="$(gsettings_strv_items "$(gsettings get "${schema}" apps)" | gsettings_strv)"
  wanted="$( { gsettings_strv_without_launchers "${schema}" apps; printf '%s\n' "$@"; } \
    | gsettings_strv)"
  if [[ "${wanted}" != "${current}" ]]; then
    gsettings set "${schema}" apps "${wanted}"
  fi
  current="$(gsettings_strv_items "$(gsettings get "${schema}" excluded-apps)" | gsettings_strv)"
  wanted="$(gsettings_strv_without_launchers "${schema}" excluded-apps | gsettings_strv)"
  if [[ "${wanted}" != "${current}" ]]; then
    gsettings set "${schema}" excluded-apps "${wanted}"
  fi

  for folder in $(gsettings_strv_items "${children}"); do
    [[ "${folder}" != "${IKA_MENU_ID}" ]] || continue
    folder_schema="$(gnome_app_folder_schema "${folder}")"
    current="$(gsettings get "${folder_schema}" apps 2>/dev/null)" || continue
    if [[ "${current}" == *"'ika-"*".desktop'"* ]]; then
      gsettings set "${folder_schema}" apps \
        "$(gsettings_strv_without_launchers "${folder_schema}" apps | gsettings_strv)"
    fi
  done
}

# Seconds GNOME Shell gets to destroy a folder that was taken out of the app
# grid, before the folder's settings are reset.
GNOME_APP_FOLDER_SETTLE_SEC=2

gnome_shell_running() {
  pgrep -u "${UID}" -x gnome-shell >/dev/null 2>&1
}

# Takes the folder out of the app grid, and resets its settings.
#
# The shell's folder dialog (AppFolderDialog) saves the name typed in its entry
# when it closes, and a folder icon that turns invisible closes it (vfunc_unmap
# -> popdown() -> _maybeUpdateFolderName()). With the dialog open, resetting the
# folder's settings in one go empties the folder and resets its name: the icon
# hides, the dialog writes its old name back, the write runs the icon's change
# handler inside the unmap, and the shell destroys the grid under it
# ("clutter_actor_set_mapped: assertion '!CLUTTER_ACTOR_IN_MAP_UNMAP'", then
# gnome-shell aborts, ending the session). The dialog also never disconnects
# from the folder's name setting, so a name changed after the folder is gone
# is written into destroyed labels.
#
# So the folder leaves 'folder-children' first, with its settings as they are,
# and is given a moment to be destroyed; the settings are reset afterwards, the
# name excepted. Without a running shell nothing reacts, and all of it goes.
remove_gnome_app_folder() {
  local bus
  local children
  local key
  local schema
  local item="'${IKA_MENU_ID}'"
  local removed=false

  bus="$(app_menu_session_bus)" || return 0
  local -x DBUS_SESSION_BUS_ADDRESS="${bus}"
  gnome_app_folders_available || return 0
  schema="$(gnome_app_folder_schema)"

  children="$(gsettings get org.gnome.desktop.app-folders folder-children)"
  if [[ "${children}" == *"${item}"* ]]; then
    children="${children//", ${item}"/}"
    children="${children//"${item}, "/}"
    children="${children//"${item}"/}"
    if [[ "${children}" == "[]" ]]; then
      children="@as []"
    fi
    gsettings set org.gnome.desktop.app-folders folder-children "${children}"
    removed=true
  fi

  if gnome_shell_running; then
    [[ "${removed}" == false ]] || sleep "${GNOME_APP_FOLDER_SETTLE_SEC}"
    while IFS= read -r key; do
      [[ -n "${key}" && "${key}" != "name" ]] || continue
      gsettings reset "${schema}" "${key}"
    done < <(gsettings list-keys "${schema}")
  elif command -v dconf >/dev/null 2>&1; then
    dconf reset -f "/org/gnome/desktop/app-folders/folders/${IKA_MENU_ID}/"
  else
    gsettings reset-recursively "${schema}"
  fi
}

# Rebuilds desktop caches: the MIME cache, and KDE's ksycoca, which Plasma's
# menus read instead of rescanning launcher files.
refresh_app_menu_caches() {
  local kbuildsycoca

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q "$(app_menu_data_dir)/applications" || true
  fi
  for kbuildsycoca in kbuildsycoca6 kbuildsycoca5; do
    if command -v "${kbuildsycoca}" >/dev/null 2>&1; then
      "${kbuildsycoca}" >/dev/null 2>&1 || true
      break
    fi
  done
}

# GNOME Shell keeps an app-grid icon, label included, for as long as its app
# stays installed, and reloads a launcher changed in place only when its name,
# command or icon changes, so a launcher updated in place would keep showing
# its old name, or its old right-click actions. Launchers that change are
# therefore moved out of the applications directory until GNOME Shell has
# dropped them, updated there, and moved back as new apps. WSLg likewise
# names a Windows Start menu shortcut once, when the launcher appears, and
# updates it in place. Prints the number of launchers updated.
refresh_changed_launchers() {
  local apps_dir="$1"
  local list="$2"
  local label
  local package
  local file
  local parked
  local -a labels=()
  local -a packages=()
  local i

  if [[ "${IKA_ON_WSLG}" != true ]] && ! pgrep -u "${UID}" -x gnome-shell >/dev/null 2>&1; then
    printf '0\n'
    return 0
  fi

  while IFS=$'\t' read -r label package; do
    is_app_package_name "${package}" || continue
    file="${apps_dir}/$(app_window_id "${package}").desktop"
    if [[ -f "${file}" ]] && grep -q '^X-Ika-Version=' "${file}" \
        && ! app_launcher_is_current "${apps_dir}" "${label}" "${package}" \
          "$(app_menu_icon "${package}")"; then
      labels+=("${label}")
      packages+=("${package}")
    fi
  done <<<"${list}"

  if [[ "${#packages[@]}" -eq 0 ]]; then
    printf '0\n'
    return 0
  fi

  parked="$(mktemp -d "${CVD_TMP_DIR}/changed-launchers.XXXXXX")"
  for package in "${packages[@]}"; do
    mv -f "${apps_dir}/$(app_window_id "${package}").desktop" "${parked}/"
  done
  refresh_app_menu_caches
  # GNOME Shell processes app changes asynchronously and rate-limits them.
  sleep 3
  for i in "${!packages[@]}"; do
    write_app_launcher "${parked}" "${labels[i]}" "${packages[i]}" \
      "$(app_menu_icon "${packages[i]}")" || true
    mv -f "${parked}/$(app_window_id "${packages[i]}").desktop" "${apps_dir}/"
  done
  rmdir "${parked}" 2>/dev/null || true
  printf '%s\n' "${#packages[@]}"
}

sync_app_menu() {
  local adb_serial
  local apps_dir
  local list
  local label
  local package
  local file
  local updated=0
  local removed=0
  local icons="unchanged"
  local sync_lock_fd
  local -A current=()
  local -a desktop_ids=()

  require_executable "${SCRCPY_BIN}" "console client"
  has_live_cvd_processes || die "Android virtual device not running; start it with '${SCRIPT_NAME} start'"
  adb_serial="$(resolve_adb_serial)"
  adb_boot_completed "${adb_serial}" || die "Android virtual device has not finished booting"

  # The app menu watcher and a manual sync must not write the same files.
  exec {sync_lock_fd}>"${APP_MENU_SYNC_LOCK_FILE}"
  flock -w 120 "${sync_lock_fd}" || die "another app menu sync is still running"

  list="$(list_guest_apps "${adb_serial}")"
  [[ -n "${list}" ]] || die "could not list apps from the Android virtual device"

  if export_app_icons "${adb_serial}"; then
    icons="rendered"
  else
    # The icon helper also lists the games; without it, a game installed since
    # its last run would be named as an app.
    refresh_app_games_file "${adb_serial}" "${list}"
  fi

  apps_dir="$(app_menu_data_dir)/applications"
  mkdir -p "${apps_dir}"
  # A launcher named for the other side of WSLg (see app_window_id) goes
  # before its replacement is written: WSLg names the Windows Start menu
  # shortcut after the launcher's Name, which both have, and removing the old
  # launcher afterwards would take the new one's shortcut with it.
  while read -r file; do
    package="$(sed -n 's/^X-Ika-Package=//p' "${file}" | head -n1)"
    if [[ -n "${package}" && "${file##*/}" != "$(app_window_id "${package}").desktop" ]]; then
      rm -f "${file}"
      removed=$((removed + 1))
    fi
  done < <(list_app_launchers)
  # Set up the group, with every launcher in it, before any launcher is
  # written: an app whose launcher appears first can end up outside it.
  # Launchers the user hid stay out of the GNOME folder's explicit list.
  while IFS=$'\t' read -r label package; do
    is_app_package_name "${package}" || continue
    file="${apps_dir}/$(app_window_id "${package}").desktop"
    if [[ ! -f "${file}" ]] || ! grep -qx 'NoDisplay=true' "${file}"; then
      desktop_ids+=("$(app_window_id "${package}").desktop")
    fi
  done <<<"${list}"
  install_xdg_app_menu
  install_gnome_app_folder "${desktop_ids[@]+"${desktop_ids[@]}"}"

  # The launchers of apps no longer listed go before any is written, for the
  # same reason: an app gone from the list can share its Name, and so its
  # Start menu shortcut, with one still there (Android TV's Settings and
  # Android's are both "Settings").
  while IFS=$'\t' read -r label package; do
    is_app_package_name "${package}" && current["${package}"]=1
  done <<<"${list}"
  while read -r file; do
    [[ -n "${file}" ]] || continue
    package="$(sed -n 's/^X-Ika-Package=//p' "${file}" | head -n1)"
    if [[ -z "${package}" || -z "${current[${package}]:-}" ]]; then
      rm -f "${file}"
      removed=$((removed + 1))
    fi
  done < <(list_app_launchers)

  updated="$(refresh_changed_launchers "${apps_dir}" "${list}")"
  while IFS=$'\t' read -r label package; do
    is_app_package_name "${package}" || continue
    # A game added to the menu starts with its default start options
    # ticked, fullscreen and the keyboard straight to Android, unless they
    # were set before.
    if [[ ! -f "${apps_dir}/$(app_window_id "${package}").desktop" ]] && is_game_app "${package}" \
        && ! app_options_saved "${package}"; then
      # shellcheck disable=SC2046 # one word per option
      save_app_options "${package}" $(default_app_options "${package}")
      log "${label}: a new game, starting fullscreen with the keyboard straight to Android"
    fi
    if write_app_launcher "${apps_dir}" "${label}" "${package}" \
        "$(app_menu_icon "${package}")"; then
      updated=$((updated + 1))
    fi
  done <<<"${list}"

  refresh_app_menu_caches
  # Release the lock now: a watcher started after this would inherit the
  # descriptor and block on it.
  exec {sync_lock_fd}>&-

  respond "${IKA_MENU_NAME}: ${#current[@]} apps (${updated} added or updated, ${removed} removed, icons ${icons})"
}

remove_app_menu() {
  local file
  local removed=0
  local sync_lock_fd

  exec {sync_lock_fd}>"${APP_MENU_SYNC_LOCK_FILE}"
  flock -w 120 "${sync_lock_fd}" || die "an app menu sync is still running"

  while read -r file; do
    [[ -n "${file}" ]] || continue
    rm -f "${file}"
    removed=$((removed + 1))
  done < <(list_app_launchers)

  rm -f "$(app_menu_merge_file)" "$(app_menu_directory_file)" "${APP_LIST_CACHE}" \
    "${APP_GAMES_FILE}"
  rm -rf "$(app_menu_icon_dir)"
  remove_gnome_app_folder
  refresh_app_menu_caches
  exec {sync_lock_fd}>&-

  respond "Removed ${IKA_MENU_NAME} (${removed} launchers)"
}

# Prints a fingerprint of the guest's enabled packages and their versions,
# which changes whenever an app is installed, updated, removed, enabled or
# disabled.
guest_package_fingerprint() {
  local packages

  packages="$(guest_adb "$1" shell cmd package list packages -e --show-versioncode 2>/dev/null \
    | tr -d '\r' || true)"
  [[ -n "${packages}" ]] || return 1
  sort <<<"${packages}" | sha256sum | cut -c1-16
}

app_menu_watcher_cleanup() {
  if [[ -f "${APP_MENU_WATCHER_PID_FILE}" \
      && "$(<"${APP_MENU_WATCHER_PID_FILE}")" == "$$" ]]; then
    rm -f "${APP_MENU_WATCHER_PID_FILE}"
  fi
}

# Seconds after Android completes a boot before the app menu watcher syncs:
# the app list is served by scrcpy's server in the guest, which cannot connect
# while Android runs its boot-completed work.
APP_MENU_BOOT_GRACE_SEC=10

# Keeps the desktop menu in sync while the VM runs: syncs once the guest has
# booted and settled, then whenever its packages change. Polling one package
# listing costs a few tens of milliseconds and needs nothing running in the
# guest. Exits when the VM stops or the menu is removed with
# 'ika app sync --remove'.
run_app_menu_watcher() {
  local adb_serial
  local fingerprint
  local synced=""
  local booted_at=""
  local watcher_lock_fd

  exec {watcher_lock_fd}>"${APP_MENU_WATCHER_LOCK_FILE}"
  flock -n "${watcher_lock_fd}" || return 0
  printf '%s\n' "$$" > "${APP_MENU_WATCHER_PID_FILE}"
  trap 'exit 0' INT TERM HUP
  trap app_menu_watcher_cleanup EXIT
  # A failed sync is logged and retried, never reported as a notification:
  # the watcher inherits IKA_NOTIFY from the menu launcher's 'ika start', and
  # its failures (a guest that stops answering) are the log's business.
  IKA_NOTIFY=false

  adb_serial="$(resolve_adb_serial)"
  log "app menu watcher started"
  while has_live_cvd_processes && [[ ! -f "${APP_MENU_DISABLED_FILE}" ]]; do
    # The adb calls go without the watcher's lock, like the sync below: one
    # may start the adb server, which would otherwise keep the lock after this
    # watcher exits and stop every later one from starting.
    if ! ( exec {watcher_lock_fd}>&-; adb_boot_completed "${adb_serial}" ); then
      # Not booted, or restarting: a mode switch restarts Android with other
      # packages, and the sync waits for the new boot to settle.
      booted_at=""
    elif [[ -z "${booted_at}" ]]; then
      booted_at="${SECONDS}"
    fi
    if [[ -n "${booted_at}" ]] \
        && (( SECONDS - booted_at >= APP_MENU_BOOT_GRACE_SEC )) \
        && fingerprint="$(exec {watcher_lock_fd}>&-; guest_package_fingerprint "${adb_serial}")" \
        && [[ "${fingerprint}" != "${synced}" ]]; then
      if [[ -n "${synced}" ]]; then
        log "guest packages changed; updating the app menu"
      fi
      # Wait in the background so that a stop request is handled at once
      # instead of after the running command.
      # Without the watcher's lock, which a daemon started during the sync
      # (such as an adb server) would otherwise keep.
      ( exec {watcher_lock_fd}>&-; sync_app_menu ) &
      if wait "$!"; then
        synced="${fingerprint}"
      else
        log "app menu sync failed; retrying in 30s"
        sleep 30 &
        wait "$!"
      fi
    fi
    sleep "${IKA_APP_MENU_POLL_SEC}" &
    wait "$!"
  done
  log "app menu watcher stopped"
}

start_app_menu_watcher() {
  [[ ! -f "${APP_MENU_DISABLED_FILE}" ]] || return 0
  supervisor_pid_from_file "${APP_MENU_WATCHER_PID_FILE}" __app_menu_watcher >/dev/null && return 0

  setsid --fork "${IKA_SCRIPT_PATH}" __app_menu_watcher \
    </dev/null >>"${APP_MENU_LOG_FILE}" 2>&1 3>&- &
  disown || true
}

stop_app_menu_watcher() {
  stop_supervisor_from_file "${APP_MENU_WATCHER_PID_FILE}" __app_menu_watcher
}

