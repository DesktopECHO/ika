<img width="1920" height="1080" alt="Ika Virtual Desktop" src="https://github.com/user-attachments/assets/ad0213c3-6a9d-45bc-9468-dcdd82abca26" />

# イカ · Ika Virtual Desktop

**Ika** _/ee-kah/_, the Japanese word for squid or cuttlefish, began as an effort to
run the [Cuttlefish](https://source.android.com/setup/create/cuttlefish) Android emulator
on [Fedora Asahi Remix](https://asahilinux.org/). It later evolved into a desktop-centric Android build for Apple Silicon and x86-64 hosts, but the name already stuck.

## Features

- **LineageOS 23.2** (Android 16) reimagined as a desktop-first operating system.
- **Native builds** for **Apple Silicon** or **x86-64** systems with as little as 16 GB RAM,
  on **Fedora**, **Debian/Ubuntu** and **Arch Linux**.
- **Dynamic display** window resizing that preserves DPI settings.
- **GPU acceleration** with support for OpenGL ES and Vulkan.
- **App windows**: run single Android apps in their own desktop windows, listed
  in your desktop's app menu; games start fullscreen with gamepad passthrough
  (see [App windows](#app-windows)).
- **Flexible build options** for **MindTheGapps**, **microG**, or a fully
  de-Googled ROM without an app store.

Changes since the last published binaries are listed in [CHANGELOG.md](CHANGELOG.md).

The Apple Silicon Vulkan memory-sharing path, including its 16 KiB-page and
udmabuf handling, is documented in [GFXSTREAM-VULKAN.md](GFXSTREAM-VULKAN.md).
The implementation patch inventory is maintained in
[lineageos/patches/README.md](lineageos/patches/README.md); known graphics-path
limitations are recorded in that Vulkan document rather than presented as
completed compatibility fixes.

## Ika Binaries (Updated 2026-09-28)

Ika consists of two packages: An Android disk image (informally, the device ROM)
and a matching Cuttlefish virtual machine application. Prebuilt Fedora 44
(`.rpm`), Debian 13/Ubuntu 26.04 (`.deb`) and Arch Linux x86_64 (`.pkg.tar.zst`)
packages are available below. Select your distribution and CPU architecture, then
download the corresponding application and disk image.

> [!NOTE]
> Debian and Ubuntu require Mesa 26.1 or newer. Get updated binaries from [Debian trixie-backports](https://backports.debian.org/Instructions/) or the [Kisak Mesa PPA](https://launchpad.net/~kisak/+archive/ubuntu/kisak-mesa) before installing the Ika packages.

| **Distribution • Architecture** | **Application** | **Disk Image** |
| --- | --- | --- |
|  |  |  |
| Fedora 44 • x86_64 | [ika-base (145 MB)](https://github.com/DesktopECHO/ika/releases/download/260928/ika-base-260928-1.fc44.x86_64.rpm) | [ika-lineageos (1.38 GB)](https://github.com/DesktopECHO/ika/releases/download/260928/ika-lineageos-260928-1.fc44.x86_64.rpm) |
|  |  |  |
| Fedora 44 • ARM64 | [ika-base (142 MB)](https://github.com/DesktopECHO/ika/releases/download/260928/ika-base-260928-1.fc44.aarch64.rpm) | [ika-lineageos (1.37 GB)](https://github.com/DesktopECHO/ika/releases/download/260928/ika-lineageos-260928-1.fc44.aarch64.rpm) |
|  |  |  |
| Debian 13 / Ubuntu 26.04  •  x86_64 | [ika-base (121 MB)](https://github.com/DesktopECHO/ika/releases/download/260928/ika-base_260928-1_amd64.deb) | [ika-lineageos (1.33 GB)](https://github.com/DesktopECHO/ika/releases/download/260928/ika-lineageos_260928-1_amd64.deb) |
|  |  |  |
| Debian 13 / Ubuntu 26.04 • ARM64 | [ika-base (106 MB)](https://github.com/DesktopECHO/ika/releases/download/260928/ika-base_260928-1_arm64.deb) | [ika-lineageos (1.31 GB)](https://github.com/DesktopECHO/ika/releases/download/260928/ika-lineageos_260928-1_arm64.deb) |
|  |  |  |
| Arch Linux • x86_64 | [ika-base (201 MB)](https://github.com/DesktopECHO/ika/releases/download/260928/ika-base-260928-1-x86_64.pkg.tar.zst) | [ika-lineageos (1.57 GB)](https://github.com/DesktopECHO/ika/releases/download/260928/ika-lineageos-260928-1-x86_64.pkg.tar.zst) |
|  |  |  |
| Arch Linux • ARM64 | [`./ika-build`](https://github.com/DesktopECHO/ika#build-ika-from-source) | [`./ika-build`](https://github.com/DesktopECHO/ika#build-ika-from-source) |

## Build Ika from Source

A successful build requires a minimum of 16GB RAM and 300GB storage.
The initial build will take 3–6 hours or more, depending on your hardware and internet bandwidth.
It's advisable to just let run it overnight. The *ika-build* script handles the prerequisite
steps and produces installable .rpm, .deb or Arch Linux packages for your distribution.
Prebuilt binaries are published for Fedora, Debian/Ubuntu and Arch Linux x86_64; on Arch Linux ARM64, build from source.

```bash
# 1. Download and extract:

curl -L https://github.com/DesktopECHO/ika/archive/refs/heads/main.zip -o ika-main.zip
unzip ika-main.zip && rm ika-main.zip && cd ika-main

# 2. Build:

# Prepares signing certificates, installs build dependencies, downloads the
# LineageOS 23.2 source, applies the overlay and source patches, builds the
# Cuttlefish target for the host architecture, creates RPM or Debian packages,
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
  prints. Extra arguments are forwarded to the ROM build, for example
  `./ika-build x86_64`, `./ika-build arm64 --microg`, or
  `./ika-build x86_64 --mtg`. With no arguments, `ika-build` prompts for microG,
  MindTheGapps, or a de-Googled image without an app store before building the
  host-native ROM.
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

See [lineageos/README.md](lineageos/README.md) for ROM-build options; provider
selection, target subsets, microG release pinning, native-bridge sources,
workspace overrides.

## Window Handling

The clock at the top-left of the console window is also a **hot corner**. 
Click+hold the hot corner to move the console window. If the window is maximized
or in fullscreen mode, click the hot corner once to return to windowed mode.

Drag the window to the left or right edge of the screen to fill half
of the desktop, or drag it to the top edge to maximize the window.

Super (Command) + F Switches in and out of fullscreen mode.

Super (Command) + T Switches the title bar on and off. 

## Managing the VM with `ika`

After the packages are installed, `ika` is available on your `PATH`. Use it to
start, stop, and restart the packaged Cuttlefish environment.

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

# Game Mode will start Ika fullscreen and enable HID keyboard and mouse 
ika start --game

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
  Switch, the camera, the Google search app, Calculator, Calendar, Clock,
  Contacts, Recorder and AudioFX. See `IKA_HIDDEN_APPS` in `tools/ika`. They
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
  sharp; set it empty to remove the cap.
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
Cuttlefish processes. `ika reset` is the destructive variant; it passes
`--clear_instance_dirs` and removes the local Chromium-install stamp.

Default `ika` settings and configuration:

- host tools from `/usr/lib/cuttlefish-common`
- the packaged LineageOS tree from `/usr/share/cuttlefish-common/lineageos`
- instance state under `~/ika`
- ~64 GB thin-provisioned ext4 userdata image
- guest vCPUs set to the available/performance-core count minus two, capped at 12
- guest RAM set to one quarter of host RAM, capped at 32 GB
- Ethernet-only guest networking by default; Wi-Fi, Bluetooth, NFC, UWB, GNSS,
  and the modem simulator remain off unless explicitly enabled

`gfxstream_guest_angle` is the default GPU mode. It runs guest OpenGL ES through
Android ANGLE over gfxstream Vulkan. Use `gfxstream` to test gfxstream's direct
OpenGL ES translator, or `guest_swiftshader` as a troubleshooting fallback when
host GPU acceleration is unavailable. See [GFXSTREAM.md](GFXSTREAM.md) for a
comparison. Use `gfxstream_guest_angle` for games and Vulkan/CTS; mixed
`gfxstream` mode does not support data-buffer AHardwareBuffers. Gfxstream uses
surfaceless EGL to avoid SSH/X11 display issues. Program-binary caching stays
disabled because it corrupts rendering in some games. On RADV hosts, `ika`
adds `syncshaders` to `RADV_DEBUG` for gfxstream modes. This prevents
asynchronous host shader compilation from intermittently executing incomplete
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

The majority of users will need only `ika-base` and `ika-lineageos`

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
reboot—see step 3 under [Building from Source](#build-ika-from-source) for the
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
