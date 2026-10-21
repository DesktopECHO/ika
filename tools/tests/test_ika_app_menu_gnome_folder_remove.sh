#!/usr/bin/bash

# Removing the "Android Apps (Ika)" GNOME folder (ika reset, ika app sync
# --remove) must not change the folder's name while GNOME Shell may still
# show it: with the folder's dialog open, resetting everything at once made
# the dialog write its old name back from inside the icon's unmap, and the
# shell aborted. With a shell running the folder leaves 'folder-children'
# first, the shell gets a moment to destroy it, and then its other settings
# are reset; without a shell all of it is reset at once.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" CVD_HOME_DIR="$T/ika" CVD_PRODUCT_OUT="$T/product" XDG_DATA_HOME="$T/data"
mkdir -p "$HOME" "$CVD_PRODUCT_OUT"
source "${ROOT}/tools/ika"
mkdir -p "${CVD_HOME_DIR}" "${CVD_TMP_DIR}"
declare -A G=()
FOLDERS='org.gnome.desktop.app-folders'
fs() { printf 'org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/%s/' "$1"; }
CALLS="$T/calls"
gsettings() {
  case "$1" in
    list-schemas) printf '%s\n' org.gnome.desktop.app-folders ;;
    list-keys) printf '%s\n' name apps excluded-apps categories translate ;;
    get) printf '%s\n' "${G[$2|$3]:-@as []}" ;;
    set) G["$2|$3"]="$4"; echo "set $3" >> "$CALLS" ;;
    reset) unset "G[$2|$3]"; echo "reset $3" >> "$CALLS" ;;
    reset-recursively) echo "reset-recursively" >> "$CALLS" ;;
  esac
}
dconf() { echo "dconf $*" >> "$CALLS"; }
sleep() { echo "sleep $*" >> "$CALLS"; }
flock() { return 0; }
pgrep() { [[ -n "${SHELL_RUNNING:-}" ]]; }
fail() { echo "FAIL: $*"; exit 1; }
eq() { [[ "$2" == "$1" ]] || fail "$3: expected [$1] got [$2]"; }
calls() { cat "$CALLS" 2>/dev/null || true; }
unset DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR="$T/run"; mkdir -p "$XDG_RUNTIME_DIR"
python3 -c "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" \
  "$XDG_RUNTIME_DIR/bus"

setup_folder() {
  G=()
  : > "$CALLS"
  G["$FOLDERS|folder-children"]="['Utilities', 'ika-android-apps', 'System']"
  G["$(fs ika-android-apps)|name"]="'Android Apps (Ika)'"
  G["$(fs ika-android-apps)|categories"]="['X-Ika-Android']"
  G["$(fs ika-android-apps)|apps"]="['ika-a.b.desktop']"
}

# 1. a running shell: out of the grid first, a pause, then the settings but the name
export SHELL_RUNNING=1
setup_folder
remove_gnome_app_folder
eq "['Utilities', 'System']" "${G[$FOLDERS|folder-children]}" "folder left the grid, others kept"
eq $'set folder-children\nsleep 2\nreset apps\nreset excluded-apps\nreset categories\nreset translate' \
  "$(calls)" "order of operations"
echo "ok 1: running shell: folder-children, pause, then the other settings"

# 2. the name is never written or reset while a shell runs
! calls | grep -q 'name\|dconf\|recursively' || fail "name or whole path touched: $(calls)"
eq "'Android Apps (Ika)'" "${G[$(fs ika-android-apps)|name]}" "name kept"
echo "ok 2: name untouched, no whole-path reset"

# 3. already out of the grid: nothing to wait for
setup_folder
G["$FOLDERS|folder-children"]="['Utilities', 'System']"
remove_gnome_app_folder
! calls | grep -q '^sleep' || fail "paused with no folder to destroy"
calls | grep -q '^reset apps' || fail "settings not reset"
echo "ok 3: folder already gone: no pause"

# 4. the only folder: the list ends empty
setup_folder
G["$FOLDERS|folder-children"]="['ika-android-apps']"
remove_gnome_app_folder
eq "@as []" "${G[$FOLDERS|folder-children]}" "empty list"
echo "ok 4: last folder removed -> @as []"

# 5. no shell: everything goes at once
unset SHELL_RUNNING
setup_folder
remove_gnome_app_folder
eq "['Utilities', 'System']" "${G[$FOLDERS|folder-children]}" "folder left the grid"
eq $'set folder-children\ndconf reset -f /org/gnome/desktop/app-folders/folders/ika-android-apps/' \
  "$(calls)" "no shell: no pause, whole path reset"
echo "ok 5: no shell: whole folder reset"

# 6. no session bus: nothing is written
rm "$XDG_RUNTIME_DIR/bus"; setup_folder
remove_gnome_app_folder
[[ ! -s "$CALLS" ]] || fail "wrote without a session bus: $(calls)"
python3 -c "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" \
  "$XDG_RUNTIME_DIR/bus"
echo "ok 6: no session bus -> skipped quietly"

# 7. ika reset / app sync --remove: launchers go, then the folder, name untouched
export SHELL_RUNNING=1
apps_dir="${XDG_DATA_HOME}/applications"
mkdir -p "${apps_dir}"
printf '[Desktop Entry]\nX-Ika-Version=5\nX-Ika-Package=a.b\n' > "${apps_dir}/ika-a.b.desktop"
printf '[Desktop Entry]\nName=Other\n' > "${apps_dir}/other.desktop"
setup_folder
remove_app_menu > "$T/out"
out="$(<"$T/out")"
[[ ! -e "${apps_dir}/ika-a.b.desktop" && -e "${apps_dir}/other.desktop" ]] || fail "launchers not removed, or a foreign one was"
[[ "${out}" == *"(1 launchers)"* ]] || fail "unexpected output: ${out}"
eq "['Utilities', 'System']" "${G[$FOLDERS|folder-children]}" "folder removed with the menu"
! calls | grep -q 'name' || fail "name touched: $(calls)"
echo "ok 7: remove_app_menu: launchers, then the folder, name untouched"
printf 'PASS: removing the GNOME app folder leaves its name alone\n'
