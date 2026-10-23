[README](README.md) | [Using Ika](USAGE.md) | [Configuration](CONFIGURATION.md) | [Graphics](GRAPHICS.md) | **Building** | [Downloads](DOWNLOADS.md) | [Changelog](CHANGELOG.md)

# Building Ika from source

`./ika-build` builds the LineageOS ROM and Ika's host packages for your
distribution, then prints the command that installs them. Prebuilt packages
are on the [Downloads](DOWNLOADS.md) page; build from source to change Ika,
to choose the ROM's Google integration, or on Arch Linux ARM, which has no
prebuilt packages.

## Requirements

- **CPU:** x86-64 or ARM64 (Apple Silicon included).
- **Distribution:** Fedora 44 (Fedora Asahi Remix on Apple Silicon), Debian 13
  (trixie), Ubuntu 26.04 or Arch Linux (Arch Linux ARM included).
- **Memory:** 32 GB recommended; 16 GB works, more slowly. The build adds
  temporary zram so that memory and zram reach 44 GB, or 2 GB per CPU thread
  plus 4 GB if that is more. The zram stays until the next reboot; the build's
  exit log prints the commands that remove it sooner.
- **Disk:** 300 GB free.
- **Time:** 3 to 6 hours or more for the first build, depending on the host
  and the network. Later builds reuse the source and the compiler cache.
- **Network:** for downloading the source and the toolchains, which all
  happens before the first compile.
- **Account:** a normal user with `sudo`; `ika-build` refuses to run as root
  and asks for the password once.

## Build and install

```bash
# 1. Download the source and enter it:
curl -L https://github.com/DesktopECHO/ika/archive/refs/heads/main.zip -o ika-main.zip
unzip ika-main.zip && rm ika-main.zip && cd ika-main

# 2. Build:
./ika-build

# 3. Install: run the command ika-build prints at the end, for example
sudo apt install ./deb/ika-base_261023-1_amd64.deb ./deb/ika-lineageos_261023-1_amd64.deb

# 4. On a first install, reboot:
sudo reboot

# 5. Start Ika:
ika start
```

`ika-build` installs the build dependencies, sets up the signing keys,
downloads the LineageOS 23.2 source, applies Ika's overlays and patches,
builds the ROM for the host's architecture and builds the host packages. A
git checkout works as well as the zip.

The install command matches what is installed: `install`, `upgrade`,
`reinstall` or `downgrade` with `dnf`, `apt install` with `--only-upgrade`,
`--reinstall` or `--allow-downgrades`, or `pacman -U`. Run it from the
source folder.

A first install needs a reboot, not only a new login: the packages add you to
the `kvm`, `cvdnetwork`, `render` and `video` groups, raise the `cvdnetwork`
group's open-file and realtime-priority limits, load the `vhost_net`,
`vhost_vsock` and `vhci-hcd` kernel modules at boot, and give the vhost
devices to the `cvdnetwork` group. `ika start` checks the session's groups and
says how to fix them if one is missing. An update needs no reboot.

### What ika-build asks

1. **Google integration**, when it runs without arguments: MicroG,
   MindTheGapps (Google Play), or de-Googled without an app store. With any
   argument it does not ask: `--microg` or `--mtg` choose, and neither builds
   the de-Googled ROM.
2. **The signing identity**, the first time: country, state, city,
   organization and so on, with defaults. It is saved in
   `~/.config/ika/signing.conf`, and the keys in `~/.android-certs`.
