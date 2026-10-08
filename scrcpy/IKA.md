# Ika changes to scrcpy

This is [scrcpy] 5.0.1 (imported unchanged in its own commit) with the changes
that make it Ika's display client: the desktop console of the Cuttlefish main
display, and the windows of single apps (`ika app`).

[scrcpy]: https://github.com/Genymobile/scrcpy

## Console: Cuttlefish frames

`--cuttlefish-frames-socket=PATH` shows the main display from the frame socket
of run_cvd's `ika_stream` (`cvd-N/internal/ika_frames.sock`) instead of a video
stream. The server still runs, for control and clipboard, with `video=false`.

`app/src/ika/cf_source.c` is a frame source like the video decoder. Each
message starts with a little-endian magic ("IKA" + a letter) and a version:

| Magic  | Content |
|--------|---------|
| `IKAS` | a memfd of frame slots (`SCM_RIGHTS`) |
| `IKAN` | a new frame in a slot: size, DRM format, stride |
| `IKAF` | a frame with its pixels inline |
| `IKAD` | a frame as a DMA-BUF (`SCM_RIGHTS`), with offset, stride and modifier |

Frames become `AVFrame`s: packed RGB, or `AV_PIX_FMT_DRM_PRIME` for DMA-BUFs.
`app/src/interop/interop_raw.c` uploads the former and imports the latter
through EGL. Alpha is ignored.

The client sends `IKAH` (version 2) on connection. A server that knows it
sends `IKAS` version 2, with a generation: the frames then point into the
slots without a copy, and the client sends `IKAR` (generation, slot index)
when the last reference to a frame is dropped. The server does not rewrite a
slot until it is released. Otherwise (`IKAS` version 1, from an older server)
the client copies each slot as soon as it is notified.

## Flex display in pixels

`--dpi=N` enables flex display: the device display follows the window size, in
pixels, so that it is shown 1:1 on HiDPI desktops too.

- Console: the server forces the size of the main display through
  IWindowManager (as `wm size`, and `wm density N` once), with Android's
  scaling off when the size fits the physical display: the content is drawn
  1:1, centered in the physical frame, and the client crops it. When the
  display has the requested size and its configuration was dispatched, the
  server sends `DISPLAY_READY`. The original size and density are restored on
  exit.
- App windows (`--new-display`): upstream flex display, requested in pixels.

`app/src/ika/flex.c` debounces the requests while the window is resized. For
the console, the window holds a blurred preview of the last content until the
guest has drawn the new size (`DISPLAY_READY`, then no new frame for 120 ms),
then the blur fades out. The first content fades in from gray.

## Other changes

- `--window-state-file=PATH`: the windowed size and fullscreen state are saved
  on exit (`version=1`, `width`, `height`, `fullscreen`), for `ika` to reopen
  the console as it was.
- `--ika-game-session`: leaving fullscreen or closing the window exits with
  status 3.
- Exit status 2 on device disconnection (upstream), which `ika` uses to
  reopen the console after a guest reboot.
- The app of a new display is watched: when it is gone, the server sends
  `APP_ENDED` and the window closes.
- Borderless windows: resize edges, a drag area in the top-left corner (a
  click there leaves fullscreen or maximized), a thin border, a minimum size.
  On X11, `GTK_THEME=...:dark` gives the title bar its dark variant.
- `IKA_TOUCH=1` sends left clicks and drags as a finger; `IKA_WINDOW_ICON` sets
  the window icon of an app window.
- Primary mouse clicks are injected as mouse events, not touch, for desktop
  apps.
- Each client pushes its own server jar (`scrcpy-server-<scid>.jar`), so that
  clients starting at the same time do not break each other.
- `com.genymobile.scrcpy.IkaAppIcons` renders the icons of the launchable apps
  and lists the games, for `ika app sync`.
- `app/deps` holds Ika's pinned static FFmpeg, SDL, libusb and dav1d builds,
  shared with crosvm. scrcpy links a second FFmpeg build with VA-API
  (`SCRCPY_FFMPEG_VAAPI=1`, in its own prefix), so that app windows decode on
  the GPU where the driver supports H.264. libva is loaded at runtime
  (`app/src/vaapi_shim.c`): without it, or without H.264 support in the
  driver, decoding falls back to software. crosvm keeps the build without
  VA-API, so it does not depend on libva.
- App windows are shown 1:1, so their textures have no mipmaps.
