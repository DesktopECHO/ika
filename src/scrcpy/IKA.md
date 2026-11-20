# Ika changes to scrcpy

This is [scrcpy] 5.0.1 with the changes that make it Ika's display client:
the desktop console, which shows the Cuttlefish main display, and the app
windows of `ika app`, which show Cuttlefish displays added for them. Ika's
options are described here, not in `scrcpy.1` or the shell completion.

[scrcpy]: https://github.com/Genymobile/scrcpy

## Options

| Option | Meaning |
| --- | --- |
| `--cuttlefish-frames-socket=PATH` | Show a Cuttlefish display from `ika_stream`'s frame socket instead of a video stream. The server still runs, for control and the clipboard |
| `--cuttlefish-display=N` | Show crosvm's display N (0-255, default 0); control goes to the Android display on that port |
| `--dpi=N` | Flex display in pixels: the device display follows the window's size at density N |
| `--window-state-file=PATH` | Save the windowed size and the fullscreen state on exit |
| `--gamekb[=SPEC]` | The keyboard and the mouse as a gamepad of the device; needs `--gamepad=uhid` |
| `--touchkb=FILE` | Keys that touch the display, as FILE says; MOD+t edits them over the game, MOD+Shift+t shows them |
| `--touchkb-edit` | Opens the touch keys' editor as the window opens |
| `--start-app=[+]info:PACKAGE` | Open PACKAGE's App info page instead of the app |

| Variable | Meaning |
| --- | --- |
| `IKA_TOUCH=1` | Left clicks and drags are sent as a finger |
| `IKA_WINDOW_ICON=PATH` | The window's icon (an app window's) |
| `IKA_LATENCY=1` | Log the frames' latency (see below) |
| `GTK_THEME` | On X11, `...:dark` gives the title bar its dark variant |

`-x` (`--flex-display`) is allowed on the Cuttlefish main display.

## Console: Cuttlefish frames

With `--cuttlefish-frames-socket`, the client reads frames from the socket of
run_cvd's `ika_stream` (`cvd-N/internal/ika_frames.sock`), and the server runs
with `video=false`.

`app/src/ika/cf_source.c` is a frame source like the video decoder. Each
message starts with a little-endian magic ("IKA" + a letter) and a version:

| Magic | Direction | Content |
| --- | --- | --- |
| `IKAH` | client | Hello, with the display it shows; version 3 adds a bitmask of what it releases: 1 the slots, 2 the DMA-BUF frames, 4 asks for timestamps |
| `IKAS` | server | A memfd of frame slots (`SCM_RIGHTS`); version 2 adds a generation |
| `IKAN` | server | A new frame in a slot: size, DRM format, stride |
| `IKAF` | server | A frame with its pixels inline |
| `IKAD` | server | A frame as a DMA-BUF (`SCM_RIGHTS`), with offset, stride and modifier; version 2 adds a frame id |
| `IKAT` | server | The next frame's timestamps: its arrival from crosvm and the send of its notice (`CLOCK_MONOTONIC`) |
| `IKAR` | client | Release of a slot (generation, slot index) |
| `IKAB` | client | Release of a DMA-BUF frame (frame id) |
| `IKAP` | client | Pause (window hidden) or resume (0) |

Frames become `AVFrame`s: packed RGB, or `AV_PIX_FMT_DRM_PRIME` for DMA-BUFs.
`app/src/interop/interop_raw.c` uploads the former and imports the latter
through EGL. Alpha is ignored.

- **Slots:** with `IKAS` version 2, frames point into the slots without a
  copy, and the client sends `IKAR` when the last reference to a frame is
  dropped; the server does not rewrite a slot until it is released. With
  `IKAS` version 1 the client copies each slot as soon as it is notified.
- **DMA-BUFs:** with `IKAD` version 2, the server keeps the guest's Wayland
  buffer of a frame (`wl_buffer.release`) until the client sends `IKAB`, so
  that the guest does not draw into a buffer the console still shows. A frame
  id of 0 means the buffer was released at once (the console was paused, for
  instance). The server holds at most three buffers per display, the depth of
  the guest's swapchain, releasing the oldest beyond that, and releases what a
  client held when it disconnects.
