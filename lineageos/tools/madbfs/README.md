# madbfs

[madbfs](https://github.com/mrizaln/madbfs) mounts Android's storage on the
host as a FUSE filesystem over adb. `ika start` mounts the VM's `/sdcard` on
`~/ika/Android` with it, and `ika stop`, `restart` and `reset` unmount it.

Two halves are built from this folder:

- `madbfs-server` runs on Android. `Android.bp` builds it into the ROM at
  `/system_ext/bin/madbfs-server` (64-bit, the ROM's own architecture).
- `madbfs` and `madbfs-msg` run on the host. `CMakeLists.txt` builds them for
  ika-base against the distribution's Boost (1.88 or later) and libfuse 3;
  the packages install them in `/usr/lib/cuttlefish-common/bin`.

## Sources

| Folder | Project | Version |
|---|---|---|
| `upstream` | [madbfs](https://github.com/mrizaln/madbfs) | v0.12.0 (d9b99b46) |
| `third_party/asio` | [asio](https://github.com/chriskohlhoff/asio), standalone | 1.36.0 (231cb29b) |
| `third_party/boost-process` | [Boost.Process](https://github.com/boostorg/process) | boost-1.88.0 (e637f848) |
| `third_party/fmt` | [fmt](https://github.com/fmtlib/fmt) | 11.2.0 (40626af8) |
| `third_party/rapidhash` | [rapidhash](https://github.com/Nicoshev/rapidhash) | rapidhash_v3 (bc4b4baa) |
| `third_party/saf` | [saf](https://github.com/ashtum/saf) | 142c7e98 |
| `third_party/spdlog` | [spdlog](https://github.com/gabime/spdlog) | v1.17.0 (79524ddd) |

Only headers, the sources that are compiled and licences are kept: no tests,
docs or build files of their own (fmt's `Android.mk` would otherwise be picked
up by the ROM build).

- Boost.Process is compiled in because Debian does not package its library;
  its headers come before the distribution's, so every distribution builds the
  same version. `v2/posix/default_launcher.hpp` has `std::decay` where
  Boost 1.88 wrote `decay`, which only compiled while another Boost header
  included `boost/type_traits/decay.hpp` (Boost 1.92 does not).
- fmt and spdlog are used header-only: distributions ship versions older than
  madbfs needs (fmt 11).
- asio, rapidhash and saf are not packaged by the distributions.

## Changes to madbfs

- The client starts `/system_ext/bin/madbfs-server`, shipped in the ROM,
  instead of embedding servers for every ABI and pushing one to
  `/data/local/tmp`. That drops the `#embed` of the server binaries (and the
  compiler versions it needs) and zstr. `--push-server` says there is nothing
  to push.
- The server listens on loopback only, and serves only a client that knows the
  secret the client sent it on standard input when starting it (a fresh one
  for each server). Upstream listened on every address with a fixed handshake,
  so anything that reached the port, including Android apps and other hosts
  on the VM's network, could read and write the device's storage as the shell
  user. The client sends its half of the handshake first; a server that gets
  a wrong secret, or nothing within 5 seconds, drops that connection and goes
  on listening, where upstream's exited.
- The server is the only transport: no falling back to `adb shell` commands
  when it cannot start or connect (madbfs's watchdog retries it every 10
  seconds), and no `--adb-only`. A device whose ABI cannot be read is not
  mounted.
- A page read from the device gets the number of bytes read as its size. Upstream
  used the file offset after them, which wraps to 0 for the page ending at
  4 GiB: reads of larger files stopped there, as if the file ended.
- Truncating a file drops the cached pages from the new or old end on, so they
  are read again from the device. Upstream trimmed and kept them: after a
  shrink and a grow, the grown part read as the old data instead of zeros.
- A file counts as changed on the device when its size or modification time
  (to the nanosecond) differs. Upstream only counted a modification time more
  than 2 seconds newer, so a file changed within 2 seconds of the cached
  version stayed stale for good.
- `operations.hpp` no longer sets the `statx` member, which libfuse 3.17 lacks;
  madbfs set it to null anyway.
- `statfs` reports the size and free space of the device's filesystem, from
  `statvfs()` in the server (a new `Statfs` RPC procedure, after `Ping`), so
  `df` and file managers show the storage. Upstream left it unimplemented. The
  protocol change bumps the version to 0.12.0.1: the handshake compares
  versions, so a host and a ROM built from different protocols refuse each
  other instead of misreading requests.
- The version comes from `madbfs-common/cmake/version.cmake` only, not git,
  which would describe the Ika repository. `android/version.cpp` is the ROM
  build's copy of the generated file: keep the two in step.
- `madbfs-common/cmake/fetched-libs.cmake` uses `third_party/saf` instead of
  downloading it.
- `as_expected.hpp` finds Asio's handler-continuation helper under either
  name: Boost 1.91 and later call its namespace `asio_handler_cont_helpers`
  (through `BOOST_ASIO_VERSIONED_NAME`) where 1.90 and earlier call it
  `boost_asio_handler_cont_helpers`, so the client builds with Boost 1.88
  through 1.92.

## Compilers

The host build needs C++23: GCC 14 or later. Clang 19 crashes on madbfs's
coroutines, so Debian trixie builds with its default GCC 14. The server is
built with the ROM's clang.
