# LineageOS Desktop 

LineageOS Desktop is a product layer for LineageOS 23.2 running in the Cuttlefish Android emulator. It is designed to be applied over an official LineageOS checkout with a local manifest.

This document covers the first part of the ika build, producing the LineageOS Desktop ROM. The second part handles creation of host packages, including `ika-lineageos`, and is documented in the project [README.md](../README.md). For the full end-to-end flow, start there or run `../ika-build` from the repository root.

This directory contains the product profile, overlays, manifests, validation scripts, and source-level patches that this phase applies to a LineageOS 23.2 source checkout.

## Products

The lunch combos registered by `AndroidProducts.mk`:

```bash
lunch lineage_desktop_cf_arm64_pgagnostic-trunk_staging-userdebug
lunch lineage_desktop_cf_arm64_pgagnostic-trunk_staging-user
lunch lineage_desktop_cf_x86_64-trunk_staging-userdebug
lunch lineage_desktop_cf_x86_64-trunk_staging-user
```

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

## Desktop Mode

The desktop products split app compatibility identity from windowing behavior:

- Android and app stores see a tablet-shaped, Wi-Fi-only, non-telephony device
- desktop/freeform mode is re-applied at boot
- taskbar clicks focus, restore, or open desktop windows instead of entering
  split selection
- setup wizard, lockscreen, mobile data, battery UI, UWB, and Thread radios are
  disabled for the desktop profile
- desktop mode is enabled by resources/properties instead of
  `android.hardware.type.pc`, which Play treats as a PC/desktop device
- the ARM64 ROM targets ARMv8.2-A-or-newer devices
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
- Launcher, framework, and Shell changes are represented as
  patches under `patches/`

Additional project docs:

- `docs/windowing-policy.md` defines the desktop windowing behavior
- `docs/app-compatibility.md` tracks app support by architecture/runtime
- `docs/release-process.md` documents release inputs and output metadata

## Host Requirements

Building this ROM is a full LineageOS source build and is resource-intensive:

- **RAM:** 32 GB recommended, 16 GB will work but the build will be much slower.
  The build script will add temporary zram swap as needed.
- **Storage:** 500 GB minimum of free space. 
- **CPU:** x86-64 and ARM64 are both supported as build hosts.

### ARM64 Build Hosts

ARM64 host builds require real `linux-arm64` prebuilts for host tools. The
build script refuses symlinked `linux-x86` substitutions. Clang-tools are
pulled from AOSP's `platform/prebuilts/clang-tools` `mirror-goog-main-prebuilts`
branch by default; provide the remaining ARM64 Rust, CMake, JDK, Go, Clang, and
build-tools prebuilts before building. The Rust prebuilt must include both
`aarch64-unknown-linux-gnu` and `aarch64-unknown-linux-musl` stdlibs. ARM64
host builds run natively with the ARM64 prebuilts prepared by the build script,
including on Apple Silicon's 16 KiB-page kernels.

## Build LineageOS Desktop

```bash
git clone https://github.com/DesktopECHO/ika.git
cd ika

./lineageos/scripts/build_lineageos_desktop.sh
```

This will build the ROM automatically for the running CPU architecture.
For x86-64 hosts, append `all` to the command to build both ARM64 and x86-64 release bundles.

The build script defaults to `BUILD_VARIANT=userdebug` so local builds keep
debug-friendly behavior such as `adb root`. For release-style images, pass
`BUILD_VARIANT=user`:

```bash
BUILD_VARIANT=user ./lineageos/scripts/build_lineageos_desktop.sh x86_64
```

`eng` is accepted for experiments, but release bundles should use `user` and the
normal signing flow. `WITH_ADB_INSECURE` is only enabled for `userdebug` builds;
`scrcpy` does not require root or insecure ADB. Cuttlefish keeps release-style
`user` builds reachable by enabling guest TCP ADB on port `5555`, disabling ADB
key authorization with `ro.adb.secure=0`, and exposing the host ADB proxy only on
`127.0.0.1:6520` for the first instance.

The resulting `lineageos-arm64/` and/or `lineageos-x86_64/` directories at the ika
repo root will be picked up by the `ika-lineageos` package in the second phase.

## How Stuff Works

The script downloads LineageOS 23.2, installs this overlay and the selected
provider manifest, syncs official LineageOS sources, overlays the local
`lineage_desktop` tree, applies the patches in `patches/`, installs the x86-64
ARM64 native bridge payload when that target is requested, and builds the
requested Cuttlefish product or products.

