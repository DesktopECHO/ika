#!/usr/bin/env bash
set -euo pipefail

# Override the default serial via the first positional argument or LINEAGE_DESKTOP_ADB_SERIAL.
# The previous hardcoded default (mbp16.local:6520) was the original developer's
# Cuttlefish host and is wrong for everyone else.
serial="${1:-${LINEAGE_DESKTOP_ADB_SERIAL:-}}"
if [[ -z "$serial" ]]; then
  printf 'usage: smoke_resize_desktop.sh <adb-serial>\n' >&2
  printf '       or set LINEAGE_DESKTOP_ADB_SERIAL=<serial>\n' >&2
  exit 2
fi
adb_cmd=(adb -s "$serial")

"${adb_cmd[@]}" wait-for-device

failures=0
fail() {
  printf '[desktop-smoke] FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

shell_get() {
  "${adb_cmd[@]}" shell "$@" | tr -d '\r'
}

echo "[desktop] feature contract"
features="$(shell_get pm list features)"
# Desktop products must expose freeform window management and the PC feature.
grep -q 'android.software.freeform_window_management' <<<"$features" || \
  fail "missing android.software.freeform_window_management"
grep -q 'android.hardware.type.pc' <<<"$features" || \
  fail "missing android.hardware.type.pc"
# Desktop products must NOT advertise phone-only features.
if grep -q 'android.hardware.telephony' <<<"$features"; then
  fail "android.hardware.telephony is present (desktop has no cellular hardware)"
fi
if grep -q 'android.hardware.uwb' <<<"$features"; then
  fail "android.hardware.uwb is present (excluded by the desktop contract)"
fi
if grep -q 'android.hardware.thread_network' <<<"$features"; then
  fail "android.hardware.thread_network is present (excluded by the desktop contract)"
fi

echo "[desktop] desktop settings"
freeform="$(shell_get settings get global enable_freeform_support || true)"
resizable="$(shell_get settings get global force_resizable_activities || true)"
multiwin="$(shell_get settings get global enable_non_resizable_multi_window || true)"
echo "  enable_freeform_support=$freeform"
echo "  force_resizable_activities=$resizable"
echo "  enable_non_resizable_multi_window=$multiwin"
[[ "$freeform" == "1" ]] || fail "enable_freeform_support is not 1 (was: $freeform)"
[[ "$resizable" == "1" ]] || fail "force_resizable_activities is not 1 (was: $resizable)"
[[ "$multiwin" == "1" ]] || fail "enable_non_resizable_multi_window is not 1 (was: $multiwin)"

enter_dt="$(shell_get getprop persist.wm.debug.enter_desktop_by_default_on_freeform_display)"
force_dt="$(shell_get getprop persist.wm.debug.force_desktop_first_on_default_display_for_testing)"
echo "  persist.wm.debug.enter_desktop_by_default_on_freeform_display=$enter_dt"
echo "  persist.wm.debug.force_desktop_first_on_default_display_for_testing=$force_dt"
[[ "$enter_dt" == "true" ]] || fail "enter_desktop_by_default_on_freeform_display is not true (was: $enter_dt)"

# Desktop must not have a lockscreen.
lockscreen="$(shell_get cmd lock_settings get-disabled || true)"
echo "  lock_settings get-disabled=$lockscreen"
[[ "$lockscreen" == "true" ]] || fail "lockscreen is not disabled (was: $lockscreen)"

original_size="$(shell_get wm size | tail -1)"
echo "[desktop] original: $original_size"

resize_to() {
  local target="$1"
  "${adb_cmd[@]}" shell wm size "$target"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    local current
    current="$(shell_get wm size | tail -1)"
    [[ "$current" == *"$target"* ]] && return 0
    sleep 1
  done
  fail "wm size did not converge to $target (last: $current)"
  return 1
}

# Multi-resize: shrink, grow, restore. After each step we verify the reported
# size and check that any freeform tasks remain inside the new viewport (the
# R6 / DesktopTasksController bounds clamp).
freeform_bounds_inside() {
  local target_w="$1" target_h="$2"
  local bounds
  bounds="$(shell_get dumpsys activity activities | grep -E 'windowingMode=freeform' || true)"
  [[ -z "$bounds" ]] && return 0
  # Look for any "Rect(L T - R B)" with negative coords or coords beyond the
  # new viewport. Conservative: if we can't parse, don't fail.
  if grep -Eo 'Rect\([- ]?[0-9]+[, ]+[- ]?[0-9]+ - [- ]?[0-9]+[, ]+[- ]?[0-9]+\)' <<<"$bounds" | \
     awk -v W="$target_w" -v H="$target_h" '
       {
         gsub(/[(),-]/," ");
         l=$2; t=$3; r=$4; b=$5;
         if (l<0||t<0||r>W||b>H) { print "OUT_OF_BOUNDS:" $0; ec=1 }
       }
       END { exit ec+0 }
     ' >&2; then
    return 0
  else
    fail "freeform task bounds escape the $target_w x $target_h viewport (see OUT_OF_BOUNDS lines above)"
    return 1
  fi
}

for spec in "1280x800" "1072x752" "1920x1080"; do
  resize_to "$spec" || continue
  w="${spec%x*}"
  h="${spec#*x}"
  freeform_bounds_inside "$w" "$h"
done

screenshot="/tmp/lineage-desktop-smoke-${serial//[^A-Za-z0-9]/_}.png"
"${adb_cmd[@]}" exec-out screencap -p > "$screenshot"

echo "[desktop] task snapshot"
shell_get dumpsys activity activities | grep -E "RootTask|windowingMode=freeform|windowingMode=fullscreen|type=home" | head -80 || true

echo "[desktop] screenshot: $screenshot"

if (( failures > 0 )); then
  printf '[desktop-smoke] %d check(s) failed\n' "$failures" >&2
  exit 1
fi
echo "[desktop-smoke] ok"
