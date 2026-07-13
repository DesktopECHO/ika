# Desktop App Compatibility Matrix

This matrix tracks apps by desktop behavior, architecture, graphics path, and
runtime dependencies. Keep it updated when a crash is fixed, a new native bridge
payload is adopted, or an app changes major versions.

The desktop ROM intentionally presents a tablet-like, non-telephony feature set
to package managers. Do not expose `android.hardware.type.pc`; Play treats that
as a desktop/PC device and filters some phone/tablet apps before install.

Status values:

- `supported`: Expected to work in release images.
- `works-with-notes`: Usable, but has a known quirk or dependency.
- `blocked`: Known not to run with the current ROM/runtime.
- `unknown`: Not yet tested on this release train.

| App | ARM64 ROM | x86-64 ROM | Native Bridge | microG Dependency | Graphics / Runtime Notes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Aurora Store | native | native | no | optional | Depends on network and anonymous/session login health. | works-with-notes |
| F-Droid | native | native | no | no | Baseline package manager smoke test. | supported |
| microG Settings | native | native | no | yes | Verifies bundled microG install and signature-spoofing path. | supported |
| Chromium | native | native | no | optional | Use bundled browser/WebView validation before release. | works-with-notes |
| Rebel Racing | native | translated on x86-64 if ARM-only | yes on x86-64 | yes | Requires fullscreen because it opts out of resizing. Newer builds also need the scoped Play Games server-auth callback carried by the default mainline GmsCore build. | works-with-notes |
| Angry Birds 2 | native | translated on x86-64 if ARM-only | yes on x86-64 | likely | Validate Play Services, GPU, and ABI selection. | unknown |
| Asphalt 8 | native | translated on x86-64 if ARM-only | yes on x86-64 | likely | May reject non-certified devices or fail GPU checks. | blocked |
| CarX Highway Racing | native | translated on x86-64 if ARM-only | yes on x86-64 | likely | Historically sensitive to graphics/native runtime. | blocked |
| Nintendo apps | native | translated on x86-64 if ARM-only | yes on x86-64 | yes | Usually depends on Play Integrity/device attestation. | blocked |
| No Limit 2 | native | translated on x86-64 if ARM-only | yes on x86-64 | unknown | Needs crash-log retest on each ROM image. | unknown |

Release smoke set:

1. Open the launcher and app drawer.
2. Launch Settings, Files, F-Droid, Aurora Store, microG Settings, and Chromium.
3. On x86-64, install one ARM64-only test APK and confirm native bridge startup
   reaches app code instead of failing in the linker.
4. Record any app that crashes in this file with the top crash frame and target
   architecture.

Every app categorized as `ApplicationInfo.CATEGORY_GAME` is launched fullscreen
by the desktop compatibility policy, regardless of its `resizeableActivity`
declaration. This preserves the lifecycle, input, and surface assumptions common
to games while non-game applications retain normal desktop windowing.
