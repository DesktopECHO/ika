<img width="1920" height="1080" alt="Ika Virtual Desktop" src="https://github.com/user-attachments/assets/ad0213c3-6a9d-45bc-9468-dcdd82abca26" />

# イカ · Ika Virtual Desktop

**Ika** _/ee-kah/_, the Japanese word for squid or cuttlefish, began as an effort to
run the [Cuttlefish](https://source.android.com/setup/create/cuttlefish) Android emulator
on [Fedora Asahi Remix](https://asahilinux.org/). It later grew into a desktop-centric Android build for Apple Silicon and x86-64 hosts, but the name stuck.

## Features

- **LineageOS 23.2** (Android 16) reimagined as a desktop-first operating system.
- **Native builds** for **Apple Silicon** and **x86-64** hosts on **Fedora**,
  **Debian/Ubuntu** and **Arch Linux**. Ika runs on machines with as little as
  4 GB of RAM; building it from source needs 16 GB.
- **X11** and **Wayland** desktop sessions are both supported.
- **Dynamic display** window resizing that preserves DPI settings.
- **GPU acceleration** with support for OpenGL ES and Vulkan.
- **App windows**: run single Android apps in their own desktop windows, listed
  in your desktop's app menu; games start fullscreen with gamepad passthrough
  (see [App windows](#app-windows)).
- **Camera**: use a webcam or a Mac's FaceTime camera as Android's front camera
  (see [Camera](#camera)).
- **Android files on the host**: Android's storage is mounted on `~/ika/Android`
  while Ika runs (see [Android files](#android-files)).
- **Built-in root utility**: `ika root` roots the VM with Magisk (see
  [Rooting with Magisk](#rooting-with-magisk)).
- **Flexible build options** for **MindTheGapps**, **microG**, or a fully
  de-Googled ROM without an app store.

Changes since the last published binaries are listed in [CHANGELOG.md](CHANGELOG.md).

The Apple Silicon Vulkan memory-sharing path, including its 16 KiB-page and
udmabuf handling, and the known graphics limitations are documented in
[GFXSTREAM-VULKAN.md](GFXSTREAM-VULKAN.md). The source patches are listed in
[lineageos/patches/README.md](lineageos/patches/README.md).

## Ika Binaries (Updated 2026-10-13)

Ika consists of two packages: an Android disk image (informally, the device ROM)
and a matching Cuttlefish virtual machine application. Prebuilt Fedora 44
(`.rpm`), Debian 13/Ubuntu 26.04 (`.deb`) and Arch Linux x86_64 (`.pkg.tar.zst`)
packages are available below. Select your distribution and CPU architecture, then
download the corresponding application and disk image.

> [!NOTE]
> Debian and Ubuntu require Mesa 26.1 or newer. Get updated binaries from [Debian trixie-backports](https://backports.debian.org/Instructions/) or the [Kisak Mesa PPA](https://launchpad.net/~kisak/+archive/ubuntu/kisak-mesa) before installing the Ika packages.

| **Distribution • Architecture** | **Application** | **Disk Image** |
| --- | --- | --- |
|  |  |  |
| Fedora 44 • x86_64 | [ika-base (160 MB)](https://github.com/DesktopECHO/ika/releases/download/261012/ika-base-261012-1.fc44.x86_64.rpm) | [ika-lineageos (1.37 GB)](https://github.com/DesktopECHO/ika/releases/download/261012/ika-lineageos-261012-1.fc44.x86_64.rpm) |
|  |  |  |
| Fedora 44 • ARM64 | [ika-base (155 MB)](https://github.com/DesktopECHO/ika/releases/download/261012/ika-base-261012-1.fc44.aarch64.rpm) | [ika-lineageos (1.36 GB)](https://github.com/DesktopECHO/ika/releases/download/261012/ika-lineageos-261012-1.fc44.aarch64.rpm) |
|  |  |  |
| Debian 13 / Ubuntu 26.04  •  x86_64 | [ika-base (122 MB)](https://github.com/DesktopECHO/ika/releases/download/261012/ika-base_261012-1_amd64.deb) | [ika-lineageos (1.32 GB)](https://github.com/DesktopECHO/ika/releases/download/261012/ika-lineageos_261012-1_amd64.deb) |
|  |  |  |
| Debian 13 / Ubuntu 26.04 • ARM64 | [ika-base (107 MB)](https://github.com/DesktopECHO/ika/releases/download/261012/ika-base_261012-1_arm64.deb) | [ika-lineageos (1.29 GB)](https://github.com/DesktopECHO/ika/releases/download/261012/ika-lineageos_261012-1_arm64.deb) |
|  |  |  |
| Arch Linux • x86_64 | [ika-base (220 MB)](https://github.com/DesktopECHO/ika/releases/download/261012/ika-base-261012-1-x86_64.pkg.tar.zst) | [ika-lineageos (1.56 GB)](https://github.com/DesktopECHO/ika/releases/download/261012/ika-lineageos-261012-1-x86_64.pkg.tar.zst) |
|  |  |  |
| Arch Linux • ARM64 | [`./ika-build`](https://github.com/DesktopECHO/ika#build-ika-from-source) | [`./ika-build`](https://github.com/DesktopECHO/ika#build-ika-from-source) |

## Build Ika from Source

Building requires at least 16 GB of RAM and 300 GB of storage. The first build
takes 3–6 hours or more, depending on your hardware and internet bandwidth, so
it's best left to run overnight. The `ika-build` script handles the prerequisite
steps and produces installable .rpm, .deb or Arch Linux packages for your
distribution. Prebuilt binaries are published for Fedora, Debian/Ubuntu and
Arch Linux x86_64; on Arch Linux ARM64, build from source.

```bash
# 1. Download and extract:

curl -L https://github.com/DesktopECHO/ika/archive/refs/heads/main.zip -o ika-main.zip
unzip ika-main.zip && rm ika-main.zip && cd ika-main

# 2. Build:

# Prepares signing certificates, installs build dependencies, downloads the
# LineageOS 23.2 source, applies the overlay and source patches, builds the
# Cuttlefish target for the host architecture, creates RPM, Debian or Arch packages,
# and prints the package installation command when the build is complete.

./ika-build

# 3. Install packages and reboot.

# Run the package installation command printed by ika-build, then reboot.
# Rebooting applies the new group memberships, limits, udev rules, and device
# permissions. Logging out is not sufficient.

sudo reboot

# 4. Launch

ika start
```

Ika requires Mesa 26.1 or newer on Debian/Ubuntu hosts (Fedora and Arch Linux
already include Mesa 26.1).
On Debian 13 (trixie), `ika-build` automatically enables `trixie-backports`
when Mesa 26.1 or newer is not already installed and installs the required Mesa
packages with explicit `package/trixie-backports` selectors, following the
[Debian Backports instructions](https://backports.debian.org/Instructions/).

On Ubuntu-family hosts, `ika-build` offers to enable `ppa:kisak/kisak-mesa`
with `add-apt-repository`, then installs the Mesa packages from Kisak. Set
`UBUNTU_ENABLE_KISAK_MESA=true` for an unattended build. See the
[Kisak Mesa PPA instructions](https://launchpad.net/~kisak/+archive/ubuntu/kisak-mesa).

Debian trixie also requires Vulkan loader 1.4.341. On trixie only, `ika-build`
builds that loader from the pinned Debian Salsa packaging source.

### Rebuilding

After the initial build, use the narrowest command that matches your changes:

- **Full build** — re-run `./ika-build`, then run the installation command it
  prints. By default it builds the host's native ROM; pass `all`, `arm64` or
  `x86_64` to choose the targets, and `--microg` or `--mtg` to choose the
  Google integration, for example `./ika-build all --mtg`. With no arguments,
  `ika-build` asks whether to use microG, MindTheGapps, or a de-Googled image
  without an app store.
- **ROM only** — re-run `./lineageos/scripts/build_lineageos_desktop.sh` (or
  pass `arm64` / `x86_64` to limit it to one target). Use this after editing
  patches or overlays under `lineageos/`. Pass `RESET_PATCHED_PROJECTS=1` if
  you want patched source projects in the workspace reset before re-applying.
- **Host packages only** — re-run `./tools/buildutils/build_packages.sh`. Use this
  after editing host sources under `base/` or `frontend/`, after editing the
  package metadata under `base/rpm/`, `base/debian/`, `frontend/rpm/`, or
  `frontend/debian/`, or whenever you've finished a fresh ROM rebuild and want
  to repackage `ika-lineageos` with the new contents. Install the outputs
  directly with your distribution's package manager.

See [lineageos/README.md](lineageos/README.md) for ROM build options: provider
selection, target subsets, microG release pinning, native-bridge sources and
workspace overrides.

## Window Handling

The clock at the top left of the console window is also a **hot corner**.
Click and hold it to move the console window. If the window is maximized or
fullscreen, click it once to return to windowed mode.

Drag the window to the left or right edge of the screen to fill half
of the desktop, or drag it to the top edge to maximize the window.

Super (Command) + F switches fullscreen mode on and off.

Super (Command) + T switches the title bar on and off.

Without a title bar, resize the console by dragging just outside its edges:
the window keeps an invisible 4-pixel margin for that, so the edge of the
Android desktop stays clickable. While a window is resized, its last complete
picture is stretched and blurred until Android has drawn the new size.

## Managing the VM with `ika`

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

# Show the built-in usage text
ika help
```

### Camera

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

### Rooting with Magisk

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

### Google sign-in on uncertified devices

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

### Android files

While the VM runs, Android's shared storage (`/sdcard`: DCIM, Download,
Pictures and the rest) is mounted on `~/ika/Android`, so any file manager or
program on the host can open, copy, change and delete files there. `ika start`
mounts it and `ika stop`, `restart` and `reset` unmount it; while Ika is
stopped the folder is empty. GNOME's Files lists it in the sidebar, and the
first mount adds it to KDE's Places as **Android**. Files are read as they are
used, over Ika's adb connection, so a large video plays without being copied
first. Files an app keeps to itself are out of reach, as they are for adb. The
mount uses [madbfs](https://github.com/mrizaln/madbfs); its log is
`~/ika/madbfs.log`.

### Backing up apps and files

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

### App windows

With the VM running, `ika app PACKAGE` opens a single app in its own
resizable window with a normal title bar, separate from the desktop console.
Each window is backed by its own Android virtual display that follows the
window size, so resizing the window gives the app more room rather than
stretching it. Super + T and Super + F work as they do in the console.

- The app is restarted on the new display if it was already running on the
  desktop, and closing the window closes the app.
- Apps can be named by package or by the label shown by `ika app`.
  Labels match case-insensitively, exactly or by a unique part
  (`ika app setti` opens Settings), and need no quotes when they contain
  spaces. An ambiguous name lists the matching apps instead of guessing.
- Some apps are hidden from `ika app`, name matching and the menu: Android
  Switch, the Google search app, Calculator, Calendar, Clock, Contacts,
  Recorder and AudioFX. See `IKA_HIDDEN_APPS` in `tools/ika`. They
  still open when given by full package name.
- The window title is the app's label; override it with `--title=TEXT`. Window
  size is remembered per app under `~/ika/apps/PACKAGE/`; `--size=WxH` sets
  it explicitly.
- `--game` enables UHID gamepad, keyboard and mouse input without forcing
  fullscreen; add `-f` for fullscreen.
- **Games** (apps that declare `android:appCategory="game"`, or are listed in
  `IKA_GAME_APPS` in `tools/ika`) start in a **game session** instead of an
  app window: the console switches to fullscreen game mode (gamepad, keyboard
  and mouse passthrough, raw frames rather than encoded video) and the game
  runs fullscreen on Android's primary display. Leaving fullscreen or closing
  that window ends the session: the window closes, and the game is sent to
  the background (Home, where it saves its state), so the Android desktop is
  in front the next time you open Ika; starting the game again resumes it
  where you left it. The desktop console comes back if it was open before.
  As on a phone, Android may still reclaim a backgrounded game, which then
  starts fresh. Starting another game replaces the current one.
  `ika app NAME --window` opens a game in its own window instead. Only games
  started with `ika app` (or from the menu) behave this way; `ika start --game`
  and games opened inside the Android desktop are unaffected.
- **Touch input** (`ika app NAME --touch`) is for games that ignore the mouse.
  Left-button clicks and drags are sent to Android as a real finger on a
  touchscreen instead of as mouse input, so a drag is a swipe. The right and
  middle buttons and the wheel stay mouse input, Ctrl or Shift with the left
  button still simulates a pinch, and no hover is sent. In a game session the
  mouse leaves UHID (the gamepad and keyboard still pass through as HID
  devices), and a session already running in the other input mode is
  restarted when you start a game in the new one. `--touch` works with app
  windows too, and `IKA_TOUCH=1 ika start --game` does the same for the
  console. Most desktop apps should not use it: some route mouse clicks
  differently from touch, for example Chromium's tab strip.
- App windows stream encoded H.264 video from the guest rather than the
  console's raw frames, which costs guest CPU time. Set `IKA_APP_BIT_RATE`
  (default `80M`) to trade quality for bandwidth. `IKA_APP_CODEC_OPTIONS`
  (default `video-qp-max:int=18`) caps the encoder's quantizer to keep text
  sharp; set it empty to remove the cap. Where the host's VA-API driver
  decodes H.264 (Intel GPUs, for example), the video is decoded on the GPU;
  otherwise in software.
- `ika app sync` adds every launchable app to the desktop's app menu, as
  "🎮 ∙ LABEL" for games (apps declaring `android:appCategory="game"`, or listed
  in `IKA_GAME_APPS` in `tools/ika`) and "ᗩ ∙ LABEL" for other apps, in an
  "Android Apps (Ika)" group: a folder in the GNOME app
  grid, or a submenu on KDE Plasma, XFCE, Cinnamon and MATE. Launchers are
  `~/.local/share/applications/ika-PACKAGE.desktop` and are named after the
  app window's ID, so the dock and task switcher show an open app window
  under its launcher. Each launcher gets the app's own icon, rendered by
  Android so adaptive icons look as they do in the Ika launcher, and stored
  in `~/ika/apps/icons/`. Edits you make to a launcher are kept unless the
  app's label or icon changes.
- Menu entries work while Ika is stopped: `ika app` then starts the VM
  without the desktop console (`ika start --no-console`) and opens the app
  once Android has booted. Launched from a menu, `ika app` reports progress
  and errors as desktop notifications.
- Right-click a menu entry for **App Settings**, which opens the app's
  Android App info page (permissions, storage, force stop, uninstall) in the
  Settings window. From a terminal: `ika app --info NAME`. The entries of
  games also offer **Play with Touch Input**, which runs
  `ika app --touch PACKAGE`.
- The menu is kept up to date automatically: once the guest has booted,
  `ika start` runs a background watcher that syncs the menu and then checks
  every few seconds (`IKA_APP_MENU_POLL_SEC`, default 5) for installed,
  updated, removed, enabled or disabled apps. It logs to `~/ika/app-menu.log`
  and stops with the VM. `ika app sync` forces a sync. `ika app sync --remove`
  deletes the launchers and the group and turns the automatic sync off until
  `ika app sync` is run again. `ika reset` removes the entries too, since a
  factory reset removes the apps; the next `ika start` rebuilds the menu.
- `ika start` leaves app windows open; `ika stop`, `reset` and `restart` close
  them.

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

### gfxstream Vulkan switch

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

## Host Packages

The repository builds the host package names listed below. On RPM distributions,
outputs land under `rpmbuild/RPMS/`; on Debian-family distributions, outputs
land under `deb/`. Non-primary packages are moved into an `extras/`
subdirectory by `tools/buildutils/build_packages.sh`.

- `ika-base` — Core host binaries, networking helpers, system services,
  and scrcpy-based virtual console used by the `ika` launcher
- `ika-lineageos` — Bundled `lineageos/` tree installed under
  `/usr/share/cuttlefish-common/lineageos`
- `ika-user` — Browser-facing operator service
- `ika-orchestration` — Host Orchestrator service and nginx configuration
- `ika-integration` — Cloud-integration utilities
- `ika-defaults` — Optional defaults-override service and configuration
- `ika-metrics` — Metrics transmitter binary
- `ika-common` — Compatibility metapackage for the primary host packages

Most users need only `ika-base` and `ika-lineageos`.

## Notes

On ARM64 Asahi Linux, this fork uses gfxstream-backed acceleration. The default
`gfxstream_guest_angle` mode uses guest ANGLE over gfxstream Vulkan, while the
`auto` policy for direct `gfxstream` mode keeps Cuttlefish's GLES and Vulkan
contexts enabled on Apple Silicon hosts with 16 KiB pages and applies the
required udmabuf-backed external-memory path. `guest_swiftshader` remains a
fallback for isolating host GPU issues.

`ika` expects your login session to be in `kvm`, `cvdnetwork`, `render`, and
`video`. The `ika-base` package adds the installing user to these groups during
package configuration, but the active session, its PAM resource limits, and the
live `/dev/kvm` udev permissions don't pick up the new state without a
reboot—see step 3 under [Build Ika from Source](#build-ika-from-source) for the
full list of deferred changes.

Bazel is installed automatically through Bazelisk by `./ika-build`, which runs
[`tools/buildutils/installbazel.sh`](tools/buildutils/installbazel.sh) during
the dependency step. That step,
[`tools/buildutils/lib/dependencies.sh`](tools/buildutils/lib/dependencies.sh),
installs the main build dependencies near the start of a build. The signing-key
bootstrap may first install its smaller certificate toolset if needed. The
standalone build scripts
(`build_lineageos_desktop.sh`, `build_packages.sh`) assume dependencies are
already installed and fail fast when one is missing.

The networking helper uses `nftables` exclusively—both the host-side
bridge/NAT setup in `cuttlefish-host-resources.sh` and the per-user
`cvdalloc` daemon manage their rules via native `nft` commands against a
shared `ip cuttlefish` table. iptables (and `iptables-nft`) and ebtables
are no longer runtime dependencies.

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/c63c8d08-d11b-4ec0-956a-d2c0220b963a" />
