[README](README.md) | [UI Intro](UI-INTRO.md) | [Ika commands](USAGE.md) | **Changelog** | [Downloads](DOWNLOADS.md)

## Ika 261018, changes since release 261016

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

### Hardware video decoding
- `ika start` gives Android a V4L2 video decoder backed by the host's VA-API
  (crosvm `--media-decoder=vaapi`, through the new cvd flag
  `--crosvm_media_decoder`) when vainfo finds a working VA-API driver that
  decodes H.264, HEVC, VP8 or VP9.
- On a GPU that has VA-API decoding but no VA-API driver installed, `ika start`
  says "VA-API Capable device but drivers are not installed".
- On Fedora, whose own VA-API drivers leave out H.264 and HEVC, `ika start`
  warns that those need the driver from RPM Fusion and names the package
  (`mesa-va-drivers-freeworld` for AMD, `intel-media-driver` for Intel).
  ika-base also recommends both packages, so dnf installs them on hosts where
  the RPM Fusion repositories are enabled. RPM Fusion's Mesa driver follows
  Fedora's Mesa version exactly, so it waits until Mesa is up to date.
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
  crosvm still returns decoded frames.
- Hardware-decoded video no longer shows a green band at the bottom, with the
  colors shifted up, when its coded size differs from its visible size, as it
  does for every 1080p H.264 stream.

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
- The console opens at Android's first frame instead of after boot
  completes: 0.4 s sooner on a 2011 MacBook Pro, 1.5 s on a 2015 MacBook Air.
- `ika start` keeps the results of its host probes (GPU detection, the
  kernel config, image signing, vulkaninfo) between launches, which saves
  about 2 s per start on a 2011 MacBook Pro.
- crosvm asks the host to back guest memory with transparent huge pages,
  which upstream measured as an 11% faster cold boot. It takes effect where
  `/sys/kernel/mm/transparent_hugepage/shmem_enabled` is `advise`,
  `within_size` or `always`.

### Fixes
- Input events and status feedback no longer sit in crosvm's virtio input
  queues until the next event (vhost-user input with EVENT_IDX).
- On hosts whose GL driver has only non-coherent framebuffer fetch, such as
  Mesa on Intel HD 3000, the guest no longer gets framebuffer fetch: Skia's
  shaders failed and Chromium's GPU process aborted.
- In gfxstream mode Android advertises no newer OpenGL ES than the host
  driver, and no Vulkan driver when gfxstream's Vulkan is off.
- ika-base installs on Fedora again (it required the unversioned
  libvirglrenderer.so) and upgrades without file conflicts over
  `etc/cvd_config`.
- LineageOS Trust no longer posts its onboarding notification at every boot.
- Switching back to the desktop turns off any TV launcher from Google Play
  chosen in TV mode, not only Catapult. The Desktop/TV icon has as much
  white around its art as the other apps' icons, at any size.
- LineageOS's "Tap to sleep" is off and no longer listed in Settings >
  Display. In Ika that gesture opened and closed the shade on a double tap of
  the status bar or the lock screen, so that double tap does nothing now.

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
