#!/usr/bin/bash

# Keeps every Ika launcher in the GNOME "Android Apps (Ika)" folder: new apps,
# apps dragged out of it or into another folder, and syncs run without the
# desktop session's environment (app menu watcher, SSH).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" CVD_HOME_DIR="$T/ika" CVD_PRODUCT_OUT="$T/product"
mkdir -p "$HOME" "$CVD_PRODUCT_OUT"
source "${ROOT}/tools/ika"
declare -A G=()
FOLDERS='org.gnome.desktop.app-folders'
fs() { printf 'org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/%s/' "$1"; }
gsettings() {
  case "$1" in
    list-schemas) printf '%s\n' org.gnome.desktop.app-folders ;;
    get) printf '%s\n' "${G[$2|$3]:-@as []}" ;;
    set) G["$2|$3"]="$4"; echo "SET $3 ($(basename "$2")) = $4" >> "$T/sets" ;;
  esac
}
fail() { echo "FAIL: $*"; exit 1; }
eq() { [[ "$2" == "$1" ]] || fail "$3: expected [$1] got [$2]"; }
unset DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR="$T/run"; mkdir -p "$XDG_RUNTIME_DIR"
python3 -c "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" \
  "$XDG_RUNTIME_DIR/bus"

# 1. fresh desktop, no session bus in env (watcher / SSH case)
G["$FOLDERS|folder-children"]="['Utilities', 'System']"
G["$(fs Utilities)|apps"]="['org.gnome.Terminal.desktop']"
install_gnome_app_folder ika-a.b.desktop ika-c.d.desktop
eq "['Utilities', 'System', 'ika-android-apps']" "${G[$FOLDERS|folder-children]}" "folder registered"
eq "['ika-a.b.desktop', 'ika-c.d.desktop']" "${G[$(fs ika-android-apps)|apps]}" "explicit apps"
eq "'Android Apps (Ika)'" "${G[$(fs ika-android-apps)|name]}" "name"
eq "['X-Ika-Android']" "${G[$(fs ika-android-apps)|categories]}" "categories"
echo "ok 1: fresh desktop via user bus socket"

# 2. new app added; user also put a non-Ika app in our folder
G["$(fs ika-android-apps)|apps"]="['ika-a.b.desktop', 'org.gnome.Calculator.desktop', 'ika-c.d.desktop']"
install_gnome_app_folder ika-a.b.desktop ika-c.d.desktop ika-new.app.desktop
eq "['org.gnome.Calculator.desktop', 'ika-a.b.desktop', 'ika-c.d.desktop', 'ika-new.app.desktop']" "${G[$(fs ika-android-apps)|apps]}" "new app listed, user entry kept"
echo "ok 2: new app added before its launcher, user's own entry kept"

# 3. user dragged one Ika app out (GNOME: removed from apps, added to excluded-apps) and one into Utilities
G["$(fs ika-android-apps)|apps"]="['org.gnome.Calculator.desktop', 'ika-c.d.desktop']"
G["$(fs ika-android-apps)|excluded-apps"]="['ika-a.b.desktop', 'org.other.desktop']"
G["$(fs Utilities)|apps"]="['org.gnome.Terminal.desktop', 'ika-new.app.desktop']"
install_gnome_app_folder ika-a.b.desktop ika-c.d.desktop ika-new.app.desktop
eq "['org.other.desktop']" "${G[$(fs ika-android-apps)|excluded-apps]}" "exclusion cleared"
eq "['org.gnome.Terminal.desktop']" "${G[$(fs Utilities)|apps]}" "removed from other folder"
eq "['org.gnome.Calculator.desktop', 'ika-a.b.desktop', 'ika-c.d.desktop', 'ika-new.app.desktop']" "${G[$(fs ika-android-apps)|apps]}" "all back"
echo "ok 3: dragged-out apps moved back"

# 4. app uninstalled
install_gnome_app_folder ika-c.d.desktop
eq "['org.gnome.Calculator.desktop', 'ika-c.d.desktop']" "${G[$(fs ika-android-apps)|apps]}" "removed app dropped"
echo "ok 4: removed app dropped from list"

# 5. no change -> no writes
: > "$T/sets"; install_gnome_app_folder ika-c.d.desktop
[[ ! -s "$T/sets" ]] || { cat "$T/sets"; fail "rewrote unchanged settings"; }
echo "ok 5: idempotent (no writes when nothing changed)"

# 6. empty app list, and no bus at all
install_gnome_app_folder
eq "['org.gnome.Calculator.desktop']" "${G[$(fs ika-android-apps)|apps]}" "no ika left"
rm "$XDG_RUNTIME_DIR/bus"; : > "$T/sets"; install_gnome_app_folder ika-x.y.desktop
[[ ! -s "$T/sets" ]] || fail "wrote without a session bus"
echo "ok 6: empty list; no session bus -> skipped quietly"

# 7. a long schema list: the folder must still be set up when grep could stop
# reading early (gsettings would get SIGPIPE under pipefail)
gsettings() {
  case "$1" in
    list-schemas) printf '%s\n' org.gnome.desktop.app-folders; seq -f 'org.example.schema%g' 200000 ;;
    get) printf '%s\n' "${G[$2|$3]:-@as []}" ;;
    set) G["$2|$3"]="$4" ;;
  esac
}
python3 -c "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" \
  "$XDG_RUNTIME_DIR/bus"
for _ in 1 2 3 4 5; do
  G=()
  install_gnome_app_folder ika-a.b.desktop
  eq "['ika-a.b.desktop']" "${G[$(fs ika-android-apps)|apps]:-}" "folder set up despite early grep exit"
done
echo "ok 7: long schema list does not skip the folder"
printf 'PASS: Ika launchers stay in the GNOME app folder\n'