3. **The `sudo` password**, once.
4. **On Ubuntu**, whether to add the Kisak Mesa PPA (see
   [Mesa and Vulkan](#mesa-and-vulkan)).

### Options

```text
./ika-build [all|arm64|x86_64]... [--microg|--mtg]
```

| Argument | Effect |
| --- | --- |
| (none) | The ROM for the host's architecture, asking for the Google integration |
| `x86_64`, `arm64` | That ROM. An x86-64 host builds either; an ARM64 host builds `arm64` only |
| `all` | Both ROMs on an x86-64 host; `arm64` on an ARM64 host |
| `--microg` | microG |
| `--mtg` | MindTheGapps, with Google Play |

Only the ROM of the host's own architecture is packaged as `ika-lineageos`. A
ROM for the other architecture stays in `lineageos-arm64/` or
`lineageos-x86_64/`.

```bash
./ika-build --mtg            # this host's ROM, with Google Play
./ika-build all --microg     # both ROMs, with microG (on x86-64)
```

### Unattended builds

A build without a terminal needs a signing identity in
`~/.config/ika/signing.conf` (or existing keys), a target or `--microg` /
`--mtg` so that nothing is asked, `UBUNTU_ENABLE_KISAK_MESA=true` on Ubuntu,
and passwordless `sudo`, or `SKIP_BUILD_DEPENDENCIES=true` when the
dependencies are already installed.

## Mesa and Vulkan

Ika needs Mesa 26.1 or newer; its packages require it. Fedora 44 and Arch
Linux have it. On Debian and Ubuntu, `ika-build` gets it:

- **Debian 13 (trixie):** it enables `trixie-backports` and installs the Mesa
  packages from it, following the
  [Debian Backports instructions](https://backports.debian.org/Instructions/).
  It also builds the Vulkan loader 1.4.341 from Debian's packaging source
  when the installed one is older, as the build needs those headers. Other
  Debian releases without Mesa 26.1 are not supported.
- **Ubuntu:** it offers to add the
  [Kisak Mesa PPA](https://launchpad.net/~kisak/+archive/ubuntu/kisak-mesa)
  and installs Mesa from it. `UBUNTU_ENABLE_KISAK_MESA=true` adds it without
  asking, `false` never does. On ARM64 the PPA must carry Mesa 26.1 for
  `arm64`.

## Rebuilding

Use the narrowest step that covers your change, then install the packages
with your package manager:

- **Everything:** run `./ika-build` again, with the same `--microg` or
  `--mtg`.
- **The ROM only**, after changing patches or overlays under `lineageos/`:
  `./lineageos/scripts/build_lineageos_desktop.sh [all|arm64|x86_64]
  [--microg|--mtg]`, then the host packages below to package it.
  `./lineageos/scripts/rebuild_cf_desktop_arm64.sh` and
  `rebuild_cf_desktop_x86_64.sh` rebuild without syncing or patching the
  source. The Google integration is not remembered: pass the same flag every
  time, or the ROM is built de-Googled.
- **The host packages only**, after changing `base/`, `frontend/` or the
  packaging, or to package a new ROM: `./tools/buildutils/build_packages.sh`.

These scripts expect the build dependencies to be installed already, as
`./ika-build` leaves them.

Before syncing, the ROM build resets the source projects it patches, so that
the patches apply to clean projects; a project with commits of its own is
left alone. `RESET_PATCHED_PROJECTS=0` turns that off, `=1` also does it in a
custom `WORKSPACE`, and `RESET_PATCHED_PROJECTS_FORCE=1` resets projects with
commits too.

See [lineageos/README.md](lineageos/README.md) for the ROM's products, source
layout and build options, and `lineageos/docs/build-cli-help.txt` for every
variable the ROM build reads. The ones used most:

| Variable | Default | Meaning |
| --- | --- | --- |
| `WORKSPACE` | `lineageos/src` | The LineageOS source checkout |
| `IKA_WORK_ROOT` | `ika-work/` | Build state: Bazel's output, the compiler cache, temporary files |
| `JOBS` | CPU threads − 2 | Parallel build jobs |
| `BUILD_VARIANT` | `userdebug` | `user`, `userdebug` or `eng` |
| `CCACHE_ENABLED`, `CCACHE_MAX_SIZE` | on, `50G` | The compiler cache, in `ika-work/.ccache` |
| `NOFILE_LIMIT` | `4194304` | The open-file limit the build raises itself to; empty leaves it |
| `SKIP_BUILD_DEPENDENCIES` | `false` | `true` skips installing the build dependencies |
| `ANDROID_CERTS_DIR` | `~/.android-certs` | The signing keys |

## Output

| What | Where |
| --- | --- |
| ROMs | `lineageos-x86_64/`, `lineageos-arm64/` |
| Fedora packages | `rpmbuild/RPMS/x86_64/` or `rpmbuild/RPMS/aarch64/` |
| Debian and Ubuntu packages | `deb/` |
| Arch Linux packages | `archbuild/packages/` |
| Build times | `buildtimes.log`: a line per ROM build, with its download and build times |

The packages other than `ika-base` and `ika-lineageos` go into an `extras/`
folder next to them.

## Host packages

Most hosts need only `ika-base` and `ika-lineageos`.

| Package | Contents |
| --- | --- |
| `ika-base` | The `ika` launcher and its desktop entries, Cuttlefish's host tools (`cvd`, `crosvm`, `cvdalloc`, ...) in `/usr/lib/cuttlefish-common`, the console (scrcpy), madbfs for Android's files, `ika-root`, and the host setup: groups, udev rules, limits, kernel modules, the `cuttlefish-host-resources` service, which loads and tunes the `udmabuf` module at boot |
| `ika-lineageos` | The ROM for the host's architecture, in `/usr/share/cuttlefish-common/lineageos` |
| `ika-user` | Cuttlefish's operator: the WebRTC signaling server and its web interface |
| `ika-orchestration` | Cuttlefish's Host Orchestrator service, with its nginx configuration |
| `ika-integration` | Utilities for Cuttlefish on Google Compute Engine, not for desktops |
| `ika-defaults` | A service that overrides Cuttlefish's defaults |
| `ika-metrics` | Cuttlefish's metrics transmitter, which sends metrics to Google |
| `ika-common` | A metapackage for `ika-base`, `ika-user` and `ika-defaults` |

## Building on an ARM64 host

An ARM64 host, such as an Apple Silicon Mac on Fedora Asahi Remix, builds the
ARM64 ROM natively. It cannot build the x86-64 ROM; an x86-64 host builds
both.

| ROM | On an x86-64 host | On an ARM64 host |
| --- | --- | --- |
| `x86_64` | Yes | No |
| `arm64` | Yes (cross-build) | Yes |

The ARM64 ROM serves hosts with 4 KB and 16 KB memory pages alike: its bundle
has a 4 KB kernel and boot image, and 16 KB ones (`boot_16k.img`,
`kernel_16k`, `ramdisk_16k.img`), which `ika` uses on 16 KB hosts such as
Apple Silicon.

### What the ARM64 build does

Android's build system expects a `linux-x86` build host, and LineageOS 23.2
has no ARM64 host toolchain. The ARM64 build works with two parts that depend
on each other:

- **Patches** in [lineageos/patches/](lineageos/patches/) make `linux-arm64`
  a host architecture, in the [series](lineageos/patches/series) order:

  | Patch | Project | Purpose |
  | --- | --- | --- |
  | `build-soong-arm64-host.patch` | `build/soong` | `linux_arm64` as a host architecture: install paths, Clang and bindgen, Rust host toolchain and proc-macros, JDK paths |
  | `build-make-arm64-host.patch` | `build/make` | The same for Make: `HOST_ARCH := arm64`, `USE_HOST_MUSL := true`, LLVM tool and runtime paths |
  | `prebuilts-arm64-host.patch` | source root | ARM64 host variants of the build-tools, JDK 21 and Rust prebuilts |
  | `frameworks-libs-binary-translation-arm64-host.patch` | `frameworks/libs/binary_translation` | Builds the translator on non-x86 hosts |
  | `external-stg-arm64-host-page-size.patch` | `external/stg` | Removes jemalloc from the ABI tools so they run on 16 KB-page hosts |
  | `external-rust-android-crates-io-arm64-host-cross.patch` | `external/rust/android-crates-io` | ARM64 Rust host modules, bindgen crates included |
  | `external-cronet-arm64-host-cross.patch` | `external/cronet` | Cronet host tools; x86 flags for x86 only |
  | `external-sdv-vsomeip-arm64-host-cross.patch` | `external/sdv/vsomeip` | SSE flags for x86-64 only |
  | `external-musl-lfs64-compat.patch` | `external/musl` | musl header modules and LFS64 aliases for the Rust musl host library |
  | `vendor-lineage-arm64-host-tools.patch` | `vendor/lineage` | Native ARM64 `lz4`, `pahole` and `mogrify` |
  | `external-trusty-lk-arm64-host.patch`, `trusty-kernel-arm64-host.patch`, `trusty-user-base-arm64-host-boringssl.patch` | Trusty | Trusty's host builds on ARM64 |
  | `system-sepolicy-checkfc-arm64-getopt.patch` | `system/sepolicy` | `checkfc`'s `getopt()` end-of-options value on ARM64 |

- **The build scripts** download the ARM64 host toolchains the patches
  expect: Go, CMake and the Clang tools from AOSP, Clang
  (`clang-r584948b`), Rust from `static.rust-lang.org`, and JDK 21 and 8 from
  Adoptium, cached in `ika-work/arm64-prebuilts`. They set the variables the
  patches read, and stop when a toolchain is missing or an x86 one stands in
  for an ARM64 one (`configure_arm64_host_build` in
  [build_exec.sh](lineageos/scripts/lib/build_exec.sh)).

Every build, on either architecture, uses Clang 22 (`clang-r584948b`, from
`mirror-goog-llvm-r596125-release`): [clang22.patch](lineageos/patches/clang22.patch)
makes the source compile with it. `CLANG_PREBUILT_GIT_REF` and
`CLANG_PREBUILT_VERSION`, or their `ARM64_` and `X86_` forms, choose another
Clang, and that patch may then need updating. On ARM64, an overlay of
symlinks at `prebuilts/clang/host/linux-x86/` points the paths Soong still
expects there at the ARM64 Clang.

C and C++ host tools are built against musl, while the Rust host tools use
glibc, because the Rust compiler is a glibc build: the musl ARM64 Rust
toolchain is mapped to `aarch64-unknown-linux-gnu`. The Soong and Make
patches must agree on this for Rust's proc-macros to load.

On 16 KB-page hosts the build uses the system's `ninja`, so the `ninja`
package must be installed. Temporary files go to `ika-work/tmp`, as Fedora
Asahi Remix's `/tmp` is small, and on Fedora the source and the work folder
get the SELinux type `src_t`.

### ARM64 troubleshooting

| Message or symptom | Fix |
| --- | --- |
| `missing ARM64 build tools prebuilt` or `...ninja` | The sync did not bring `prebuilts/build-tools/linux-arm64`: check the sync's result and access to `android.googlesource.com` |
| A JDK download fails | The JDKs come from Adoptium; check access to it and run the build again |
| A Clang 22 error in a project | `clang22.patch` needs a `-Wno-...` or a fix for that project |
| A Rust proc-macro fails to load | The musl and glibc mapping drifted: check that `rust/config/arm_linux_host.go` maps the Rust triple to `aarch64-unknown-linux-gnu` |
| `refusing to use non-ARM64 Clang payload on ARM64 host` | An x86 Clang is in `prebuilts/clang/host/linux-x86`: remove it so the build can recreate the overlay |
| Very large Ninja dependency files, slow Trusty dependency scans | Check that `build-soong-arm64-host.patch` applied fully: it skips `.git` and `prebuilts/` when collecting Trusty's dependencies |

References: [Enabling aarch64 as an Android build host](https://jsteward.moe/aarch64-build-host.html),
[a C/C++ toolchain for aarch64](https://jsteward.moe/toolchain-for-android.html),
[AOSP's ARM64 Clang prebuilts](https://android.googlesource.com/platform/prebuilts/clang/host/linux-arm64/),
[Asahi Linux: software with 16K page issues](https://asahilinux.org/docs/sw/broken-software/),
[Android's 16 KB pages](https://source.android.com/docs/core/architecture/16kb-page-size/16kb).
Google does not support ARM64 build hosts.
