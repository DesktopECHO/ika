<img width="2480" height="2064" alt="Screenshot From 2026-04-01 22-30-37" src="https://github.com/user-attachments/assets/24e59e40-5dfd-45c2-9d69-ed64f1155c6c" />

# イカ (Ika, /ee-kah/)

This project originally started as an effort to get [Cuttlefish](https://source.android.com/setup/create/cuttlefish) (Google's Android Virtual Device built on Debian tooling) running on [Fedora Asahi Remix](https://asahilinux.org/), so the project was given the name **ika (イカ)**, the Japanese word for cuttlefish (or squid).

The repository is a fork of [google/android-cuttlefish](https://github.com/google/android-cuttlefish), adapted for RPM-based distributions like Fedora Asahi Remix.  [Cuttlefish](https://source.android.com/setup/create/cuttlefish) is a configurable Android Virtual Device (AVD) that runs on Linux x86_64 and aarch64 hosts as well as Google Compute Engine.

## Quick start

First build the LineageOS ROM for your target architecture (x86-64 or Apple Silicon) then build Cuttlefish, CrosVM, and ika-scrcpy RPMs:

```bash
# 1. Clone
git clone https://github.com/DesktopECHO/ika.git
cd ika

# 2. Build the LineageOS Desktop ROM for both arches.
#    First run: ~1-2h (downloads LineageOS 23.2 source, applies the overlay
#    and source patches in lineageos/, builds the ARM64 and x86-64 Cuttlefish
#    targets). The first signed build may prompt once for a signing identity
#    and writes keys under ~/.android-certs by default. Incremental runs are
#    much faster.
#    Produces ./lineageos-arm64/ and ./lineageos-x86_64/ at the repo root.
./lineageos/scripts/build_lineageos_desktop.sh

# 3. Build the host Cuttlefish + LineageOS RPMs (~30-60 min first run).
#    ika-lineageos bundles ./lineageos-<host_arch>/ from step 2 into
#    /usr/share/cuttlefish-common/lineageos. If step 2 was skipped or only
#    built the other arch, ika-lineageos is silently skipped here.
./tools/buildutils/build_packages.sh

# 4. Install the host packages and the bundled LineageOS tree.
#    ika-base's %post detects your logged-in user and adds it to the
#    required kvm / cvdnetwork / render / video groups automatically.
sudo dnf install \
  ./rpmbuild/RPMS/*/ika-base-*.rpm \
  ./rpmbuild/RPMS/*/ika-scrcpy-*.rpm \
  ./rpmbuild/RPMS/*/ika-lineageos-*.rpm

# 5. Reboot.
#    Required so group memberships, limits, udev rules, and Cuttlefish host
#    resources are picked up cleanly. Logging out is not enough.
sudo reboot

# 6. Launch
ika start
```

A few seconds after the virtual device starts, the bundled `ika` viewer
opens automatically against the running Cuttlefish instance.
The viewer uses Cuttlefish raw frames for both windowed and fullscreen
sessions by default; set `IKA_SCRCPY_VIDEO_SOURCE=encoded` only if you need to
fall back to ADB display capture for troubleshooting.

### Rebuilding one phase

Once you have an initial build, you can rebuild either phase independently:

- **ROM only** — re-run `./lineageos/scripts/build_lineageos_desktop.sh` (or
  pass `arm64` / `x86_64` to limit it to one target). Use this after editing
  patches or overlays under `lineageos/`. Pass `RESET_PATCHED_PROJECTS=1` if
  you want patched source projects in the workspace reset before re-applying.
- **RPMs only** — re-run `./tools/buildutils/build_packages.sh`. Use this
  after editing host sources under `base/` or `frontend/`, after editing the
  RPM specs under `base/rpm/`, or whenever you've finished a fresh ROM
  rebuild and want to repackage the `ika-lineageos` RPM with the new
  contents.

See [lineageos/README.md](lineageos/README.md) for ROM-build options (target
subsets, microG release pinning, native-bridge sources, workspace overrides)
and [tools/buildutils/cw/README.md](tools/buildutils/cw/README.md) for the
optional containerized RPM build.

## Managing the VM with `ika`

After the RPMs are installed, `ika` is available on your `PATH` and can be used
to start, stop, and restart the packaged Cuttlefish environment.

```bash
# Start a windowed VM
ika start 

# Check whether the VM is running
ika status

# Stop the VM and clear instance state
ika stop

# Restart with new launch arguments
ika restart --gpu_mode=gfxstream --cpus=8 --memory_mb=8192

# Temporarily enable gfxstream Vulkan on Apple Silicon for testing
ika restart --gfxstream-vulkan=on

# Use a 32 GiB userdata image on first start after reset
ika reset
ika start --userdata_gb=32

# Show the built-in usage text
ika help
```

`ika start` and `ika restart` pass extra arguments directly to
`cvd_internal_start`, so you can override launch settings on the command line.
`stop` calls the matching low-level stop helper (`cvd_internal_stop` or
`stop_cvd`) with `--clear_instance_dirs` and then cleans up local Cuttlefish
processes.

By default `ika` uses:

- host tools from `/usr/lib/cuttlefish-common`
- the packaged LineageOS tree from `/usr/share/cuttlefish-common/lineageos`
- instance state under `~/ika`
- `gfxstream` GPU acceleration
- host Bluetooth, with Wi-Fi, netsim, and UWB disabled unless you override them

`gfxstream` is the preferred GPU mode for the packaged workflow. Use
`guest_swiftshader` only as a troubleshooting fallback when host GPU
acceleration is not usable.

Set `USERDATA_GB` or pass `--userdata_gb=32` to choose the size, in gigabytes,
of a newly created userdata image. Existing userdata is preserved, so apply a
new size by resetting first and then starting with the override.

### gfxstream Vulkan switch

`ika` has a launcher-level switch for the gfxstream Vulkan context:

```bash
ika start --gfxstream-vulkan=auto
ika restart --gfxstream-vulkan=off
ika restart --gfxstream-vulkan=on
```

`auto` is the default. On Apple Silicon hosts with 16 KiB pages, `auto`
requests GLES-only gfxstream (`gfxstream-gles:gfxstream-composer`) because the
Vulkan blob path has been unreliable there. On other hosts, `auto` leaves the
normal Cuttlefish gfxstream defaults alone, so x86_64 keeps Vulkan enabled.

Use `--gfxstream-vulkan=on` to re-enable gfxstream Vulkan for testing, or
`--gfxstream-vulkan=off` to force GLES-only gfxstream. The same policy can be
set with `IKA_GFXSTREAM_VULKAN=auto|off|on`; an explicit
`--gpu_context_types=...` argument takes precedence.

## Fedora RPM packages

The repo currently builds these Fedora packages:

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

For the local Fedora/Asahi workflow, `ika-base`, `ika-scrcpy`, and
`ika-lineageos` are the key packages. The RPM specs also provide and obsolete
the old `cuttlefish-*` package names for upgrades, but newly built RPM files
use the `ika-*` names.

## Notes

On ARM64 Asahi Linux, this fork keeps `gfxstream` as the forward path. The
packaged `ika` launcher disables only the gfxstream Vulkan context by default
on Apple Silicon 16 KiB-page hosts while keeping gfxstream GLES enabled;
`guest_swiftshader` remains a fallback for isolating host GPU issues.

`ika` expects your login session to be in `kvm`, `cvdnetwork`, `render`, and
`video`. The `ika-base` RPM adds the installing user to these groups
in its `%post` hook, but the active session, its PAM resource limits, and
the live `/dev/kvm` udev permissions don't pick up the new state without a
reboot — see step 5 of the Quick start for the full list of what's deferred.

Bazel is installed automatically through Bazelisk by
[`tools/buildutils/installbazel.sh`](tools/buildutils/installbazel.sh).

The networking helper uses `nftables` exclusively — both the host-side
bridge/NAT setup in `cuttlefish-host-resources.sh` and the per-user
`cvdalloc` daemon manage their rules via native `nft` commands against a
shared `ip cuttlefish` table. iptables (and `iptables-nft`) and ebtables
are no longer runtime dependencies.

## Google Compute Engine

The current GCE image tooling in this fork lives under `tools/baseimage/`.
See [tools/baseimage/README.md](tools/baseimage/README.md) for the current
workflow.

## Container images

Please read [container/README.md](container/README.md) to build and use Docker
or Podman images containing the Cuttlefish RPM packages.
