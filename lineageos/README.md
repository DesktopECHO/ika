# LineageOS Desktop (ROM build, phase 1 of 2)

LineageOS Desktop is a desktop-mode-only product layer for LineageOS 23.2 running in the Cuttlefish Android emulator. It is designed to be applied over an official LineageOS checkout with a local manifest.

This document covers **phase 1** of the ika build: producing the LineageOS Desktop ROM. Phase 2 (host Cuttlefish RPMs that bundle the ROM into `/usr/share/cuttlefish-common/lineageos`) is documented in the project [README.md](../README.md). For the full end-to-end flow, start there.

This directory contains the product profile, overlays, manifests, validation scripts, and source-level patches that this phase applies to a LineageOS 23.2 source checkout.

## Products

The lunch combos registered by `AndroidProducts.mk`:

```bash
lunch lineage_desktop_cf_arm64_pgagnostic-trunk_staging-userdebug
lunch lineage_desktop_cf_x86_64-trunk_staging-userdebug
```

(The space-separated form `lunch lineage_desktop_cf_arm64_pgagnostic trunk_staging userdebug` also works.)

This product targets Apple Silicon and x86-64 CPUs running in the Cuttlefish emulator.
Both targets use Cuttlefish's default 8 GiB thin-provisioned f2fs userdata image.

## Source Layout

This repository owns product policy only:

- desktop-only product makefiles
- desktop overlays
- desktop default settings
- build/package helper scripts
- documentation and validation scripts
- source-level patches for the projects that cannot be customized by overlays

Behavioral framework, Launcher, SystemUI, Shell, and Cuttlefish changes are
stored under `patches/` and applied to an official LineageOS 23.2 checkout.
That keeps the project archiveable as "official LineageOS plus this overlay"
without requiring separate fork branches.

## Desktop Contract

The desktop products intentionally keep phone/tablet behaviors out of the
runtime contract:

- desktop/freeform mode is re-applied at boot
- taskbar clicks focus, restore, or open desktop windows instead of entering
  split selection
- setup wizard, lockscreen, mobile data, battery UI, UWB, and Thread radios are
  disabled for the desktop profile
- ARM64 and x86-64 share the same desktop overlays, provisioning, userdata
  format, and taskbar behavior; native bridge support is the x86-64-only
  architecture addition
- host launches should use display dimensions and DPI that avoid host compositor
  scaling; the packaged `ika` launcher supplies a host-sized Cuttlefish display
  unless the user passes an explicit display override

The policy is split by layer so it stays reviewable:

- `config/desktop_windowing_policy.mk` owns product-level desktop properties
- `overlays/SettingsProvider` owns first-boot desktop defaults
- Cuttlefish `set_adb.sh` reapplies drift-prone settings every boot
- Launcher, framework, Shell, and Cuttlefish source changes are represented as
  patches under `patches/`

Additional project docs:

- `docs/windowing-policy.md` defines the desktop windowing behavior
- `docs/app-compatibility.md` tracks app support by architecture/runtime
- `docs/release-process.md` documents release inputs and output metadata

## One-Command Build

From a Linux build host:

```bash
git clone https://github.com/DesktopECHO/ika.git
cd ika

WORKSPACE="$HOME/lineageos-desktop-23.2" \
./lineageos/scripts/build_lineageos_desktop.sh
```

The resulting `lineageos-arm64/` and `lineageos-x86_64/` directories at the ika repo root are picked up by the `cuttlefish-lineageos` RPM in phase 2.

The script downloads LineageOS 23.2, installs this overlay and the microG
partner manifest as local manifests, syncs official LineageOS sources, overlays
the local `lineage_desktop` tree, applies the patches in `patches/`, refreshes
the microG prebuilts, installs the x86-64 ARM native bridge payload, and builds
both Cuttlefish products.

Before compiling, the script runs `scripts/validate_build_inputs.sh` to verify
that source patches are applied, required desktop aconfig flags are enabled,
userdata remains the default 8 GiB f2fs image, microG and WebView APKs are valid
zip files, and the x86-64 native bridge payload is complete. Set
`VALIDATE_BUILD_INPUTS=0` only for local experiments.

