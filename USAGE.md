[README](README.md) | [UI Intro](UI-INTRO.md) | **Ika commands** | [Changelog](CHANGELOG.md) | [Downloads](DOWNLOADS.md)

# Ika commands

After the packages are installed, `ika` is available on your `PATH`. Use it to
start, stop, and restart the packaged Cuttlefish environment. Right-click the
Ika icon in the dock or app menu for **Stop Ika**, **Restart Ika** and
**Start with Camera**.

```bash
# Start a windowed VM
ika start

# Check whether the VM is running
ika status

# Stop the VM
ika stop

# Factory reset the VM and clear instance state
ika reset

# Restart with new launch arguments
ika restart --gpu_mode=gfxstream --cpus=8 --memory_mb=8192

# Explicitly force the GLES+Vulkan context set in direct gfxstream mode
ika restart --gpu_mode=gfxstream --gfxstream_vulkan=on

# Factory reset and use a 128 GB userdata image on the next start
ika reset --data_gb=128

# Root the VM with Magisk; the first time, this factory-resets the VM and
# unlocks its bootloader, after asking to confirm
ika root

# Print the GSF ID, copy it and open Google's uncertified device page
ika gsf

# Back up your apps and files to ~/ika, and restore the latest backup after a reset
ika backup
ika restore

# Game mode: start Ika fullscreen, passing the gamepad, keyboard and mouse
# through as HID devices
ika start --game

# Use the host's camera as Android's camera (auto-detected, or a given node)
ika restart --camera
ika restart --camera=video2

# List launchable apps (open app windows in bold), open one in its own
# window by label or package name, close it
ika app
ika app Asphalt 8 --game
ika app com.android.settings
ika app --info Chromium
ika app close Asphalt 8

# Sync the Android apps into the desktop's app menu now (ika start keeps
# it in sync automatically), or remove them and turn that off
ika app sync
ika app sync --remove

# Install APK files, and uninstall an app by label or package name
ika install ~/Downloads/some-app.apk
ika remove Some App
ika remove com.example.someapp

# Show the built-in usage text
ika help
```

## Camera

