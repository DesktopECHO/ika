[README](README.md) | [UI Intro](UI-INTRO.md) | [Ika commands](USAGE.md) | **Changelog** | [Downloads](DOWNLOADS.md)

## Unreleased, changes since release 261012

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
