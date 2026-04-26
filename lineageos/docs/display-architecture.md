# Display architecture — upstream Cuttlefish vs ika

This document compares how upstream Cuttlefish drives an Android virtual display against what [tools/ika](../../tools/ika) does on this product. The differences are not surface tweaks; they change the user experience from "phone emulator in a browser" to "native desktop window."

## TL;DR

| Concern | Upstream Cuttlefish | ika |
|---|---|---|
| Frame transport | WebRTC over network | Unix domain socket → scrcpy native window |
| Host front-end | `webRTC` browser viewer (HTML/JS) | scrcpy with `--cuttlefish-frames-socket=…` |
| Window resize | Client scales frames; guest display geometry is static | Client signals server; **guest display geometry actually changes** |
| Resize event flow | none (visual scale only) | SDL → scrcpy client → `TYPE_RESIZE_DISPLAY` → scrcpy server → `Device.setDisplaySizeAndDensity` → `WindowManagerService.setForcedDisplaySize` → DisplayManager listeners |
| DPI selection | Static at launch (`--display=…,dpi=…`) | Computed from host width (`width / 12`), clamped 72–640 by default; user can override 72–1200 |
| Input transport | WebRTC data channel | scrcpy `UInput` injection |
| Audio transport | WebRTC media stream | scrcpy raw audio with low-latency buffer settings |
| Multi-display / hotplug | `cvd_display add/remove/resize` CLI | Same CLI is available; ika does not currently drive it |
| GPU path | varies (host, gfxstream, virgl) | `gpu_mode=gfxstream`, `gpu_vhost_user_mode=off`, `use_cvdalloc=true` |
| Boot animation | enabled by default | disabled (`enable_bootanimation=false`) |
| CPU pinning | none | host frontend pinned to last two performance cores |

## 1. Frame transport

**Upstream:** Cuttlefish ships its own host renderer family. The historical path was a built-in `vncviewer`; the modern path is `webRTC` (HTML/JavaScript client served from the host). Frames are encoded by the host (h264/vp8) and streamed over a WebRTC peer connection to a browser tab. The viewer is a generic remote-desktop client — it has no understanding of "the Android device that produced these frames."

**ika:** The scrcpy fork in this repo (`scrcpy/`) is modified to read frames directly from a Cuttlefish-internal Unix domain socket. ika passes that socket path to scrcpy via `--cuttlefish-frames-socket=$(resolve_cuttlefish_frames_socket)`. The socket lives at `…/cvd-1/internal/ika_frames.sock` (or a path derived from the frame_sock_path field in `cuttlefish_config.json`). Bypassing WebRTC removes the encode-decode round trip and the browser-tab middleman; frames arrive in scrcpy's SDL renderer with sub-frame latency on a loopback socket.

## 2. Window resize: scale vs. true device resize

This is the most behaviorally significant difference.

**Upstream:** the host display geometry is fixed by the `--display=width=W,height=H,dpi=D,refresh_rate_hz=60` flag passed to `cvd_internal_start`. Once Cuttlefish boots, that geometry is the device's primary display for its lifetime. Resizing the WebRTC viewer's browser window only scales the rendered frames — the guest Android still thinks it has a W×H display at D dpi, and the launcher / SystemUI never re-layout.

To change the device geometry at runtime, upstream requires either:
- A restart with new `--display=` flags
- `cvd_display add --width=… --height=…` to add a **new** virtual display (a separate `DisplayInfo` with a new `displayId`), then move the activity to it
- `cvd_display resize` (which works on hotplugged secondary displays, not the primary)