`--camera` passes a host camera to Android as its front camera (crosvm
virtio-media, served by Android's external camera HAL):

- `ika start --camera` (or `ika restart --camera`) uses the first video
  capture device that offers MJPEG, NV12 or YUYV: USB webcams, the FaceTime
  camera of Apple Silicon Macs on an Asahi kernel (`apple-isp`), and that of
  Intel Macs (UVC on 2011-2012 and T2 models, `facetimehd` on 2013-2017
  models). Metadata nodes, such as the second node of a UVC webcam, are
  skipped, and virtual cameras (v4l2loopback, vivid) are used only when there
  is no other.
- `--camera=video2` or `--camera=/dev/video2` picks a device; `v4l2-ctl
  --list-devices` lists them.
- The camera is attached when Android starts: `ika start --camera` refuses
  while it runs, so use `ika restart --camera` then. It is used until the
  next `ika start` or `ika restart` without `--camera`. It needs the `video`
  group, and while Android streams from it, other programs on the host can't.

## TV mode

Android has a TV interface as well as the desktop. Desktop is the default, and
only **Desktop/TV** changes the mode. Open it from the app drawer or the
desktop's "Android Apps (Ika)" menu in desktop mode (it opens in the console),
or from the TV launcher's apps in TV mode. It lists **Desktop Mode**, then,
under a **TV mode** heading, each TV launcher on the system by name, such as
**Catapult** (LineageOS's TV launcher) or one from Google Play:

- In TV mode, choosing a TV launcher makes it the Home app straight away.
  Choosing **Desktop Mode** asks whether to reboot into the desktop.
- In desktop mode, choosing a TV launcher asks whether to reboot into TV mode
  with that launcher as the Home app.
- **Reboot** switches Settings (TV Settings in TV mode), the keyboard (the
  Leanback keyboard in TV mode) and the Home app, and restarts Android in the
  other mode, as much of the interface is set up when it starts. **Cancel**
  keeps the mode. Back in desktop mode, the desktop's Home app comes back.
- In TV mode Android runs the Android TV system UI (its notification panel,
  picture-in-picture and volume controls), and apps run fullscreen, without a
  status bar, taskbar or desktop windows. Apps and Google Play see an Android
  TV device that runs TV apps only (the leanback, leanback-only and live TV
  features, television UI mode), so apps with a TV version show it. Google
  Play may then hide apps without TV support, and show phone apps you
  installed in desktop mode as not compatible; they still run. Unlike a TV,
  Ika keeps its touchscreen, for the desktop's apps.
- TV mode has the Android TV build of the Google Play Store, and desktop mode
  the phone build: the phone build does not run on a TV. Switching modes sets
  the Play Store's update aside for the mode you leave and puts back the one
  the other mode had last time, so each mode keeps its own Play Store version
  (about 60 MB each). If the update can't be removed, the switch doesn't
  happen. On x86-64 hosts the TV build is MindTheGapps' ARM64 one, which runs
  through Android's ARM translation, as other ARM-only apps do.
- The console follows the mode Android is in: in TV mode it opens fullscreen,
  at 1.5 times the density Ika would pick automatically for the desktop, so
  the TV interface is larger (`tv_dpi` in `ika.ini` sets it, and `--dpi`
  applies in either mode), and passes the gamepad through as the remote: the
  D-pad or left stick moves, A selects, B goes back and the guide button goes
  Home. The keyboard and mouse work as on the desktop, except that a right
  click goes back, as a remote's Back button does (Shift and right- click for
  a right click). When Android restarts in the other mode, the console reopens
  for it.
- Apps opened from the desktop's app menu or with `ika app` still open in
  their own windows on the Linux desktop, at the desktop's density, and games
  in a game session.

## Rooting with Magisk

`ika root` roots the VM with [Magisk](https://github.com/topjohnwu/Magisk).
It works on user and userdebug builds and needs nothing else installed. If
the VM is not running, it is started first.

- The first time, `ika root` factory-resets the VM and unlocks its
  bootloader, after asking to confirm. Unlocking changes the keys that
  encrypt Android's data, so the data cannot be kept, just as when a phone's
  bootloader is unlocked.
- It downloads the latest Magisk release from GitHub into `~/ika` (again only
  when a newer one is out), patches Android's `init_boot` image with Magisk's
  own patcher, flashes it from the bootloader and finishes Magisk's setup.
  The VM reboots a few times along the way.
- Afterwards `adb shell su` works without a prompt, the Magisk app is
  installed and Android's developer options are enabled.
- Running `ika root` again on a rooted VM keeps its data and updates Magisk
  to the latest release.
- `ika reset` undoes it: it relocks the bootloader and returns the VM to
  stock Android.

## Google sign-in on uncertified devices

Ika is not Play Protect certified, so Google may block signing in to Google
Play, showing a "Device is not Play Protect certified" notification. Many
devices never see this. If yours does, register its Google Services Framework
(GSF) ID with your Google account:

1. Run `ika gsf`. It copies the ID to the clipboard (with `wl-copy`,
   `xclip` or `xsel`), prints it and opens
   [google.com/android/uncertified](https://www.google.com/android/uncertified)
   in the default browser. If the VM is not running, it is started first.
2. Paste the ID on that page and register it.
3. Wait a few minutes, then run `ika restart`.

Registering lifts the sign-in block only. The device stays uncertified, so
apps that check Play Integrity still fail. A factory reset (`ika reset`, or
rooting for the first time) gives the device a new ID, which has to be
registered again. `ika gsf` needs Google Play Services, so it works on
MindTheGapps builds only.

## Android files

While the VM runs, Android's shared storage (`/sdcard`: DCIM, Download,
Pictures and the rest) is mounted on `~/ika/Android`, so any file manager or
program on the host can open, copy, change and delete files there. `ika start`
mounts it and `ika stop`, `restart` and `reset` unmount it; while Ika is
stopped the folder is empty. GNOME's Files lists it in the sidebar, and the
first mount adds it to KDE's Places as **Android**. Files are read as they are
used, over Ika's adb connection, so a large video plays without being copied
first. Files an app keeps to itself are out of reach, as they are for adb. On
a rooted ROM (`ika root`) the mount is Android's whole filesystem, `/`, served
as root: apps' private files in `/data` show up too, and changes there are made
as root, so take care. The mount uses [madbfs](https://github.com/mrizaln/madbfs);
its log is `~/ika/madbfs.log`.

## Backing up apps and files

`ika backup [FILE]` saves, as a gzip-compressed tar archive
(`~/ika/ika-backup-YYYYMMDDHHMMSS.tgz` by default): the apps you installed with
their split APKs (except Chromium, which Ika installs on new devices), their
files in `/sdcard/Android/data`, game downloads in `/sdcard/Android/obb`, the
DCIM, Pictures, Download, Documents, Music, Movies and Recordings folders, and
your choices: the permissions you granted to apps, special app access (such as
"Display over other apps"), default apps, apps you disabled, the dark theme,
and a curated set of settings (font size, keyboard, spell checker, pointer
speed, screen timeout, accessibility and animation speed). `ika restore [FILE]`
reinstalls the apps, copies the files back and reapplies those choices, for
example after `ika reset`; without FILE it restores the latest backup in
`~/ika`. It asks you to type `y` first, as it replaces the apps, files and
settings on the device. Backups hold APKs, files and settings rather than disk
images, so they also work across ROM updates.

Each app is stopped while its files are copied, so close any game you are
playing first. Files an app keeps readable only to itself are skipped, and
`ika backup` lists each one as it goes (`skipping /sdcard/Android/data/...`);
an app's files that cannot be copied at all are skipped too and do not fail
the backup. App-private data such as logins, in-app settings and saved games
is not included; many apps restore it from your account when you sign in
again. The wallpaper and the taskbar layout are not included either. Each
backup gets a new file, and a backup that fails partway leaves no file behind. Restored apps keep the installer that
installed them, so Google Play goes on updating its apps.

## Installing and removing apps

`ika install FILE.apk...` installs APK files in Android; an app that is
already installed is replaced, keeping its data. The file manager offers it as
**Ika APK installer** in the Open With menu of APK files, so an APK can be
installed without a terminal, and the result shows as a notification.
`ika remove NAME` uninstalls an app and deletes its data. NAME is a package
name or the label shown by `ika app`, matched as `ika app` does, and an
ambiguous name lists the matching apps instead of guessing. Apps that come
with Android cannot be removed. If the VM is not running, either command
starts it without the console first.

## Launch arguments and defaults

`ika start` and `ika restart` pass extra arguments directly to
`cvd_internal_start`, so you can override launch settings on the command line.
`ika stop` calls the matching low-level stop helper and then cleans up local
Cuttlefish processes. `ika reset` is the destructive variant: it passes
`--clear_instance_dirs`, removes the local Chromium-install stamp, relocks the
bootloader and removes root.

Default `ika` settings and configuration:

- host tools from `/usr/lib/cuttlefish-common`
- the packaged LineageOS tree from `/usr/share/cuttlefish-common/lineageos`
- instance state under `~/ika`
- ~64 GB thin-provisioned ext4 userdata image
- Chromium installed as the default browser on new devices
- guest vCPUs set to the available/performance-core count minus two, capped at 12
- guest RAM set to one quarter of host RAM, capped at 32 GB
- Ethernet-only guest networking by default; Wi-Fi, Bluetooth, NFC, UWB, GNSS,
  and the modem simulator remain off unless explicitly enabled

`gfxstream_guest_angle` is the default GPU mode. It runs guest OpenGL ES through
Android ANGLE over gfxstream Vulkan. If the host only has llvmpipe, `ika` uses
`gfxstream` instead, which is much lighter on the CPU. Passing `--gpu_mode`
overrides this. See [GFXSTREAM.md](GFXSTREAM.md) for a comparison. Use
`gfxstream_guest_angle` for games and Vulkan/CTS; mixed `gfxstream` mode does
not support data-buffer AHardwareBuffers. Program-binary caching stays disabled
because it corrupts rendering in some games. On RADV hosts, `ika` adds
`syncshaders` to `RADV_DEBUG` for gfxstream modes. This prevents asynchronous
host shader compilation from intermittently executing incomplete
transform-feedback pipelines; existing caller-provided `RADV_DEBUG` options are
retained. Other Vulkan drivers are unchanged.

Pass `--data_gb=128` to `ika reset` to choose the size, in decimal gigabytes,
of newly created userdata. The selected size is stored under `~/ika` and takes
effect on the next `ika start`. It remains the configured size for later factory
resets until changed by another `ika reset --data_gb=...`.

## gfxstream Vulkan switch

The `--gfxstream_vulkan` switch controls the optional Vulkan context only when
`--gpu_mode=gfxstream` is selected. It has no effect with the default
`gfxstream_guest_angle` mode because that path requires Vulkan.

```bash
ika start --gpu_mode=gfxstream --gfxstream_vulkan=auto
ika restart --gpu_mode=gfxstream --gfxstream_vulkan=off
ika restart --gpu_mode=gfxstream --gfxstream_vulkan=on
```

`auto` is the default. When the primary host Vulkan device is llvmpipe, `auto`
requests GLES-only gfxstream (`gfxstream-gles:gfxstream-composer`). On Apple
Silicon hosts with 16 KiB pages, `auto` leaves Cuttlefish's normal GLES+Vulkan
selection in place and routes host-visible guest Vulkan memory through the
udmabuf-backed path the Apple GPU supports. On other hosts, `auto` leaves the
normal Cuttlefish gfxstream defaults alone, so systems with hardware Vulkan keep
Vulkan enabled.

Use `--gfxstream_vulkan=on` to re-enable gfxstream Vulkan for testing, or
`--gfxstream_vulkan=off` to force GLES-only gfxstream. The same policy can be
set with `GFXSTREAM_VULKAN=auto|off|on`; an explicit
`--gpu_context_types=...` argument takes precedence.

In direct `gfxstream` mode, the guest advertises OpenGL ES 3.2, including
`ANDROID_EMU_gles_max_version_3_2`, with fallback to ES 3.1, 3.0, and 2.0 when
the host translator cannot provide 3.2. Vulkan remains the preferred accelerated
API for applications that support it.

## Settings

Ika's defaults live in `~/ika/ika.ini`, which Ika writes, with every default
in place, the first time it runs. The file is divided into sections, such as `[compute]`, `[gpu]`,
`[network]`, `[storage]`, `[console]` and `[apps]`, and each setting has a
comment. Edit it to change what `ika start` uses by default: the guest's CPUs
and memory, the GPU mode, the data size of a new VM, the apps hidden from the app list,
timeouts and more.

```ini
[compute]
cpus = 8
memory_mb = auto

[apps]
game_apps = com.example.game
```

Command-line options override the file, and so do the environment variables
that `ika help` lists. Delete a line to use the built-in default for that
setting, or delete the file to get a fresh copy. Ika reports lines it does not
understand, and a package update does not change your copy.
