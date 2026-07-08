<img width="2480" height="2064" alt="Screenshot From 2026-04-01 22-30-37" src="https://github.com/user-attachments/assets/24e59e40-5dfd-45c2-9d69-ed64f1155c6c" />

# イカ (Ika, /ee-kah/)

This project started as an effort to get the [Cuttlefish](https://source.android.com/setup/create/cuttlefish) Android Emulator running on [Fedora Asahi Remix](https://asahilinux.org/).  **ika (イカ)** is the Japanese word for cuttlefish (or squid) and the name stuck, even as it evolved to include x86-64 support.

Ika consists of two components:  The Android OS disk image (the device ROM, informally) and a virtual machine player (Cuttlefish) that runs Android on x86-64 or ARM64 (Asahi) Linux hosts.

## Binaries

Prebuilt packages for Fedora Linux (.rpm) and Debian/Ubuntu (.deb) are linked below from the [latest release](https://github.com/DesktopECHO/ika/releases/latest) (`260629`). Pick the row for your package and the column for your distro and CPU architecture.

The Mesa packages supplied by Debian 13 and Ubuntu 26.04 are too old for Ika; install the supported Mesa stack from a suitable backport or PPA archive.

On Debian 13 (trixie), enable `trixie-backports` and install the Mesa stack from backports using the [Debian Backports instructions](https://backports.debian.org/Instructions/).

On Ubuntu-family hosts, use the [Kisak Mesa PPA instructions](https://launchpad.net/~kisak/+archive/ubuntu/kisak-mesa).

| Package | Fedora x86_64 | Fedora ARM64 | Debian x86_64 | Debian ARM64 |
| --- | --- | --- | --- | --- |
| **ika-lineageos** (ROM image) | [1.36 GB](https://github.com/DesktopECHO/ika/releases/download/260629/ika-lineageos-260629-1.fc44.x86_64.rpm) | [1.17 GB](https://github.com/DesktopECHO/ika/releases/download/260629/ika-lineageos-260629-1.fc44.aarch64.rpm) | [1.32 GB](https://github.com/DesktopECHO/ika/releases/download/260629/ika-lineageos_260629-1_amd64.deb) | [1.13 GB](https://github.com/DesktopECHO/ika/releases/download/260629/ika-lineageos_260629-1_arm64.deb) |
| **ika-base** (virtualization app + virtual console) | [139 MB](https://github.com/DesktopECHO/ika/releases/download/260629/ika-base-260629-1.fc44.x86_64.rpm) | [135 MB](https://github.com/DesktopECHO/ika/releases/download/260629/ika-base-260629-1.fc44.aarch64.rpm) | [115 MB](https://github.com/DesktopECHO/ika/releases/download/260629/ika-base_260629-1_amd64.deb) | [100 MB](https://github.com/DesktopECHO/ika/releases/download/260629/ika-base_260629-1_arm64.deb) |

## Building from Source

You will need a minimum of 16GB RAM, 300GB storage, and some patience for the build to complete.  `ika-build` handles all the install prequisitres. 

```bash
# 1. Clone:
git clone https://github.com/DesktopECHO/ika.git
cd ika

# 2. Build:
#    Prepares signing certificates, installs build dependencies, downloads
#    LineageOS 23.2 source, applies the overlay and source patches in lineageos,
#    builds the Cuttlefish target for the host arch, creates RPM or Debian packages
#    and offers to install them after the build is completed. 

./ika-build

# 3. Reboot.
#    Required so group memberships, limits, udev rules, and device permissions
#    are picked up cleanly. Logging out is not enough.

sudo reboot

# 4. Launch
ika start
```

A few seconds after the virtual device starts, the bundled `ika` virtual console
opens automatically against the running Cuttlefish instance.
The virtual console uses Cuttlefish raw frames for both windowed and fullscreen
sessions.

### Rebuilding

Once you have an initial build, use the narrowest command that matches the work
you changed:

- **Full build + install** — re-run `./ika-build` and accept the install prompt. Extra
  arguments are forwarded to the ROM build, for example
  `./ika-build x86_64`.
- **Install package files only** — run `./ika-build --install-packages`. This
  does not build source, assumes yes to installation, and installs the
  existing `ika-base` and `ika-lineageos` packages using `dnf`
  or `apt` as appropriate.
- **ROM only** — re-run `./lineageos/scripts/build_lineageos_desktop.sh` (or
  pass `arm64` / `x86_64` to limit it to one target). Use this after editing
  patches or overlays under `lineageos/`. Pass `RESET_PATCHED_PROJECTS=1` if
  you want patched source projects in the workspace reset before re-applying.
- **Host packages only** — re-run `./tools/buildutils/build_packages.sh`. Use this
  after editing host sources under `base/` or `frontend/`, after editing the
  package metadata under `base/rpm/`, `base/debian/`, `frontend/rpm/`, or
  `frontend/debian/`, or whenever you've finished a fresh ROM rebuild and want
  to repackage `ika-lineageos` with the new contents. Then run
  `./ika-build --install-packages` to install the package outputs.

See [lineageos/README.md](lineageos/README.md) for ROM-build options (target
subsets, microG release pinning, native-bridge sources, workspace overrides)
and [tools/buildutils/cw/README.md](tools/buildutils/cw/README.md) for the
optional containerized RPM build.

## Managing the VM with `ika`

After the packages are installed, `ika` is available on your `PATH` and can be used
to start, stop, and restart the packaged Cuttlefish environment.

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

# Temporarily enable gfxstream Vulkan on Apple Silicon for testing
ika restart --gfxstream_vulkan=on

# Use a 128 GiB userdata image on first start after reset
ika reset
ika start --data_gb=128

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
- guest RAM set to about one quarter of host RAM, capped at 32 GB 
- `gfxstream` GPU acceleration

`gfxstream` is the preferred GPU mode for the packaged workflow. Use
`guest_swiftshader` only as a troubleshooting fallback when host GPU
acceleration is not usable.

Set `DATA_GB` or pass `--data_gb=128` to choose the size, in gigabytes,
of a newly created userdata image. Existing userdata is preserved, so apply a
new size by resetting first and then starting with the override.

### gfxstream Vulkan switch

`ika` has a launcher-level switch for the gfxstream Vulkan context:

```bash
ika start --gfxstream_vulkan=auto
ika restart --gfxstream_vulkan=off
ika restart --gfxstream_vulkan=on
```

`auto` is the default. When the primary host Vulkan device is llvmpipe, `auto`
requests GLES-only gfxstream (`gfxstream-gles:gfxstream-composer`). On Apple
Silicon hosts with 16 KiB pages, `auto` requests GLES+Vulkan and routes
host-visible guest Vulkan memory through the udmabuf-backed path the Apple GPU
supports. On other hosts, `auto` leaves the normal Cuttlefish gfxstream defaults
alone, so systems with hardware Vulkan keep Vulkan enabled.

Use `--gfxstream_vulkan=on` to re-enable gfxstream Vulkan for testing, or
`--gfxstream_vulkan=off` to force GLES-only gfxstream. The same policy can be
set with `GFXSTREAM_VULKAN=auto|off|on`; an explicit
`--gpu_context_types=...` argument takes precedence.

## Host Packages

The repo currently builds these host package names. On RPM distributions,
outputs land under `rpmbuild/RPMS/`; on Debian-family distributions, outputs
land under `deb/`. Non-primary packages are moved into an `extras/`
subdirectory by `tools/buildutils/build_packages.sh`.

* `ika-base` - Core host binaries, networking helpers, system services, and
  the bundled virtual console used by the `ika` launcher
* `ika-user` - Browser-facing operator service
* `ika-orchestration` - Host Orchestrator service and nginx config
* `ika-integration` - Cloud integration utilities
* `ika-defaults` - Optional defaults override service and config
* `ika-metrics` - Metrics transmitter binary
* `ika-lineageos` - Bundled `lineageos/` tree installed under
  `/usr/share/cuttlefish-common/lineageos`
* `ika-common` - Compatibility metapackage for the primary host packages

For the local workstation workflow, `ika-base` and `ika-lineageos` are the key
packages; `ika-base` includes the virtual console used by the `ika` launcher. On
RPM distributions, the specs also provide and obsolete the old `cuttlefish-*`
package names for upgrades, but newly built package files use the `ika-*` names.

## Notes

On ARM64 Asahi Linux, this fork keeps `gfxstream` as the forward path. The
packaged `ika` launcher disables only the gfxstream Vulkan context by default
on Apple Silicon 16 KiB-page hosts while keeping gfxstream GLES enabled;
`guest_swiftshader` remains a fallback for isolating host GPU issues.

`ika` expects your login session to be in `kvm`, `cvdnetwork`, `render`, and
`video`. The `ika-base` package adds the installing user to these groups during
package configuration, but the active session, its PAM resource limits, and the
live `/dev/kvm` udev permissions don't pick up the new state without a
reboot — see step 3 of the Quick start for the full list of what's deferred.

Bazel is installed automatically through Bazelisk by `./ika-build`, which runs
[`tools/buildutils/installbazel.sh`](tools/buildutils/installbazel.sh) during
its dependency step. That step
([`tools/buildutils/lib/dependencies.sh`](tools/buildutils/lib/dependencies.sh))
handles the main build dependency install near the start of a build rather than
partway through. The signing-key bootstrap may install its small certificate
tool set first if needed. The standalone build scripts
(`build_lineageos_desktop.sh`, `build_packages.sh`) assume dependencies are
already installed and fail fast when one is missing.

The networking helper uses `nftables` exclusively — both the host-side
bridge/NAT setup in `cuttlefish-host-resources.sh` and the per-user
`cvdalloc` daemon manage their rules via native `nft` commands against a
shared `ip cuttlefish` table. iptables (and `iptables-nft`) and ebtables
are no longer runtime dependencies.

## Google Compute Engine

The current GCE image tooling in this fork lives under `tools/baseimage/`.
See [tools/baseimage/README.md](tools/baseimage/README.md) for the current
workflow.
