# Dynamic display handling — implementation reference

LineageOS Desktop runs on Cuttlefish. The host-side launcher [tools/ika](../../tools/ika) starts `cvd_internal_start` with an initial `--display=width=W,height=H,dpi=D` derived from the host's primary monitor, then opens **scrcpy** as the display front-end (`tools/ika:842 start_scrcpy_with_retries`). ika exits after boot; the user interacts with the scrcpy window from then on, including resizing it at will.

## Runtime resize is driven by scrcpy, not ika

The scrcpy fork in this repo (`scrcpy/`) already implements end-to-end window-resize-to-device-resize:

1. **scrcpy client** ([scrcpy/app/src/screen.c](../../scrcpy/app/src/screen.c)) — SDL window-resize event triggers `sc_screen_on_resize`, debounces via `FLEX_DISPLAY_RESIZE_SETTLE_DELAY`, and calls `sc_screen_maybe_request_display_resize` which sends a `TYPE_RESIZE_DISPLAY` control message to the server with the new pixel size (8-pixel aligned).
2. **scrcpy server** ([scrcpy/server/src/main/java/com/genymobile/scrcpy/control/Controller.java#setDisplaySize](../../scrcpy/server/src/main/java/com/genymobile/scrcpy/control/Controller.java) line 796) — receives the message and calls `Device.setDisplaySizeAndDensity(displayId, requestedSize, requestedDpi)`. For the primary display, `requestedDpi` is **0** unless flex-display DPI is explicitly set, meaning **scrcpy resizes do not change density** by default.
3. **AOSP framework** — `Device.setDisplaySizeAndDensity` is the same path as `adb shell wm size` / `wm density`; it lands in `WindowManagerService.setForcedDisplaySize`, propagates through `LogicalDisplayMapper.setDisplayInfoOverrideFromWindowManagerLocked` → `EVENT_DISPLAY_BASIC_CHANGED` → `DisplayManager.DisplayListener#onDisplayChanged`.
4. **Launcher3** — the existing Launcher3 patch already plumbs `DisplayController` for desktop sizing (`getDynamicDesktopGridSize`, `applyResponsiveAllAppsLayout`, etc.) and `TaskbarManagerImpl.onConfigurationChanged` fires on the config delta.

**The actual gap this product needs to close**: scrcpy's resize sets `dpi=0` (no density change), so `Configuration.diff` reaching `TaskbarManagerImpl.onConfigurationChanged` doesn't carry `CONFIG_DENSITY`; depending on diff semantics it may not carry `CONFIG_SCREEN_SIZE` either. The cached `InvariantDeviceProfile` can stay stale and the workspace grid never recomputes.

[**R1**](#r1) is the load-bearing fix: when the primary display reports any size/density delta or `dp == null`, force `InvariantDeviceProfile.onConfigChanged(mContext)`.

## Secondary contract: `vendor.cuttlefish.display.*` sysprops

For manual testing (`adb shell setprop`) and for host-side actors that don't go through scrcpy, the product also accepts:

| Property | Format | Meaning |
|---|---|---|
| `vendor.cuttlefish.display.size` | `"<width>x<height>"` (e.g. `"1920x1080"`) | New display resolution. |
| `vendor.cuttlefish.display.dpi` | `"<dpi>"` (e.g. `"160"`) | New display density. Optional. |

A guest init-triggered helper ([prebuilts/cvd_display_resize/](../prebuilts/cvd_display_resize/)) translates property writes into `cmd window size` / `cmd window density`, landing in the same `setForcedDisplaySize` path as scrcpy. This is a redundant fallback channel — scrcpy's path is the production one. Useful for repro, testing, or future host-side actors that aren't scrcpy.

## Already wired up (product / overlay / scripts)

| Item | Where | Behavior |
|---|---|---|
| `config_freeformWindowManagement`, `config_supportsMultiWindow`, `config_supportsSplitScreenMultiWindow`, `config_perDisplayFocusEnabled` | [overlays/framework-res/res/values/config.xml](../overlays/framework-res/res/values/config.xml) | Desktop windowing + per-display focus are now product-owned, not inherited from the Cuttlefish base. |
| Per-display windowing seed | [prebuilts/display_settings/display_settings.xml](../prebuilts/display_settings/display_settings.xml) → `/vendor/etc/display_settings.xml` (wired via `PRODUCT_COPY_FILES` in [config/common_desktop_mode_only.mk](../config/common_desktop_mode_only.mk)) | Cuttlefish default display `local:0` boots into `WINDOWING_MODE_FREEFORM` with system decors. DPI is intentionally absent — `/usr/bin/ika` controls density. |
| Host-window resize listener (R5) | [prebuilts/cvd_display_resize/](../prebuilts/cvd_display_resize/) → `/system_ext/bin/cvd_display_resize.sh` + `/system_ext/etc/init/cvd_display_resize.rc`. SELinux extension to the existing `set_adb` domain lives in the cuttlefish patch. | When ika (or any host actor) writes `vendor.cuttlefish.display.size` or `.dpi`, the init property trigger fires `cmd window size` / `cmd window density`, propagating the new geometry through `LogicalDisplayMapper` to Launcher and Shell. |
| Desktop persist syspropsmust survive user `setprop` clearing | `set_adb.sh` (hunk in [patches/device-google-cuttlefish.patch](../patches/device-google-cuttlefish.patch)) | `persist.wm.debug.enter_desktop_by_default_on_freeform_display` and `persist.wm.debug.force_desktop_first_on_default_display_for_testing` are reasserted every boot. |
| User-mutable settings seeded once | Same patch | `pointer_speed` and `screen_off_timeout` are inside the `lineage_desktop_provisioned` sentinel — user adjustments survive reboot. |
| Aconfig validator with undefined/disabled split | [scripts/check_desktop_flags.sh](../scripts/check_desktop_flags.sh) | Build-time validator distinguishes "flag not declared in this AOSP rev" from "flag declared but disabled in this release config." |
| Smoke test multi-resize + freeform-bounds assertion | [scripts/smoke_resize_desktop.sh](../scripts/smoke_resize_desktop.sh) | Resizes three times; asserts `wm size` converges to each value; asserts freeform task bounds stay inside the new viewport. |

## Deferred — source-patch work

The following changes need to land in the AOSP tree itself and require a synced workspace to author/verify against. Each item below has been spec'd in enough detail that an implementer with the tree open can write the patch directly.

### R1 — Launcher IDP recompute on display info change

**File:** `packages/apps/Launcher3/quickstep/src/com/android/launcher3/taskbar/TaskbarManagerImpl.java`

**Seam:** the existing patch already touches `onConfigurationChanged` at the hunk around the `isExternalDisplay`/`createExternalDeviceProfile` block. Immediately after `int configDiff = mOldConfig.diff(newConfig) & ~SKIP_RECREATE_CONFIG_CHANGES;`, add:

```java
// LineageOS Desktop: when the virtual display resizes (wm size / wm density from
// /usr/bin/ika, or a real DisplayInfo change), force the workspace IDP to recompute
// even if Configuration didn't see a DENSITY or SCREEN_SIZE diff at the activity
// boundary. Belt-and-suspenders against the case where Configuration was batched
// past the resize.
if (displayId == mPrimaryDisplayId
        && (configDiff & (ActivityInfo.CONFIG_DENSITY | ActivityInfo.CONFIG_SCREEN_SIZE)) != 0) {
    LauncherAppState appState = LauncherAppState.getInstanceNoCreate();
    if (appState != null) {
        appState.getInvariantDeviceProfile().onConfigChanged(mContext);
    }
}
```

**Imports to add (if not present):**
- `import android.content.pm.ActivityInfo;`
- `import com.android.launcher3.LauncherAppState;`

**Aconfig:** `com.android.launcher3/enable_scalability_for_desktop_experience` (already in the project list).

### R2 — Launcher.onResume width-delta belt-and-suspenders

**File:** `packages/apps/Launcher3/src/com/android/launcher3/Launcher.java`

**Seam:** add a private cache field `private WindowMetrics mLastWindowMetrics;` and extend `onResume()`:

```java
@Override
protected void onResume() {
    super.onResume();
    // ... existing onResume body ...

    WindowMetrics current = WindowMetricsCalculator.getOrCreate()
            .computeCurrentWindowMetrics(this);
    if (mLastWindowMetrics != null) {
        Rect prev = mLastWindowMetrics.getBounds();
        Rect curr = current.getBounds();
        int prevDpi = mLastWindowMetrics.getDensity();
        int currDpi = current.getDensity();
        if (prev.width() != curr.width()
                || prev.height() != curr.height()
                || prevDpi != currDpi) {
            LauncherAppState appState = LauncherAppState.getInstanceNoCreate();
            if (appState != null) {
                appState.getInvariantDeviceProfile().onConfigChanged(this);
            }
        }
    }
    mLastWindowMetrics = current;
}
```

**Imports:**
- `import androidx.window.layout.WindowMetricsCalculator;`
- `import android.view.WindowMetrics;`
- `import android.graphics.Rect;`

Note: `BubbleBarView` already uses `WindowMetricsCalculator` so the dependency is on the classpath.

### R6 — DesktopTasksController clamps existing freeform bounds on display change

**File:** `frameworks/base/libs/WindowManager/Shell/src/com/android/wm/shell/desktopmode/DesktopTasksController.kt`

**Seam:** the existing `frameworks-base.patch` already touches this file for `toggleShowDesktop`, `restoreShownDesktopTasks`, `restoreMinimizedDesktopTasks`. Add a new method and register it with the displays-changed listener:

```kotlin
init {
    // ... existing init block ...
    displayController.addDisplayWindowListener(object : DisplayController.OnDisplaysChangedListener {
        override fun onDisplayConfigurationChanged(displayId: Int, newConfig: Configuration) {
            clampFreeformTasksToDisplay(displayId)
        }
    })
}

private fun clampFreeformTasksToDisplay(displayId: Int) {
    val displayLayout = displayController.getDisplayLayout(displayId) ?: return
    val displayBounds = Rect(0, 0, displayLayout.width(), displayLayout.height())
    val activeTasks = taskRepository.getActiveTasks(displayId)
    for (taskId in activeTasks) {
        val task = shellTaskOrganizer.getRunningTaskInfo(taskId) ?: continue
        if (task.windowingMode != WINDOWING_MODE_FREEFORM) continue
        val currentBounds = task.configuration.windowConfiguration.bounds
        val clamped = Rect(currentBounds)
        // Translate into bounds first, then clamp width/height to the new display.
        if (clamped.right > displayBounds.right) clamped.offset(displayBounds.right - clamped.right, 0)
        if (clamped.bottom > displayBounds.bottom) clamped.offset(0, displayBounds.bottom - clamped.bottom)
        if (clamped.left < 0) clamped.offset(-clamped.left, 0)
        if (clamped.top < 0) clamped.offset(0, -clamped.top)
        clamped.intersect(displayBounds)
        if (clamped.width() < minimumTaskBounds.width()) clamped.right = clamped.left + minimumTaskBounds.width()
        if (clamped.height() < minimumTaskBounds.height()) clamped.bottom = clamped.top + minimumTaskBounds.height()
        if (clamped != currentBounds) {
            val wct = WindowContainerTransaction()
            wct.setBounds(task.token, clamped)
            shellTaskOrganizer.applyTransaction(wct)
        }
    }
}
```

**Aconfig:** `com.android.window.flags/enable_windowing_dynamic_initial_bounds` (already in the project list).

**Rebase risk:** `DesktopTasksController.kt` is the highest-conflict file in the patch set; isolate this hunk so it can be reverted without losing other desktop work.

### R9 — Caption-bar inset handling in Launcher workspace

**Files:**
- `packages/apps/Launcher3/src/com/android/launcher3/Workspace.java`
- `packages/apps/Launcher3/src/com/android/launcher3/Hotseat.java`

Neither file is touched by the existing patch, so this is a vanilla-tree edit.

**Workspace.java** — override `onApplyWindowInsets`:

```java
@Override
public WindowInsets onApplyWindowInsets(WindowInsets insets) {
    Insets caption = insets.getInsets(WindowInsets.Type.captionBar());
    if (caption.top > 0) {
        setPadding(getPaddingLeft(), getPaddingTop() + caption.top,
                getPaddingRight(), getPaddingBottom());
    }
    return super.onApplyWindowInsets(insets);
}
```

Apply the same pattern in `Hotseat.java` if hotseat icons appear under the system caption strip.

**Aconfig:** `com.android.window.flags/enable_themed_app_headers` (already in the project list).

### R14 — `PROPERTY_SUPPORTS_MULTI_INSTANCE_SYSTEM_UI`

**File:** `frameworks/base/packages/SystemUI/AndroidManifest.xml`

RROs cannot add manifest `<property>` entries, so this requires a source patch. Inside `<application>`:

```xml
<property
    android:name="android.window.PROPERTY_SUPPORTS_MULTI_INSTANCE_SYSTEM_UI"
    android:value="true" />
```

### R3 — `WindowSizeClass` migration (P2, cosmetic)

Replace bespoke DP bands in `quickstep/src/com/android/launcher3/taskbar/allapps/TaskbarAllAppsContainerView.java#getResponsiveDesktopTaskbarColumns` with `androidx.window.core.layout.WindowSizeClass`. Drop the four `DESKTOP_TASKBAR_ALL_APPS_*_WIDTH_DP` constants. AOSP-canonical, but rebase-medium because if Launcher3 upstream introduces its own adapter the bands will collide.

## Why these were deferred

Hand-authoring supplementary patches without a synced AOSP workspace risks:
1. Wrong import paths — compile errors after `apply_source_patches.sh`.
2. Wrong context lines — `git apply` fuzz-fail or apply-to-wrong-location.
3. Wrong method signatures — runtime crash that's hard to trace to the patch.

The product-layer work (overlays, scripts, set_adb.sh inside the cuttlefish patch where the post-patch content is the entire file) is verifiable from this repo alone. The source-level changes above need to be authored inside a `repo sync`'d tree where the post-existing-patch content can be opened in an editor.

## Workflow for landing the deferred items

From a synced LineageOS Desktop tree:

```bash
cd $ANDROID_ROOT
vendor/lineage_desktop/scripts/apply_source_patches.sh
# now make the R1/R2/R6/R9/R14 edits as Java/Kotlin/XML changes in the tree
cd packages/apps/Launcher3 && git diff > /tmp/launcher3-dynamic-display.patch
cd $ANDROID_ROOT/frameworks/base && git diff > /tmp/frameworks-base-dynamic-display.patch
# fold the diffs back into vendor/lineage_desktop/patches/ or land as new patch files
# add the new patches to vendor/lineage_desktop/patches/series in the right order
```

Run `vendor/lineage_desktop/scripts/validate_build_inputs.sh "$PWD"` to confirm everything applies. Build with the standard `rebuild_cf_desktop_*.sh`, then validate with the extended `smoke_resize_desktop.sh` which now exercises the dynamic-display contract.
