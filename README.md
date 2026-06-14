<img width="2480" height="2064" alt="Screenshot From 2026-04-01 22-30-37" src="https://github.com/user-attachments/assets/24e59e40-5dfd-45c2-9d69-ed64f1155c6c" />

# イカ (Ika, /ee-kah/)

This project originally started as an effort to get [Cuttlefish](https://source.android.com/setup/create/cuttlefish) (Google's Android Virtual Device built on Debian tooling) running on [Fedora Asahi Remix](https://asahilinux.org/), so the project was given the name **ika (イカ)**, the Japanese word for cuttlefish (or squid).

The repository is a fork of [google/android-cuttlefish](https://github.com/google/android-cuttlefish), adapted into a desktop-oriented ika workflow with RPM and Debian package builds.  [Cuttlefish](https://source.android.com/setup/create/cuttlefish) is a configurable Android Virtual Device (AVD) that runs on Linux x86_64 and aarch64 hosts as well as Google Compute Engine.

## Quick start

For the normal local workflow, use `ika-build` from the repository root. It
builds the LineageOS Desktop ROM, builds the host packages for the detected
distribution family, and installs the primary runtime packages.

```bash
# 1. Clone
git clone https://github.com/DesktopECHO/ika.git
cd ika

# 2. Build and install.
#    Prepares signing certificates, installs build dependencies, then downloads
#    LineageOS 23.2 source,
#    applies the overlay and source patches in lineageos/, builds the
#    Cuttlefish target for the host arch, and creates RPM or Debian packages.
#    Incremental runs are much faster.
./ika-build --auto-install

# 3. Reboot.
#    Required so group memberships, limits, udev rules, and device permissions
#    are picked up cleanly. Logging out is not enough.
sudo reboot

# 4. Launch
ika start
```

A few seconds after the virtual device starts, the bundled `ika` viewer
opens automatically against the running Cuttlefish instance.
The viewer uses Cuttlefish raw frames for both windowed and fullscreen
sessions by default; set `IKA_SCRCPY_VIDEO_SOURCE=encoded` only if you need to
fall back to ADB display capture for troubleshooting.

### Rebuilding

Once you have an initial build, use the narrowest command that matches the work
you changed:

- **Full build + install** — re-run `./ika-build --auto-install`. Extra
  arguments are forwarded to the ROM build, for example
  `./ika-build --auto-install x86_64`.
- **Install existing packages only** — run `./ika-build --install-only`. This
  skips ROM and package builds, assumes yes to installation, and installs the
  existing `ika-base`, `ika-scrcpy`, and `ika-lineageos` packages using `dnf`
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
  `./ika-build --install-only` to install the package outputs.

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
ika restart --gfxstream-vulkan=on

# Use a 128 GiB userdata image on first start after reset
ika reset
ika start --datagb=128

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
- a ~64 GB thin-provisioned f2fs userdata image
- `gfxstream` GPU acceleration
- host Bluetooth, with Wi-Fi, netsim, and UWB disabled unless you override them

`gfxstream` is the preferred GPU mode for the packaged workflow. Use
`guest_swiftshader` only as a troubleshooting fallback when host GPU
acceleration is not usable.

Set `DATAGB` or pass `--datagb=128` to choose the size, in gigabytes,
of a newly created userdata image. Existing userdata is preserved, so apply a
new size by resetting first and then starting with the override.

### gfxstream Vulkan switch

`ika` has a launcher-level switch for the gfxstream Vulkan context:

```bash
ika start --gfxstream-vulkan=auto
ika restart --gfxstream-vulkan=off
ika restart --gfxstream-vulkan=on
```

`auto` is the default. On Apple Silicon hosts with 16 KiB pages, or when the
primary host Vulkan device is llvmpipe, `auto` requests GLES-only gfxstream
(`gfxstream-gles:gfxstream-composer`). On other hosts, `auto` leaves the normal
Cuttlefish gfxstream defaults alone, so x86_64 systems with hardware Vulkan keep
Vulkan enabled.

Use `--gfxstream-vulkan=on` to re-enable gfxstream Vulkan for testing, or
`--gfxstream-vulkan=off` to force GLES-only gfxstream. The same policy can be
set with `IKA_GFXSTREAM_VULKAN=auto|off|on`; an explicit
`--gpu_context_types=...` argument takes precedence.

## Host Packages

The repo currently builds these host package names. On RPM distributions,
outputs land under `rpmbuild/RPMS/`; on Debian-family distributions, outputs
land under `deb/`. Non-primary packages are moved into an `extras/`
subdirectory by `tools/buildutils/build_packages.sh`.

* `ika-base` - Core host binaries, networking helpers, and system
  services
* `ika-user` - Browser-facing operator service
* `ika-orchestration` - Host Orchestrator service and nginx config
* `ika-integration` - Cloud integration utilities
* `ika-defaults` - Optional defaults override service and config
* `ika-metrics` - Metrics transmitter binary
* `ika-lineageos` - Bundled `lineageos/` tree installed under
  `/usr/share/cuttlefish-common/lineageos`
* `ika-common` - Compatibility metapackage for the primary host packages
* `ika-scrcpy` - Native viewer used by the `ika` launcher

For the local workstation workflow, `ika-base`, `ika-scrcpy`, and
`ika-lineageos` are the key packages. On RPM distributions, the specs also
provide and obsolete the old `cuttlefish-*` package names for upgrades, but
newly built package files use the `ika-*` names.

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
