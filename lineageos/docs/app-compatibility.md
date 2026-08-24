# Desktop App Compatibility Matrix

This matrix tracks apps by architecture and by graphics path. Keep it updated
when a crash is fixed, a new native bridge payload is adopted, or an app changes
major versions.

The desktop ROM intentionally presents a tablet-like, non-telephony feature set
to package managers. Do not expose `android.hardware.type.pc`; Play treats that
as a desktop/PC device and filters some phone/tablet apps before installation.

## Status

| Dot | Meaning |
| --- | --- |
| 🟢 | Works. |
| 🟡 | Works with conditions — a known quirk, or it runs but renders incorrectly. See the Detail column. |
| 🔴 | Does not run. |
| ⚪ | Not yet tested on this release train. |

One row per app. The four dot columns are architecture × graphics path:

- **A64** — ARM64 ROM  ·  **x86** — x86-64 ROM (ARM-only apps run translated)
- **dir** — `--gpu_mode=gfxstream`  ·  **ang** — `--gpu_mode=gfxstream_guest_angle` (the default)

Results do not carry across either axis, so grade each cell separately. Grade
graphics from **actual gameplay**: menus and cutscenes frequently render
correctly while the same title is corrupt in-world.

## Matrix

| App | A64 dir | A64 ang | x86 dir | x86 ang | Detail |
| --- | :---: | :---: | :---: | :---: | --- |
| Angry Birds 2 | ⚪ | ⚪ | ⚪ | ⚪ | Validate Play Services, GPU, ABI selection |
| Asphalt 8 | 🔴 | 🔴 | 🔴 | 🔴 | Device certification, not graphics-path specific |
| CarX Drift Racing 3 | 🟢 | 🟢 | ⚪ | ⚪ | [details](#carx-drift-racing-3) |
| CarX Highway Racing | 🟢 | 🟡 | ⚪ | ⚪ | Textures corrupt in gameplay under ANGLE — [details](#carx-highway-racing) |
| Chromium | 🟡 | 🟡 | 🟡 | 🟡 | Bundled browser/WebView validation |
| Destiny Rising | ⚪ | 🟢 | ⚪ | ⚪ | [details](#destiny-rising) |
| Nintendo apps | 🔴 | 🔴 | 🔴 | 🔴 | Play Integrity / device attestation |
| No Limit 2 | ⚪ | ⚪ | ⚪ | ⚪ | Needs crash-log retest on each ROM image |
| Rebel Racing | ⚪ | ⚪ | ⚪ | ⚪ | [details](#rebel-racing) |

## Graphics paths

Guest ANGLE translates GLES to Vulkan; `gfxstream` uses the direct GLES path
instead. Both run against the *host* Vulkan driver, so a result does not carry
across architectures: the ARM64 results below were taken on Apple Silicon
(Honeykrisp), while an x86-64 host runs RADV, ANV or a proprietary driver
instead. Re-grade per architecture rather than assuming. Neither path is clean:

- **Guest ANGLE corrupts compressed textures for some titles.** They decode as
  block noise or vertical stripes while geometry, lighting, text and vector UI
  stay correct. This is per-title, not a property of the path — CarX Highway
  Racing is corrupt in gameplay while CarX Drift Racing 3, also Unity on ANGLE,
  is clean. The trigger is more likely a specific texture format or footprint.
  Apps using Vulkan directly are unaffected.
- **`gfxstream` loses color buffers.** Across app relaunch cycles the renderer
  logs `Failed to find ColorBuffer: <id>` and `TextureDraw: GL error=0x502`,
  after which `adb screencap` returns whole-screen magenta, pure black, or
  hangs. The guest stays responsive and the console keeps receiving frames, so
  the display survives and a VM restart clears it. Note the consequence for
  testing: **a magenta capture in this mode is not by itself a texture fault.**

## Per-app details

### CarX Drift Racing 3

<a href="images/carx-drift-racing-3-full.jpg"><img src="images/carx-drift-racing-3.jpg" width="120" alt="CarX Drift Racing 3 in-world test drive, rendering correctly"></a>

*In-world test drive under `gfxstream_guest_angle`.*

Unity/GLES through ANGLE, but renders correctly in gameplay under both modes,
verified in-world with HUD rather than from the garage menu. Kept here as the
counterexample to "Unity on ANGLE is broken": being a Unity/ANGLE title does not
by itself imply the corruption seen in CarX Highway Racing.

### CarX Highway Racing

<a href="images/carx-highway-gfxstream-full.jpg"><img src="images/carx-highway-gfxstream.jpg" width="120" alt="CarX Highway Racing in gameplay, textures rendering correctly"></a>

*In-race under `gfxstream`. The billboard and car body are the surfaces that
corrupt under `gfxstream_guest_angle`.*

Launches and plays on ARM64. Under `gfxstream_guest_angle` its compressed
textures corrupt in gameplay: roadside billboards become coloured block noise,
and the road surface, car body panels, interior and HUD bar draw as vertical
stripes. Geometry, lighting, text and vector UI stay correct. The same build
renders correctly under `gfxstream`, so the fault is in the guest ANGLE path
rather than the host renderer or the ASTC decoder. Its menus and cutscenes
render correctly in both modes, so grade this one from a race.

### Destiny Rising

<a href="images/destiny-rising-full.jpg"><img src="images/destiny-rising.jpg" width="120" alt="Destiny Rising in-world at Haven with full HUD"></a>

*In-world at Haven under `gfxstream_guest_angle`, full HUD intact.*

Needs three ROM behaviours together:

1. Writable dynamic DEX, for the packed `classes.dex` it unpacks at runtime.
2. UFFD GC disabled on the 16 KiB guest — ART otherwise takes SIGBUS during
   mark-compact heap relocation.
3. Explicit ART null checks, so NetEase CrashHunter cannot intercept ART's
   internal faults and kill the process.

Uses Vulkan directly, so it is unaffected by the ANGLE compressed-texture issue.
Reaches gameplay and streams its multi-GB asset packs. Not yet graded under
`gfxstream`: it launches, but no verified gameplay frame was captured.

### Rebel Racing

Requires fullscreen because it opts out of resizing. Newer builds also need a
GmsCore release containing the scoped Play Games server-auth callback. Launches
and holds foreground on ARM64, but a sideloaded `base.apk` on its own stalls on
its in-game asset download at 0% and never reaches gameplay, so it cannot be
graded for graphics under either mode. Install the full split set, or via Play,
to test.

## Release smoke set

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
