# ika-scrcpy

This is a fork of [scrcpy](https://github.com/Genymobile/scrcpy) used as the display system for the [ika](https://github.com/DesktopECHO/ika) project — a Cuttlefish (Android Virtual Device) host for Fedora Asahi Remix and other RPM-based distributions.

The fork replaces scrcpy's normal ADB/USB video path with a direct Unix socket connection to the Cuttlefish frame server, removing the Android device dependency entirely. The result is a native desktop window that shows the Cuttlefish display at full render resolution and resizes the virtual hardware display dynamically as the window is resized.

---

## How it differs from upstream scrcpy

### 1. New video source: `cuttlefish-wayland`

Pass `--video-source=cuttlefish-wayland` together with `--cuttlefish-frames-socket=PATH` to bypass the ADB/USB/TCP connection path and receive raw frames directly from Cuttlefish.

```
ika-scrcpy --video-source=cuttlefish-wayland \
           --cuttlefish-frames-socket=/run/cuttlefish/cvd-1/display_0 \
           --display-id=0
```

In this mode no Android device is needed on the host — the scrcpy server APK is not pushed or launched.

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

### 4. `--flex-display` — live display resize

When `--flex-display` (or `--flex-display=DPI`) is passed, ika-scrcpy tells the Cuttlefish virtual hardware to resize its display whenever the window is resized.

The resize is issued by spawning `cvd display resize` as a child process:

```
cvd display resize \
    --instance_num=<N> \
    --display_id=<ID> \
    --display=width=<W>,height=<H>,dpi=<DPI>,refresh_rate_hz=60
```

The instance number `N` is parsed from the socket path by scanning for the pattern `cvd-N`. The `cvd` binary path defaults to `/usr/lib/cuttlefish-common/bin/cvd` and can be overridden with the `IKA_CVD_BIN` environment variable.

Resize requests are throttled: a new resize is not sent until 1 second has elapsed with no further window-resize activity (`RAW_FRAME_RESIZE_STILL_DELAY`), and rapid successive requests are rate-limited to at most one every 33 ms (`RAW_FRAME_RESIZE_ACTIVE_MIN_INTERVAL`). Only one resize child process runs at a time; any still-running child is reaped before a new one is spawned.

For raw-frame paths (DMA-BUF and shared memory), the resize target is the renderer output size so that HiDPI desktop scaling does not upscale already-rendered content. For encoded video paths, it is the logical window size, rounded down to the nearest 8 pixels to satisfy codec macroblock alignment.

### 5. Blur fade during resize transitions

While a flex-display resize is in flight, the screen is in `transient_stretch` mode. During this period:

- The old GPU texture is held and stretched to fill the window.
- 28 ghost copies of the texture are composited at low alpha and staggered pixel offsets to produce a soft-blur effect without a shader pass.
- When the Cuttlefish device confirms the new size is active (via the `DISPLAY_READY` device message), `transient_stretch` is cleared and the blur fades out linearly over 250 ms (`FLEX_DISPLAY_BLUR_FADE_DURATION`).
- A fallback timer fires if `DISPLAY_READY` never arrives.

The result is a smooth visual transition rather than a jarring jump when the window is resized.

### 6. `DISPLAY_READY` device message

The scrcpy server (running on the Android side inside Cuttlefish) sends a `DISPLAY_READY` message when the display subsystem has settled at the new dimensions. The client-side handler `sc_screen_on_display_ready()` matches the reported size against the most recently requested size; if they agree, `transient_stretch` is cleared and the blur fade begins.

### 7. Raw frame buffer pool

To avoid repeated `malloc`/`free` calls for inline raw frames, a pool of four reusable pixel buffers (`SC_RAW_FRAME_BUFFER_POOL_SIZE`) is maintained in `sc_screen`. The pool evicts the smallest entry when all slots are full and a larger allocation is needed.

---

## Relevant CLI options

| Option | Description |
|--------|-------------|
| `--video-source=cuttlefish-wayland` | Use the Cuttlefish frame socket instead of ADB |
| `--cuttlefish-frames-socket=PATH` | Path to the Cuttlefish display Unix socket |
| `--display-id=N` | Which Cuttlefish display to show (default 0) |
| `--flex-display[=DPI]` | Enable live window-to-display resize; optional DPI override (default 320) |

---

## Environment variables

| Variable | Description |
|----------|-------------|
| `IKA_CVD_BIN` | Override the path to the `cvd` binary used for display resize (default `/usr/lib/cuttlefish-common/bin/cvd`) |

---

## What is not changed

All upstream scrcpy features (ADB mirroring, audio forwarding, camera, HID input, recording, virtual displays, etc.) are preserved. The Cuttlefish path is a purely additive code path selected by `--video-source=cuttlefish-wayland`; all other `--video-source` values follow the unchanged upstream logic.