Before compiling, the script runs `scripts/lib/validate_build_inputs.sh` to verify
that source patches are applied, required desktop aconfig flags are enabled,
patched XML files do not reference missing local XML resources, userdata remains
the default ~64 GB ext4 image, selected provider and WebView prebuilts are
valid, and the x86-64 native bridge payload is complete. Set
`VALIDATE_BUILD_INPUTS=0` only for local experiments.

The build signs target-files and extracted images before packaging the final
Cuttlefish bundles. Signing keys live in `ANDROID_CERTS_DIR` (default:
`~/.android-certs`). On a new clone, `./ika-build` prepares them immediately
after installing build dependencies. Direct ROM builds use `signing_common.sh`
to run `tools/buildutils/setup_keys.sh` before compiling. That setup prompts
once for a certificate identity, writes it to `~/.config/ika/signing.conf`, and
generates any missing APK/APEX keys. `STRICT_APEX_SIGNING=1` and
`STRICT_PRESIGNED_ALLOWLIST=1` are the defaults; relax them only for local
debugging.

If `repo` is not installed, `./ika-build` downloads it during dependency setup
and installs it to `$HOME/.local/bin/repo`. Missing host tools such as `git`,
`git-lfs`, `python3`, `rsync`, `curl`, and `tar` are a hard error; `./ika-build`
installs them with the rest of the build dependencies
(`tools/buildutils/lib/dependencies.sh`).
Git network operations run with a build-local git config that enables repo
color output, sets a local builder identity, and rewrites common GitHub SSH/git
remotes to anonymous HTTPS, so public sources can sync without a GitHub account
or SSH key.

LineageOS source sync uses repo partial clone by default to reduce initial
downloads. Partial-clone checkouts run in a conservative phased mode because the
missing file blobs are fetched lazily during checkout. Set `REPO_CLONE_FILTER=`
to force full clones, or lower `REPO_SYNC_CHECKOUT_JOBS` if a network/proxy still
has trouble with lazy blob fetches.

Final Cuttlefish-ready bundles are written as directories at the ika repo
root:

```text
ika/lineageos-arm64/
ika/lineageos-x86_64/
```

The `ika-lineageos` package built by `tools/buildutils/build_packages.sh`
picks up the bundle matching the build host's architecture from that
location. Each bundle includes `build-info.json`, `build-info.txt`, and, when
`repo` can produce it, `source-manifest.xml`. These files record image
checksums, overlay commit state, microG APK checksums, WebView APK checksums,
and x86-64 native bridge metadata.

Override the destination with `OUTPUT_DIR=/some/other/dir` if you want the
bundles somewhere other than the ika repo root. Signed target-files staging also
uses `OUTPUT_DIR`, so point it at a filesystem with enough free space for the
final signing and bundle extraction steps.

To build only one architecture:

```bash
./lineageos/scripts/build_lineageos_desktop.sh arm64
./lineageos/scripts/build_lineageos_desktop.sh x86_64
```

Use `--microg` or `--mtg` to include that provider:

```bash
./lineageos/scripts/build_lineageos_desktop.sh --microg arm64
./lineageos/scripts/build_lineageos_desktop.sh --mtg x86_64
```

Useful environment overrides:

```text
WORKSPACE=/path/to/android/source
OUTPUT_DIR=/path/to/final/images    # default: ika repo root
BUILD_VARIANT=userdebug             # userdebug, user, or eng
JOBS=16
LINEAGE_BRANCH=lineage-23.2
REPO_INSTALL_PATH=$HOME/.local/bin/repo
REPO_CLONE_FILTER=blob:none     # empty uses full clones
REPO_SYNC_JOBS=4                # also used as partial-clone network jobs
REPO_SYNC_CHECKOUT_JOBS=4
RESET_PATCHED_PROJECTS=0
UPDATE_MICROG_PREBUILTS=1
MICROG_GMSCORE_RELEASE=latest
MICROG_GSFPROXY_RELEASE=latest
MICROG_FDROID_RELEASE=latest
MICROG_FDROID_PRIVILEGED_RELEASE=latest
MICROG_PREBUILT_CACHE_DIR=~/ika-build/microg-prebuilts
INCLUDE_X86_ARM_NATIVE_BRIDGE=1
UPDATE_NATIVE_BRIDGE_PREBUILTS=1
NATIVE_BRIDGE_SOURCE_DIR=/path/to/extracted/android/system
NATIVE_BRIDGE_SDK_PACKAGE=/path/or/url/to/google_apis_x86_64_system_image.zip
NATIVE_BRIDGE_SDK_PACKAGE_SHA1=
VALIDATE_BUILD_INPUTS=1
```