If `repo` is not installed, the script asks before downloading it and using
`sudo install` to copy it to `/usr/local/bin/repo`. It also attempts to install
missing basic host tools such as `git`, `git-lfs`, `python3`, `rsync`, `curl`,
and `tar` with `apt`, `dnf`, or `pacman` when available. Set
`AUTO_INSTALL_DEPS=0` to make missing tools a hard error instead.

Final Cuttlefish-ready bundles are written as directories at the ika repo
root:

```text
ika/lineageos-arm64/
ika/lineageos-x86_64/
```

The `cuttlefish-lineageos` RPM built by `tools/buildutils/build_packages.sh`
picks up the bundle matching the build host's architecture from that
location. Each bundle includes `build-info.json`, `build-info.txt`, and, when
`repo` can produce it, `source-manifest.xml`. These files record image
checksums, overlay commit state, microG APK checksums, WebView APK checksums,
and x86-64 native bridge metadata.

Override the destination with `OUTPUT_DIR=/some/other/dir` if you want the
bundles somewhere other than the ika repo root.

To build only one architecture:

```bash
scripts/build_lineageos_desktop.sh arm64
scripts/build_lineageos_desktop.sh x86_64
```

Useful environment overrides:

```text
WORKSPACE=/path/to/android/source
OUTPUT_DIR=/path/to/final/images    # default: ika repo root
JOBS=16
LINEAGE_BRANCH=lineage-23.2
REPO_INSTALL_PATH=/usr/local/bin/repo
AUTO_INSTALL_DEPS=0
RESET_PATCHED_PROJECTS=0
INCLUDE_MICROG=1
UPDATE_MICROG_PREBUILTS=1
MICROG_GMSCORE_RELEASE=latest
MICROG_GSFPROXY_RELEASE=latest
MICROG_FDROID_RELEASE=latest
MICROG_FDROID_PRIVILEGED_RELEASE=latest
INCLUDE_X86_ARM_NATIVE_BRIDGE=1
UPDATE_NATIVE_BRIDGE_PREBUILTS=1
NATIVE_BRIDGE_SOURCE_DIR=/path/to/extracted/android/system
NATIVE_BRIDGE_SDK_PACKAGE=/path/or/url/to/google_apis_x86_64_system_image.zip
NATIVE_BRIDGE_SDK_PACKAGE_SHA1=
VALIDATE_BUILD_INPUTS=1
```

The `WORKSPACE` directory is created if needed and reused on later runs. The
default workspace is treated as script-managed, so patched source projects are
reset before each `repo sync` and then patched again. For a custom workspace,
set `RESET_PATCHED_PROJECTS=1` if you want the same cleanup behavior.

`INCLUDE_MICROG=1` is the default product behavior. It syncs
`vendor/partner_gms` from the lineageos4microg manifest and includes GmsCore,
FakeStore, GsfProxy, F-Droid, and the F-Droid privileged extension. With
`UPDATE_MICROG_PREBUILTS=1`, the script downloads the latest official
`microg/GmsCore` custom-ROM APKs for GmsCore and FakeStore, the latest GsfProxy
APK from the microG F-Droid repository, and F-Droid/F-Droid Privileged Extension
from the official F-Droid repository before building. Set
`MICROG_GMSCORE_RELEASE` to a release tag, or set `MICROG_GSFPROXY_RELEASE`,
`MICROG_FDROID_RELEASE`, or `MICROG_FDROID_PRIVILEGED_RELEASE` to version
names/codes, to pin reproducible versions.

