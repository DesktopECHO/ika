## Unreleased, changes since release 260930

### Graphics
- GLES games no longer lose textures under the default
  `gfxstream_guest_angle` mode on Apple Silicon hosts. Fruit Ninja drew its fruit as black shapes and
  was missing its menu artwork. gfxstream advertised Vulkan host image copy,
  which it cannot carry to the host, so texture uploads through it were
  dropped. It is no longer offered to the guest.

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
