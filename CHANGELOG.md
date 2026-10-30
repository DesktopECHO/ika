[README](README.md) | [Using Ika](USAGE.md) | [Configuration](CONFIGURATION.md) | [Graphics](GRAPHICS.md) | [Building](BUILDING.md) | [Downloads](DOWNLOADS.md) | **Changelog**

## Ika 261023, changes since release 261016

### Low-CPU mode
- `ika start` runs a low-CPU mode on weak hosts: the display refreshes at
  30 Hz instead of 60, window blurs are off and animations run at half their
  length, with the display's size and density unchanged. It is on by itself
  when the host has no hardware Vulkan driver or the GPU mode is
  `guest_swiftshader` or `guest_lavapipe`, gives the guest 2 vCPUs or fewer,
  or has less than 8 GB of memory; `--lowcpu`, `--no-lowcpu`,
  `IKA_LOWCPU` and the `[lowcpu]` section of ika.ini (`mode`,
  `refresh_rate_hz`) set it.

### Display
- The display's refresh rate follows the host display outside low-CPU mode:
  120 Hz on a 120 Hz panel instead of a fixed 60, so that the guest's frames
  land on the host's refreshes. `refresh_rate_hz` in the `[console]` section
  of ika.ini, or `IKA_REFRESH_RATE_HZ`, sets a number instead; app windows'
  displays use the same rate.
