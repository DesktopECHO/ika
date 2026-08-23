# Desktop App Compatibility Matrix

This matrix tracks apps by desktop behavior, architecture, graphics path, and
runtime dependencies. Keep it updated when a crash is fixed, a new native bridge
payload is adopted, or an app changes major versions.

The desktop ROM intentionally presents a tablet-like, non-telephony feature set
to package managers. Do not expose `android.hardware.type.pc`; Play treats that
as a desktop/PC device and filters some phone/tablet apps before installation.

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
| Rebel Racing | native | translated on x86-64 if ARM-only | yes on x86-64 | yes | Requires fullscreen because it opts out of resizing. Newer builds also need a GmsCore release containing the scoped Play Games server-auth callback. Retested on ARM64: launches and holds foreground, but a sideloaded `base.apk` on its own stalls on its in-game asset download at 0%, so gameplay could not be reached or graded for graphics on either gpu_mode. Install the full split set or via Play to test. | works-with-notes |
| Angry Birds 2 | native | translated on x86-64 if ARM-only | yes on x86-64 | likely | Validate Play Services, GPU, and ABI selection. | unknown |
| Asphalt 8 | native | translated on x86-64 if ARM-only | yes on x86-64 | likely | May reject non-certified devices or fail GPU checks. | blocked |
| CarX Highway Racing | native | unknown | yes on x86-64 | likely | Launches and plays on ARM64. Under the default `gfxstream_guest_angle` mode its compressed textures decode as vertical stripes on billboards, car body panels, interior and the HUD bar; the same build renders correctly under `ika start --gpu_mode=gfxstream`, so the fault is in the guest ANGLE path rather than the host renderer or the ASTC decoder. | works-with-notes |
| CarX Drift Racing 3 | native | unknown | unknown | likely | Unity/GLES through ANGLE, but renders correctly in gameplay under **both** `gfxstream_guest_angle` and `gfxstream` (verified in-world with HUD, not just menus). Useful counterexample: being a Unity/ANGLE title does not by itself imply the compressed-texture corruption seen in CarX Highway Racing. | supported |
| Destiny Rising | native | unknown | unknown | likely | Needs all three ROM behaviours together: writable dynamic DEX for the packed `classes.dex` it unpacks at runtime, UFFD GC disabled on the 16 KiB guest (ART otherwise takes SIGBUS during mark-compact heap relocation), and explicit ART null checks so NetEase CrashHunter cannot intercept ART internal faults and kill the process. Uses Vulkan directly, so it is unaffected by the ANGLE compressed-texture issue. Reaches gameplay and streams its multi-GB asset packs. | works-with-notes |
| Nintendo apps | native | translated on x86-64 if ARM-only | yes on x86-64 | yes | Usually depends on Play Integrity/device attestation. | blocked |
| No Limit 2 | native | translated on x86-64 if ARM-only | yes on x86-64 | unknown | Needs crash-log retest on each ROM image. | unknown |
| Vulkan Caps Viewer 4.11 | native ARM64 | translated ARM64 only | yes on x86-64 | no | Its bundled Qt 6.9.3 Android platform plugin dereferences a null accessibility backend during startup under translation, before creating a Vulkan instance. Qt 6.10 removed that startup call; use a Caps Viewer build based on Qt 6.10+ or a native x86-64 build when available. | blocked |

> [!NOTE]
> Graphics artifacts are gpu_mode-specific, so always record which mode they were seen under, and
> grade them from actual gameplay: menus and cutscenes frequently render correctly while the same
> title is corrupt in-world.
>
> Some GLES titles corrupt compressed textures through guest ANGLE, decoding them as block noise or
> vertical stripes while geometry, lighting, text and vector UI stay correct. This is per-title, not
> a property of the ANGLE path: CarX Highway Racing is corrupt in gameplay under
> `gfxstream_guest_angle` and clean under `gfxstream`, while CarX Drift Racing 3 -- also Unity on
> ANGLE -- is clean under both. Apps that use Vulkan directly (Destiny Rising) are unaffected.
>
> `gfxstream` is not a clean fallback either. Its renderer can lose color buffers across app
> relaunches (`Failed to find ColorBuffer`, `TextureDraw: GL error=0x502`), after which `adb
> screencap` returns whole-screen magenta, pure black, or hangs. The guest stays healthy and the
> console keeps receiving frames, so this affects capture rather than the display; a VM restart
> clears it. Beware that a magenta capture in this mode is not necessarily a texture fault.

Release smoke set:

1. Open the launcher and app drawer.
2. Launch Settings, Files, F-Droid, Aurora Store, microG Settings, and Chromium.
3. On x86-64, run the bundled static and dynamic ARM64 native-bridge suites,
   then install one representative ARM64-only APK and confirm startup reaches
   app code instead of failing in the linker.
4. Record any app that crashes in this file with the top crash frame and target
   architecture.

Every app categorized as `ApplicationInfo.CATEGORY_GAME` is launched fullscreen
by the desktop compatibility policy, regardless of its `resizeableActivity`
declaration. This preserves the lifecycle, input, and surface assumptions common
to games while non-game applications retain normal desktop windowing.
