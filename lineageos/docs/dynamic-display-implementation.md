# Dynamic Display Implementation

LineageOS Desktop is designed to treat the Cuttlefish primary display as a
resizable desktop surface. The host launcher starts Cuttlefish with an initial
display size and DPI derived from the host monitor, then opens Ika's scrcpy
client (`scrcpy/`) as the frontend.

## Runtime Resize Flow

The default viewer path uses raw Cuttlefish frames:

1. `tools/ika` launches scrcpy with `--cuttlefish-frames-socket=...` and
   `--dpi=<computed-or-user-value>`.
2. scrcpy follows the window size in pixels, debounced while the window
   is being resized.
3. scrcpy sends `TYPE_RESIZE_DISPLAY` to the scrcpy server, which forces
   the logical size of the main display (as `wm size`, with `wm scaling off`
   when it fits the physical display, and `wm density` once), and sends
   `DISPLAY_READY` when the display has settled.
4. Android reports the new display metrics through `DisplayManager` and the
   normal configuration-change path. The physical Cuttlefish display keeps its
   size; the client shows the logical display 1:1 from its frames.

See [`scrcpy/IKA.md`](../../scrcpy/IKA.md).

## Guest Fallback Contract

For manual testing and future host-side actors that do not go through
scrcpy, the product also accepts:

| Property | Format | Meaning |
| --- | --- | --- |
| `vendor.cuttlefish.display.size` | `"<width>x<height>"` | New primary display resolution. |
| `vendor.cuttlefish.display.dpi` | `"<dpi>"` | New display density. Optional. |

`prebuilts/cvd_display_resize/` installs `/system_ext/bin/cvd_display_resize.sh`
and `/system_ext/etc/init/cvd_display_resize.rc`. Init property triggers invoke
the helper, which fans property writes into `cmd window size` and
`cmd window density`.

## Launcher and Taskbar Handling

`packages-apps-Launcher3.patch` contains the runtime Launcher3 work needed for
resize: desktop taskbar behavior, taskbar all-apps, responsive desktop profiles,
desktop-large-screen handling, invariant/device profile refresh after primary
display metric changes, all-apps profile updates, taskbar window recreation on
size/layout config changes, live `WindowManager.currentWindowMetrics()` bounds
for placement and sizing, and debug-only dynamic-display cache rebuild logs.

## Product Wiring

| Item | Where | Behavior |
| --- | --- | --- |
| Desktop/freeform resource defaults | `overlays/framework-res/res/values/config.xml` | Enables desktop windowing support for the product. |
| Per-display freeform seed | `prebuilts/display_settings/display_settings.xml` | Boots Cuttlefish display `local:0` into freeform mode with system decor. |
| Display resize sysprop helper | `prebuilts/cvd_display_resize/` | Applies `vendor.cuttlefish.display.*` property changes in the guest. |
| Desktop sysprop defaults | `config/desktop_windowing_policy.mk` | Enables desktop-first/freeform behavior. |
| Resize smoke test | `scripts/smoke_resize_desktop.sh` | Resizes repeatedly and checks `wm size` plus freeform task bounds. |

## Remaining Cleanup Ideas

These are not required for the current runtime path:

- Replace bespoke Launcher3 all-apps width bands with AndroidX
  `WindowSizeClass` if upstream moves that way.
- Add more Shell-side tests for existing freeform window bounds after rapid
  host resizes.
- Extend `ika` with a first-class display-resize subcommand if another front-end
  needs to drive the sysprop fallback directly.
