# Contributing

Ika is a fork of `google/android-cuttlefish` with Ika's packaging, the `ika`
launcher, the console (a modified scrcpy) and the LineageOS Desktop ROM.

Send changes as GitHub pull requests. Keep each one narrow, and include the
commands you used to check it. Changes meant for Cuttlefish itself belong
upstream, following Google's contribution process and CLA in the upstream
repository.

## Checks

```bash
# Shell syntax of the build and launch scripts
bash -n ika-build tools/ika

# The launcher's tests
for t in tools/tests/test_ika_*.sh; do LANG=C.UTF-8 bash "$t" || break; done

# The ROM's build inputs (needs a synced LineageOS source)
./lineageos/scripts/lib/validate_build_inputs.sh ./lineageos/src

# The host packages
./tools/buildutils/build_packages.sh
```

scrcpy's unit tests run in a debug build of the client, which needs SDL 3:

```bash
meson setup build-scrcpy scrcpy -Dbuildtype=debug -Dcompile_server=false
meson test -C build-scrcpy
```

Some checks need a synced LineageOS source or built ROMs; say which ones you
could not run.

## Documentation

The documentation describes how Ika works now. When a change alters what a
user sees or sets, update the page that covers it:

| Page | Covers |
| --- | --- |
| [README.md](README.md) | What Ika is, requirements, installing |
| [USAGE.md](USAGE.md) | Using Ika: the console, app windows, input, TV mode, everyday commands |
| [CONFIGURATION.md](CONFIGURATION.md) | Commands, options, `ika.ini`, environment variables, files |
| [GRAPHICS.md](GRAPHICS.md) | GPU modes and graphics settings |
| [BUILDING.md](BUILDING.md) | Building from source |
| [scrcpy/IKA.md](scrcpy/IKA.md) | Ika's changes to scrcpy |
| [CHANGELOG.md](CHANGELOG.md) | What changed, per release |

`ika help` and the comments of the `ika.ini` template in `tools/ika` describe
the same settings, and should agree with the pages.
