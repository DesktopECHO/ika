# Display Architecture: Upstream Cuttlefish vs. Ika

This document compares upstream Cuttlefish's Android virtual-display path with
the path used by [tools/ika](../../tools/ika). The differences change the user
experience from a phone emulator in a browser to a native desktop window.

## TL;DR

| Concern | Upstream Cuttlefish | Ika |
|---|---|---|
| Frame transport | WebRTC over network | Unix domain socket → scrcpy native window |
| Host frontend | WebRTC browser viewer (HTML/JavaScript) | ika-scrcpy with `--cuttlefish-frames-socket=…` |
| Window resize | Client scales frames; guest display geometry is static | Client sends an Android logical resize request; the raw-frame path also attempts a physical Cuttlefish resize |
| Resize event flow | None (visual scaling only) | SDL → ika-scrcpy → physical resize attempt for raw frames + `TYPE_RESIZE_DISPLAY`/`DISPLAY_READY` settle tracking → DisplayManager listeners |
| DPI selection | Static at launch (`--display=…,dpi=…`) | Computed from host width; user can override with `--dpi` or `IKADPI` |
| Input transport | WebRTC data channel | scrcpy control channel using Android input APIs; UHID in game mode |
| Audio transport | WebRTC media stream | Cuttlefish virtio-snd → host PipeWire stream |
| Multi-display / hotplug | `cvd display add/list/remove` CLI | Same CLI is available; Ika does not currently drive add/remove operations |
| GPU path | Varies (host, gfxstream, virgl) | `gpu_mode=gfxstream_guest_angle`, `enable_gpu_udmabuf=true`, `gpu_vhost_user_mode=off`, `use_cvdalloc=true` |
| CPU policy | No Ika-specific policy | Guest vCPUs prefer performance cores; the default count is the available/performance-core count minus two, capped at 12 |

## 1. Frame transport

**Upstream:** Cuttlefish ships its own family of host renderers. The historical
path was a built-in `vncviewer`; the modern path is WebRTC (an HTML/JavaScript
client served from the host). The host encodes frames as H.264 or VP8 and streams
them over a WebRTC peer connection to a browser tab. The viewer is a generic
remote-desktop client with no knowledge of the Android device that produced the
frames.

**Ika:** The scrcpy fork in this repository (`scrcpy/`) reads frames directly
from a Cuttlefish-internal Unix-domain socket. Ika passes that socket path to
scrcpy with `--cuttlefish-frames-socket=...`. The socket is normally
`…/cvd-1/internal/ika_frames.sock`, derived from the `frame_sock_path` field in
`cuttlefish_config.json`. Bypassing WebRTC removes the encode/decode round trip
and browser intermediary; frames arrive at scrcpy's SDL renderer over a local
socket.

## 2. Window resize: scaling vs. device resize requests

This is the most behaviorally significant difference.

**Upstream:** The host display geometry is fixed by the
`--display=width=W,height=H,dpi=D,refresh_rate_hz=60` flag passed to
`cvd_internal_start`. Once Cuttlefish boots, that geometry remains the device's
primary display. Resizing the WebRTC browser window only scales the rendered
frames; Android still reports a W×H display at D DPI, so Launcher and SystemUI
do not reflow.

To change the device geometry with the host tools in this tree, use one of the
following:

- A restart with new `--display=` flags
- `cvd display add --display=width=…,height=…` to add a **new** virtual display
  with its own `DisplayInfo` and `displayId`, then move the activity to it

**Ika:** The scrcpy fork has a `flex_display` mode that:
1. Catches SDL window-resize events in
   [`scrcpy/app/src/screen.c`](../../scrcpy/app/src/screen.c).
2. Debounces via `FLEX_DISPLAY_RESIZE_QUIET_DELAY` and rate-limits requests with
   `FLEX_DISPLAY_REQUEST_MIN_INTERVAL` so a continuous drag does not flood the
   control path.
3. For raw Cuttlefish frames, attempts to spawn `cvd display resize` with the
   new physical display size and the current Ika DPI.
4. Sends `TYPE_RESIZE_DISPLAY` to the scrcpy server for both raw and encoded
   capture. The server calls
   `Device.setDisplaySizeAndDensity(displayId, size, dpi)` and reports
   `DISPLAY_READY` when the logical display settles.
5. The framework propagates the display change through DisplayManager listeners
   and normal configuration updates.

The Android-side request updates the logical display configuration. Launcher3's
`DisplayController` sees the change, and
[packages-apps-Launcher3.patch](../patches/packages-apps-Launcher3.patch)
refreshes the cached invariant/device profile so the workspace grid, hotseat
columns, and all-apps layout recompute. The same patch keeps placement and popup
decisions tied to live window bounds.

