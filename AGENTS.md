# Working on Ika with a coding agent

This page is for coding agents (Claude Code, Codex, Cursor, Copilot, Gemini
and others) and for the people who use them. It says where Ika's own code
is, the project's rules, and how to check a change. The user documentation
starts at [README.md](README.md); [CONTRIBUTING.md](CONTRIBUTING.md) covers
pull requests.

Ika is a fork of `google/android-cuttlefish`: Cuttlefish's host tools with
Ika's packaging, the `ika` launcher, the console (a modified scrcpy) and the
LineageOS Desktop ROM, which runs in a Cuttlefish virtual machine. Most of the
tree is upstream code; change it only when the task is about it.

## Where things are

| Path | What it is |
| --- | --- |
| `src/tools/ika` | The launcher: every `ika` command, the `ika.ini` template, the GPU mode choice, app windows, the app menu, WSL. One Bash script |
| `src/tools/tests/test_ika_*.sh` | The launcher's tests. Each sources `src/tools/ika` with stubbed commands; none needs a VM |
| `src/tools/*.desktop`, `src/tools/ika-*` | Desktop entries, the login session, `ika-root`, the WSL setup |
| `ika-build` | The full build: the ROM, then the host packages |
| `ika-wsl.ps1`, `src/tools/wsl/` | The Windows installer and Ika's WSL helpers |
| `src/scrcpy/` | The console. [src/scrcpy/IKA.md](src/scrcpy/IKA.md) lists Ika's changes to scrcpy |
| `src/base/` | The `ika-base` package: `debian/`, `rpm/` and `arch/` packaging, and `cvd/`, Cuttlefish's host tools (Bazel) |
| `src/base/cvd/build_external/<project>/` | Ika's patches to the pinned crosvm, gfxstream, virglrenderer and other host dependencies |
| `src/tools/mesa/` | Ika's Mesa for the host: `release.env` (the one Mesa release) and the patches (`dzn-*` are Dozen, Vulkan on Direct3D 12, for WSL) |
| `src/lineageos/` | The ROM: products, overlays, `sepolicy/`, small apps in `packages/`, and `patches/` with `series` (the apply order) and `README.md` (what each patch does) |
| `src/frontend/` | Cuttlefish's web interface (`ika-user`) |
| `src/base/cvd/vendor_src/`, `src/e2etests/` | Vendored and upstream code: leave it alone |

## Rules

- **The ROM and the host tools ship together**, built from one commit. Don't
  add code or notes for a newer launcher with an older ROM, or the reverse.
- **Ika runs on 8 to 10 years of hardware**: x86-64 and Apple Silicon, on
  Linux and on Windows through WSL2. Fix the cause for every host it affects.
  A fix for one machine, or a setting the user has to find, is not a fix.
- **Update the documentation with the code.** When a change alters what a
  user sees or sets, update the page that covers it; the table in
  [CONTRIBUTING.md](CONTRIBUTING.md#documentation) says which. `ika help` and
  the `ika.ini` template in `src/tools/ika` must agree with the pages. The
  pages describe how Ika works now, not its history.
- **ROM patches** are applied in the order of `src/lineageos/patches/series`.
  A new patch gets a line there and a row at the same place in
  `src/lineageos/patches/README.md`, saying what it does.
- **Tests never touch a real device or the user's files.** A test sets
  `HOME`, `CVD_HOME_DIR` and `CVD_PRODUCT_OUT` to a temporary folder before it
  sources `src/tools/ika`, and stubs `adb` and every other command that would
  reach Android or the desktop.
- **Commit messages** start with the area (`ika:`, `scrcpy:`, `base:`,
  `mesa:`, `lineageos:`, `wsl:`, `Docs:`) and say in one sentence what
  changes for the user, for example `ika: stop and restart have Android write
  its data to disk first, so ...`.

## Checking a change

```bash
./check.sh
```

It checks the shell syntax of Ika's scripts and runs the launcher's tests,
with a line per test and a summary; `./check.sh session gpu` runs only the
tests whose names contain one of the words. It needs Linux (on a Mac, a Linux
VM or container), Bash 4 or newer, Python 3, git and pigz, but no KVM or GPU,
and it starts no Android. GitHub runs it on every push and pull request
(`.github/workflows/check.yml`); a change that fails it is not done.

The other checks are in [CONTRIBUTING.md](CONTRIBUTING.md#checks): scrcpy's
unit tests, the ROM's build inputs and the host packages.

Much of Ika can only be tried on the hardware it is for. Say in your summary
what you could not try.

| A change to | Is tried on |
| --- | --- |
| The launcher's logic | `./check.sh`; new behaviour gets a test in `src/tools/tests/` |
| The console | A Linux desktop with SDL 3: build scrcpy (see CONTRIBUTING.md) and run it against a running Ika |
| GPU modes, gfxstream, Venus, crosvm | A Linux host with KVM and that GPU; AMD, Intel, NVIDIA and Apple each behave differently |
| Apple Silicon | Fedora Asahi Remix with its 16 KB-page kernel |
| WSL2 and Dozen | Windows 11 with nested virtualization |
| The ROM | A synced LineageOS source (300 GB free) and hours of building; [BUILDING.md](BUILDING.md#rebuilding) gives the narrowest rebuild |

Don't start `./ika-build` or a ROM build unless asked: they take hours and
hundreds of gigabytes. [HACKING.md](HACKING.md) says how to try a change on a
host in minutes instead: the launcher, the console, one host tool, a test ROM,
one guest library.

## Logs

Ika keeps its logs in `~/ika`:

| Log | What it records |
| --- | --- |
| `ikastart.log` | Each `ika start`: the host checks, the GPU mode chosen, errors |
| `console.log` | The console's last launch |
| `session.log` | The Android login session (`ika session`) |
| `app-menu.log` | The app menu watcher |
| `madbfs.log` | The mount of Android's files |
| `apps/PACKAGE/window.log` | An app window |
| `cuttlefish/instances/cvd-1/logs/` | Cuttlefish's `launcher.log`, `kernel.log` and `logcat` |

[CONFIGURATION.md](CONFIGURATION.md#files-and-folders) lists every file Ika
keeps.
