# LineageOS Desktop Patch Set

This directory contains source patches applied by
`../scripts/apply_source_patches.sh` and by the ROM build flow. The canonical
application order is `series`; keep this README in the same order so rebases can
quickly answer what each patch is supposed to preserve.

Most patches carry a short `Patch summary:` header as well. This file is the
cross-project index.

## Patches In Apply Order

| Patch | Project | Purpose |
| --- | --- | --- |
| [`external-google-highway.patch`](external-google-highway.patch) | `external/google-highway` | Marks `libhwy` as `vendor_available` so vendor-side desktop graphics/camera modules can depend on the upstream SIMD helper library instead of carrying a duplicate shim. |
| [`clang22.patch`](clang22.patch) | source root | Consolidates the cross-project Clang 22 compatibility fixes for external libraries, bionic, Trusty, `device/generic/goldfish`, `hardware/ril`, and `frameworks/native`, covering stricter character conversion, fixed-size string initialization, redundant virtual, nullable pointer, and uninitialized placeholder diagnostics. |
| [`external-minigbm.patch`](external-minigbm.patch) | `external/minigbm` | Allows mediaswcodec to read the Cuttlefish graphics debug property type used by minigbm debug probes, eliminating the matching enforcing-mode AVCs. |
| [`external-skia.patch`](external-skia.patch) | `external/skia` | Marks `libskia_skcms` as `vendor_available` so vendor modules can use Skia color-management support needed by the desktop graphics/camera stack. |
| [`external-XMP-Toolkit-SDK.patch`](external-XMP-Toolkit-SDK.patch) | `external/XMP-Toolkit-SDK` | Marks XMP Toolkit SDK libraries as `vendor_available` so vendor image-metadata users can link them across the vendor boundary. |
| [`art.patch`](art.patch) | `art` | Makes native-bridge namespaces drop APK-embedded `apk.zip!/lib/...` search paths. ARM apps running through x86 native bridge are more reliable when translated libraries are extracted as real files. |
| [`device-google-cuttlefish.patch`](device-google-cuttlefish.patch) | `device/google/cuttlefish` | Adds the Cuttlefish device foundation for desktop products: desktop product entries, PC feature declarations, batteryless health behavior, graphics property plumbing, desktop boot defaults, ADB/provisioning setup, microG GmsCore overlay (SYSTEM_ALERT_WINDOW) appop grant on boot, x86_64 Sandy Bridge/native-bridge product config, and ROM-first AVB key lookup. |
| [`frameworks-av.patch`](frameworks-av.patch) | `frameworks/av` | Raises software AVC encoder advertised and actual limits to support high-resolution desktop capture/playback, including larger sizes, higher bitrate, and AVC level 5.1. |
| [`frameworks-native-logspam.patch`](frameworks-native-logspam.patch) | `frameworks/native` | Demotes the benign InputDispatcher task-input-sink token correction that is expected in desktop/freeform mode, keeping the self-heal without flooding error logs. |
| [`frameworks-base.patch`](frameworks-base.patch) | `frameworks/base` | Applies the main platform and SystemUI desktop contract: desktop/freeform defaults, show-desktop shell plumbing, QS cleanup/blocklisting plus the desktop media-volume slider, keyguard clock suppression for desktop images, storage reporting tweaks, display/power behavior, double-tap shade toggling, status bar/shade adjustments, microG permission support, ScanPackageUtils 16 KB alignment check now also runs on system apps so third-party prebuilts (e.g. microG GmsCore) auto-enter page-size compat mode, and tests for the framework behavior. |
| [`frameworks-base-native-bridge.patch`](frameworks-base-native-bridge.patch) | `frameworks/base` | Adjusts package/native-library handling for x86-to-ARM native bridge installs so bridged APK native libraries are extracted as real files after ABI selection, while preserving normal native app behavior. |
| [`frameworks-base-logspam.patch`](frameworks-base-logspam.patch) | `frameworks/base` | Creates or treats missing recents task/image directories as empty so first-boot desktop recents cleanup does not repeatedly log directory-access errors. |
| [`system-core.patch`](system-core.patch) | `system/core` | Copies the host-supplied `ro.boot.timezone` into `persist.sys.timezone` during init so the guest boots with the host timezone. |
| [`system-sepolicy.patch`](system-sepolicy.patch) | `system/sepolicy` | Adds minimal desktop SELinux policy for expected VM behavior, including quieting known benign denials and allowing shell display-density property checks used by host tests. |
| [`packages-apps-Launcher3.patch`](packages-apps-Launcher3.patch) | `packages/apps/Launcher3` | Converts Launcher3/Quickstep into the primary desktop shell: taskbar-first navigation, desktop app drawer behavior, taskbar context menus, pinning, bubbles integration, freeform launch coordination, responsive device profiles, dynamic display refresh, show-desktop plumbing, taskbar popup/live-bounds fixes, visual effects, deep shortcuts, log cleanup, and broad test coverage. |
| [`vendor-lineage.patch`](vendor-lineage.patch) | `vendor/lineage` | Adds Lineage-side desktop product plumbing: optional app exclusions, empty launcher workspace overlays, and desktop defaults that belong in the Lineage vendor layer rather than AOSP framework/device projects. |
| [`build-make-releasetools.patch`](build-make-releasetools.patch) | `build/make` | Fixes target-files signing for embedded boot OTA zips that are intentionally not regenerated, and preserves signed `boot_16k.img` when present. |
| [`build-release.patch`](build-release.patch) | `build/release` | Sets release aconfig defaults for desktop builds: keeps SystemUI Quick Settings on the classic implementation and enables Launcher3 desktop visual-effect flags in generated release flag sets. |

## Maintenance Notes

- Add new patches to `series`; the build scripts use that file as the source of
  truth for project and order.
- Use `.` in `series` only for patches whose paths are rooted at the Android
  source checkout rather than an individual repo project.
- Keep broad platform behavior in `frameworks-base.patch` and native-bridge
  package manager behavior in `frameworks-base-native-bridge.patch`.
- If a patch exists only to avoid a rebase conflict, say that in both the patch
  header and this README.
