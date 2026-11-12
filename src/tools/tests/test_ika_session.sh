#!/usr/bin/bash

# `ika session`, the login session that runs only Ika: it starts Cage around
# itself, then inside it starts Ika full screen, waits for the console to
# close, and stops Android only if the session started it. A start that fails
# is shown in a window, with the error ika gave.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

host_is_wsl2() { false; }

# WSL has no login screen
out="$( host_is_wsl2() { true; }; run_session_command 2>&1 )" && fail "ran on WSL"
[[ "${out}" == *"WSL has no login screen"* ]] || fail "WSL message: ${out}"

# No Cage
out="$( IKA_SESSION_CAGE="${T}/no-cage" run_session_command 2>&1 )" && fail "ran without Cage"
[[ "${out}" == *"install the cage package"* ]] || fail "Cage message: ${out}"

# Arguments are refused
( run_session_command --fullscreen ) 2>/dev/null && fail "took an argument"

# Outside Cage, it runs itself again inside Cage, with VT switching
cat >"${T}/cage" <<EOF
#!/usr/bin/bash
printf '%s\n' "IKA_SESSION_IN_CAGE=\${IKA_SESSION_IN_CAGE:-}" "\$@" >"${T}/cage-args"
EOF
chmod +x "${T}/cage"
( IKA_SESSION_CAGE="${T}/cage" IKA_SCRIPT_PATH=/usr/bin/ika run_session_command )
expect_equal "$(<"${T}/cage-args")" $'IKA_SESSION_IN_CAGE=true\n-s\n--\n/usr/bin/ika\nsession' \
  "Cage's command line"

# Inside Cage. The fake ika records the commands the session runs; START_FAILS
# makes its start fail as ika does.
cat >"${T}/fake-ika" <<EOF
#!/usr/bin/bash
printf '%s\n' "\$*" >>"${T}/calls"
# As ika start, which writes its output to the start log under a header line
if [[ "\$1" == start && -n "\${START_FAILS:-}" ]]; then
  printf '==== 2026-11-12 03:38:59 ika start\n[ika] error: %s\n' "\${START_FAILS}" \
    >>"${CVD_HOME_DIR}/ikastart.log"
  printf 'Startup Failed.\n'
  exit 1
fi
case "\$1" in
  start) touch "${T}/android-up" ;;
  stop) rm -f "${T}/android-up" ;;
esac
EOF
chmod +x "${T}/fake-ika"
export IKA_SCRIPT_PATH="${T}/fake-ika"

show_session_failure() { printf 'failure: %s\n' "$1" >>"${T}/calls"; }

# systemd-inhibit, recording what it was asked to hold and run, and its
# descriptors, then holding on as the real one does until it is ended
cat >"${T}/inhibit" <<EOF
#!/usr/bin/bash
printf '%s\n' "\$@" >"${T}/inhibit-args"
# Listed by ls alone: while bash starts a pipeline it holds the pipes' ends
# itself, which ls could list
ls /proc/\$\$/fd >"${T}/inhibit-fds"
printf '%s\n' "\$\$" >"${T}/inhibit-pid"
exec sleep 300
EOF
chmod +x "${T}/inhibit"
export IKA_SESSION_INHIBIT="${T}/inhibit"

# A console that runs for a second, as the supervisor pid's process
start_console() {
  sleep 1 &
  CONSOLE_PID=$!
}
scrcpy_supervisor_pid() { printf '%s\n' "${CONSOLE_PID}"; }

# Whether Android runs: the fake ika's start and stop set it
has_live_cvd_processes() { [[ -e "${T}/android-up" ]]; }

# Android not running before: the session stops it once the console closes
: >"${T}/calls"
rm -f "${T}/android-up"
start_console
( run_session_in_cage )
expect_equal "$(<"${T}/calls")" $'start --fullscreen\nstop' "session that started Android"
# The power and sleep keys are held back from logind for the session's life
expect_equal "$(head -n 4 "${T}/inhibit-args")" \
  $'--what=handle-power-key:handle-suspend-key:handle-hibernate-key\n--who=Ika\n--why=Android takes the power and sleep keys\n--mode=block' \
  "inhibitor"
expect_equal "$(tail -n +5 "${T}/inhibit-args" | head -n 2)" $'tail\n--pid='"$$" \
  "what the inhibitor holds on to"
# It holds nothing of the session's, such as Cage's pipe, which kept Cage, and
# the inhibitor, after the session ended; and the session ends it.
# (bash's 255 is its own handle on the script)
expect_equal "$(grep -vx 255 "${T}/inhibit-fds" | sort -n | tr '\n' ' ')" "0 1 2 " "the inhibitor's descriptors"
sleep 0.2
kill -0 "$(<"${T}/inhibit-pid")" 2>/dev/null && fail "the inhibitor outlived the session"
grep -q 'console closed' "${SESSION_LOG_FILE}" || fail "log: $(<"${SESSION_LOG_FILE}")"

# Android already running, from a desktop session: left running
: >"${T}/calls"
touch "${T}/android-up"
start_console
( run_session_in_cage )
expect_equal "$(<"${T}/calls")" 'start --fullscreen' "session with Android already running"

# A failed start: the window shows ika's error
: >"${T}/calls"
rm -f "${T}/android-up"
scrcpy_supervisor_pid() { return 1; }
( START_FAILS="no KVM" run_session_in_cage )
expect_equal "$(<"${T}/calls")" $'start --fullscreen\nfailure: no KVM' "failed start"

# An error of an earlier start in the start log is not this start's
printf '==== 2026-11-12 03:40:00 ika start\n[ika] starting\n' >>"${CVD_HOME_DIR}/ikastart.log"

# Android started but no console within the wait: said so, and Android,
# which the session started, stopped
: >"${T}/calls"
( IKA_SESSION_CONSOLE_WAIT_SEC=1 run_session_in_cage )
expect_equal "$(<"${T}/calls")" $'start --fullscreen\nfailure: The console did not open.\nstop' \
  "no console"

# What the session starts holds no descriptor past standard error, such as
# Cage's pipe, which would keep Cage, and the black screen, after the console
# closed: here fd 7, and the fds bash holds itself
exec 7>"${T}/cage-pipe"
# (bash lists its own fds: "; :" keeps it from running ls in its place)
fds="$(run_without_inherited_fds bash -c 'ls /proc/$$/fd; :' | sort -n | tr '\n' ' ')"
exec 7>&-
expect_equal "${fds}" "0 1 2 " "descriptors of what the session runs"

printf 'ok\n'
