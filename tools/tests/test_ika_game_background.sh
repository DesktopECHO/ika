#!/usr/bin/bash

# Games in the background: opening a game closes the other games' windows but
# keeps each game on its own Cuttlefish display, turned off; opening it again
# turns the display back on in a new window, and 'ika app close', stop and
# restart end it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
SUPERVISOR_PIDS=()
cleanup() {
  local pid
  for pid in "${SUPERVISOR_PIDS[@]}"; do
    kill "${pid}" >/dev/null 2>&1 || true
  done
  rm -rf "${T}"
}
trap cleanup EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"

source "${ROOT}/tools/ika"
log() { printf '%s\n' "$*" >>"${T}/log"; }
notify_user() { :; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# The guest: 'am stack list' prints STACK_LIST, the display power commands
# succeed unless POWER_STATUS says otherwise, and every call is recorded.
STACK_LIST=""
POWER_STATUS=0
BOOT_ID="11111111-2222-3333-4444-555555555555"
guest_adb() {
  shift
  printf '%s\n' "$*" >>"${T}/adb"
  case "$*" in
    "shell am stack list") printf '%s' "${STACK_LIST}" ;;
    "shell cmd display power-"*) return "${POWER_STATUS}" ;;
  esac
  return 0
}
adb_guest_boot_id() { printf '%s\n' "${BOOT_ID}"; }
remove_cuttlefish_display() { printf 'remove %s\n' "$1" >>"${T}/displays"; }

calls() {
  [[ -f "${T}/$1" ]] && cat "${T}/$1"
  : >"${T}/$1"
}

# A window supervisor as supervisor_pid_from_file knows it: a process of this
# user whose command line has __app_supervisor and the window's display.
start_window() {
  local package="$1"
  local display="$2"

  bash -c 'trap "exit 0" TERM; while :; do sleep 0.05; done' \
    ika __app_supervisor "${package}" serial false -- scrcpy \
    "--cuttlefish-display=${display}" &
  SUPERVISOR_PIDS+=("$!")
  printf '%s\n' "$!" >"$(app_supervisor_file "${package}" pid)"
  mkdir -p "${IKA_APPS_DIR}/${package}"
}

stack_list() {
  local entry
  local package
  local display
  local task
  for entry in "$@"; do
    IFS=: read -r package display task <<<"${entry}"
    printf 'RootTask id=%s bounds=[0,0][1920,1080] displayId=%s userId=0\n' "${task}" "${display}"
    printf ' configuration={1.0 winConfig={ mWindowingMode=fullscreen}}\n'
    printf '  taskId=%s: %s/%s.MainActivity bounds=[0,0][1920,1080] userId=0 visible=true\n\n' \
      "${task}" "${package}" "${package}"
  done
}

mkdir -p "${CVD_TMP_DIR}" "${IKA_APPS_DIR}"
printf 'com.example.racer\ncom.example.flyer\n' >"${APP_GAMES_FILE}"

# The setting: on unless turned off.
for value in "" true yes on 1 TRUE; do
  IKA_BACKGROUND_GAMES="${value}" background_games_enabled || fail "background_games '${value}' is off"
done
for value in false no off 0 False; do
  if IKA_BACKGROUND_GAMES="${value}" background_games_enabled; then
    fail "background_games '${value}' is on"
  fi
done
IKA_BACKGROUND_GAMES=true
echo "ok: background_games is on unless turned off"

# The displays of a package's tasks, not the console's, and not by prefix.
# Each entry is PACKAGE:DISPLAY:TASK.
STACK_LIST="$(stack_list com.example.racer:12:29 com.example.racer:0:31 \
  com.example.racer2:14:32 com.example.store:13:30)"
expect_equal "$(guest_app_task_displays com.example.racer serial)" "12" "the game's display"
expect_equal "$(guest_app_task_displays com.example.flyer serial)" "" "no task, no display"
echo "ok: a game's display is found from its tasks"

# Opening a game sends the other open games to the background; other apps
# stay open.
start_window com.example.racer 5
printf 'Racer\n' >"${IKA_APPS_DIR}/com.example.racer/title"
start_window com.example.store 6
calls adb >/dev/null
background_other_games com.example.flyer serial
app_window_is_open com.example.racer && fail "the game's window is still open"
app_window_is_open com.example.store || fail "the app's window was closed"
expect_equal "$(<"$(app_background_file com.example.racer)")" "${BOOT_ID} 5 12" "the record"
[[ ! -e "$(app_keep_display_file com.example.racer)" ]] || fail "the keep-display mark was left behind"
expect_equal "$(calls displays)" "" "the game's display is kept"
expect_equal "$(calls adb | grep power)" "shell cmd display power-off 12" "the game's display is turned off"
expect_equal "$(list_background_apps)" $'Racer\tcom.example.racer' "the background list"
echo "ok: opening a game sends the other games to the background"

