**README** | [UI Intro](UI-INTRO.md) | [Ika commands](USAGE.md) | [Changelog](CHANGELOG.md) | [Downloads](DOWNLOADS.md)

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
  in your desktop's app menu; games start fullscreen, with the gamepad
  passed through when `gamepad = on` is set in ika.ini (see
  [App windows](UI-INTRO.md#app-windows)).
- **Camera**: use a webcam or a Mac's FaceTime camera as Android's front camera
  (see [Camera](USAGE.md#camera)).
- **Android files on the host**: Android's storage is mounted while Ika runs,
  under **Android** in the file manager's sidebar (see
  [Android files](USAGE.md#android-files)).
- **Built-in root utility**: `ika root` roots the VM with Magisk (see
  [Rooting with Magisk](USAGE.md#rooting-with-magisk)).
- **Flexible build options** for **MindTheGapps**, **microG**, or a fully
  de-Googled ROM without an app store.

Prebuilt packages are on the [Downloads](DOWNLOADS.md) page, the console and app
windows are described in [UI Intro](UI-INTRO.md), and the `ika` commands in
[Ika commands](USAGE.md). Changes since the
last published binaries are listed in [CHANGELOG.md](CHANGELOG.md).

The Apple Silicon Vulkan memory-sharing path, including its 16 KiB-page and
udmabuf handling, and the known graphics limitations are documented in
[GFXSTREAM-VULKAN.md](GFXSTREAM-VULKAN.md). The source patches are listed in
[lineageos/patches/README.md](lineageos/patches/README.md).

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
