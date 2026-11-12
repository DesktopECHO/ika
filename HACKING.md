# Hacking on Ika

A full `./ika-build` takes hours. Most changes can be tried in minutes, on a
host that already runs an installed Ika, by rebuilding and replacing only what
changed. This page collects those shortcuts. [BUILDING.md](BUILDING.md) covers
the full build, and [AGENTS.md](AGENTS.md) the layout of the tree and the
checks.

## On a test host

- **Back up what you replace**, next to it:
  `sudo cp -p /usr/bin/ika /usr/bin/ika.pre-CHANGE`. Installing the packages
  again puts everything back.
- **Install every file the change touches.** A change to the launcher and the
  console needs both on the host: testing a new `ika` with the old console
  tests neither.
- **Over ssh, run Ika in a unit of the user's session**, so that it reaches the
  desktop, and so that its console outlives the command:

  ```bash
  systemd-run --user --unit=ika-test -p Type=oneshot -p RemainAfterExit=yes ika restart -f
  ```

  Without `RemainAfterExit`, systemd ends the console and app windows as soon
  as `ika` returns. Stop the unit afterwards with `systemctl --user stop`.
- **Leave the host's own Ika alone**: a host may be someone's desktop. Close
  your own app windows by name (`ika app close NAME`), never with `--all`.
- **GNOME settings in a throwaway D-Bus session**: set `XDG_CONFIG_HOME` and
  `XDG_DATA_HOME` on the `dbus-run-session` command line itself. dconf is
  started by the bus with the bus's environment, so settings written from
  inside the session otherwise land in the real `~/.config/dconf/user`.

## The launcher

`src/tools/ika` is the installed `/usr/bin/ika` as it is, so trying a change
is copying it:

```bash
./check.sh
scp src/tools/ika HOST:/tmp/ika-test
ssh HOST 'sudo cp -p /usr/bin/ika /usr/bin/ika.pre-CHANGE && sudo install -m 0755 /tmp/ika-test /usr/bin/ika'
```

- `ika start -f` while Android runs only reopens the console; `ika restart -f`
  restarts Android too.
- A window of `ika`'s own (Startup Options, Settings) can be opened straight
  from the copy: `systemd-run --user --unit=ika-gtk-test --collect bash
  /tmp/ika-test app --options NAME`.
- `bash -c 'source /usr/bin/ika; FUNCTION'` runs one function, but cannot open
  app windows: the launcher then thinks it is `bash`.