- `ika status` says how the console's frames travel: `Console frames:
  DMA-BUFs (...)` or `pixels read back by crosvm (...), the slow path`, and
  ika_stream logs each change of path.
- With a window open on the Apple Silicon desktop every frame was read back
  by crosvm and copied to the console: hwc3 flushed SurfaceFlinger's client
  target to the display as it was, a buffer the host cannot export. It now
  composes it into its swapchain image, so the console gets DMA-BUFs with
  windows open too. This is a change to the ROM's hwc3, so it arrives with
  the next ROM build.
- `IKA_LATENCY=1` in the console's environment logs the frames' latency
  (crosvm's commit to the console's present) as percentiles every 300 frames;
  the console's INFO lines now reach `~/ika/console.log` as they are written.

### App start options and input
- Ika's own entry in the app menu has a right-click action, "Startup
  options" (`ika options`), which opens "Startup Options · Ika", a window
  like an app's: a Startup Options tab with the CPUs and RAM, the desktop
  and TV densities, the refresh rate, the GPU mode as ika.ini names it (auto,
  the default, gfxstream_guest_angle, gfxstream, venus, guest_swiftshader and
  guest_lavapipe; "gfxstream, OpenGL ES
  only" is gfxstream with gfxstream_vulkan = off), hardware video decoding,
  low-CPU mode and "Enable gamepad emulation in TV mode", and a Gamepad
  Emulation tab with ika.ini's keyboard gamepad. It writes the settings
  changed in ika.ini, each in place of its line (`ika_ini_set`), and
  "Apply and restart" restarts Ika too. Its "Start with the camera" replaces
  the launcher's "Start with Camera" action: `device` in `[camera]` (off,
  auto or videoN) passes a camera at every start, a missing one left out
  without stopping Ika, and `--no-camera` starts without it once. Startup
  options is the launcher's last action.
- `tv_keyboard_gamepad = true` in `[console]` of ika.ini makes the keyboard a
  gamepad in TV mode too, with the keys of `[keyboard_gamepad]`; the host's
  gamepads are the TV remote either way.
- Each app's entry in the desktop's app menu has a new right-click action,
  "Startup options", which opens a window with a checkbox for
  each option the app can start with: fullscreen; the keyboard, the mouse
  and gamepads, each passed through to Android as a HID device
  (`--keyboard=uhid`, `--mouse=uhid`, `--gamepad=uhid`); the keyboard as a
  gamepad (scrcpy's new `--gamekb`); and touch input (`--touch`). The ticked
  options are saved in `~/ika/app-options.ini`, one section per app, and
  apply whenever the app's window opens, from the menu or a terminal. "Apply
  settings" saves the ticked options, "Apply and start" saves them and
  starts the app with them, and Cancel leaves them as they were;
  `ika app --options NAME` opens the window from a terminal. The packages
  now depend on yad and on python3's GTK 3 bindings (python3-gobject;
  python3-gi and gir1.2-gtk-3.0 on Debian). A game added to the menu starts
  with fullscreen ticked.
- The start options include the app window's display density: "Display
  density, 0=Auto", 0 for the console's, else 96 to 999 DPI (a number under
  96 is 96), saved as `dpi =` in the app's section of `app-options.ini`.
  `ika app NAME --dpi=N` opens the window at a density of its own for one
  start, over the saved one (`--dpi=auto`: the console's).
- The start options window has two tabs, "Startup Options" and
  "Gamepad Emulation" (the app's controller mapping), under a title bar,
  "Startup Options · APP", the same window for games and other apps;
  `ika app --controller NAME` opens it on the second tab. "Apply settings"
  saves the mapping when it was edited or the app already has one of its
  own, no longer a copy of ika.ini's when it was not touched. The window is
  GTK 3's, from python3, native on Wayland (GNOME's and KDE's, without
  XWayland) as on X11, with yad's fields; without python3's GTK bindings,
  each tab opens as a yad window of its own. "Reset to default" asks
  "Apply defaults to APP" (Ok, Cancel), then resets the start options too,
  a game's to fullscreen at the console's density, besides deleting the
  app's mapping.
- The Startup Options windows show the Ika icon in GNOME's dock and KDE's
  task bar, instead of an unknown app's: they have an app ID (Wayland) and
  window class (X11) of their own, `ika-startup-options`, which a hidden
  desktop entry the packages install, `ika-startup-options.desktop`, names.
- The Gamepad Emulation tab, and its window of its own, has a smaller font
  and lower rows, so that the window fits on a screen 768 pixels high. For
  the windows of their own, with Debian's yad 0.40, whose `--gtkrc` styles a window but none of its fields,
  that CSS and the display density's narrow box come in a theme of each
  window's own, Adwaita (or Adwaita dark) and then the CSS; before, neither
  reached the fields there. Its explanation is shorter, without SDL's
  name; the walk key's field reads "Hold to walk", Guide's "Guide (Home)",
  and the settings "Full tilt, ms (0 = Instant)" (`stick_ramp_ms`),
  "Opposite directions" ("Last pressed wins" or "Cancel out", `socd = last`
  or `neutral`) and "Mouse → Analog stick". Its fields follow the hands:
  the left half of the pad, the walk key and the sticks' settings in the
  left column, the right half, Guide and the mouse's settings in the right;
  ika.ini and the mappings keep their order.
- The start options read "Fullscreen mode (F11, Cmd+F or Left-Alt+F
  exits)", "Send the keyboard straight to Android (many games need this)",
  "Send the mouse straight to Android (Cmd or Left-Alt releases pointer)",
  "Use gamepads, including ones plugged in later",
  "Keyboard as a gamepad (keys on the Gamepad Emulation tab)" and "Mouse as
  touch: clicks tap, drags swipe", instead of HID devices and "Touch input:
  Left-click and drag gets interpreted as tap and swipe".
- Game mode and game sessions are gone. `--game` is no longer an option of
  `ika start`, `ika restart` or `ika app`, and `ika app` has no `--window`:
  games open in their own windows like any other app, with the input ticked
  in their start options, so a game without them gets the desktop's
  keyboard and mouse and no gamepad. scrcpy's `--ika-game-session` is gone
  too. For the console, `--ika_scrcpy=` (or `scrcpy_args` in ika.ini) still
  passes scrcpy's `--keyboard=uhid`, `--mouse=uhid` or `--gamepad=uhid`.
- Games' menu entries no longer have "Play with Touch Input": touch input is
  one of every app's start options, and `ika app NAME --touch` still turns
  it on for one start.
- `ika app --controller NAME` opens a window (yad) with the keyboard
  gamepad's keys and settings for a game: a field per control, how long a
  stick takes to full tilt, the walk speed and the rule for opposite keys.
  "Apply settings" saves them in `~/ika/apps/PACKAGE/controller.ini`, over
  `[keyboard_gamepad]` in ika.ini, and ticks the keyboard as a gamepad in the
  game's start options; "Apply and start" also starts the game; "Default
  mapping", once confirmed, removes the mapping and shows ika.ini's in the
  window. `ika app --controller NAME` opens it from a
  terminal. A key typed for one control leaves the control it was shown on.
- The keyboard gamepad's sticks move as a thumb pushes them: a stick takes
  `stick_ramp_ms` (100) from its center to where a key sends it, so a tap
  moves a little and a held key all the way, and comes back at once; a new
  `walk` key (Tab), held, caps the sticks at `walk_percent` (50) of their
  deflection; `socd` (`last` or `neutral`, per pad with `socd_dpad`,
  `socd_left_stick`, `socd_right_stick`) says whether two opposite keys held
  together keep the last pressed or cancel out. All in `[keyboard_gamepad]`
  in ika.ini, and in scrcpy's `--gamekb` spec as `ramp_ms`, `walk`,
  `walk_percent` and `socd`. A stick now moves in one HID report instead of
  one per axis.
- The mouse can be the keyboard gamepad's too: with `mouse_stick = right`
  (or `left`; `off`, the default, leaves the mouse alone) moving it moves
  that stick, the right one the camera in most games, as fast as the mouse
  moves, full at 32 pixels per 8 ms at `mouse_sensitivity`
  100, and back to the center when the mouse stops; the stick's keys win
  while held. The mouse's buttons and wheel are keys of the mapping
  (`Mouse_Left`, `Mouse_Right`, `Mouse_Middle`, `Mouse_X1`, `Mouse_X2`,
  `Wheel_Up`, `Wheel_Down`, `Wheel_Left`, `Wheel_Right`): by default the
  left button is the right trigger, the right button the left trigger, the
  middle button the right stick's click and the wheel the shoulders. With
  `mouse_stick` set, the window captures the pointer as for a HID mouse, left
  Alt (or left Super, scrcpy's capture keys) releases it and takes it back,
  and the released pointer is the usual mouse; with `mouse_stick = off`, the
  mouse, its buttons and wheel too, is not the gamepad's at all. scrcpy's `--gamekb` takes it as `mouse_stick`, `mouse_sensitivity`
  and the mouse key names, and the Controller mapping window has fields for
  the stick the mouse moves and its sensitivity.
- "App Settings" is now "App info", and opens the app's App
  info page alone in the Settings window: as the window's first page, with
  no Settings home page shown before it and no list of settings beside it.
  scrcpy's `--start-app` takes `info:PACKAGE` for it.
- An app's menu entry offers "Launch app" first, where GNOME offered "New
  Window": the launcher has a `new-window` action of its own, which GNOME
  Shell lists instead, and `SingleMainWindow=true`, as an app has one window.
- The keyboard as a gamepad: WASD is the left stick, the arrows the D-pad,
  IJKL the right stick, Space is A, Esc is B, C is X, V is Y, Enter is
  Start, Backspace is Back, Q and E the shoulders, Z and X the triggers,
  Left Shift and F the sticks' clicks; those keys no longer type, other keys
  still do. It behaves as a physical pad: the D-pad and the sticks are
  apart, a stick on a diagonal is pushed as far as on an axis (not to the
  corner of a square, which would move faster on diagonals), of two opposite
  directions only the last pressed counts (by default; `socd` above chooses)
  and the D-pad never points both ways, and a control stays pressed while
  any of its keys is held. The keys
  are set in the new `[keyboard_gamepad]` section of ika.ini, one line per
  control; a key given to a control there leaves the control it is a
  default of.
- The desktop console passes no gamepad, and the TV console always passes
  the gamepad through, as the remote. A `--gamepad=` or `--gamekb` option
  among the extra console args still wins.
- The gamepad Ika passes through is named **Ika Emulated GamePad** in Android,
  not "Microsoft X-Box 360 Pad". It keeps an Xbox 360 controller's vendor and
  product IDs, so the key layout and the mapping games use stay the same. A
  console that is already open keeps the old name until it is restarted.
- A window's gamepads, the keyboard gamepad and the host's real ones (each a
  gamepad of its own), are connected to Android only while the window has
  the focus: they disconnect when it loses it and connect again when it gets
  it back. A game in the background has no gamepad, and of several windows
  only the focused one's gamepads reach Android.
- The keyboard gamepad's letter keys and Space no longer also type into the
  game: with the console's text input (`--prefer-text`) each press, and each
  repeat of a held key, still reached Android as a typed letter, so holding
  X to accelerate typed a stream of x.

### Graphics
- A host whose GPU gfxstream passes over for llvmpipe, because the GPU's
  Vulkan is older (a Haswell GPU offers Vulkan 1.2, llvmpipe 1.4), starts in
  the `gfxstream` mode with OpenGL ES only, rendered on the GPU, instead of
  rendering everything on the CPU. On a Haswell MacBook Air a 1080p video
  dropped 1% of its frames instead of 62%. Its Android has no Vulkan, and the
  ROM's Chromium gets its no-Vulkan settings.
- `host_cached_memory = on` in the `[gpu]` section of ika.ini
  (`--host_cached_memory=on`, `IKA_HOST_CACHED_MEMORY`) makes gfxstream take
  the guest's host-visible Vulkan memory from a cached coherent host memory
  type instead of a write-combined one (a new `VulkanPreferHostCachedMemory`
  renderer feature), which is faster for the guest's uploads on some drivers.
  Off by default until measured on the drivers Ika runs on; see USAGE.md.
- `--gpu_mode=venus` works: Android's Vulkan runs on Mesa's Venus driver,
  which sends the calls to virglrenderer and the host's own Vulkan driver,
  with ANGLE for OpenGL ES. On an AMD host (Radeon 780M, RADV) Android draws
  its desktop and Chromium's window with Vulkan 1.4 and OpenGL ES 3.2. The
  ROM builds Venus (`vulkan.virtio`) and its protocol headers (venus-protocol
  1.1.3), and three fixes made it work: crosvm's Vulkan-based gralloc, which
  hosts without a minigbm driver (AMD) allocate guest buffers through,
  measured optimal-tiled images and so failed every request; the guest's
  minigbm read Linux's virtio-gpu param 8 as ChromeOS's
  `CREATE_GUEST_HANDLE` and asked for buffers the kernel rejects (now
  numbered as upstream minigbm does); and Venus crashed `vulkaninfo` when it
  chained a queue-family struct Venus keeps no data for.
- Venus works on Apple Silicon too: on an M1 Pro Android draws its desktop
  and Chromium's pages over Honeykrisp with Vulkan 1.4 and OpenGL ES 3.2.
  crosvm now maps Venus's GPU memory into the guest within one region (fixed
  blob mapping), as Asahi's muvm does, since KVM there refuses a memory slot
  per GPU buffer (the M1 lacks stage-2 forced write-back); it loads the
  package's `libvirglrenderer` instead of the system's (Debian 13's older one
  capped Venus at Vulkan 1.3); virglrenderer creates the device at medium
  priority when Honeykrisp refuses SurfaceFlinger's high one; and ANGLE gets
  the same OpenGL ES 3.2 workaround as with gfxstream. `ika start` no longer
  refuses `--gpu_mode=venus` there, and the Startup Options offer it.
- Venus plays video on Intel hosts: hardware-decoded H.264, and any YV12
  picture such as software decoders write, crashed SurfaceFlinger there.
  Intel's Vulkan drivers (hasvk, anv) refuse a YV12 picture's chroma planes
  in the order Venus bound them; Venus now binds them in memory order and
  swaps the chroma back in its color conversion, and a failed import no
  longer crashes its memory report (a fix from Mesa main).
- `gpu_mode = auto`, the default, picks `venus` on a host whose first Vulkan
  device is a GPU with Vulkan 1.3 or newer and ETC2 compressed textures as
  Venus's guest sees them, which Android expects of a Vulkan device and
  Chromium's GPU process requires: Ika asks `vulkaninfo` with the
  `vk_require_etc2` and `vk_require_astc` settings crosvm starts Venus's host
  side with, under which RADV emulates both. Other hosts keep
  `gfxstream_guest_angle`, or `gfxstream` where they had it, and
  `~/ika/ikastart.log` says why; a mode named in ika.ini or on the command
  line still wins. On a Radeon 780M a WebGL page with 12,800 draw calls a
  frame ran at 60 fps instead of 24, with about 40% less of the host's CPU.
  Haswell, whose driver has no ETC2, stays on `gfxstream`; Broadwell gets
  OpenGL ES 3.1 instead of 3.2, as its driver cannot sample ASTC textures.
  On an M1 Pro Venus uses less of the host's CPU but runs games a little
  slower (Asphalt 9 at 56.5 fps against 59.5 with `gfxstream_guest_angle`),
  as Honeykrisp compresses the textures Venus's guest creates.
- `--gpu_mode=guest_lavapipe` works: the guest renders on its CPU with Mesa's
  lavapipe (Vulkan 1.4) and ANGLE, like `guest_swiftshader` with Vulkan 1.4
  instead of 1.3, and it turns low-CPU mode on too.
- Android tells apps the Vulkan version its driver offers instead of always
  1.3: 1.4 with `guest_lavapipe`, 1.3 with `guest_swiftshader`, and in the
  gfxstream and Venus modes the host GPU's version, so 1.4 on RADV, ANV and
  Honeykrisp and 1.1 on a Vulkan 1.2 GPU such as Haswell's (Android has no 1.2
  level). In the OpenGL ES only mode Android no longer claims Vulkan at all:
  it has no Vulkan driver there.
- The ROM now has one Vulkan driver package (APEX) per guest driver,
  gfxstream, lavapipe, SwiftShader and Venus, and the host tools activate the
  one with the driver Android loads, or none.
- gfxstream is updated to upstream main of 2026-10-19. Its renderer allocates
  the transfer buffer of a guest color buffer at the first transfer, and
  trims its heap when a guest app exits: on an Apple Silicon host its heap
  is 4 MB at idle after boot (340 MB without) and 173 MB 45 s after closing
  Asphalt 9 (754 MB without).
- On a host that samples ASTC textures with optimal tiling only, such as
  Apple Silicon's, gfxstream emulates only the linear-tiled ASTC images; the
  optimal-tiled ones are native, so textures cost their compressed size, not
  4-16 times that as a decompressed copy in the guest's memory. In an
  Asphalt 9 race the guest's host-visible Vulkan memory was 549-649 MB
  (3230 MB with every ASTC image emulated).
- The ROM's Mesa is 26.3.0-rc2 (was 26.1.8), with two of Ika's gfxstream
  fixes left on top: sync2 barriers keep imported AHardwareBuffer contents,
  and deep copies skip inactive descriptor pointers. Upstream now has the
  others (push-descriptor templates, map-memory2, maintenance6 bind
  statuses, device memory reports, BGRA AHardwareBuffers, driver and ID
  properties); the conformance-only ones it lacks are dropped: global
  priority emulation, protected-pipeline and video format masking, EAC
  transfer bits, device-creation unwinding and the acquire-unmodified
  extension. A third patch keeps clang 22 from failing the host lavapipe on
  the trace code's hex table. The guest drivers no longer include
  virtgpu_kumquat, gfxstream's VM-less test transport, which Ika never
  used and whose new Rust code needs a rustix the ROM does not have.
  `lineageos/scripts/mesa3d/regenerate.sh` writes the Android build files
  for a new Mesa pin. This arrives with the next ROM build.
- Apple Silicon hosts get OpenGL ES 3.2 instead of 3.1 with
  `gfxstream_guest_angle`. Honeykrisp has no
  `VK_EXT_primitives_generated_query`, without which ANGLE leaves out
  geometry and tessellation shaders; the host tools now turn on ANGLE's
  pipeline-statistics fallback for such GPUs when they have pipeline
  statistics queries. On an M1 Pro, dEQP's GLES 3.1 geometry-shader query
  tests (29) and the tessellation winding, draw, state-query and
  primitive-discard tests (92) pass with it.
- virglrenderer, Venus's host side, is updated to upstream main of
  2026-10-21. On GPUs whose first memory type is both device-local and
  host-visible, such as Apple Silicon's and Intel's, Venus offers the guest
  a device-local memory type ahead of it, which apps take for their
  textures, so those are no longer allocated as memory the host must be
  able to export. Venus also closes the file of each shared-memory buffer
  it imports, and zeroes its command decoder's scratch memory, which could
  pass old host data to the guest.

### Console window
- An app window opens about a second sooner, and the console a little: `ika`
  asks the guest for what it needs in one adb round trip, keeps
  `vulkaninfo`'s answer for the host boot, reads `wayland-info` once, and on
  WSLg asks Windows whether Shift is held in the background. Where `timeout`
  is uutils' (Ubuntu 25.10 and later), which polls for its command's end
  every 0.1 s, perl's alarm times commands out instead. scrcpy polls for its
  server every 20 ms instead of 100.
- The console and app windows are Wayland windows on a Wayland session and
  X11 windows on an X11 session. scrcpy's SDL used to open an X11 window
  through Xwayland on a Wayland compositor without the fifo-v1 protocol
  (KWin before 6.4), which put Xwayland in the path of every frame; Ika now
  sets SDL's video driver from the session unless `SDL_VIDEO_DRIVER` is set.

### Cuttlefish 1.58 (development)
- The host tools are updated from upstream Cuttlefish main of 2026-06-16 to
  the 1.58.0 development head (google/android-cuttlefish 8bed5e228), about
  1,100 upstream changes: passt user-mode networking for crosvm, Venus and
  guest Lavapipe GPU modes, the `v4l2_stream_proxy` camera type, integrated
  GPU detection for host Vulkan, crosvm built with `-c opt`, and the
  `cuttlefish/package:common` packaging rule.
- Ika keeps its own graphics pins (crosvm, gfxstream, Mesa, minigbm, SPIR-V
  and Vulkan headers), its nftables networking, the system Wayland library,
  and its launcher behaviour: the launcher still exits when Android powers
  off.
- `--media` takes upstream's new form, `--media=TYPE:KEY=VALUE`; `ika start`
  passes the camera as `--media=v4l2_proxy:device=/dev/videoN`.
- Android's UI renders with SkiaVK in the gfxstream ANGLE modes, as upstream
  now chooses, with gfxstream emulating the second Vulkan queue when the host
  driver has only one. GLES-only hosts keep SkiaGL;
  `--guest_hwui_renderer=skiagl` returns to it on any host.

### Windows (WSL2)
- `ika-wsl-setup`, installed with `ika-base`, readies a WSL2 distribution
  for Ika: it reports what is missing (`--check`) and installs it. It
  enables nested virtualization and cgroup v2 in `.wslconfig` and systemd in
  `/etc/wsl.conf`, adds the user to Ika's groups, and when Microsoft's kernel
  lacks vhost-vsock, vhost-net or udmabuf builds the WSL2 kernel at the
  running version with them built in and points `.wslconfig` at it. See
  [Windows (WSL2)](CONFIGURATION.md#windows-wsl2).
- WSL2's distributions share one `/dev`, and another distribution's udev can
  give `/dev/kvm`, `/dev/vhost-vsock` and `/dev/vhost-net` to its own groups,
  whose IDs mean other groups, or none, in Ika's, so that crosvm could not
  open them and `ika start` failed with only "Startup Failed." on the
  terminal. ika-base's udev rules now also give each device an ACL entry for
  its group (`kvm`, `cvdnetwork`), which the other distributions' udev leaves
  in place, and installing or upgrading ika-base runs the rules again (ika-base
  depends on `acl` for it). `ika start` checks before starting that it can
  open the devices, and otherwise says which it cannot and the `udevadm
  trigger` command that gives them back; `ika-wsl-setup` reports and fixes
  devices without the ACL entry.
- Windows keeps the task bar shortcuts it made for WSLg windows after their
  distribution is gone, and the app ID it gives a WSLg window leaves the
  distribution out: Ika's console in one distribution showed another's name,
  a blank icon and a right-click entry starting that distribution. Ika
  removes such shortcuts, those of distributions no longer registered, when
  it starts and when a window closes.
- Ika's windows in different WSL distributions no longer share a task bar
  button, whose name, icon and right-click entry were those of whichever
  distribution Windows met first: on WSLg their app IDs carry the
  distribution's name. The console's is `ika-DISTRIBUTION`, whose desktop
  entry, a copy of `ika.desktop`, Ika writes to `~/.local/share/applications`,
  with an `ika.desktop` there that hides the package's own from WSLg, so that
  the Start menu keeps one Ika; app windows' are `ika-DISTRIBUTION-PACKAGE`,
  and their launchers are renamed at the next app menu sync. It needs the
  link from `/usr/local/share/applications` that `ika-wsl-setup` makes;
  without it the console keeps `ika`.
- Ika's windows on Windows have Windows 11's title bar: its height, flat
  minimize, maximize and close buttons with Windows' glyphs (close turns red),
  and the title in Segoe UI Variable, which Ika copies from Windows to
  `~/ika/fonts`. The title bar is sized for Windows' display scale when the
  window opens. It still takes the color of the app's content.
- The title bar's glyphs are PNGs, which GTK colors in memory (their SVGs
  stay where librsvg is missing): on Ubuntu 26.04 gdk-pixbuf loads every
  image through a sandboxed process, 25 ms apiece, which cost a window half
  a second at its start and a stall at each hover. The plugin's own button
  icons, hidden under the glyphs, come from an empty stand-in theme for the
  same reason. The close button's glyph turns white on its red.

### Hardware video decoding
- `ika start` gives Android a V4L2 video decoder backed by the host's VA-API
  (crosvm `--media-decoder=vaapi`, through the new cvd flag
  `--crosvm_media_decoder`) when vainfo finds a working VA-API driver that
  decodes H.264, HEVC, VP8 or VP9.
- On a GPU that has VA-API decoding but no VA-API driver installed, `ika start`
  says "VA-API Capable device but drivers are not installed".
- On Fedora, whose Mesa and Intel iHD VA-API drivers leave out H.264 and HEVC
  (its i965 driver for Haswell and older Intel GPUs decodes H.264), `ika
  start` warns that those need the driver from RPM Fusion and names the
  package (`mesa-va-drivers-freeworld` for AMD, `intel-media-driver` for
  Intel). ika-base also recommends both packages, so dnf installs them on
  hosts where the RPM Fusion repositories are enabled. RPM Fusion's Mesa
  driver requires Fedora's exact Mesa version: while RPM Fusion's build lags
  behind a Fedora Mesa update, dnf holds Mesa back on hosts that have it.
- `hw_video_decode = off` in ika.ini, `--hw_video_decode=off` or
  `IKA_HW_VIDEO_DECODE=off` leaves the decoder out.
- ika-base depends on vainfo (libva-utils).
- The ROM has the V4L2 Codec2 HAL, which offers the host's decoder to apps as
  `c2.v4l2.avc.decoder` (and the HEVC, VP8 and VP9 decoders when the host
  decodes those), ahead of the software decoders. It lists only the codecs
  the host's decoder takes, so with the decoder left out Android decodes in
  software as before. crosvm's decoder takes MMAP buffers only, so the HAL
  copies each frame in and each picture out. It takes video up to 1080p, in
  either orientation, and up to 4K (listed as `c2.v4l2.avc.decoder.uhd` and
  so on) when the host's VA-API driver decodes 4096x4096; larger video
  decodes in software.
- crosvm's video decoder takes compressed frames of up to 8 MB instead of
  1 MB, so 4K and high-bitrate keyframes decode. A frame over the limit
  stopped playback.
- On x86_64 the ROM removes the write-combining MTRR the bootloader leaves
  over all of memory at boot. Linux mapped device memory such as the
  decoder's buffers uncached because of it, and AMD hosts honour that, so
  hardware-decoded video played at about 2 fps on them.
- The ROM's virtio-media driver, rebuilt from fixed source for the same
  kernel, no longer wakes the decoder in a loop: HEVC 1080p60 played at
  0.5-35 fps on an AMD host and now plays at 60 fps. It also no longer
  crashes Android (a kernel panic) when a video player closes or seeks while
  crosvm still returns decoded frames, and no longer stops playback with a
  decode error about once an hour, when it read a command's reply before the
  reply's length was stored.
- Hardware-decoded video no longer shows a green band at the bottom, with the
  colors shifted up, when its coded size differs from its visible size, as it
  does for every 1080p H.264 stream.
- A buffer the host's VA-API decoder fails to decode, such as a stream with a
  level it does not support, is logged by crosvm and fails for the guest
  (EIO); the VM keeps running.
- On Intel GPUs that share the CPU's cache, the host decodes each picture
  straight into Android's buffer, in the GPU's own tiled layout, instead of
  decoding it into its own memory and copying it over, which un-tiled it on
  the CPU; the HAL un-tiles it as it copies it into its block. Playing 1080p30
  H.264 on a Broadwell MacBook Air, crosvm's video thread went from 24% of a
  CPU to 2.5% and crosvm from 99% to 82%, the package drew 6.65 W instead of
  7.0 W, and the pictures are identical either way. Haswell's i965 driver
  does it too, through the older import it takes and in the swizzled tiles
  Haswell writes: on a Haswell MacBook Air crosvm's video thread went from
  12% to 2.5% and the package from 10.6 W to 8.9 W. crosvm first decodes a
  test frame that way, once per start, and copies as before when no import
  gives the right picture or the GPU is another make. The launcher log says
  which way it went.
- On Apple Silicon hosts, whose Android kernel has 16 KB pages, Android's
  hardware video decoder failed on its second buffer and Chrome went back to
  decoding in software: crosvm numbered the buffers it shares with the guest
  4 KB apart, and such a kernel maps only multiples of 16 KB. They are 64 KB
  apart now. Ika attaches the decoder only on hosts with VA-API, which these
  lack, so it shows with `--crosvm_media_decoder=ffmpeg`, which decodes on
  the host's CPU.
- Video that ends and starts over, such as a looping clip, no longer stops
  the hardware decoder with an error at its second end: crosvm returned the
  buffer that marks the end of the stream a second time while its decoder
  held it, and Android put it back. crosvm's FFmpeg decoder refused that in
  11 of 29 one-minute runs on an M1 Pro MacBook Pro; VA-API did not check.
- Before it learns a video's size, Android's hardware video decoder no longer
  allocates its output buffers at the largest size the host decodes (21 of
  4096x4096 with VA-API, of 16384x16384 with FFmpeg): crosvm took the
  placeholder size of -1 x -1 that Android sets for the compressed input as
  that largest size.
- With hardware video decoding, crosvm no longer logs three GPU errors at
  every boot ("hang-up detected: ResourceBridge"): it gave the decoder a
  resource bridge to the GPU, which the decoder dropped unused.

### Camera
- `ika start --camera` sets the camera's anti-flicker to the mains frequency
  of the country of the host's timezone (60 Hz in most of the Americas, 50 Hz
  in most other places). Cameras that start at 50 Hz showed bands under 60 Hz
  lights and ran slower in dim light: the FaceTime camera of a 2011 MacBook
  Pro went from 14 to 17 fps in the same room.
  `--camera_power_line_frequency=50|60|off`, or `power_line_frequency` in the
  new `[camera]` section of ika.ini, sets it instead.

### Starting and stopping
- `ika start` works again after `ika stop`, and after Android powers off or
  fails to boot. Cuttlefish 1.58 starts the VM through `cvd create`, which
  kept such a VM recorded as running ("Group is already running"); `ika stop`
  and `ika start` now clear that record. Android's data is kept.
- `ika start` no longer gives up on a slow host or the first boot of a new
  ROM: past `boot_timeout_sec` it keeps waiting while Android still makes
  progress, for up to four times as long, then opens the console.
- `ika start` no longer fails at random right after launching the VM, while
  `cvd create` is still setting it up.
- `ika stop` disconnects adb from Android, so the adb server no longer keeps
  trying to reconnect to the stopped VM several times a second.
- The adb server's log, `~/ika/tmp/adb.<uid>.log`, keeps only its last 24
  hours: `ika start` trims it when Android starts. It used to grow by about
  1 MB a day for as long as the adb server ran.
- `~/ika/ikastart.log` keeps its last 1,000 lines across `ika start` runs,
  each run under a dated header line, instead of only the latest run.
- `~/ika/madbfs.log` keeps its last 1,000 lines across mounts of Android's
  storage. madbfs emptied it each time `ika start` mounted the storage.
- madbfs, which mounts Android's storage, caches at most 64 MiB of files
  (72 MiB of memory), and takes that memory only as files are read. It took
  288 MiB as soon as it mounted the storage, whether or not a file was read.
- The console opens at Android's first frame instead of after boot
  completes: 0.4 s sooner on a 2011 MacBook Pro, 1.5 s on a 2015 MacBook Air.
- `ika start` keeps the results of its host probes (GPU detection, the
  kernel config, image signing, vulkaninfo) between launches, which saves
  about 2 s per start on a 2011 MacBook Pro.
- Installing Chromium on a new or reset VM no longer opens it: getchromium
  started Chromium for a few seconds, then stopped it. It also takes
  `ika start`'s vulkaninfo result instead of running vulkaninfo again, and is
  half as long.
- crosvm asks the host to back guest memory with transparent huge pages,
  which upstream measured as an 11% faster cold boot. It takes effect where
  `/sys/kernel/mm/transparent_hugepage/shmem_enabled` is `advise`,
  `within_size` or `always`.

### Desktop/TV
- **Desktop/TV**, opened from the desktop's "Android Apps (Ika)" menu or with
  `ika app Desktop/TV`, opens in a window of its own like any other app,
  instead of inside the console. The window is sized to the list (480 by 560
  dp at the guest's density) rather than to 60% of the screen; resize it and
  the size is kept. It closes when Android restarts in the other mode, and the
  console for that mode opens as before. Opened from the app drawer inside
  the console, it is still a window on the desktop, and opening it from the
  menu no longer starts the console when Ika is not running.
- The question that asks to restart in the other mode covers the list at its
  size and place, with Cancel and Restart at the bottom, instead of a smaller
  dialog with the list showing around it. This is in the ROM's IkaMode app, so
  it arrives with the next ROM build.
- In TV mode, choosing another TV launcher in Desktop/TV also opens it, so
  that Home need not be pressed. This is in the ROM's IkaMode app too.
- Desktop/TV has an app icon and a TV banner, Catapult fills the cards of
  apps without a TV banner, and gets notification access in TV mode. These
  are in the ROM too.

### Fixes
- On WSL2, video from a software decoder no longer restarts Android's
  framework, freezing every app window: a Play Store trailer, or any H.264
  video an app played without a hardware decoder. Its YV12 frames need a
  three-plane YUV format, which Direct3D 12 does not have, so gfxstream could
  not create their buffers and SurfaceFlinger aborted ("Failed to create a
  valid texture"). gfxstream now keeps a YUV buffer whose format the GPU
  cannot create as RGBA8, converted from the guest's YUV bytes, and Ika's
  Dozen layer creates Android's images of it as RGBA8.
- Android no longer fails to start where PipeWire cannot make a stream:
  ika_stream freed the stream's properties a second time after PipeWire had,
  aborted, and took the device down with it. Its audio is then dropped.
- On WSLg Cuttlefish's audio goes to WSLg's PulseAudio server only. When
  ika_stream cannot play there it logs an error and drops the audio, the
  microphone silent, instead of trying PipeWire, which WSL distributions do
  not run: a distribution without `libpulse0`, which only a recommended
  package brought in, did, and without PipeWire's `client.conf` hit the
  abort above. ika-base now depends on `libpulse0` (`pulseaudio-libs`).
- Input events and status feedback no longer sit in crosvm's virtio input
  queues until the next event (vhost-user input with EVENT_IDX).
- On hosts whose GL driver has only non-coherent framebuffer fetch, such as
  Mesa on Intel HD 3000, the guest no longer gets framebuffer fetch: Skia's
  shaders failed and Chromium's GPU process aborted.
- In gfxstream mode Android advertises no newer OpenGL ES than the host
  driver, and no Vulkan driver when gfxstream's Vulkan is off.
- In the gfxstream modes crosvm frees what an Android app made when the
  app exits: its OpenGL ES contexts, surfaces and textures, and its Vulkan
  instances. It kept them all (an upstream gfxstream regression); with
  OpenGL ES only, 60 to 200 MB stayed behind each time Chrome was closed,
  until the host ran out of memory and killed the VM.
- Closing an app window frees its display's buffers on the host. crosvm
  never released a buffer it had shown, so the console's compositor kept
  three for each app window opened and closed until Ika stopped. Crosvm
  holds at most 64: after about 17 app windows every new buffer failed to
  import, the console fell back to crosvm reading every frame back (`ika
  status` said "the slow path"), and each failed frame left one more buffer
  behind. A fix from upstream crosvm.
- The ROM's graphics buffer allocator (minigbm) carries nine upstream fixes:
  it rejects malformed buffer handles passed between processes, no longer
  leaks a buffer when an import fails or closes a GPU buffer handle that
  another buffer still uses, and refuses video buffers whose sizes overflow
  32 bits instead of allocating them too small. In the venus GPU mode,
  Android's display composer (drm_hwcomposer) no longer risks hanging when
  an app window's display is removed. Both arrive with the next ROM build.
- ika-base installs on Fedora again (it required the unversioned
  libvirglrenderer.so) and upgrades without file conflicts over
  `etc/cvd_config`.
- LineageOS Trust no longer posts its onboarding notification at every boot.
- Switching back to the desktop turns off any TV launcher from Google Play
  chosen in TV mode, not only Catapult. The Desktop/TV icon has as much
  white around its art as the other apps' icons, at any size.
- Switching between the desktop and TV mode no longer shows a "could not
  list apps from the Android virtual device" notification: the app menu
  watcher, started by the Ika launcher, waits 10 seconds after Android
  boots before it syncs the menu, and retries a sync that fails instead of
  reporting it.
- Dragging an app window's title bar to the top edge of the desktop takes
  the app out of the desktop, fullscreen on the console, instead of
  maximizing it; the maximize button still fills the desktop.
- LineageOS's "Tap to sleep" is off and no longer listed in Settings >
  Display. In Ika that gesture opened and closed the shade on a double tap of
  the status bar or the lock screen, so that double tap does nothing now.
- `ika start` recovers from a host that crashed or lost power while the
  VM was being assembled: it removes the empty or truncated
  `cuttlefish_config.json` such a crash leaves behind, on which every
  start failed with "Check failed: previous_config". The VM's disks and
  data are kept.
- The desktop console comes back as it was after a round trip through TV
  mode: fullscreen when it was fullscreen, else windowed at its last size.
  The console opened after a mode switch ignored the saved fullscreen state,
  so the desktop always returned windowed.
- The clock and status icons keep their place as the notification shade
  opens (the ROM's SystemUI).

## Ika 261016, changes since release 261012

### TV mode
- Android has a TV interface as well as the desktop, in the same ROM:
  **Desktop/TV** in the app drawer, the desktop's app menu and the TV
  launcher's apps lists Desktop Mode and each TV launcher, such as Catapult or
  one from Google Play. Switching modes asks, then Android reboots in the other
  mode; in TV mode, choosing a TV launcher makes it the Home app straight away.
  TV mode has the Android TV system UI, TV Settings and the Leanback keyboard,
  runs apps fullscreen without a status bar or taskbar, and the console shows
  it fullscreen with the gamepad as the remote. In TV mode, apps and Google
  Play see a TV-only device, and the Google Play Store is its Android TV build.
  App windows on the Linux desktop work in both modes. Desktop mode is
  unchanged. See [TV mode](USAGE.md#tv-mode).

### App windows
- App windows show their app on a Cuttlefish display of their own and get its
  frames straight from the VM, as the console does, instead of a video that
  Android encoded: sharper, with less work for both Android and the host. The
  display client no longer uses VA-API. App windows close when Android
  restarts, and open at the desktop's density in TV mode too.

### Settings file
- `~/ika/ika.ini` holds Ika's defaults in sections (`[compute]`, `[gpu]`,
  `[network]`, `[storage]`, `[console]`, `[apps]`, `[timeouts]` and others),
  each setting with a comment: guest CPUs and memory, GPU mode, data size, app
  window quality, hidden apps, timeouts and more. Ika writes it, with every
  default in place, the first time it runs. Command-line options and environment variables still override
  it. See [Settings](USAGE.md#settings).

### Installing and removing apps
- `ika install FILE.apk...` installs APK files in Android, replacing an
  installed version of the app and keeping its data, and APK files in the file
  manager get an **Ika APK installer** action (Open With). `ika remove NAME`
  uninstalls an app by its label or package name, as `ika app` finds apps. If
  the VM is not running, either command starts it without the console.

### Backup and restore
- `ika backup [FILE]` saves your apps, their files and settings into one
  compressed archive, `~/ika/ika-backup-YYYYMMDDHHMMSS.tgz` by default, and
  `ika restore [FILE]` puts them back, after `ika reset` for example; without
  FILE it restores the latest backup. No root needed. See [Backing up apps and files](USAGE.md#backing-up-apps-and-files).

### Android files on the host
- While Ika runs, Android's shared storage is mounted on `~/ika/Android`, so
  host programs can open, change and delete its files directly, streamed as
  they are read. It uses [madbfs](https://github.com/mrizaln/madbfs), whose
  server is built into the ROM. ika-base needs `fuse3`. On a rooted ROM
  (`ika root`) it shows Android's whole filesystem, `/`, served as root. See
  [Android files](USAGE.md#android-files).

### Faster adb
- Ika talks to Android over native vsock (`vsock:3:5555`) instead of the TCP
  proxy on port 6520, so copying files from Android runs about 25 times
  faster. `adb devices` lists one device. Port 6520 still accepts
  `adb connect` and fastboot.

### Fixes
- `ika reset` no longer logs you out of GNOME: removing the app folder
  crashed GNOME Shell.
- The Chromium and Magisk APKs that Ika downloads are kept in `~/ika/apps`, and
  Ika's pid and lock files in `~/ika/tmp`.

## Ika 261012, changes since release 260930

### Root and Google sign-in
- Built-in root utility: `ika root` roots Android with Magisk, on user and
  userdebug builds, and turns on developer options. It downloads the latest
  Magisk itself. The first time, it unlocks the bootloader, which
  factory-resets the device after asking. `ika reset` relocks the bootloader
  and returns the VM to stock Android. See
  [Rooting with Magisk](USAGE.md#rooting-with-magisk).
- `ika gsf` shows the device's Google Services Framework ID, copies it to the
  clipboard and opens Google's uncertified device page, for when Google
  blocks sign-in because the device is not Play Protect certified. See
  [Google sign-in on uncertified devices](USAGE.md#google-sign-in-on-uncertified-devices).
  Android also publishes the ID as the `sys.ika.gsf_android_id` property.

### Camera
- `ika start --camera` passes a host camera to Android: USB webcams, the
  FaceTime camera of Apple Silicon Macs (Asahi kernel) and Intel Macs, or a
  given device (`--camera=video2`). See
  [Camera](USAGE.md#camera). Ika now depends on v4l-utils.
- The Camera app (Aperture) is in the app list and menu. Photos default to
  16:9, video records at 640x480, 720p or 1080p with AAC stereo sound, and
  only the sizes and settings the camera supports are offered, with noise
  reduction at every level. The preview matches the aspect ratio of the photo
  or video.
- The FaceTime camera on 2013-2017 Intel Macs (facetimehd driver) works with
  the stock driver. Ika used to start the camera streaming before Android had
  set it up, so Android couldn't open it.

### Display
- The console and app windows are now based on scrcpy 5.0.1 (previously
  3.3.4).
- While the console or an app window is resized, the last complete picture
  is stretched and blurred until Android has drawn the new size, then fades
  to it.
- You resize the console by dragging just outside its edge, so the resize
  handles no longer cover the edge of the Android desktop. This works on GNOME
  and KDE, under Wayland and X11.
- The console no longer makes an extra copy of each frame, which halves its
  CPU use while the screen changes.
- App windows decode their video on the GPU through VA-API where the driver
  supports H.264 (Intel, for example): on a 2011 MacBook Pro, an app window
  went from 41% to 4% CPU. Other hosts decode in software as before.
- App windows no longer ignore clicks on displays with fractional scaling,
  such as 125%. At some window sizes, Android resized the app's display just
  after it opened, and the window then stopped responding to clicks. App
  windows now always use an even pixel size.
- On X11, Ika now sizes the Android display and chooses the DPI from the
  screen's resolution, as it already did on Wayland. It used to fall back to
  144 DPI and a fixed display size.

### Graphics
- GLES games no longer lose textures on Apple Silicon hosts. Fruit Ninja drew
  its fruit as black shapes and was missing its menu artwork.
- Hosts with only a software Vulkan driver (llvmpipe) default to the lighter
  `gfxstream` GPU mode, and gfxstream prefers an integrated GPU over a CPU
  Vulkan device such as llvmpipe.
- Videos no longer play pink, and the GPU errors that came with them are
  gone.
- crosvm, gfxstream, minigbm and Mesa are updated.

### Launcher, app menu and notifications
- The Ika launcher's right-click menu has Stop, Restart and Start with
  Camera, and "Start Ika" replaces "New Window".
- Newly installed apps appear inside the "Android Apps (Ika)" folder on
  GNOME instead of loose in the app grid.
- Notifications show up on every desktop (Ika now depends on notify-send)
  and name the app, e.g. "Starting Angry Birds 2…", instead of its package.
- App windows show the app's own icon, and KDE's taskbar groups them under
  their own launchers instead of the Ika console. The desktop entry is now
  `ika.desktop`.

### Android guest
- Each device has its own serial number, made on its first start and kept
  across updates and factory resets; it used to be the same on every
  install. The device is named "Ika" and its model is "Ika Android".
- Chromium opens without its first-run screens, on user builds too. Its APK
  is kept as `~/ika/Chromium.apk` and installed on new devices. On hosts
  without a hardware Vulkan driver, `getchromium` installs a Chromium build
  that starts without one; newer builds closed at startup.
- Audio recovers when a virtio-snd stream stalls, and playback no longer
  drops buffers.
- Compressed memory swap (zram) is on from early in boot, not only after boot
  completes.
- The logs show fewer errors that are expected on a desktop VM: power
  statistics without a battery, mobile data without telephony, virtual
  display teardown.
- The desktop tile in Overview has a solid background. Its wallpaper
  background was drawn unscaled and left part of the tile empty on large
  displays.

### User builds
- ADB works on user builds with authentication on: Ika passes your
  `~/.android/adbkey` to the guest at each start, and only that key is
  accepted.

### Fixes
- `ika start` right after a VM stops no longer fails with "Startup Failed."
- A factory reset no longer fills the host's disk.
- Flashing with `ika root` no longer hangs on x86 VMs with 2 GB of RAM.

### Other
- Every app and APEX module in the ROM is signed with Ika's own keys: apps
  built with the default test key get the release key, and 40 hardware and
  Cuttlefish APEXes no longer keep public AOSP keys. Prebuilt Google and
  microG apps keep their upstream signatures.
- Ika waits longer for Android to boot, so slower machines no longer time
  out.
- Packages build against pinned static FFmpeg 9.0.2, SDL 3.4.18 and libusb
  instead of the distribution's libraries. libva is a build dependency; at
  runtime it is loaded only when installed.

## Ika 260930, changes since release 260928

### Sharper windows
- The console is pixel-exact at any window size: Android draws the window's
  exact size 1:1 instead of stretching it to the display, so text is no
  longer resampled and there are no black bars. This needed a framework fix,
  because `wm scaling off` had no effect in Android 16.
- App windows are sized in native pixels on HiDPI desktops instead of being
  upscaled, and their H.264 video defaults to 80M with the encoder's
  quantizer capped (`IKA_APP_CODEC_OPTIONS`, default `video-qp-max:int=18`).
- Window title bars follow the desktop's light or dark style on GNOME,
  under Wayland and X11. Ika now depends on libdecor's GTK plugin.
- The console window fades in sooner after it opens.

### App windows
- An app window closes by itself when its app finishes, is killed, or moves
  to the main display, instead of staying open and black.
- `ika app NAME --touch` sends left-button clicks and drags as touch, for
  games that ignore the mouse. Game launchers get a "Play with Touch Input"
  action.
- App windows wider than 2560 pixels (about 1280 points on a 2x HiDPI
  display) no longer open blank or freeze on a distorted frame. Android's
  software H.264 encoder now goes up to 4096x2304 (or 2304x4096). A window
  beyond what the encoder takes is scaled to fit instead of failing.
- An app window no longer stays distorted after a resize when Android
  reported the new size late.

### Android guest
- A new VM starts in the desktop's light or dark theme; it can be changed in
  Android afterwards.
- New VMs boot with a locked bootloader, so verified boot is enforced and
  the device reports a green boot state. Existing VMs keep their state.
- Bluetooth no longer crashes in a loop: Ika turns it off in the guest,
  which has no Bluetooth controller.
- Fewer recurring errors in the logs: Play services' blocked configuration
  sync, Settings' developer-option refresh, the carrier-configuration warning
  on a device without telephony, and several benign SELinux denials.

### Build
- The source tarball leaves out Ika's runtime files when the repository is
  checked out at `~/ika`, which is also where Ika keeps its VM state.

## Ika 260928, changes since release 260726

**NOTE:  Apple Silicon devices must be running Kernel 7.1 or newer**

### New:  App windows and desktop integration
- `ika app NAME` opens a single Android app in its own resizable window, backed
  by its own virtual display that follows the window size. Apps can be named
  by label (partial, case-insensitive) or package. Plain `ika app` lists the
  launchable apps.
- Android apps appear in the desktop's app menu under "Android Apps (Ika)",
  with their own icons: a folder in the GNOME app grid, or a submenu in KDE
  Plasma, XFCE, Cinnamon and MATE. The menu stays in sync as apps are
  installed or removed, and each entry has an "App Settings" action.
- Menu entries work while Ika is stopped: the VM starts in the background
  (`ika start --no-console`) and progress is shown as desktop notifications.
- Games start in a fullscreen game session with gamepad, keyboard and mouse
  passthrough. Leaving fullscreen sends the game to the background and
  restores the desktop console if it was open. `--window` opens a game in a
  window instead.
- New commands and options: `ika app sync [--remove]`, `ika app close`,
  `ika app --info` and `ika start --no-console`.

### Graphics
- Mesa 26.1.8, Vulkan headers 1.4.360, and updated SPIR-V tools and glslang.
- Updated crosvm and gfxstream, with ANGLE and guest SwiftShader pinned.
- Stability fixes backported to drm_hwcomposer and minigbm.
- Many gfxstream Vulkan conformance fixes: memory reports, map-memory2,
  sparse and compressed formats, feature and query consistency, and ordered
  push-constant replay. Host image-copy calls that cannot be marshalled are
  now refused.
- Vulkan memory is now safe on RADV (the workaround only applies to Vega-era
  GPUs), and GPU detection no longer depends on a display.
- Fixed red and blue being swapped in the guest software composer (for
  example, in Asphalt 8).
- Dropped the udmabuf retention workaround, which the Asahi kernel no longer
  needs. 

### Android guest and game compatibility
- Builds on stable Android 16 (BP4A).
- Fixes for games: packed games can load their unpacked code (writable dynamic
  DEX is allowed), and games with crash-reporting SDKs no longer crash, because
  ART now uses explicit suspend and null checks that those SDKs cannot
  intercept.
- The userfaultfd garbage collector is disabled on the 16 KB ARM64 guest,
  which fixes SIGBUS crashes.
- Fixed playback and microphone audio. Quick Settings has a five-stream audio
  mixer, and the notification shade and default settings were refined for
  desktop use.

### Apple Silicon and ARM64 hosts
- Accelerated GPU modes are allowed on Apple Silicon.
- vhost-user-gpu runs in auto mode, falling back to external-blob when a host
  feature is missing.

### Console and host
- Smoother window resizing. 
- An expected guest power-off stops the VM cleanly again, so `ika status` no
  longer reports a stopped VM as running.
- Fixed timezone detection.

### Packaging and build
- Arch Linux is now supported!
- New dependencies: `desktop-file-utils` and `lsof`.
- Builds against FFmpeg 9 for Arch.
- Google Play services for x86-64 are fetched from Git LFS.
