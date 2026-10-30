#!/usr/bin/bash

# App IDs on WSLg carry the distribution's name, since Windows gives windows of
# the same app ID in different distributions one task bar button: the console
# gets ika-DISTRIBUTION and a desktop entry of that name, where WSLg reads it,
# with ika.desktop hidden from WSLg; app windows get ika-DISTRIBUTION-PACKAGE.
# Outside WSLg, or where WSLg does not read the user's entries, nothing changes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
unset XDG_DATA_HOME
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"

source "${ROOT}/tools/ika"
log() { printf '%s\n' "$*" >>"${T}/log"; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

apps="${HOME}/.local/share/applications"
IKA_DESKTOP_ENTRY="${T}/usr/share/applications/ika.desktop"
WSLG_LINKED_APPLICATIONS_DIR="${T}/usr/local/share/applications"
mkdir -p "$(dirname "${IKA_DESKTOP_ENTRY}")" "$(dirname "${WSLG_LINKED_APPLICATIONS_DIR}")"
cp "${ROOT}/tools/ika.desktop" "${IKA_DESKTOP_ENTRY}"

IKA_ON_WSLG=false
WSL_DISTRO_NAME="Ubuntu-24.04"
write_wslg_console_entry
[[ ! -e "${apps}" ]] || fail "entries were written outside WSLg"
[[ "$(console_app_id)" == ika ]] || fail "console app ID outside WSLg: $(console_app_id)"
[[ "$(app_window_id com.android.settings)" == ika-com.android.settings ]] \
  || fail "app window ID outside WSLg: $(app_window_id com.android.settings)"
echo "ok: outside WSLg the app IDs are ika and ika-PACKAGE, and no entry is written"

IKA_ON_WSLG=true
write_wslg_console_entry
[[ ! -e "${apps}/ika-ubuntu-24-04.desktop" ]] || fail "an entry was written where WSLg does not read it"
[[ "$(console_app_id)" == ika ]] || fail "console app ID without the link: $(console_app_id)"
echo "ok: on a WSLg that does not read the user's entries the console keeps ika"

mkdir -p "${apps}"
ln -s "${apps}" "${WSLG_LINKED_APPLICATIONS_DIR}"
write_wslg_console_entry
entry="${apps}/ika-ubuntu-24-04.desktop"
[[ -f "${entry}" ]] || fail "no console entry"
[[ "$(console_app_id)" == ika-ubuntu-24-04 ]] || fail "console app ID: $(console_app_id)"
grep -qx 'StartupWMClass=ika-ubuntu-24-04' "${entry}" || fail "the entry names another class"
grep -qx 'Name=Ika' "${entry}" || fail "the entry lost ika.desktop's name"
[[ "$(sed -n '/^\[Desktop Entry\]/,/^\[/p' "${entry}" | grep -cx 'X-Ika-Console=true')" == 1 ]] \
  || fail "the marker is not in the entry's [Desktop Entry] group"
grep -qx 'Hidden=true' "${apps}/ika.desktop" || fail "ika.desktop is not hidden from WSLg"
[[ "$(app_window_id com.android.settings)" == ika-ubuntu-24-04-com-android-settings ]] \
  || fail "app window ID on WSLg: $(app_window_id com.android.settings)"
echo "ok: on WSLg the console gets ika-DISTRIBUTION, its entry, and ika.desktop hidden"

touch -d '@1' "${entry}"
write_wslg_console_entry
[[ "$(stat -c %Y "${entry}")" == 1 ]] || fail "an unchanged entry was written again"
echo "ok: an unchanged entry is left alone"

touch -d '@1' "${apps}/ika.desktop"
touch "${IKA_DESKTOP_ENTRY}"
write_wslg_console_entry
(( $(stat -c %Y "${apps}/ika.desktop") > 1 )) || fail "ika.desktop was not hidden again after its reinstall"
(( $(stat -c %Y "${entry}") > 1 )) || fail "the console entry was not written again after ika.desktop's reinstall"
echo "ok: after ika.desktop is installed again it is hidden again, and the console entry written after"

printf '[Desktop Entry]\nName=Settings\nX-Ika-Version=1\nX-Ika-Package=com.android.settings\n' \
  >"${apps}/ika-ubuntu-24-04-com-android-settings.desktop"
WSL_DISTRO_NAME="Debian"
write_wslg_console_entry
[[ ! -e "${entry}" ]] || fail "the entry of the distribution's former name was kept"
[[ -f "${apps}/ika-debian.desktop" ]] || fail "no entry for the distribution's new name"
[[ -f "${apps}/ika-ubuntu-24-04-com-android-settings.desktop" ]] || fail "an app launcher was removed"
echo "ok: a renamed distribution's console entry is replaced, and app launchers stay"
