#!/system/bin/sh
#
# LineageOS Desktop: react to host-window resize events from /usr/bin/ika.
#
# /usr/bin/ika opens the Cuttlefish host window. It sets the initial display
# geometry, but the user can resize the host window at any time after that.
# When the user does, ika writes the new geometry to one or both of:
#
#     vendor.cuttlefish.display.size   = "<width>x<height>"  (e.g. "1920x1080")
#     vendor.cuttlefish.display.dpi    = "<dpi>"             (e.g. "160")
#
# init's property triggers (cvd_display_resize.rc) invoke this script with the
# current values of those properties as $1 and $2. We translate them to
# `cmd window size` / `cmd window density`, which fan out through
# LogicalDisplayMapper.setDisplayInfoOverrideFromWindowManagerLocked ->
# DisplayManager.DisplayListener#onDisplayChanged into Launcher3 and Shell.
#
# The same path is used whether the trigger came from ika, an interactive
# `adb shell setprop`, or any other host-side actor: the property is the
# contract.

size="${1:-}"
dpi="${2:-}"

# Reject obviously malformed values rather than handing garbage to cmd.
changed=0
case "$size" in
    ""|*[!0-9x]*) ;;
    *x*)
        cmd window size "$size" >/dev/null 2>&1
        changed=1
        ;;
esac

case "$dpi" in
    ""|*[!0-9]*) ;;
    *)
        cmd window density "$dpi" >/dev/null 2>&1
        changed=1
        ;;
esac

# Fix 2b: belt-and-suspenders for the sysprop channel only.
#
# scrcpy-driven resizes go through Device.setDisplaySizeAndDensity (a sibling of
# `cmd window size`) and Fix 2a in TaskbarManagerImpl.onConfigurationChanged
# handles those, propagating the new DeviceProfile into the all-apps view.
#
# For the property-driven channel (this script's reason to exist), the launcher
# may be in the background when the property fires (e.g., interactive `adb
# shell setprop` while a foreground app has focus). In that case
# onConfigurationChanged does deliver to TaskbarManagerImpl, but the all-apps
# view inside the paused launcher may not redraw until it next becomes visible.
# Force the launcher process to restart so its IDP and all-apps grid both come
# up fresh against the new geometry. Cheap (~300 ms cold start on Cuttlefish)
# and guaranteed to be correct.
if [ "$changed" = "1" ]; then
    am force-stop com.android.launcher3 >/dev/null 2>&1
fi