- The logs are in `~/ika` ([AGENTS.md](AGENTS.md#logs) lists them).

## The console (scrcpy)

The package build leaves the console's Meson build directory in
`src/base/_build_scrcpy` (Debian and Ubuntu packages; the Fedora and Arch
Linux builds use their own trees). After a first package build, a console
change builds in seconds:

```bash
ninja -C src/base/_build_scrcpy app/scrcpy
sudo cp -p /usr/lib/cuttlefish-common/bin/scrcpy /usr/lib/cuttlefish-common/bin/scrcpy.pre-CHANGE
sudo install -m 0755 src/base/_build_scrcpy/app/scrcpy /usr/lib/cuttlefish-common/bin/scrcpy
ika start -f
```

- `ika start -f --ika_scrcpy=--verbosity=debug` adds the console's debug lines
  to `~/ika/console.log`.
- `IKA_LATENCY=1` in the console's environment logs frame latency percentiles
  every 300 frames.
- scrcpy's unit tests are in [CONTRIBUTING.md](CONTRIBUTING.md#checks).

## Host tools: crosvm, gfxstream, Cuttlefish

The host tools are built by Bazel in `src/base/cvd`, with the command and
flags in `src/base/debian/rules`. After a first package build, the same
command with a single target and the same output root reuses the cache, and
takes minutes:

| Target | What it builds |
| --- | --- |
| `//build_external/crosvm:crosvm_bin_opt` | crosvm, with gfxstream and Venus |
| `//cuttlefish/host/frontend/webrtc:ika_stream` | The console's frame source |
| `//cuttlefish/package:common` | Everything the packages hold |

Install the result over its copy in `/usr/lib/cuttlefish-common/bin`, with a
backup, and run `ika restart -f`.

A change to crate annotations in crosvm's `MODULE.bazel` can break another
Bazel hub than crosvm's: give a new annotation `repositories = ["crosvm_bin"]`
unless it is meant for every hub, and run `bazel build --nobuild
//cuttlefish/package:common` with the package's flags before pushing.

## The ROM

`./ika-build` resets every patched project and applies the whole series again,
which touches every patched file, so the ROM is rebuilt almost from scratch.
For a test ROM, change only what changed in the tree the last build left in
`src/lineageos/src`:

1. Apply the new patch in its project:
   `git -C src/lineageos/src/PROJECT apply PATCH`. For a patch you changed,
   reverse the old version first (`apply -R`).
2. Rebuild without syncing or patching:
   `./src/lineageos/scripts/rebuild_cf_desktop_x86_64.sh`, or
   `rebuild_cf_desktop_arm64.sh`. It signs and bundles the ROM into
   `src/lineageos-x86_64/` or `src/lineageos-arm64/`.
3. Copy it over the installed ROM, with checksums, as the images keep the same
   sizes and times:
   `sudo rsync -a --checksum src/lineageos-x86_64/ /usr/share/cuttlefish-common/lineageos/`.
4. `ika restart -f`. When the boot ramdisk changed, `ika start` refuses to
   reuse Android's disk, and needs `ika reset`, which wipes Android.

The next `./ika-build` resets the projects and applies the series again, so
nothing is left behind.

### Compiling one file

A plain `m MODULE` does not work in this tree. To check that a patched file
compiles, reuse the last build's rules: write a ninja file at the top of the
tree that defines the pools Soong expects and includes its rules, then build
the object you want:

```bash
cd src/lineageos/src
printf 'pool highmem_pool\n  depth = 4\npool local_pool\n  depth = 8\nsubninja out/soong/build.lineage_desktop_cf_x86_64.ninja\n' > one.ninja
prebuilts/build-tools/linux-x86/bin/ninja -f one.ninja out/soong/.intermediates/PATH/TO/FILE.o
```

The targets are listed in `out/soong/build.PRODUCT.incremental.ninja` and its
numbered parts. A shared library or an APK builds the same way, in seconds to
minutes.

### Trying one library or system app

On a rooted Android (`ika root`):

- **A vendor library in an APEX** (gfxstream's `vulkan.ranchu.so`,
  `libOpenglSystemCommon.so`): in init's mount namespace (`nsenter -t 1 -m`),
  mount a tmpfs over the APEX's library folder holding copies of its files
  with yours in place, then restart the service that uses it (`stop; start`
  for SurfaceFlinger and the apps). A bind mount of a single file from
  `/data/local/tmp` fails: the Vulkan loader resolves it outside its
  namespace. Push each build under a new file name, so that a failed push
  cannot leave the old one in place.
- **SystemUI and other persistent apps**: sign the APK with the platform key
  the ROM was signed with, put it in a Magisk module
  (`/data/adb/modules/ID/system/system_ext/priv-app/SystemUI/SystemUI.apk`,
  SELinux label `u:object_r:system_file:s0`) and reboot Android. Never
  bind-mount a new APK over the running SystemUI: it crash-loops, and Android
  falls back to recovery's wipe prompt.

## Seeing the host's screen

- GNOME: `src/tools/testutils/gnome-screenshot-ssh.sh HOST shot.png`.
- KDE Plasma: run Spectacle in the user's session,
  `systemd-run --user --wait -p Type=oneshot spectacle --background --nonotify --fullscreen --output ~/shot.png`.
- Android itself: `adb exec-out screencap -p > shot.png` with Ika's adb,
  `/usr/lib/cuttlefish-common/bin/adb`.
