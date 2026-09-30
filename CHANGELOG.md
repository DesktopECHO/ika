## Ika 260928, changes since release 260726

**NOTE:  Apple Silicon devices must be running Kernel 7.1 or newer**

### New: app windows and desktop integration
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
