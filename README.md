<img width="1920" height="1080" alt="Ika Virtual Desktop" src="https://github.com/user-attachments/assets/ad0213c3-6a9d-45bc-9468-dcdd82abca26" />

# イカ · The LineageOS Virtual Desktop

**Ika** _/ee-kah/_ - Japanese for "cuttlefish" - began as an effort to run the
[Cuttlefish](https://source.android.com/setup/create/cuttlefish) Android emulator
on [Fedora Asahi Remix](https://asahilinux.org/). It has since evolved into a
desktop operating system for Apple Silicon and x86-64 hosts, but the name stuck.

## Features

- **LineageOS 23.2** (Android 16) reimagined as a desktop-first operating system.
- **Dynamic display** window resizing that preserves the configured DPI settings.
- **Accelerated GPU rendering** with OpenGL ES and Vulkan support.
- **Native builds on Asahi Linux** and x86-64 systems with as little as 16 GB
  of RAM.
- **Flexible build options** for **MindTheGapps**, **microG**, or a fully
  de-Googled ROM without an app store.

## Ika Binaries

Ika consists of two packages: an Android disk image (informally, the device ROM)
and a matching Cuttlefish virtual machine application. Prebuilt Fedora Linux
(`.rpm`) and Debian/Ubuntu (`.deb`) packages are available below.
Select your distribution and CPU architecture, then download the corresponding
application and disk image.

| **Distribution / architecture** | **Application** | **Disk Image** |
| --- | --- | --- |
|  |  |  |
| Fedora x86_64 | [ika-base (144 MB)](https://github.com/DesktopECHO/ika/releases/download/260713/ika-base-260713-1.fc44.x86_64.rpm) | [ika-lineageos (1.31 GB)](https://github.com/DesktopECHO/ika/releases/download/260713/ika-lineageos-260713-1.fc44.x86_64.rpm) |
|  |  |  |
| Fedora ARM64 | [ika-base (141 MB)](https://github.com/DesktopECHO/ika/releases/download/260713/ika-base-260713-1.fc44.aarch64.rpm) | [ika-lineageos (1.29 GB)](https://github.com/DesktopECHO/ika/releases/download/260713/ika-lineageos-260713-1.fc44.aarch64.rpm) |
|  |  |  |
| Debian x86_64 | [ika-base (116 MB)](https://github.com/DesktopECHO/ika/releases/download/260713/ika-base_260713-1_amd64.deb) | [ika-lineageos (1.26 GB)](https://github.com/DesktopECHO/ika/releases/download/260713/ika-lineageos_260713-1_amd64.deb) |
|  |  |  |
| Debian ARM64 | [ika-base (101 MB)](https://github.com/DesktopECHO/ika/releases/download/260713/ika-base_260713-1_arm64.deb) | [ika-lineageos (1.24 GB)](https://github.com/DesktopECHO/ika/releases/download/260713/ika-lineageos_260713-1_arm64.deb) |

> [!NOTE]
> Debian and Ubuntu require Mesa 26.1 or newer. Get an updated Mesa from
> [Debian trixie-backports](https://backports.debian.org/Instructions/) or the
> [Kisak Mesa PPA](https://launchpad.net/~kisak/+archive/ubuntu/kisak-mesa)
> before installing the binary packages.

## Building Ika from Source

A successful build requires a minimum of 16GB RAM and 300GB storage.
The initial build will take 3–6 hours or more, depending on your hardware and internet bandwidth.
It's advisable to just let run it overnight. The *ika-build* script handles the prerequisite
steps and produces installable .deb/.rpm packages for your distribution. 

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

Ika requires Mesa 26.1 or newer on Debian/Ubuntu hosts (Fedora already includes
Mesa 26.1).
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
  `./ika-build x86_64`, `./ika-build --microg arm64`, or
  `./ika-build --mtg x86_64`. With no arguments, `ika-build` prompts for microG,
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
ika start

# Show the built-in usage text
ika help
```

`ika start` and `ika restart` pass extra arguments directly to
`cvd_internal_start`, so you can override launch settings on the command line.
`ika stop` calls the matching low-level stop helper and then cleans up local
Cuttlefish processes. `ika reset` is the destructive variant; it passes
`--clear_instance_dirs` and removes the local Chromium-install stamp.

By default `ika` uses:

- host tools from `/usr/lib/cuttlefish-common`
- the packaged LineageOS tree from `/usr/share/cuttlefish-common/lineageos`
- instance state under `~/ika`
- a ~64 GB thin-provisioned ext4 userdata image
- guest vCPUs set to the available/performance-core count minus two, capped at 12
- guest RAM set to about one quarter of host RAM, rounded to 2 GB steps and
  capped at 32 GB
- `gfxstream_guest_angle` GPU acceleration
- Ethernet-only guest networking by default; Wi-Fi, Bluetooth, NFC, UWB, GNSS,
  and the modem simulator remain off unless explicitly enabled

`gfxstream_guest_angle` is the default GPU mode. It runs guest OpenGL ES through
Android ANGLE over gfxstream Vulkan. Use `gfxstream` to test gfxstream's direct
OpenGL ES translator, or `guest_swiftshader` as a troubleshooting fallback when
host GPU acceleration is unavailable. See [GFXSTREAM.md](GFXSTREAM.md) for a
comparison. The launcher selects EGL's surfaceless platform for gfxstream modes
so an unavailable X11 display inherited from SSH cannot redirect host-renderer
initialization. The desktop product also leaves gfxstream's optional
program-binary link-status feature disabled; shader-source compilation remains
available and avoids corrupt cached-program rendering in affected games.

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

The repository currently builds these host package names. On RPM distributions,
outputs land under `rpmbuild/RPMS/`; on Debian-family distributions, outputs
land under `deb/`. Non-primary packages are moved into an `extras/`
subdirectory by `tools/buildutils/build_packages.sh`.

- `ika-base` — Core host binaries, networking helpers, system services, and
  the bundled virtual console used by the `ika` launcher
- `ika-lineageos` — Bundled `lineageos/` tree installed under
  `/usr/share/cuttlefish-common/lineageos`
- `ika-user` — Browser-facing operator service
- `ika-orchestration` — Host Orchestrator service and nginx configuration
- `ika-integration` — Cloud-integration utilities
- `ika-defaults` — Optional defaults-override service and configuration
- `ika-metrics` — Metrics transmitter binary
- `ika-common` — Compatibility metapackage for the primary host packages

For the local workstation workflow, `ika-base` and `ika-lineageos` are the key
packages; `ika-base` includes the virtual console used by the `ika` launcher. On
RPM distributions, the specs also provide and obsolete the old `cuttlefish-*`
package names for upgrades, but newly built package files use the `ika-*` names.

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
reboot—see step 3 under [Building from Source](#building-from-source) for the
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
