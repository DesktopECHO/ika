#!/usr/bin/bash

# Desktop notifications never hold ika up. With a notification server running
# they are sent as before. Without one, as in a session that runs only Ika,
# where the session bus lists GNOME's or Plasma's server but cannot start it,
# notify-send waited about a minute: a message goes in the background instead,
# and a progress message, withdrawn once the work is done, is not sent.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# gdbus answers NameHasOwner from SERVER; notify-send records its message
# after DELAY seconds, as one waiting for a server to start does
cat >"${T}/bin/gdbus" <<EOF
#!/usr/bin/bash
[[ "\$*" == *NameHasOwner*org.freedesktop.Notifications* ]] || exit 1
if [[ "\$(<"${T}/server")" == running ]]; then echo "(true,)"; else echo "(false,)"; fi
EOF
cat >"${T}/bin/notify-send" <<EOF
#!/usr/bin/bash
sleep "\$(<"${T}/delay")"
printf '%s\n' "\${@: -1}" >>"${T}/sent"
[[ "\$1" != --print-id ]] || echo 42
EOF
chmod +x "${T}/bin/gdbus" "${T}/bin/notify-send"
export PATH="${T}/bin:${PATH}"
export IKA_NOTIFY=true

# A server running: sent at once, as before
echo running >"${T}/server"
echo 0 >"${T}/delay"
: >"${T}/sent"
notify_user "Installed Something"
notify_progress "Installing Something…"
expect_equal "$(<"${T}/sent")" $'Installed Something\nInstalling Something…' "with a server"
expect_equal "${IKA_PROGRESS_NOTIFICATIONS[*]}" "42" "the progress message's id"
IKA_PROGRESS_NOTIFICATIONS=()

# None running, and notify-send waiting for one: ika goes on at once
echo none >"${T}/server"
echo 2 >"${T}/delay"
: >"${T}/sent"
started="${SECONDS}"
notify_user "Installed Something"
notify_progress "Installing Something…"
(( SECONDS - started < 2 )) || fail "notify_user waited for notify-send"
expect_equal "${IKA_PROGRESS_NOTIFICATIONS[*]}" "" "progress without a server"
# The message still goes, in the background, should a server start
for _ in $(seq 1 50); do
  [[ -s "${T}/sent" ]] && break
  sleep 0.1
done
expect_equal "$(<"${T}/sent")" "Installed Something" "background message"

printf 'ok\n'