**ika:** the scrcpy fork has a `flex_display` mode that:
1. Catches SDL window-resize events ([scrcpy/app/src/screen.c#sc_screen_on_resize_settled](../../scrcpy/app/src/screen.c)).
2. Debounces via `FLEX_DISPLAY_RESIZE_SETTLE_DELAY` so a continuous drag doesn't spam control messages.
3. Sends `TYPE_RESIZE_DISPLAY` with the new pixel size (8-pixel aligned) to the scrcpy server.
4. The server's [Controller.setDisplaySize](../../scrcpy/server/src/main/java/com/genymobile/scrcpy/control/Controller.java) calls `Device.setDisplaySizeAndDensity(displayId, size, dpi)` — the same path `adb shell wm size` uses.
5. The framework then propagates the change through `WindowManagerService.setForcedDisplaySize` → `LogicalDisplayMapper.setDisplayInfoOverrideFromWindowManagerLocked` → `EVENT_DISPLAY_BASIC_CHANGED` → every registered `DisplayManager.DisplayListener`.

The guest's primary `DisplayInfo` actually updates. Launcher3's `DisplayController` sees the change, and the supplementary R1 patch ([patches/packages-apps-Launcher3-dynamic-display.patch](../patches/packages-apps-Launcher3-dynamic-display.patch)) forces `InvariantDeviceProfile.onConfigChanged(...)` so the workspace grid, hotseat columns, and all-apps layout recompute. End result: the launcher reflows like a real desktop, and freeform tasks are positioned against the new display bounds.

## 3. DPI policy

**Upstream:** DPI is chosen once by the human starting Cuttlefish and baked into the `--display=…,dpi=N` flag. No automatic relationship to host hardware.

**ika:** DPI is derived from the host monitor's pixel width at launch ([tools/ika#resolve_scrcpy_dpi](../../tools/ika)):

```text
DPI = native_display_width / 12
```

clamped to the AOSP density-bucket range 72–640. The formula lands exactly on standard buckets at common monitor widths (1920→160, 2880→240, 3840→320, 5760→480, 7680→640), which keeps Android's bitmap-asset selection clean. A user can override with `IKADPI=<value>` for 72–1200, useful for HiDPI accessibility setups.

DPI does **not** change when the scrcpy window is resized — only resolution changes. Content gets larger or smaller in absolute screen pixels, the same way a desktop monitor behaves when its viewport shrinks. If a different DPI is needed for a different host monitor, restart ika.

## 4. Input transport

**Upstream:** the WebRTC client serializes mouse/keyboard/touch events into a data-channel message; a host-side WebRTC handler relays them to the guest's `UInput` device.

**ika:** scrcpy's standard injection path. The scrcpy server runs inside the guest (uploaded over adb at startup) and uses the framework's hidden input APIs to dispatch events. Mouse, keyboard, gamepad, and clipboard all use the same channel; the binding `--mouse-bind=+hsn:b+++` configures secondary-click and middle-click behavior for a desktop-shaped right-click contract.

## 5. Audio transport

**Upstream:** audio is muxed into the WebRTC media stream with whatever codec is negotiated (typically Opus).

**ika:** scrcpy's audio with explicit low-latency settings: `--audio-buffer=80 --audio-output-buffer=10 --audio-codec=raw`. The 10ms output buffer keeps perceived audio latency below the threshold where it desyncs from on-screen events, at the cost of more frequent buffer underruns on a contended host.

## 6. Multi-display and hotplug

The `cvd_display add/remove/resize` CLI is unmodified and still works for adding secondary virtual displays at runtime. ika doesn't currently invoke it — the primary display + scrcpy window is the sole desktop surface. The `vendor.cuttlefish.display.*` sysprop contract documented in [docs/dynamic-display-implementation.md](dynamic-display-implementation.md) is a parallel fallback channel any host-side actor (including a future ika subcommand) can use without modifying scrcpy.

## 7. GPU / boot / scheduling

ika sets:

```text
gpu_mode=gfxstream
gpu_vhost_user_mode=off
enable_gpu_udmabuf=false        # Asahi crosvm path is unstable with udmabuf
use_cvdalloc=true
enable_bootanimation=false      # skip the dancing-bug splash
prefer_performance_cores=true
```

It also reserves the host's last two performance cores for the scrcpy / webRTC frontend (`taskset -c <p-1,p-2> scrcpy …`). Upstream Cuttlefish leaves GPU mode / boot animation / scheduling to user configuration.

## Why ika diverges

Upstream Cuttlefish is built primarily for **CI testing of Android changes**: every Android engineer needs a way to bring up a known-good virtual device and exercise it. A browser-tab front-end and a static display geometry are right for that use case — the device is being tested against a fixed spec, not driven as a daily-use desktop.

LineageOS Desktop is built for a different use case: an Android-based desktop OS that the user actually sits in front of. That use case needs:
- A native window with frame-perfect input and low audio latency (→ scrcpy + Unix socket frame channel)
- A display geometry that actually responds to window resizes (→ scrcpy `flex_display` + R1 IDP recompute)
- A DPI that matches the host monitor without manual configuration (→ width/12 heuristic in ika)
- Boot/lifecycle/scheduling defaults that favor interactive responsiveness (→ no boot animation, performance-core pinning)

The upstream contracts that don't need to change (the `cvd_internal_start` CLI, the `cvd_display` hotplug CLI, the underlying crosvm + gfxstream stack) are reused unmodified. The divergence is concentrated at the front-end transport and the resize event path, which is where the desktop UX actually lives.
