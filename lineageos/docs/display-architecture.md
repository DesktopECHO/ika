# Display architecture — upstream Cuttlefish vs ika

This document compares how upstream Cuttlefish drives an Android virtual display against what [tools/ika](../../tools/ika) does on this product. The differences are not surface tweaks; they change the user experience from "phone emulator in a browser" to "native desktop window."

## TL;DR

| Concern | Upstream Cuttlefish | ika |
|---|---|---|
| Frame transport | WebRTC over network | Unix domain socket → scrcpy native window |
| Host front-end | `webRTC` browser viewer (HTML/JS) | scrcpy with `--cuttlefish-frames-socket=…` |
| Window resize | Client scales frames; guest display geometry is static | Client signals server; **guest display geometry actually changes** |
| Resize event flow | none (visual scale only) | SDL -> ika-scrcpy client -> `cvd display resize` for raw frames, plus `TYPE_RESIZE_DISPLAY`/`DISPLAY_READY` for settle tracking -> DisplayManager listeners |
| DPI selection | Static at launch (`--display=…,dpi=…`) | Computed from host width; user can override with `--dpi` or `IKADPI` |
| Input transport | WebRTC data channel | scrcpy `UInput` injection |
| Audio transport | WebRTC media stream | Cuttlefish virtio-snd -> host PipeWire stream |
| Multi-display / hotplug | `cvd_display add/remove/resize` CLI | Same CLI is available; ika does not currently drive it |
| GPU path | varies (host, gfxstream, virgl) | `gpu_mode=gfxstream`, `enable_gpu_udmabuf=true`, `gpu_vhost_user_mode=off`, `use_cvdalloc=true` |
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
3. For raw Cuttlefish frames, spawns `cvd display resize` with the new physical
   display size and the current ika DPI. For encoded fallback display capture,
   sends `TYPE_RESIZE_DISPLAY` to the scrcpy server, which calls
   `Device.setDisplaySizeAndDensity(displayId, size, dpi)`.
4. The raw-frame path also sends `TYPE_RESIZE_DISPLAY` so the Android-side
   control path can report `DISPLAY_READY` when the display settles.
5. The framework propagates the display change through DisplayManager listeners
   and normal configuration updates.

The guest's primary `DisplayInfo` actually updates. Launcher3's `DisplayController` sees the change, and [packages-apps-Launcher3.patch](../patches/packages-apps-Launcher3.patch) refreshes the cached invariant/device profile so the workspace grid, hotseat columns, and all-apps layout recompute. The same patch keeps placement and popup decisions tied to live window bounds. End result: the launcher reflows like a real desktop, and freeform tasks are positioned against the new display bounds.

## 3. DPI policy

**Upstream:** DPI is chosen once by the human starting Cuttlefish and baked into the `--display=…,dpi=N` flag. No automatic relationship to host hardware.

**ika:** DPI is derived from the host's display at launch; a user can override it with `--dpi=<value>` or `IKADPI=<value>`.

DPI does **not** change when the scrcpy window is resized — only resolution changes. Content gets larger or smaller in absolute screen pixels, the same way a desktop monitor behaves when its viewport shrinks. If a different DPI is needed for a different host monitor, restart ika or pass a new `--dpi` value.

## 4. Input transport

**Upstream:** the WebRTC client serializes mouse/keyboard/touch events into a data-channel message; a host-side WebRTC handler relays them to the guest's `UInput` device.

**ika:** scrcpy's standard injection path. The scrcpy server runs inside the guest (uploaded over adb at startup) and uses the framework's hidden input APIs to dispatch events. Mouse, keyboard, gamepad, and clipboard all use the same channel; the binding `--mouse-bind=+hsn:b+++` configures secondary-click and middle-click behavior for a desktop-shaped right-click contract.

## 5. Audio transport

**Upstream:** audio is muxed into the WebRTC media stream with whatever codec is negotiated (typically Opus).

**ika:** Cuttlefish audio is enabled even though WebRTC is off. The raw `ika_stream` frontend services the guest virtio-snd device and publishes mixed guest playback as a normal PipeWire application stream named `ika`. scrcpy runs with `--no-audio`, so sound is no longer tied to adb, the scrcpy server, or whether the console window is open.

## 6. Multi-display and hotplug

The `cvd_display add/remove/resize` CLI is unmodified and still works for adding secondary virtual displays at runtime. ika doesn't currently invoke it — the primary display + scrcpy window is the sole desktop surface. The `vendor.cuttlefish.display.*` sysprop contract documented in [docs/dynamic-display-implementation.md](dynamic-display-implementation.md) is a parallel fallback channel any host-side actor (including a future ika subcommand) can use without modifying scrcpy.

## 7. GPU / boot / scheduling

ika sets:

```text
gpu_mode=gfxstream
gpu_vhost_user_mode=off
enable_gpu_udmabuf=true         # zero-copy virtio-gpu path when supported
use_cvdalloc=true
enable_bootanimation=false      # skip the dancing-bug splash
prefer_performance_cores=true
```

`gfxstream` is the primary path going forward. `guest_swiftshader` is useful as
a diagnostic fallback because it removes host GPU acceleration from the equation,
but it is not the normal performance target for this product.

The production guest Vulkan stack pins patched Mesa 25.3 at `d4b6f1eba289`.
That revision is verified with the pinned gfxstream, rutabaga_gfx, crosvm,
minigbm, and Vulkan-Headers revisions in `manifests/lineageos-desktop.xml`.

Run `ika graphics-check` to verify that the VM is using hardware gfxstream
Vulkan and the zero-copy flags. Run `ika graphics-check --chromium` for the
end-to-end check; it opens Example Domain, saves `~/ika/graphics-check.png`,
and fails if the frame matches the solid-magenta or blank regression.
