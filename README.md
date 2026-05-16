<img width="2480" height="2064" alt="Screenshot From 2026-04-01 22-30-37" src="https://github.com/user-attachments/assets/24e59e40-5dfd-45c2-9d69-ed64f1155c6c" />

# イカ (Ika, /ee-kah/)

This project originally started as an effort to get [Cuttlefish](https://source.android.com/setup/create/cuttlefish) (Google's Android Virtual Device built on Debian tooling) running on [Fedora Asahi Remix](https://asahilinux.org/), so the project was given the name **ika (イカ)**, the Japanese word for cuttlefish (or squid).

The repository is a fork of [google/android-cuttlefish](https://github.com/google/android-cuttlefish), adapted for RPM-based distributions like Fedora Asahi Remix.  [Cuttlefish](https://source.android.com/setup/create/cuttlefish) is a configurable Android Virtual Device (AVD) that runs on Linux x86_64 and aarch64 hosts as well as Google Compute Engine.

## Quick start

The build is two phases — ROM then RPMs — and the RPM phase needs the ROM
phase's output. Run them in order:

```bash
# 1. Clone
git clone https://github.com/DesktopECHO/ika.git
cd ika

# 2. Build the LineageOS Desktop ROM for both arches.
#    First run: ~1-2h (downloads LineageOS 23.2 source, applies the overlay
#    and source patches in lineageos/, builds the ARM64 and x86-64 Cuttlefish
#    targets). Incremental runs are much faster.
#    Produces ./lineageos-arm64/ and ./lineageos-x86_64/ at the repo root.
./lineageos/scripts/build_lineageos_desktop.sh

# 3. Build the host Cuttlefish + LineageOS RPMs (~30-60 min first run).
#    cuttlefish-lineageos bundles ./lineageos-<host_arch>/ from step 2 into
#    /usr/share/cuttlefish-common/lineageos. If step 2 was skipped or only
#    built the other arch, cuttlefish-lineageos is silently skipped here.
./tools/buildutils/build_packages.sh

# 4. Install the host packages and the bundled LineageOS tree.
#    cuttlefish-base's %post detects your logged-in user and adds it to the
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

### Rebuilding one phase

Once you have an initial build, you can rebuild either phase independently:

- **ROM only** — re-run `./lineageos/scripts/build_lineageos_desktop.sh` (or
  pass `arm64` / `x86_64` to limit it to one target). Use this after editing
  patches or overlays under `lineageos/`. Pass `RESET_PATCHED_PROJECTS=1` if
  you want patched source projects in the workspace reset before re-applying.
- **RPMs only** — re-run `./tools/buildutils/build_packages.sh`. Use this
  after editing host sources under `base/` or `frontend/`, after editing the
  RPM specs under `base/rpm/`, or whenever you've finished a fresh ROM
  rebuild and want to repackage the `cuttlefish-lineageos` RPM with the new
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
ika restart --gpu_mode=guest_swiftshader --cpus=8 --memory_mb=8192

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
- host Bluetooth, with Wi-Fi, netsim, and UWB disabled unless you override them

For this Fedora Asahi workflow, `guest_swiftshader` is the documented GPU mode
to pass when launching the VM.

## Fedora RPM packages

The repo currently builds these Fedora packages:

* `cuttlefish-base` - Core host binaries, networking helpers, and system
  services
* `cuttlefish-user` - Browser-facing operator service
* `cuttlefish-orchestration` - Host Orchestrator service and nginx config
* `cuttlefish-integration` - Cloud integration utilities
* `cuttlefish-defaults` - Optional defaults override service and config
* `cuttlefish-metrics` - Metrics transmitter binary
* `cuttlefish-lineageos` - Bundled `lineageos/` tree installed under
  `/usr/share/cuttlefish-common/lineageos`
* `cuttlefish-common` - Deprecated compatibility metapackage

For the local Fedora/Asahi workflow, `cuttlefish-base`, `cuttlefish-user`, and
`cuttlefish-lineageos` are the key packages.

## Notes

On ARM64 Asahi Linux, `guest_swiftshader` is the safe documented GPU mode for
the packaged workflow in this fork.

`ika` expects your login session to be in `kvm`, `cvdnetwork`, `render`, and
`video`. The `cuttlefish-base` RPM adds the installing user to these groups
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