- **The import cache:** the guest's hwcomposer cycles through a few color
  buffers, so consecutive frames are the same handful of DMA-BUFs, each
  `IKAD` with a new fd of one of them. The interop identifies a DMA-BUF by the
  inode of its fd (`fstat`) and keeps up to 6 imported, each as an `EGLImage`
  attached once to its own SDL texture: a frame of a known buffer only
  switches the texture shown. The `EGLImage` keeps the buffer alive, so a
  frame's fd is closed, and its `IKAB` sent, as soon as the frame is no longer
  shown. A buffer that comes back with another layout is reimported, buffers
  of another size than the current frame are dropped, the least recently used
  entry is evicted when the cache is full, and `sc_texture_reset()` drops them
  all. With `-V debug`, every import is logged, and the hit and miss counts
  every 1000 frames.
- **Paused windows:** while the window is hidden (minimized or occluded), the
  client sends `IKAP`; `ika_stream` keeps the display's latest frame and sends
  it when the window is shown again.
- **Several clients:** `ika_stream` keeps the frames of each display apart
  and serves one client per display at once; a second client of the same
  display waits until the first one leaves. A server that serves one client
  with the frames of every display is handled too: the client ignores the
  other displays.
- **Latency:** with `IKA_LATENCY=1`, the client asks for `IKAT` and logs, every
  300 frames, the p50, p90 and p99 in ms of each stage: `server` (arrival from
  crosvm to the notice's send), `socket` (send to receive), `client` (receive
  to present) and `total`, with the frames skipped unshown
  (`app/src/ika/latency.c`). Both ends read the host's `CLOCK_MONOTONIC`.

## Cuttlefish displays

`--cuttlefish-display=N` shows another Cuttlefish display than the main one:
the Nth display of crosvm's GPU device, which `ika` adds at runtime with
`crosvm gpu add-displays` on its control socket (`vhost-user-gpu-control`).
The server sends control to the Android display connected to port N (the low
byte of its physical display id), waiting up to 5 s for it to appear, and
resizes it as it resizes the console's.

- The guest reports every Cuttlefish display as internal, so the WM Shell
  opens apps there in a desk, as freeform windows: the server moves such tasks
  out of the desk, fullscreen (`WMShell desktopmode moveTaskOutOfDesk`).
- The app started on a Cuttlefish display waits up to 2 s for the display's
  first resize to the window, so that it does not first draw at the display's
  full size, and `DISPLAY_READY` is held until the app has started.
- `AppEndWatcher` sends `APP_ENDED` when the display has had no app for 1 s,
  and the window closes. Removing the display destroys its content, so closing
  an app window closes its app.
- `--start-app=info:PACKAGE` starts `APPLICATION_DETAILS_SETTINGS` for
  PACKAGE as the first page of a new task, as a Settings subpage, so that it
  shows alone, without Settings' two-pane list; `+info:` force-stops Settings
  first. `ika` uses it for an app's **App info**.

## Flex display in pixels

`--dpi=N` turns on flex display: the device display follows the window's size,
in pixels, so that it is shown 1:1 on HiDPI desktops too. The server forces
the size of the Cuttlefish display through IWindowManager (as `wm size`, and
`wm density N` once), with Android's scaling off when the size fits the
physical display: the content is drawn 1:1, centered in the physical frame,
and the client crops it. When the display has the requested size and its
configuration was dispatched, the server sends `DISPLAY_READY`.

The size, density and scaling stay on exit, and Android keeps them across
reboots, so that the next session and the next boot start at the window's
size. A server that finds a size already forced forces its density when it
starts, before the capture, so that the window never shows the content
relaid out from another density. On a display at its physical size it forces
the density right after the first size instead: SystemUI only inflates its
views again on a density change, so a density forced first would leave it
with the dimensions of the physical size (on a display wider than 1500 dp, a
status bar clock half again as large) once the size changes.

