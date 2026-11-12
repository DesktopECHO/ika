# Contributing

Ika is a fork of `google/android-cuttlefish` with Ika's packaging, the `ika`
launcher, the console (a modified scrcpy) and the LineageOS Desktop ROM.

Send changes as GitHub pull requests and keep the scope narrow for each one.
PRs are reviewed by the lead developer and evaluated based on the PR's quality
and benefit to the project.  Coding agents are assumed to be in use to some
degree by everyone, no need for attribution:  A carpenter doesn't credit
DeWalt or Stihl when they use a power tool to cut a 2x4 in half.

For coding agents, [AGENTS.md](AGENTS.md) provides the layout of the tree,
the project's rules and how to check a change. [HACKING.md](HACKING.md) says
how to try a change on a host without a full build.

## Checks

GitHub runs `./check.sh` on every push and pull request, in a Debian 13
container (`.github/workflows/check.yml`).

```bash
# Shell syntax of Ika's scripts, and the launcher's tests
./check.sh

# The ROM's build inputs (needs a synced LineageOS source)
./src/lineageos/scripts/lib/validate_build_inputs.sh ./src/lineageos/src

# The host packages
./src/tools/buildutils/build_packages.sh
```

scrcpy's unit tests run in a debug build of the client, which needs SDL 3:

```bash
meson setup build-scrcpy scrcpy -Dbuildtype=debug -Dcompile_server=false
meson test -C build-scrcpy
```

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
| [src/scrcpy/IKA.md](src/scrcpy/IKA.md) | Ika's changes to scrcpy |

`ika help` (`src/tools/ika-lib/cli.sh`) and the comments of the `ika.ini`
template (`src/tools/ika-lib/config.sh`) describe the same settings, and
should agree with the pages.
