# Ika changes to scrcpy

This is [scrcpy] 5.0.1 with the changes that make it Ika's display client: the
desktop console of the Cuttlefish main display, and the windows of single apps
(`ika app`).

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
| `IKAD` | a frame as a DMA-BUF (`SCM_RIGHTS`), with offset, stride and modifier; version 2 adds a frame id |

Frames become `AVFrame`s: packed RGB, or `AV_PIX_FMT_DRM_PRIME` for DMA-BUFs.
`app/src/interop/interop_raw.c` uploads the former and imports the latter
through EGL. Alpha is ignored.

The guest's hwcomposer cycles through a few color buffers, so the DMA-BUFs of
consecutive frames are the same handful of buffers (each `IKAD` carries a new
fd of one of them). The interop identifies a DMA-BUF by the inode of its fd
(`fstat`, unique per DMA-BUF for its lifetime) and keeps up to 6 of them
imported, each as an `EGLImage` attached once to its own SDL texture: a frame
of a known buffer only switches the texture shown, with no EGL or GL call.
The `EGLImage` keeps the buffer alive by itself, so an entry holds no frame:
the frame's fd is closed, and its `IKAB` sent, as soon as the frame is no
longer shown. A buffer that comes back with another layout is reimported, buffers of another size than the current frame are dropped, the
least recently used entry is evicted when the cache is full, and a reset of
the texture (`sc_texture_reset()`) drops them all. With `-V debug`, every
import is logged, and the hit/miss counts every 1000 frames.

The client sends `IKAH` (version 2) on connection, with the display it shows.
A server that knows it sends `IKAS` version 2, with a generation: the frames
then point into the slots without a copy, and the client sends `IKAR`
(generation, slot index) when the last reference to a frame is dropped. The
server does not rewrite a slot until it is released. Otherwise (`IKAS`
version 1, from an older server) the client copies each slot as soon as it is
notified.

The client then sends `IKAH` version 3, whose first argument is a bitmask of
what it releases: 1 the slots, 2 the DMA-BUF frames (an older server ignores
it: it checks the version 2 hello's argument exactly). A server that knows it
sends `IKAD` version 2, with a frame id, and keeps the guest's Wayland buffer
of that frame (`wl_buffer.release`) until the client sends `IKAB` (frame id)
when the last reference to the frame is dropped, so that the guest does not
draw into a buffer the console still shows. A frame id of 0 means the buffer
was released at once (the console was paused, for instance). The server holds
at most three buffers per display, the depth of the guest's swapchain, and
releases the oldest anyway beyond that; it releases everything the client
held when it disconnects.

While its window is hidden (minimized or occluded), the client sends `IKAP`:
`ika_stream` then keeps the display's latest frame without sending it, and
sends it when the window is shown again (`IKAP` with 0).

`ika_stream` keeps the frames of each display apart and serves several clients
at once, one per display: a second client of the same display waits until the
first one leaves. An older `ika_stream` serves one client, with the frames of
all displays; the client ignores the other displays.

`--cuttlefish-display=N` shows another Cuttlefish display than the main one:
the Nth display of crosvm's GPU device, added at runtime with
`crosvm gpu add-displays` on its control socket (`vhost-user-gpu-control`).
The server sends control to the Android display connected to port N (the low
byte of its physical display id), waiting up to 5 s for it to appear, and
resizes it as the console does with `--dpi`. The guest reports every
Cuttlefish display as internal, so the WM Shell opens apps there in a desk, as
freeform windows: the server moves such tasks out of the desk into fullscreen
(`WMShell desktopmode moveTaskOutOfDesk`). As for a new display, `APP_ENDED`
is sent when the display has no app left.

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
Cuttlefish displays, the window holds a blurred preview of the last content
until the guest has drawn the new size: `DISPLAY_READY`, two frames since the
request (a resize first shows the app's previous buffer in the resized display,
then the app's redraw), and no new frame for 120 ms, or 1 s after
`DISPLAY_READY` at most. Then the blur fades out. The first content fades in
from gray.

## Other changes

- `--window-state-file=PATH`: the windowed size and fullscreen state are saved
  on exit (`version=1`, `width`, `height`, `fullscreen`), for `ika` to reopen
  the console as it was.
- `--ika-game-session`: leaving fullscreen or closing the window exits with
  status 3.
- `--gamekb[=SPEC]` (with `--gamepad=uhid`): the keyboard is a
  gamepad of the device too; other keys still type. SPEC gives the keys of
  each control as `control=key/key,control=key`: the controls are `dpad_up`,
  `dpad_down`, `dpad_left`, `dpad_right` (which also move the left stick),
  `a`, `b`, `x`, `y`, `start`, `back`, `guide`, `left_shoulder`,
  `right_shoulder`, `left_stick`, `right_stick`, `left_trigger` and
  `right_trigger`; the keys are SDL key names, with `_` for a space
  (`Keypad_Enter`); unknown keys and controls are reported and skipped.
  Without SPEC: arrows or WASD steer, Space is A, Esc is B, C is X, V is Y,
  Enter is Start, Backspace is Back, Q and E are the shoulders, Z and X the
  triggers. A held key is released whatever modifier is down by then, and
  every key when the window loses focus, so no button stays pressed on the
  device. `ika` passes it, with the keys of `[keyboard_gamepad]` in ika.ini,
  in game mode and TV mode when `gamepad = on` is set and the host has no
  gamepad.
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
  shared with crosvm.
- No VA-API: Ika's windows show raw frames, so scrcpy never decodes video with
  the GPU; `--hwdec` keeps only the Windows and macOS decoders.
- App windows are shown 1:1, so their textures have no mipmaps.