`app/src/ika/flex.c` debounces the requests while the window is resized. The
window holds a blurred preview of the last content until the guest has drawn
the new size: `DISPLAY_READY`, two frames since the request (a resize first
shows the app's previous buffer in the resized display, then its redraw), and
no new frame for 120 ms, or 1 s after `DISPLAY_READY` at most. Then the blur
fades out. The first content fades in from the Android theme's background.
Flex-display windows are shown 1:1, so their textures have no mipmaps.

## Device messages

| Message | Meaning |
| --- | --- |
| `DISPLAY_READY` | The display has the requested size, and its configuration was dispatched |
| `APP_ENDED` | The display's app is gone |
| `THEME_BACKGROUND` | The Android theme's background color: the window's background (unless `--background-color` is given), the border's shade, and the color the flex preview holds and reveals from |

## Windows

- **Borderless windows** (the console): resize edges, 4 px outside the
  content and 16 px along it at the corners, none when the window opened
  fullscreen; a 2 px border whose color follows the theme; a drag area in the
  top-left corner, 5% of the screen's width by 2.5% of its height.
- **Every window:** a quick click in the top-left corner (under 220 ms and
  8 px) leaves fullscreen or maximized, and never reaches Android; a minimum
  size of 360×540 logical pixels; F11 toggles fullscreen, as MOD+F does.
- Once a resize settles, the window's size is snapped to even pixels.
- In pixel mode, the area around the content takes the color of the frame's
  top-right pixel.
- `--window-state-file=PATH` saves `version=1`, `width`, `height` and
  `fullscreen` on exit, for `ika` to reopen the window as it was.

## Input

- **Primary clicks** are injected as mouse events, not touch, for desktop
  apps. With `IKA_TOUCH=1`, left clicks and drags are sent as a finger.
- **Mouse capture:** with `--mouse=uhid`, or a keyboard gamepad that uses the
  mouse, the window captures the pointer. Tapping MOD (Left Alt or Left Super)
  releases it and takes it back; with `--mouse=uhid` a click also takes it
  back.
- **UHID gamepads** are named `Ika Emulated GamePad`, with the Xbox 360
  controller's IDs, 045e:028e (`app/src/uhid/gamepad_uhid.c`). A stick moves
  in one HID report: the gamepad processor has an optional
  `process_gamepad_stick` op, which the UHID and AOA gamepads implement.
- **Special keys:** with `--keyboard=sdk`, these are injected as Android's
  keycodes (`app/src/keyboard_sdk.c`): Mute, Volume Up and Down (`VOLUME_*`),
  the media keys (`MEDIA_*`, Eject included), F1 to F12 (F11 stays the
  fullscreen shortcut), Insert, Print Screen (`SYSRQ`, a screenshot), Pause
  (`BREAK`), the lock keys, Cut, Copy, Paste, Help, the context menu key
  (`MENU`), the browser keys (`BACK`, `FORWARD`, `HOME`, `REFRESH`, `SEARCH`,
  `BOOKMARK`) and Power, Sleep and Wake (`POWER`, `SLEEP`, `WAKEUP`).
  `AKEYCODE_REFRESH` (285) joins `android/keycodes.h`. `--keyboard=uhid` passes
  a standard keyboard's keys only: the HID keyboard has no usages past 0x65.

### Keyboard gamepad

`--gamekb[=SPEC]` (with `--gamepad=uhid`) makes the keyboard and the mouse a
gamepad of the device too; other keys still type
(`app/src/ika/keyboard_gamepad.c`).

- **Controls:** `left_stick_up`, `left_stick_down`, `left_stick_left`,
  `left_stick_right`, `dpad_up`, `dpad_down`, `dpad_left`, `dpad_right`,
  `right_stick_up`, `right_stick_down`, `right_stick_left`,
  `right_stick_right`, `a`, `b`, `x`, `y`, `start`, `back`, `guide`,
  `left_shoulder`, `right_shoulder`, `left_stick`, `right_stick` (the sticks'
  clicks), `left_trigger`, `right_trigger` and `walk` (held, it caps the
  sticks' deflection).
- **SPEC** gives the keys of each control as `control=key/key,control=key`.
  Keys are SDL scancode names, physical positions on a US layout, with `_`
  for a space (`Keypad_Enter`), or the mouse's `Mouse_Left`, `Mouse_Right`,
  `Mouse_Middle`, `Mouse_X1`, `Mouse_X2`, `Wheel_Up`, `Wheel_Down`,
  `Wheel_Left` and `Wheel_Right` (a wheel notch presses its control for
  40 ms). Unknown keys and controls are reported and skipped, as is a key
  given to a second control. A key pressed with Ctrl, Alt or Super types.
- **Settings in SPEC:**
  - `mouse_stick=right|left|off` (`off`) moves that stick with the mouse, as
    a velocity: full deflection at 32 pixels per 8 ms at
    `mouse_sensitivity=100`, back to the center 24 ms after the mouse stops,
    the stick's keys winning while held. Walk does not cap it.
  - `ramp_ms=N` (`0`) pushes a stick from its center to its target over N ms,
    as a thumb does, and back at once.
  - `walk_percent=N` (`50`) is the sticks' deflection with `walk` held.
  - `socd=last|neutral` is what two opposite directions held together do,
    the last pressed or nothing, for every pad; `socd_dpad`,
    `socd_left_stick` and `socd_right_stick` set one pad.
- **The mouse:** with `mouse_stick` set, the gamepad takes the mouse: the
  window captures the pointer, and while it is captured the mouse's motion,
  buttons and wheel reach the gamepad in the input manager, unmapped buttons
  dropped, a button pressed before the capture released where it was
  pressed. A HID mouse then gets nothing. When the window lets the pointer go
  (the capture key, the focus loss), the gamepad releases the mouse's buttons
  and wheel and centers the mouse's stick. With `mouse_stick=off`, mapped
  mouse buttons and wheel do nothing, and the mouse works as usual.
- **The timer:** an SDL timer (`SC_EVENT_GAMEKB_TIMER`) sends one report every
  8 ms while a stick ramps, while the mouse moves a stick, and while a wheel
  notch is held.
- **Without SPEC:** WASD is the left stick, the arrows the D-pad, IJKL the
  right stick, Space is A, Esc is B, C is X, V is Y, Enter or Keypad Enter is
  Start, Backspace is Back, Q and E are the shoulders, Z and X the triggers,
  Left Shift and F the sticks' clicks, Tab is walk.
- **As a physical pad:** the D-pad and the sticks are apart, a stick on a
  diagonal is as far from its center as on an axis (a round gate), no pad
  points two opposite ways, and a control stays pressed while any of its keys
  is held. A held key is released whatever modifier is down by then, and
  every key when the window loses focus, so no button stays pressed on the
  device.

`ika` passes its own SPEC: the keys and settings of `[keyboard_gamepad]` in
`ika.ini`, or of a game's `controller.ini`, whose defaults have a 100 ms ramp
and map the mouse's buttons to the triggers and a stick click and its wheel to
the shoulders, with `mouse_stick=off`: those mouse keys work only once a game's
mapping sets a stick for the mouse.

### Touch keys

`--touchkb=FILE` makes keys touch the display, for games with on-screen
controls only (`app/src/ika/keyboard_touch.c`); other keys still type. It
cannot be used with `--gamekb`, whose timer it shares for the joystick's
ramp.

- **The file** (`touch.ini`, which need not exist yet) has a `[touch]`
  section of `key key = X Y` lines: while one of the keys is held, a finger
  touches the display at X Y, fractions of its width and height, 0 0 the top
  left corner. Keys are named as in `--gamekb`'s spec, separated by blanks,
  the wheel excepted. `key = X Y cast R` is a skill cast: the finger touches
  X Y and slides toward the free mouse pointer, seen from `cast_center = X
  Y` (the character, 0.5 0.5 by default), up to R (a fraction of the
  display's height) once the pointer is half the display's height away, and
  lifts when the key does. `joystick = X Y R` is an on-screen joystick of
  radius R, whose `joystick_up`, `joystick_down`, `joystick_left` and
  `joystick_right` keys (W, S, A, D by default) touch its center and slide R
  away over `joystick_ramp_ms` (60; a quarter at once, then on the 8 ms
  timer), as far on a diagonal as on an axis, the last pressed of two
  opposite directions counting; its `joystick_walk` and `joystick_sprint`
  keys make that `joystick_walk_percent` (50) and `joystick_sprint_percent`
  (200) of R. `aim = X Y R` makes the captured mouse a finger dragged from X
  Y (`aim_sensitivity = N`, 100: N/100 of a display pixel per mouse pixel).
  `aspect = W/H` is the display's aspect ratio the points were placed at. Ika's
  Startup Options window (`src/tools/ika-lib/window.sh`, `touch_load` and
  `touch_dump`) reads and writes the same file, byte for byte as the client
  writes it.
- **Aspect ratio:** on a display of another aspect ratio (both landscape),
  points move as a game scaling its interface with the display's height
  moves its controls: the left third keeps its distance from the left edge,
  the right third from the right edge, the middle from the center, in
  display heights; portrait the same way vertically, in widths. The editor
  rebases the points on the display it is shown on (and on each resize), and
  saves that display's aspect ratio.
- **The aim's edge:** when the motion would take the finger R from X Y, it
  moves to the edge, the aim's other finger touches X Y, the first lifts,
  and the second takes the rest of the motion, cut at each edge again for a
  long flick (at most 64 times an event): there is always a finger on the
  view, and no lift-and-touch the game could take for a tap.
- **Fingers:** each point, the joystick and the aim's two is a finger of its
  own, pointer ids from `SC_KEYBOARD_TOUCH_POINTER_ID`, apart from the
  mouse's, so that they touch together and with the mouse. A point stays
  down while any of its keys is held. No more than ten touch at once (what
  Android and scrcpy's server take): an eleventh is dropped, with its
  moves and release, and logged once.
- **Keys:** any key but the shortcut modifiers (MOD) can touch; a key pressed
  with MOD is a shortcut. A held key is released whatever modifier is down
  by then, and every finger lifts when the window loses the focus.
- **The mouse:** with `aim`, the window captures the pointer as for a
  keyboard gamepad's `mouse_stick`, and while it is captured the mouse's
  buttons are touch keys (unmapped ones and the wheel dropped). Free, or
  without `aim`, the left button is a finger, as with `IKA_TOUCH=1`, and the
  other buttons touch their points if they have one; the pointer's position
  goes to the skill casts.

The editor (`app/src/ika/touch_editor.c`) opens with MOD+t, or at start with
`--touchkb-edit`, and draws the controls over the game in the window's
renderer, with SDL's debug font; the direct Wayland present is off meanwhile.
The game gets no input while it is open; keys with MOD still reach the
shortcuts, so MOD+t closes it. A click on the display adds a point and the
next key is its key; a click selects a control and a drag moves it, or
resizes the joystick's, the aim's or a skill cast's ring from its edge; a
key, or a right, middle or side click, adds or takes off a key of the
selected point; with the joystick selected, keys go to its directions, then
to walk and sprint, in turn; the wheel sets the aim's sensitivity. The
toolbar's buttons add the joystick and the aim, make a point a skill cast,
give the left button, delete, and close (Done); with a skill cast, a
character marker sets `cast_center`. Closing drops the points without a key
and saves the file. MOD+Shift+t shows the keys faintly over the game while
it is played (hints), the direct present off as well.

## Server

- `com.genymobile.scrcpy.IkaAppIcons` renders the icons of the launchable apps
  and lists the games, for `ika app sync`.
- Each client pushes its own server jar (`scrcpy-server-<scid>.jar`), so that
  clients starting at the same time do not break each other.

## Client and build

- `ika` reopens the console when scrcpy exits with status 2, a device
  disconnection, as after a guest reboot.
- Log lines on stdout are flushed one by one, so that `~/ika/console.log` is
  up to date.
- `app/deps` holds Ika's pinned static FFmpeg, SDL, libusb and dav1d builds,
  shared with crosvm. `app/deps/patches/sdl-wayland-fine-wheel.patch` makes
  SDL take a Wayland scroll's precise value over its whole-notch count, which
  compositors before `wl_seat` 8 send in every frame: under WSLg, touchpad
  and wheel scrolling then moves the console by tenths of a notch, not only
  by whole notches.
- No VA-API: Ika's windows show raw frames, so scrcpy never decodes video with
  the GPU; `--hwdec` keeps only the Windows and macOS decoders.
- `app/tests/test_keyboard_gamepad.c` tests the keyboard gamepad, and
  `app/tests/test_keyboard_touch.c` the touch keys and their file, in a debug
  build (`meson test`).
