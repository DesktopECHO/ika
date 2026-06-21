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
| [`clang22.patch`](clang22.patch) | source root | Consolidates the cross-project Clang 22 compatibility fixes for external libraries, bionic, Trusty, `device/generic/goldfish`, `hardware/ril`, and `frameworks/native`, covering stricter diagnostics plus Trusty's Clang/Rust host setup. |
| [`external-trusty-lk-arm64-host-rust-link.patch`](external-trusty-lk-arm64-host-rust-link.patch) | `external/trusty/lk` | Lets Trusty's ARM64 host envsetup override Rust proc-macro linker args so GNU Rust host libraries link against host glibc instead of the musl sysroot, while preserving the existing default for x86 hosts. |
| [`external-trusty-lk-host-target-config.patch`](external-trusty-lk-host-target-config.patch) | `external/trusty/lk` | Records optional Trusty Clang host target/link flags in `toolchain.config` so incremental builds rebuild host objects when ARM64-host target/runtime flags change, while x86 keeps the empty default. |
| [`trusty-kernel-arm64-host-dtc.patch`](trusty-kernel-arm64-host-dtc.patch) | `trusty/kernel` | Lets Trusty's DTB rules use an env-provided DTC so ARM64 hosts can run Soong's host-built `dtc`, while x86 hosts keep the legacy x86 prebuilt default. |
| [`trusty-kernel-arm64-host-clang-target.patch`](trusty-kernel-arm64-host-clang-target.patch) | `trusty/kernel` | Threads an optional Clang host target/runtime flag set into Trusty host tool and test compiles, letting ARM64 hosts use the checked-in musl compiler runtimes while x86 hosts keep the empty/default path. |
| [`external-libpcap-bison-data.patch`](external-libpcap-bison-data.patch) | `external/libpcap` | Points libpcap's Bison genrules at the checked-in build-tools data directory so parser generation works with the project-managed prebuilts. |
| [`external-one-true-awk-bison-data.patch`](external-one-true-awk-bison-data.patch) | `external/one-true-awk` | Applies the same Bison data-directory fix to awk grammar generation, avoiding host-dependent parser failures. |
| [`external-iproute2-bison-data.patch`](external-iproute2-bison-data.patch) | `external/iproute2` | Applies the same Bison data-directory fix to traffic-control grammar generation, avoiding host-dependent parser failures. |
| [`external-mesa3d-bison-data.patch`](external-mesa3d-bison-data.patch) | `external/mesa3d` | Applies the same Bison data-directory fix to Mesa GLSL grammar generation, avoiding host-dependent parser failures. |
| [`external-stg-arm64-host-page-size.patch`](external-stg-arm64-host-page-size.patch) | `external/stg` | Removes `libjemalloc5` from the ARM64 musl host variant of `stg`/`stgdiff` so ABI dump generation runs on 16 KiB-page ARM64 hosts while x86 host variants keep the existing allocator. |
| [`prebuilts-rust-x86-musl-stdlib.patch`](prebuilts-rust-x86-musl-stdlib.patch) | `prebuilts/rust` | Adds the missing ARM64 musl host target properties for Rust stdlib prebuilts, using the real `linux-arm64` Rust payload on ARM64 hosts. |
| [`external-musl-lfs64-compat.patch`](external-musl-lfs64-compat.patch) | `external/musl` | Restores public musl header visibility and weak LFS64 alias symbols (`open64`, `stat64`, `mmap64`, etc.) needed by the Rust musl host stdlib shim on ARM64 hosts. |
| [`external-rust-android-crates-io-arm64-host-cross.patch`](external-rust-android-crates-io-arm64-host-cross.patch) | `external/rust/android-crates-io` | Enables required Rust host-cross modules, including bindgen-related crates, for ARM64 host builds. |
| [`external-cronet-arm64-host-cross.patch`](external-cronet-arm64-host-cross.patch) | `external/cronet` | Makes Cronet host tools and Rust pieces host-cross capable while keeping x86-specific compiler flags scoped to x86 targets. |
| [`external-sdv-vsomeip-arm64-host-cross.patch`](external-sdv-vsomeip-arm64-host-cross.patch) | `external/sdv/vsomeip` | Restricts SSE flags to x86_64 musl variants so the module graph can be generated on ARM64 hosts without x86-only flags leaking into ARM64 builds. |
| [`external-minigbm.patch`](external-minigbm.patch) | `external/minigbm` | Allows mediaswcodec to read the Cuttlefish graphics debug property type used by minigbm debug probes, eliminating the matching enforcing-mode AVCs. |
| [`external-skia.patch`](external-skia.patch) | `external/skia` | Marks `libskia_skcms` as `vendor_available` so vendor modules can use Skia color-management support needed by the desktop graphics/camera stack. |
| [`external-XMP-Toolkit-SDK.patch`](external-XMP-Toolkit-SDK.patch) | `external/XMP-Toolkit-SDK` | Marks XMP Toolkit SDK libraries as `vendor_available` so vendor image-metadata users can link them across the vendor boundary. |
| [`art.patch`](art.patch) | `art` | Makes native-bridge namespaces drop APK-embedded `apk.zip!/lib/...` search paths. ARM apps running through x86 native bridge are more reliable when translated libraries are extracted as real files. |
| [`device-google-cuttlefish.patch`](device-google-cuttlefish.patch) | `device/google/cuttlefish` | Adds the Cuttlefish device foundation for desktop products: desktop product entries, PC feature declarations, batteryless health behavior, graphics property plumbing, desktop boot defaults, ADB/provisioning setup, microG GmsCore overlay (SYSTEM_ALERT_WINDOW) appop grant on boot, x86_64 Sandy Bridge/native-bridge product config, and ROM-first AVB key lookup. |
| [`frameworks-av.patch`](frameworks-av.patch) | `frameworks/av` | Raises software AVC encoder advertised and actual limits to support high-resolution desktop capture/playback, including larger sizes, higher bitrate, and AVC level 5.1. |
| [`frameworks-native-logspam.patch`](frameworks-native-logspam.patch) | `frameworks/native` | Demotes the benign InputDispatcher task-input-sink token correction that is expected in desktop/freeform mode, keeping the self-heal without flooding error logs. |
| [`frameworks-base.patch`](frameworks-base.patch) | `frameworks/base` | Applies the main platform and SystemUI desktop contract: desktop/freeform defaults, show-desktop shell plumbing, QS cleanup/blocklisting plus the desktop media-volume slider, keyguard clock suppression for desktop images, storage reporting tweaks, display/power behavior, double-tap shade toggling, status bar/shade adjustments, microG permission support, missing recents directory log cleanup, ScanPackageUtils 16 KB alignment check now also runs on system apps so third-party prebuilts (e.g. microG GmsCore) auto-enter page-size compat mode, and tests for the framework behavior. |
| [`frameworks-base-native-bridge.patch`](frameworks-base-native-bridge.patch) | `frameworks/base` | Adjusts package/native-library handling for x86-to-ARM native bridge installs so bridged APK native libraries are extracted as real files after ABI selection, while preserving normal native app behavior. |
| [`system-core.patch`](system-core.patch) | `system/core` | Copies the host-supplied `ro.boot.timezone` into `persist.sys.timezone` during init so the guest boots with the host timezone. |
| [`system-sepolicy.patch`](system-sepolicy.patch) | `system/sepolicy` | Adds minimal desktop SELinux policy for expected VM behavior, including quieting known benign denials and allowing shell display-density property checks used by host tests. |
| [`system-sepolicy-checkfc-arm64-getopt.patch`](system-sepolicy-checkfc-arm64-getopt.patch) | `system/sepolicy` | Stores `checkfc`'s `getopt()` result in an `int` so ARM64 hosts correctly see the `-1` end-of-options sentinel instead of falling through to usage output. |
| [`packages-apps-Launcher3.patch`](packages-apps-Launcher3.patch) | `packages/apps/Launcher3` | Converts Launcher3/Quickstep into the primary desktop shell: taskbar-first navigation, desktop app drawer behavior, taskbar context menus, pinning, bubbles integration, freeform launch coordination, responsive device profiles, dynamic display refresh, show-desktop plumbing, taskbar popup/live-bounds fixes, visual effects, deep shortcuts, log cleanup, and broad test coverage. |
| [`vendor-lineage.patch`](vendor-lineage.patch) | `vendor/lineage` | Adds Lineage-side desktop product plumbing: optional app exclusions, empty launcher workspace overlays, and desktop defaults that belong in the Lineage vendor layer rather than AOSP framework/device projects. |
| [`vendor-lineage-arm64-host-kernel-tools.patch`](vendor-lineage-arm64-host-kernel-tools.patch) | `vendor/lineage` | Uses native ARM64 host `lz4` and `pahole` for kernel builds while preserving the existing x86 prebuilt tool paths on non-ARM64 hosts. |
| [`vendor-lineage-arm64-host-mogrify.patch`](vendor-lineage-arm64-host-mogrify.patch) | `vendor/lineage` | Lets bootanimation generation fall back to native host ImageMagick `mogrify` when the checked-in x86 tools-lineage prebuilt cannot execute on ARM64 hosts, while x86 hosts keep the prebuilt path. |
| [`build-soong-arm64-host.patch`](build-soong-arm64-host.patch) | `build/soong` | Adds ARM64 host support across Soong's host tags, install paths, Clang/bindgen selection, Rust host-cross modules, proc macros, and JDK path handling, while keeping x86-hosted `linux_musl_arm64` Rust artifacts on the musl ABI with musl CRT/libc deps. |
| [`build-make-arm64-host.patch`](build-make-arm64-host.patch) | `build/make` | Uses the active host prebuilt tag for LLVM tools, compiler-rt/libc++ paths, and host build rules so ARM64 hosts use ARM64 prebuilts. |
| [`prebuilts-build-tools-arm64-host.patch`](prebuilts-build-tools-arm64-host.patch) | `prebuilts/build-tools` | Enables ARM64 and `linux_musl_arm64` variants of the checked-in build tools needed by Soong and Make. |
| [`prebuilts-jdk21-arm64-host.patch`](prebuilts-jdk21-arm64-host.patch) | `prebuilts/jdk/jdk21` | Enables JDK 21 prebuilt build-tool modules on ARM64 hosts. |
| [`trusty-user-base-arm64-host-boringssl.patch`](trusty-user-base-arm64-host-boringssl.patch) | `trusty/user/base` | Allows Trusty's host BoringSSL archive to build on ARM64 Linux hosts while preserving the existing x86-64 host path. |
| [`frameworks-libs-binary-translation-arm64-host.patch`](frameworks-libs-binary-translation-arm64-host.patch) | `frameworks/libs/binary_translation` | Broadens binary-translation host helper defaults so required host-side tools can be built from ARM64 hosts without x86-only defaults. |
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