# Opening an app that is not a game, or with the setting off, leaves games
# open.
start_window com.example.flyer 7
background_other_games com.example.store serial
app_window_is_open com.example.flyer || fail "an app closed a game's window"
IKA_BACKGROUND_GAMES=false background_other_games com.example.racer serial
app_window_is_open com.example.flyer || fail "background_games = false closed a game's window"
echo "ok: other apps and background_games = false leave games open"

# The window's supervisor leaves the display when the mark is there, and
# removes it otherwise.
APP_WINDOW_PACKAGE=com.example.flyer
APP_CUTTLEFISH_DISPLAY=7
: >"$(app_keep_display_file com.example.flyer)"
remove_app_cuttlefish_display
expect_equal "$(calls displays)" "" "a marked display is kept"
[[ ! -e "$(app_keep_display_file com.example.flyer)" ]] || fail "the mark was not used up"
APP_CUTTLEFISH_DISPLAY=7
remove_app_cuttlefish_display
expect_equal "$(calls displays)" "remove 7" "an unmarked display is removed"
APP_WINDOW_PACKAGE=""
echo "ok: a window keeps its display only for the background"

# Back from the background: the display is turned on and reused.
resumed=""
resume_background_app com.example.racer serial resumed || fail "the game did not come back"
expect_equal "${resumed}" "5" "the display reused"
expect_equal "$(calls adb | grep power)" "shell cmd display power-reset 12" "the display is turned back on"
app_is_in_background com.example.racer && fail "the record was kept"

# After Android restarted, or when the game ended meanwhile, it opens anew.
printf '%s 5 12\n' "99999999-2222-3333-4444-555555555555" >"$(app_background_file com.example.racer)"
resumed=""
if resume_background_app com.example.racer serial resumed; then
  fail "a game of another boot came back"
fi
expect_equal "$(calls displays)" "" "another boot's display number is left alone"
app_is_in_background com.example.racer && fail "a stale record was kept"
printf '%s 5 12\n' "${BOOT_ID}" >"$(app_background_file com.example.racer)"
STACK_LIST="$(stack_list com.example.store:13:30)"
if resume_background_app com.example.racer serial resumed; then
  fail "an ended game came back"
fi
expect_equal "$(calls displays)" "remove 5" "an ended game's display is removed"
echo "ok: a game comes back from the background, or opens anew"

# A game that cannot be kept, or whose display does not turn off, is closed.
stop_supervisor_from_file "$(app_supervisor_file com.example.flyer pid)" __app_supervisor
start_window com.example.racer 5
STACK_LIST=""
background_app_window com.example.racer serial
app_window_is_open com.example.racer && fail "a game without a task kept its window"
app_is_in_background com.example.racer && fail "a game without a task was recorded"
start_window com.example.racer 5
STACK_LIST="$(stack_list com.example.racer:12:29)"
POWER_STATUS=1
background_app_window com.example.racer serial
POWER_STATUS=0
app_is_in_background com.example.racer && fail "a game whose display stayed on was recorded"
expect_equal "$(calls displays)" "remove 5" "the display that stayed on is removed"
echo "ok: a game that cannot be kept in the background is closed"

# 'ika app close' ends a game in the background, unless its display number is
# now another window's; stopping all windows ends them all.
printf '%s 5 12\n' "${BOOT_ID}" >"$(app_background_file com.example.racer)"
close_app_window racer >/dev/null
app_is_in_background com.example.racer && fail "ika app close kept the game"
expect_equal "$(calls displays)" "remove 5" "ika app close removes the display"
printf '%s 6 13\n' "${BOOT_ID}" >"$(app_background_file com.example.racer)"
discard_background_app com.example.racer
expect_equal "$(calls displays)" "" "a display number in use by a window is left alone"
printf '%s 8 15\n' "${BOOT_ID}" >"$(app_background_file com.example.racer)"
printf '%s 9 16\n' "${BOOT_ID}" >"$(app_background_file com.example.flyer)"
stop_app_supervisors
app_window_is_open com.example.store && fail "stop_app_supervisors left a window open"
expect_equal "$(calls displays | sort)" $'remove 8\nremove 9' "stop ends the games in the background"
expect_equal "$(list_background_apps)" "" "no game left in the background"
echo "ok: closing and stopping end the games in the background"

echo "PASS: games in the background"
