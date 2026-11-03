#!/usr/bin/bash

# Windows programs started by a job in the background, on WSL: the interop
# socket of the session that started Ika stops answering when that session
# ends, so such a job goes through WSL's socket for the whole VM when there is
# one. And a start that finds Android's storage mounted adds the shortcut to
# Explorer again, as the start that mounted it may have failed to.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}" "${T}/bin"

# Stubs: powershell.exe records its arguments and the interop socket it is
# started through, wslpath names the path as Windows would, and madbfs
# records that it ran.
cat >"${T}/bin/powershell.exe" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${T}/powershell.args"
printf '%s\n' "\${WSL_INTEROP:-unset}" >"${T}/powershell.interop"
STUB
cat >"${T}/bin/wslpath" <<'STUB'
#!/usr/bin/env bash
printf '\\\\wsl.localhost\\Ubuntu%s\n' "${2//\//\\}"
STUB
cat >"${T}/bin/madbfs" <<STUB
#!/usr/bin/env bash
touch "${T}/madbfs.ran"
STUB
chmod +x "${T}/bin/powershell.exe" "${T}/bin/wslpath" "${T}/bin/madbfs"
export PATH="${T}/bin:${PATH}"

# A socket file, as WSL's sockets are
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${T}/1_interop"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${T}/session_interop"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Waits for PowerShell to have run
wait_for_powershell() {
  for _ in $(seq 1 50); do
    [[ -s "${T}/powershell.interop" ]] && return 0
    sleep 0.1
  done
  fail "PowerShell did not run"
}

# The socket WSL_INTEROP names in a job in the background
job_interop() {
  ( detach_background_job; printf '%s\n' "${WSL_INTEROP:-unset}" )
}

WSL_SYSTEM_INTEROP="${T}/1_interop"
export WSL_INTEROP="${T}/session_interop"
[[ "$(job_interop)" == "${T}/1_interop" ]] \
  || fail "a job in the background does not use the VM's socket: $(job_interop)"
[[ "${WSL_INTEROP}" == "${T}/session_interop" ]] \
  || fail "the caller's WSL_INTEROP changed: ${WSL_INTEROP}"
echo "ok: a job in the background uses the VM's socket, and only the job does"

WSL_SYSTEM_INTEROP="${T}/missing_interop"
[[ "$(job_interop)" == "${T}/session_interop" ]] \
  || fail "without the VM's socket the session's is not kept: $(job_interop)"
unset WSL_INTEROP
[[ "$(job_interop)" == "unset" ]] || fail "WSL_INTEROP was set from nothing: $(job_interop)"
echo "ok: without the VM's socket, WSL_INTEROP stays as it was"

# The shortcut's job reaches PowerShell through the VM's socket, from a
# session whose own socket is gone
WSL_SYSTEM_INTEROP="${T}/1_interop"
export WSL_INTEROP="${T}/ended_session_interop"
IKA_ON_WSLG=true
edit_windows_android_storage_shortcut add /run/user/1000/ika/Android
wait_for_powershell
[[ "$(<"${T}/powershell.interop")" == "${T}/1_interop" ]] \
  || fail "PowerShell was started through $(<"${T}/powershell.interop")"
echo "ok: the Explorer shortcut's PowerShell goes through the VM's socket"

# Storage that is mounted already: the shortcut is added again, and madbfs
# does not run
rm -f "${T}/powershell.args" "${T}/powershell.interop"
PACKAGED_MADBFS_BIN="${T}/bin/madbfs"
ANDROID_STORAGE_DIR="/run/user/1000/ika/Android"
android_storage_mounted() { return 0; }
mount_android_storage vsock:3:5555
wait_for_powershell
script="$(grep -A1 -x -- '-EncodedCommand' "${T}/powershell.args" | tail -n 1 | base64 -d | iconv -f UTF-16LE)"
[[ "${script}" == *"\$action = 'add'"* ]] || fail "the shortcut was not added: ${script:0:200}"
[[ "${script}" == *"\$target = '\\\\wsl.localhost\\Ubuntu\\run\\user\\1000\\ika\\Android'"* ]] \
  || fail "the shortcut leads elsewhere: ${script:0:200}"
[[ ! -e "${T}/madbfs.ran" ]] || fail "madbfs ran on storage that is mounted"
echo "ok: a start that finds the storage mounted adds the shortcut again"

# Outside WSLg that start does nothing more
rm -f "${T}/powershell.args" "${T}/powershell.interop"
IKA_ON_WSLG=false
mount_android_storage vsock:3:5555
wait
[[ ! -e "${T}/powershell.args" ]] || fail "PowerShell ran outside WSLg"
echo "ok: nothing runs outside WSLg"