### Current resize limitation

> [!IMPORTANT]
> The current Cuttlefish 1.55 command dispatcher exposes `add`, `list`,
> `remove`, and `screenshot`, but not `resize`; see
> [`host/commands/display/main.cpp`](../../base/cvd/cuttlefish/host/commands/display/main.cpp).
> Consequently, `ika-scrcpy`'s raw-frame physical-resize child exits without
> applying the new Cuttlefish hardware size. The Android logical resize and
> `DISPLAY_READY` path still run. Restoring the host `resize` subcommand is
> required for true window-to-physical-display resizing.

## 3. DPI policy

**Upstream:** DPI is chosen once in the Cuttlefish launch configuration and
stored in the `--display=…,dpi=N` flag. It has no automatic relationship to the
host hardware.

**Ika:** DPI is derived from the host display at launch. Override it with
`--dpi=<value>` or `IKADPI=<value>`.

DPI does **not** change when the scrcpy window is resized; only the resolution
changes. Content gets larger or smaller in absolute screen pixels, as it does
when a desktop viewport changes. If another host monitor needs a different DPI,
restart Ika with a new `--dpi` value.

## 4. Input transport

**Upstream:** The WebRTC client serializes mouse, keyboard, and touch events into
a data-channel message; a host-side WebRTC handler relays them to the guest's
`UInput` device.

**Ika:** Ika uses scrcpy's standard injection path. The scrcpy server runs inside
the guest (uploaded over ADB at startup) and uses framework input APIs to dispatch
events. Mouse, keyboard, gamepad, and clipboard traffic use the same channel;
`--mouse-bind=+hsn:b+++` configures secondary- and middle-click behavior for a
desktop-oriented mouse contract.

## 5. Audio transport

**Upstream:** Audio is multiplexed into the WebRTC media stream with the
negotiated codec, typically Opus.

**Ika:** Cuttlefish audio is enabled even though WebRTC is off. The raw
`ika_stream` frontend services the guest virtio-snd device, publishes mixed
guest playback as a normal PipeWire application stream named `ika`, and routes
the desktop's default PipeWire microphone source into the guest's built-in mic.
The capture stream is connected only while an Android app is recording; if the
host has no microphone source, Android receives silence. scrcpy runs with
`--no-audio`, so sound is no longer tied to ADB, the scrcpy server, or whether
the console window is open.

## 6. Multi-display and hotplug

The `cvd display add/list/remove` CLI supports secondary virtual displays at
runtime. Ika does not currently invoke the add/remove operations; the primary
display and scrcpy window form the sole desktop surface. The
`vendor.cuttlefish.display.*` system-property contract documented in
[dynamic-display-implementation.md](dynamic-display-implementation.md) is a
parallel fallback channel that a host-side actor can use without modifying
scrcpy.

## 7. GPU, boot, and scheduling

Ika sets:

```text
gpu_mode=gfxstream_guest_angle
gpu_vhost_user_mode=off
enable_gpu_udmabuf=true         # zero-copy virtio-gpu path when supported
use_cvdalloc=true
enable_bootanimation=false      # skip the dancing-bug splash
prefer_performance_cores=true
```

`gfxstream_guest_angle` is the default GPU mode. Direct `gfxstream` remains
available for testing the native gfxstream GLES translator, while
`guest_swiftshader` is a diagnostic fallback that removes host GPU acceleration
from the equation.

The production guest Vulkan stack pins patched Mesa 26.1.5 at
`6a02618ccf6c`. That revision is verified with the pinned gfxstream,
rutabaga_gfx, crosvm, minigbm, and Vulkan-Headers revisions in
`manifests/lineageos-desktop.xml`. Both guest architectures pin their kernels
and virtual-device modules to the same Android 16 6.12.74 GKI build; ARM64 also
pins the corresponding 16 KiB variant.
The development images retain `deqp-binary` and its test data under `/data` so
the active Vulkan path can be regression-tested after any graphics update.
The companion gfxstream translator advertises OpenGL ES 3.2 and
`ANDROID_EMU_gles_max_version_3_2`, with version fallback when the host cannot
provide the complete ES 3.2 capability set.

To inspect the guest Vulkan implementation, run:

```bash
adb -s 127.0.0.1:6520 shell vulkaninfo --summary
```

The effective Cuttlefish launch configuration is stored in
`~/ika/cuttlefish/instances/cvd-1/cuttlefish_config.json`, and startup details
are logged in `~/ika/ikastart.log`.