`INCLUDE_X86_ARM_NATIVE_BRIDGE=1` is the default for the x86-64 product. The
build helper runs `scripts/update_native_bridge_prebuilts.py`, which downloads
the Android 16 Google APIs x86-64 SDK system image, verifies its SHA1, extracts
Google's `libndk_translation.so` runtime, proxy libraries, and binfmt/init glue,
and installs those proprietary files into the workspace at
`vendor/lineage_desktop/prebuilts/native_bridge/system`. The binaries are not
committed to this repository. ARM/ARM64 guest bionic and Android support
libraries, including `/system/lib64/arm64/libc.so`, are built from the matching
LineageOS source tree via AOSP's native bridge support modules; they are not
copied from the SDK image or from the ARM64 ROM. When Google's SDK payload does
not include `libndk_translation_proxy_libm.so`, the updater generates Soong
metadata so the x86-64 build creates that proxy from AOSP's native bridge
support sources and links it to Google's translator runtime. The product imports
the generated translator payload and sets
`ro.dalvik.vm.native.bridge=libndk_translation.so` without changing any
partition or disk image sizes. The overlay also patches ART's native loader for
bridged app namespaces so extracted ARM64 app libraries are used directly and
APK zip library search paths are not handed to the translated ARM64 linker. For
apps whose selected ABI is translated, PackageManager forces native library
extraction even when the APK requested embedded library loading.

For offline or pinned builds, set `NATIVE_BRIDGE_SDK_PACKAGE` to a local SDK zip
or set `NATIVE_BRIDGE_SOURCE_DIR` to an already-extracted Android system image
root that contains `lib64/libndk_translation.so`. Manual x86-64 builds need
`USE_NDK_TRANSLATION_BINARY=true` exported before `lunch`; the one-command build
script sets it automatically.

Native bridge support is a compatibility feature, not a guarantee that every
ARM64 app will run on x86-64. Apps may still fail due to Play Integrity,
anti-tamper checks, missing proprietary services, unsupported GPU paths, or
translator limitations. Track those results in `docs/app-compatibility.md`.

The updater uses standard image extraction tools from the host or Android tree
when needed, including `simg2img`, `lpunpack`, `debugfs`, `fsck.erofs`, or `7z`.
If a required extractor is missing, it stops with the exact tool to install or
build.

## Manual Checkout

If you want to inspect or customize the Android tree yourself, the scripted
checkout is equivalent to:

```bash
repo init -u https://github.com/LineageOS/android.git -b lineage-23.2
mkdir -p .repo/local_manifests
curl -L -o .repo/local_manifests/lineageos-desktop.xml \
  https://raw.githubusercontent.com/DesktopECHO/ika/main/lineageos/manifests/lineageos-desktop.xml
curl -L -o .repo/local_manifests/lineageos4microg.xml \
  https://raw.githubusercontent.com/DesktopECHO/ika/main/lineageos/manifests/lineageos4microg.xml
repo sync -c -j"$(nproc)"
vendor/lineage_desktop/scripts/apply_source_patches.sh
vendor/lineage_desktop/scripts/update_microg_prebuilts.py
vendor/lineage_desktop/scripts/update_native_bridge_prebuilts.py
```

The manifest checks out `DesktopECHO/ika` under `vendor/ika` and links this
profile into `vendor/lineage_desktop`, which is the path used by the product
makefiles. The patch script applies the source-level changes listed in
`patches/series`.

The microG partner manifest is stored at `manifests/lineageos4microg.xml`.

## Existing-Checkout Helpers

Inside an already-synced Android source tree, the per-architecture helper
scripts remain available:

```bash
vendor/lineage_desktop/scripts/rebuild_cf_desktop_arm64.sh
vendor/lineage_desktop/scripts/rebuild_cf_desktop_x86_64.sh
```

The x86-64 helper also refreshes the native bridge payload unless
`INCLUDE_X86_ARM_NATIVE_BRIDGE=0` is set.

Those development helpers write to:

```text
/home/zero/temp/lineageos-desktop-arm64.tar
/home/zero/temp/lineageos-desktop-x86_64.tar
```

## Validation

Before building from an already-synced checkout:

```bash
vendor/lineage_desktop/scripts/validate_build_inputs.sh "$PWD" arm64 x86_64
```

This checks release inputs without needing a booted device.

After launching a Cuttlefish instance:

```bash
vendor/lineage_desktop/scripts/smoke_resize_desktop.sh mbp16.local:6520
```

This checks the desktop feature contract, resizes the display, verifies the
desktop settings remain enabled, and captures a screenshot.
