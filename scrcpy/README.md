# ika-scrcpy

This is a fork of [scrcpy](https://github.com/Genymobile/scrcpy) used as the display system for the [ika](https://github.com/DesktopECHO/ika) project — a Cuttlefish (Android Virtual Device) host for Fedora Asahi Remix and other RPM-based distributions.

The fork replaces scrcpy's normal encoded video path with a direct Unix socket connection to the Cuttlefish frame server. Control, audio, clipboard, and `DISPLAY_READY` settle acknowledgements still use the normal scrcpy server path over ADB. The result is a native desktop window that shows the Cuttlefish display at full render resolution and resizes the virtual hardware display dynamically as the window is resized.

---

## How it differs from upstream scrcpy

### 1. New video source: `cuttlefish-wayland`

Pass `--video-source=cuttlefish-wayland` together with `--cuttlefish-frames-socket=PATH` to bypass the ADB/USB/TCP connection path and receive raw frames directly from Cuttlefish.

```
ika-scrcpy --video-source=cuttlefish-wayland \
           --cuttlefish-frames-socket=/run/cuttlefish/cvd-1/display_0 \
           --display-id=0
```

Passing `--cuttlefish-frames-socket=PATH` is enough to select this mode; the
explicit `--video-source=cuttlefish-wayland` flag is optional. The Android-side
scrcpy server is still launched for control, audio, clipboard, and resize-settle
messages, but it does not encode or stream display frames.

### 2. `cuttlefish_frame_source` — dedicated frame reader thread

The new source file `app/src/cuttlefish_frame_source.c` owns a background thread that:

1. Connects to the Cuttlefish frame Unix socket.
2. Reads a two-field common header (magic + version) from each message, using `recvmsg` so ancillary file descriptors (DMA-BUF fds) can be received in the same call.
3. Dispatches to the appropriate handler based on the magic value.
4. Auto-reconnects with a 250 ms back-off if the socket drops.

### 3. Three frame delivery modes

The Cuttlefish frame server can send frames via three different transports. All use little-endian 32-bit magic values that spell **IKA** + a type letter:

| Magic | ASCII | Transport |
|-------|-------|-----------|
| `0x46414b49` | `IKAF` | Raw inline pixels — pixel data follows the header inline on the socket |
| `0x44414b49` | `IKAD` | DMA-BUF — a GPU buffer file descriptor is passed via `SCM_RIGHTS` ancillary data; no pixel copy |
| `0x53414b49` | `IKAS` | Shared-memory init — an fd for a shared memory region is passed via `SCM_RIGHTS`; the client `mmap`s it |
| `0x4e414b49` | `IKAN` | Shared-memory notify — tells the client which slot in the pre-mapped region holds the new frame |

Each header carries width, height, a DRM FourCC (e.g. `XR24`, `AB24`) for pixel format, stride in bytes, and a display number. Frames addressed to a display number other than the configured `--display-id` are silently discarded.

Pixel formats are translated from DRM FourCCs to SDL3 `SDL_PixelFormat` values before being handed to the renderer.

### 4. `--flex-display` / `--dpi` — live display resize

When `--flex-display`, `--flex-display=DPI`, or the ika alias `--dpi=DPI` is passed, ika-scrcpy tells the Cuttlefish virtual hardware to resize its display whenever the window is resized.

The resize is issued by spawning `cvd display resize` as a child process:

```
cvd display resize \
    --instance_num=<N> \
    --display_id=<ID> \
    --display=width=<W>,height=<H>,dpi=<DPI>,refresh_rate_hz=60
```

The instance number `N` is parsed from the socket path by scanning for the pattern `cvd-N`. The `cvd` binary path defaults to `/usr/lib/cuttlefish-common/bin/cvd` and can be overridden with the `IKA_CVD_BIN` environment variable.

Display resize requests are rate-limited by `FLEX_DISPLAY_REQUEST_MIN_INTERVAL`. Separately, raw-frame rendering is throttled for `RAW_FRAME_RESIZE_THROTTLE_WINDOW` after window-resize activity, with redraws limited by `RAW_FRAME_RESIZE_RENDER_INTERVAL`. Only one resize child process runs at a time; any still-running child is reaped before a new one is spawned.

For raw-frame paths (DMA-BUF and shared memory), the resize target is the renderer output size so that HiDPI desktop scaling does not upscale already-rendered content. For encoded video paths, it is the logical window size, rounded down to the nearest 8 pixels to satisfy codec macroblock alignment.

### 5. Blur fade during resize transitions

While a flex-display resize is in flight, the screen is in `transient_stretch` mode. During this period:

- A resize preview texture is captured from the current live texture crop, stretched to fill the window, and blurred.
- Jittered ghost copies of the preview are composited at low alpha and staggered fractional pixel offsets to produce a soft-blur effect without a shader pass.
- When the Cuttlefish device confirms the new size is active (via the `DISPLAY_READY` device message), the host window has not resized for the settle delay, and a raw frame newer than the current display resize request has arrived, `transient_stretch` is cleared. The final live frame is drawn underneath while the preview texture stays opaque briefly, then crossfades out.

The result is a smooth visual transition rather than a jarring jump when the window is resized.

### 6. `DISPLAY_READY` device message

The scrcpy server (running on the Android side inside Cuttlefish) sends a `DISPLAY_READY` message when the display subsystem has reached the requested dimensions and WindowManager has reported a display-window configuration update for that resize. The client-side handler `sc_screen_on_display_ready()` matches the reported size against the most recently requested size, then releases `transient_stretch` only after the host window has also been quiet for `FLEX_DISPLAY_RESIZE_QUIET_DELAY` and a raw frame newer than the current display resize request has arrived. If that frame arrived before `DISPLAY_READY`, the client waits up to `FLEX_DISPLAY_POST_READY_FRAME_GRACE` before accepting it.

### 7. Raw frame buffer pool

To avoid repeated `malloc`/`free` calls for inline raw frames, a pool of four reusable pixel buffers (`SC_RAW_FRAME_BUFFER_POOL_SIZE`) is maintained in `sc_screen`. The pool evicts the smallest entry when all slots are full and a larger allocation is needed.

---

## Relevant CLI options

| Option | Description |
|--------|-------------|
| `--video-source=cuttlefish-wayland` | Use the Cuttlefish frame socket instead of ADB |
| `--cuttlefish-frames-socket=PATH` | Path to the Cuttlefish display Unix socket |
| `--display-id=N` | Which Cuttlefish display to show (default 0) |
| `--flex-display[=DPI]` / `--dpi=DPI` | Enable live window-to-display resize; optional DPI override (default 320 when not supplied by `ika`) |

---

## Environment variables

| Variable | Description |
|----------|-------------|
| `IKA_CVD_BIN` | Override the path to the `cvd` binary used for display resize (default `/usr/lib/cuttlefish-common/bin/cvd`) |

---

## What is not changed

All upstream scrcpy features (ADB mirroring, audio forwarding, camera, HID input, recording, virtual displays, etc.) are preserved. The Cuttlefish frame path is a purely additive video path selected by `--cuttlefish-frames-socket=PATH` or `--video-source=cuttlefish-wayland`; all other `--video-source` values follow the upstream logic.