The `WORKSPACE` directory is created if needed and reused on later runs. The
default workspace is `ika/lineageos/src` and is treated as script-managed, so
patched source projects are reset before each `repo sync` and then patched
again. For a custom workspace, set `RESET_PATCHED_PROJECTS=1` if you want the
same cleanup behavior.

`--microg` syncs `vendor/partner_gms` from the lineageos4microg manifest and
includes GmsCore, FakeStore, GsfProxy, F-Droid, and the F-Droid privileged
extension. With `UPDATE_MICROG_PREBUILTS=1`, the script resolves the newest
published, non-draft `microg/GmsCore` entry from GitHub Releases, including an
entry marked prerelease, and downloads its official GmsCore and FakeStore APKs.
It also downloads the latest official GsfProxy, F-Droid, and F-Droid Privileged
Extension APKs before
building the ROM. Set `MICROG_GMSCORE_RELEASE` to an explicit published release
tag, or set `MICROG_GSFPROXY_RELEASE`,
`MICROG_FDROID_RELEASE`, or `MICROG_FDROID_PRIVILEGED_RELEASE` to version
names/codes, to pin reproducible versions.

`--mtg` syncs the MindTheGapps `baklava` vendor tree to `vendor/gapps` and
inherits its matching `arm64` or `x86_64` product makefile. Its Google-signed
APK and APEX prebuilts remain presigned during target-files signing, and the
exact vendor commit is recorded in each bundle's release metadata. ARM64 uses
the branch's current Android 16 GSF and Play Services pair. Because upstream's
native x86-64 Play Services remains at its Android 13 version, x86-64 uses the
Google-signed GSF from that same upstream package-set commit so its required
`com.google.android.gsf.gservices` provider remains available.

Downloaded APKs are cached under `MICROG_PREBUILT_CACHE_DIR` (default
`~/ika-build/microg-prebuilts`, alongside the ccache and ARM64 prebuilt caches).
The cache is keyed by the upstream, version-stamped file name, so a rebuild
whose resolved versions are already cached copies them into `vendor/partner_gms`
without re-downloading. A small `index.json` manifest in the same directory maps
each pinned version to its cached APK.

For a **fully offline** build, pin every `MICROG_*_RELEASE` to an explicit
version (not `latest`) and warm the cache once online. On later runs each pinned
module whose APK is already cached is installed straight from the manifest with
no upstream request at all — not even the release-metadata or F-Droid index
lookup. `latest` always re-queries metadata so a newer upstream release is not
missed (though an unchanged version still skips the download).

`INCLUDE_X86_ARM_NATIVE_BRIDGE=1` is the default for the x86-64 product. The
build helper runs `scripts/update_native_bridge_prebuilts.py`, which downloads
the Android 16 Google APIs x86-64 SDK system image, verifies its SHA1, extracts
Google's `libndk_translation.so` runtime, proxy libraries, and binfmt/init glue,
and installs those proprietary files into the workspace at
`vendor/lineage_desktop/prebuilts/native_bridge/system`. The binaries are not
committed to this repository. ARM64 guest bionic and Android support
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

From the ika checkout, those helpers also use the default source tree at
`lineageos/src`:

```bash
lineageos/scripts/rebuild_cf_desktop_arm64.sh
lineageos/scripts/rebuild_cf_desktop_x86_64.sh
```

These are thin wrappers around `build_lineageos_desktop.sh` run with `REBUILD=1`,
which reuses the existing tree (skips repo sync and source patching) and then
builds, signs, and bundles exactly as a full run. Override with `SKIP_SYNC=0` /
`SKIP_PATCH=0` to re-enable either step. The x86-64 helper still refreshes the
native bridge payload unless `INCLUDE_X86_ARM_NATIVE_BRIDGE=0` is set, and the
host/target matrix is enforced (x86-64 builds on x86-64 hosts only; arm64 builds
on x86-64 and arm64 hosts).

They write the Cuttlefish bundle into the same per-arch directories as a full
build:

```text
lineageos-arm64/
lineageos-x86_64/
```

## Validation

Before building from an already-synced checkout:

```bash
vendor/lineage_desktop/scripts/lib/validate_build_inputs.sh "$PWD" arm64 x86_64
```

This checks release inputs without needing a booted device.

After launching a Cuttlefish instance:

```bash
vendor/lineage_desktop/scripts/smoke_resize_desktop.sh mbp16.local:6520
```

This checks the desktop feature contract, resizes the display, verifies the
desktop settings remain enabled, and captures a screenshot.
