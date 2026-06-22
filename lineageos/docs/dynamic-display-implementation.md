# Dynamic Display Implementation

LineageOS Desktop treats the Cuttlefish primary display as a resizable desktop
surface. The host launcher starts Cuttlefish with an initial display size and
DPI derived from the host monitor, then opens ika-scrcpy as the front-end.

## Runtime Resize Flow

The default viewer path uses raw Cuttlefish frames:

1. `tools/ika` launches ika-scrcpy with `--cuttlefish-frames-socket=...` and
   `--dpi=<computed-or-user-value>`.
2. ika-scrcpy listens for SDL window resize events and debounces them.
3. For raw Cuttlefish frames, ika-scrcpy resizes the physical Cuttlefish
   display by spawning:

   ```bash
   cvd display resize \
     --instance_num=<N> \
     --display_id=<ID> \
     --display=width=<W>,height=<H>,dpi=<DPI>,refresh_rate_hz=60
   ```

4. ika-scrcpy also sends `TYPE_RESIZE_DISPLAY` to the scrcpy server so the
   Android-side control path can acknowledge `DISPLAY_READY` when the display
   settles.
5. Android reports the new display metrics through `DisplayManager` and the
   normal configuration-change path.

## Guest Fallback Contract

For manual testing and future host-side actors that do not go through
ika-scrcpy, the product also accepts:

| Property | Format | Meaning |
| --- | --- | --- |
| `vendor.cuttlefish.display.size` | `"<width>x<height>"` | New primary display resolution. |
| `vendor.cuttlefish.display.dpi` | `"<dpi>"` | New display density. Optional. |

`prebuilts/cvd_display_resize/` installs `/system_ext/bin/cvd_display_resize.sh`
and `/system_ext/etc/init/cvd_display_resize.rc`. Init property triggers invoke
the helper, which fans property writes into `cmd window size` and
`cmd window density`.

## Launcher And Taskbar Handling

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
