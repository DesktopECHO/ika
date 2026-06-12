# Building the LineageOS Desktop ROM on an ARM64 Host

This document explains how the **ika** build is made to run on an **ARM64
(aarch64) Linux host** — the Apple-Silicon / Fedora Asahi Remix target the
project was created for. It covers the build-matrix constraints, the two layers
that make ARM64-host builds possible (source patches + runtime orchestration),
the Clang prebuilt story, and a troubleshooting reference.

> Scope: building **on** an ARM64 host. The same engine also cross-builds the
> ARM64 *ROM* from x86_64; the hard part documented here is running the Android
> build system itself with a `linux-arm64` toolchain.

---

## 1. The core problem

AOSP and LineageOS assume the build **host** is `linux-x86`. Across Soong
(`build/soong`), Make (`build/make`), the checked-in prebuilts, and many
external projects, the host toolchain path is hardcoded to `linux-x86`, and
several host targets are only enabled for `x86_64`. The `lineage-23.2` branch
does not even ship a `prebuilts/clang/host/linux-arm64` payload.

Making the build run on an ARM64 host therefore requires **two coordinated
layers**:

1. **Source patches** that teach the build system `linux-arm64` is a real host
   arch and resolve toolchains from the *active* host tag instead of `linux-x86`.
2. **Runtime orchestration** in the build scripts that *provisions* the ARM64
   host prebuilts (Clang, Go, Rust, JDK, CMake, build-tools) and *exports* the
   env vars those patches read — failing fast if anything is missing.

Neither layer works without the other: the source patches provide ARM64 host
awareness, and the scripts provide the ARM64 prebuilts and environment those
patches expect.

---

## 2. Build-matrix constraints

| ROM target | x86_64 host | ARM64 host |
|---|---|---|
| `x86_64` ROM | ✅ | ❌ (refused) |
| `arm64` ROM | ✅ (cross) | ✅ (native) |

- x86_64 ROMs can only be built on an x86_64 host — enforced in
  [build_lineageos_desktop.sh](lineageos/scripts/build_lineageos_desktop.sh)
  and the ELF arch checks in
  [signing_common.sh](lineageos/scripts/signing_common.sh).
- ARM64 host builds run **natively** with real `linux-arm64` host prebuilts.
  The build scripts refuse symlinked `linux-x86` substitutions and log the host
  page size, but they no longer wrap the Android build in a guest VM.

---

## 3. Prerequisites for an ARM64 host

The build engine provisions most prebuilts itself, but the host must supply:

- Network **throughout the build** — ARM64 host prebuilts (Clang, Go, Rust, JDK,
  CMake, clang-tools) are fetched from `android.googlesource.com` at setup, and
  partial-clone fetches blobs on demand during compile.
- A high open-file limit — `raise_host_open_file_limit` bumps it
  (`NOFILE_LIMIT`, default `4194304`; set empty to skip).
- JDK — if no `javac` is on PATH and no ARM64 JDK prebuilt can be fetched, the
  build dies asking for `ARM64_JDK21_PREBUILT_URL` / `ARM64_ANDROID_JAVA_HOME`.

---

## 4. The patch layer

All ARM64-host patches live under [lineageos/patches/](lineageos/patches/),
applied in [series](lineageos/patches/series) order by
[apply_source_patches.sh](lineageos/scripts/apply_source_patches.sh) (self-checked:
every line resolves to a file, every file is referenced — no orphans).

| Patch | Project | What it unlocks |
|---|---|---|
| [`build-soong-arm64-host.patch`](lineageos/patches/build-soong-arm64-host.patch) | `build/soong` | Registers `linux_arm64` as a host arch; host install paths, Clang/bindgen selection, Rust host-cross + proc-macros, JDK path handling |
| [`build-make-arm64-host.patch`](lineageos/patches/build-make-arm64-host.patch) | `build/make` | Make/kati mirror: host prebuilt tag for LLVM tools, compiler-rt/libc++ paths, `HOST_ARCH := arm64`, `USE_HOST_MUSL := true` |
| [`prebuilts-build-tools-arm64-host.patch`](lineageos/patches/prebuilts-build-tools-arm64-host.patch) | `prebuilts/build-tools` | Enables `arm64` / `linux_musl_arm64` variants of checked-in build tools |
| [`prebuilts-jdk21-arm64-host.patch`](lineageos/patches/prebuilts-jdk21-arm64-host.patch) | `prebuilts/jdk/jdk21` | Enables JDK 21 prebuilt build-tool modules on ARM64 |
| [`prebuilts-rust-x86-musl-stdlib.patch`](lineageos/patches/prebuilts-rust-x86-musl-stdlib.patch) | `prebuilts/rust` | Adds ARM64 musl host target props for the Rust stdlib prebuilt |
| [`frameworks-libs-binary-translation-arm64-host.patch`](lineageos/patches/frameworks-libs-binary-translation-arm64-host.patch) | `frameworks/libs/binary_translation` | `berberis_all_hosts_defaults_64` so the translator builds on non-x86 hosts |
| [`clang22.patch`](lineageos/patches/clang22.patch) | source root | Cross-project Clang 22 diagnostic fixes (see §6) |
| [`external-rust-android-crates-io-arm64-host-cross.patch`](lineageos/patches/external-rust-android-crates-io-arm64-host-cross.patch) | `external/rust/android-crates-io` | Rust host-cross modules (incl. bindgen crates) for ARM64 |
| [`external-cronet-arm64-host-cross.patch`](lineageos/patches/external-cronet-arm64-host-cross.patch) | `external/cronet` | Cronet host tools/Rust host-cross; scopes x86 flags to x86 |
| [`external-sdv-vsomeip-arm64-host-cross.patch`](lineageos/patches/external-sdv-vsomeip-arm64-host-cross.patch) | `external/sdv/vsomeip` | Restricts SSE flags to x86_64 so the graph generates on ARM64 |
| [`external-musl-lfs64-compat.patch`](lineageos/patches/external-musl-lfs64-compat.patch) | `external/musl` | musl LFS64 compatibility for host builds |
| [`vendor-lineage-arm64-host-kernel-tools.patch`](lineageos/patches/vendor-lineage-arm64-host-kernel-tools.patch) | `vendor/lineage` | Native ARM64 `lz4` / `pahole` for kernel builds |
| [`external-trusty-lk-arm64-host-rust-link.patch`](lineageos/patches/external-trusty-lk-arm64-host-rust-link.patch) | `external/trusty/lk` | Trusty ARM64 host Rust proc-macro linker args (GNU glibc, not musl sysroot) |
| [`external-trusty-lk-host-target-config.patch`](lineageos/patches/external-trusty-lk-host-target-config.patch) | `external/trusty/lk` | Records Trusty Clang host target/link flags in `toolchain.config` |
| [`trusty-kernel-arm64-host-dtc.patch`](lineageos/patches/trusty-kernel-arm64-host-dtc.patch) | `trusty/kernel` | Env-provided host `dtc` instead of x86 prebuilt |
| [`trusty-kernel-arm64-host-clang-target.patch`](lineageos/patches/trusty-kernel-arm64-host-clang-target.patch) | `trusty/kernel` | Threads Clang host target/runtime flags into Trusty host compiles |
| [`trusty-user-base-arm64-host-boringssl.patch`](lineageos/patches/trusty-user-base-arm64-host-boringssl.patch) | `trusty/user/base` | Host BoringSSL archive builds on ARM64 Linux |

### 4.1 `build-soong-arm64-host.patch` deep dive (21 files)

Four themes:

1. **Make `linux_arm64` a first-class host target.**
   - `android/arch.go` — dedup guard so the native build and the arm64 host
     target don't produce duplicate host `Target` entries (Soong errors on dups).
   - `android/paths.go` — host install paths emit `arm64` (not hardcoded `x86`)
     when `BuildArch == Arm64`, so host tools land under `host/linux-arm64/`.
2. **Resolve toolchains from the host tag, not hardcoded x86.**
   - `cc/config/global.go` — `ClangAsanLibDir` → `${HostPrebuiltTag}`.
   - `java/config/{config,makevars}.go` — `ANDROID_JAVA8_HOME` driven by a
     `Java8Home` env var set by `soong_ui`, not a hardcoded jdk8 path.
3. **Rust host toolchain for ARM64** (the bulk — ~15 hunks). The crux is
   `rust/config/arm_linux_host.go`: Soong routes Linux host modules through
   **musl** toolchain variants, but the ARM64 `rustc` actually run is a
   **GNU/glibc** toolchain. So the musl-arm64 Rust toolchain is remapped —
   triple `aarch64-unknown-linux-musl` → `aarch64-unknown-linux-gnu`, musl link
   flags → glibc link flags, `Glibc()` → `true` — keeping the stdlib ABI aligned
   with `rustc` so **proc-macros load** (a wrong-ABI proc-macro can't be
   dlopened by the compiler).
4. **Build-infra robustness on ARM64 hosts.**
   - `cmd/dir_to_depfile/dir_to_depfile.go` — skip `.git` and `prebuilts/` when
     collecting Trusty `dir_srcs` deps, so nsjail-bind-mounted toolchain trees
     don't blow up Ninja's deps records. *(This was the most recent ARM64 change,
     commit `d91d29f`.)*

### 4.2 `build-make-arm64-host.patch` — the Make/kati mirror

The legacy Make layer has the same `host == linux-x86` hardcodes:

- `core/envsetup.mk` — recognize `aarch64`/`arm64` UNAME → `HOST_ARCH := arm64`,
  `HOST_IS_64_BIT`, `HOST_PREBUILT_ARCH := arm64`, **`USE_HOST_MUSL := true`**.
  (The Make analog of `arch.go`'s host registration.)
- `core/clang/HOST_arm64.mk` *(new)* — `HOST_LIBPROFILE_RT` /
  `HOST_LIBCRT_BUILTINS` → `aarch64-unknown-linux-musl` clang_rt libs.
- `core/binary.mk`, `core/clang/config.mk`, `core/install_jni_libs_internal.mk`
  — `$(BUILD_OS)-x86` → `$(HOST_PREBUILT_TAG)` for libc++, syntax tools,
  llvm-readobj, the runtime lib path, and embedded-JNI libc++.
- `envsetup.sh` `get_host_prebuilt_prefix` — `linux-x86` → `linux-arm64` on
  aarch64.

### 4.3 The musl / glibc interplay (read this if Rust host modules fail)

The two patches deliberately disagree on ABI, and they have to:

- **C/C++ host modules → musl.** `build-make` sets `USE_HOST_MUSL := true` and
  `HOST_arm64.mk` points at `aarch64-unknown-linux-musl` clang_rt.
- **Rust host modules → glibc.** `build-soong`'s `arm_linux_host.go` remaps the
  "musl arm64" Rust toolchain's triple back to `aarch64-unknown-linux-gnu`
  because the `rustc` prebuilt is GNU.

So on an ARM64 host, Rust host modules are a glibc `rustc` wearing the
"musl variant" label. If the two patches drift apart, proc-macros fail to load —
which is why they must be updated together.

---

## 5. Runtime orchestration

`configure_arm64_host_build` in
[build_exec.sh](lineageos/scripts/lib/build_exec.sh) is the other half
of the contract. It runs only on ARM64 hosts and provisions exactly what the
patches assume, dying fast if anything is missing:

```
ensure_arm64_go_prebuilt                       # prebuilts/go/linux-arm64
prebuilts/build-tools/linux-arm64 + ninja      # else die
ensure_arm64_rust_prebuilt / tool_bridges      # GNU rustc host toolchain
ensure_linux_arm64_clang_prebuilt / _ready     # fetch + verify ARM64 Clang (§6)
ensure_linux_arm64_clang_trusty_dirgroup       # Trusty dirgroup wiring
ensure_linux_x86_clang_arm64_soong_compat      # x86-path overlay (§6.2)
ensure_arm64_clang_tools_prebuilt
ensure_arm64_native_cmake_prebuilt
ensure_arm64_native_jdk21_prebuilt / jdk8      # feeds ANDROID_JAVA*_HOME
ensure_no_arm64_x86_prebuilt_substitutions     # guard against x86 shadowing
raise_host_open_file_limit
```

### The patch ⇄ runtime contract

| Patch expects (reads) | Script provides (sets) |
|---|---|
| `ANDROID_JAVA8_HOME = ${Java8Home}` | JDK 8/21 prebuilts + `OVERRIDE_ANDROID_JAVA_HOME` |
| `linux-arm64` host Clang via `HostPrebuiltTag` | `ensure_linux_arm64_clang_prebuilt` / `_ready` |
| `prebuilts/build-tools/linux-arm64` enabled | hard `die` if `…/bin/ninja` missing |
| GNU Rust host toolchain | `ensure_arm64_rust_prebuilt` + `_tool_bridges` |
| arm64 install paths not shadowed by x86 | `ensure_no_arm64_x86_prebuilt_substitutions` |

Relevant env knobs (defaults in the header of
[build_lineageos_desktop.sh](lineageos/scripts/build_lineageos_desktop.sh)):
`NOFILE_LIMIT`, `ARM64_SOONG_GOMEMLIMIT`, `ARM64_SOONG_GOMAXPROCS`,
`ARM64_JDK21_PREBUILT_URL`, `ARM64_ANDROID_JAVA_HOME`.

---

## 6. The ARM64 Clang story ("clang missing, had to update")

### 6.1 The branch ships no ARM64 host Clang

`lineage-23.2` ships `prebuilts/clang/host/linux-x86` but **not**
`prebuilts/clang/host/linux-arm64`. On an ARM64 host the host C/C++ compiler is
simply absent, so the build cannot start.

`ensure_linux_arm64_clang_prebuilt`
([prebuilts.sh:208](lineageos/scripts/lib/prebuilts.sh#L208)) fixes this by
**fetching** the ARM64 host Clang from
`android.googlesource.com/platform/prebuilts/clang/host/linux-arm64` at a pinned
ref, and installing it under `prebuilts/clang/host/linux-arm64/<payload>`. The
pins live in the build script header
([build_lineageos_desktop.sh:49-56](lineageos/scripts/build_lineageos_desktop.sh#L49-L56)):

```
clang_prebuilt_git_ref     = mirror-goog-llvm-r596125-release   # branch/tag
clang_prebuilt_version     = clang-r584948b                     # payload (LLVM/Clang 22)
```

Override with `ARM64_CLANG_PREBUILT_GIT_REF` / `ARM64_CLANG_PREBUILT_VERSION`
(and the matching `X86_*` for x86 hosts). `ensure_linux_arm64_clang_ready`
([prebuilts.sh:351](lineageos/scripts/lib/prebuilts.sh#L351)) then verifies the
payload is a real ARM64 ELF with libc++ headers and creates the
`lib/libc++.so → aarch64-unknown-linux-musl/libc++.so` symlink Soong expects.

### 6.2 Soong still references the `linux-x86` Clang path

Parts of Soong still reference the `linux-x86` Clang *metadata* path. Rather than
ship a real x86 compiler, `ensure_linux_x86_clang_arm64_soong_compat`
([prebuilts.sh:422](lineageos/scripts/lib/prebuilts.sh#L422)) builds an
**overlay** at `prebuilts/clang/host/linux-x86/<payload>` from symlinks into the
ARM64 payload, remapping the x86 triple names Soong expects
(`i386-/x86_64-unknown-linux-gnu`) onto the ARM64 `…-musl` equivalents. It is
rebuilt each run and refuses to clobber a genuine non-ARM64 payload.

### 6.3 Why the Clang 22 update was needed

The pinned payload `clang-r584948b` is **Clang/LLVM 22**, newer than what the
`lineage-23.2` source tree was written against. Clang 22 promotes new warnings
to errors (e.g. `-Wunterminated-string-initialization`), which breaks otherwise
fine source. [`clang22.patch`](lineageos/patches/clang22.patch) is the
consolidated fix across `external/musl`, `external/icu`, bionic, Trusty,
`device/generic/goldfish`, `hardware/ril`, and `frameworks/native` — adding
`-Wno-…` suppressions and rewriting a few constructs (e.g. the `xdigits[16]`
string-initializer in musl's `vfprintf.c` becomes an explicit char array).

**So "we had to update" is two coupled things:** the ARM64 host Clang was
*fetched and pinned* (the branch ships none), and because that pin is Clang 22
the source was *patched* (`clang22.patch`) to compile under it. Bumping the pin
later means re-checking `clang22.patch` against the new diagnostics.

---

## 7. Building

```bash
# Native ARM64 ROM on an ARM64 host
./lineageos/scripts/build_lineageos_desktop.sh arm64

# Incremental rebuild (skip sync + patch, reuse the tree)
REBUILD=1 ./lineageos/scripts/rebuild_cf_desktop_arm64.sh
```

The build appends a row to `buildtimes.log` (start, end, duration, arch,
status). A successful ARM64 run lands the bundle in `lineageos-arm64/`.

---

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `missing ARM64 build tools prebuilt` / `…ninja` | Setup couldn't fetch `prebuilts/build-tools/linux-arm64`; check network to `android.googlesource.com`. |
| `ARM64 host needs JDK 21…` | No `javac` and no fetchable JDK; set `ARM64_JDK21_PREBUILT_URL` or `ARM64_ANDROID_JAVA_HOME`. |
| Clang 22 diagnostic errors in a new project after a rebase | `clang22.patch` needs a new `-Wno-…`/rewrite for that project. |
| Rust proc-macro fails to load / ABI mismatch | The soong/make musl⇄glibc split (§4.3) drifted; verify `arm_linux_host.go` still maps the Rust triple to `…-gnu`. |
| `refusing to use non-ARM64 Clang payload on ARM64 host` | A stale/real x86 Clang is sitting in the x86 path; remove it so the overlay (§6.2) can be rebuilt. |
| Oversized Ninja deps / slow Trusty dep scan | The `dir_to_depfile` skip (§4.1) — ensure `build-soong-arm64-host.patch` is fully applied. |

---

## 9. Reference map & external resources

In-tree:
- Engine: [build_lineageos_desktop.sh](lineageos/scripts/build_lineageos_desktop.sh) · ARM64 setup: [build_exec.sh](lineageos/scripts/lib/build_exec.sh) · prebuilts: [prebuilts.sh](lineageos/scripts/lib/prebuilts.sh)
- Patches: [apply_source_patches.sh](lineageos/scripts/apply_source_patches.sh) · [patches/series](lineageos/patches/series) · [patches/README.md](lineageos/patches/README.md)
- Arch enforcement: [signing_common.sh](lineageos/scripts/signing_common.sh)

External (there is no official Google support for ARM64 build hosts — all WIP/community):
- Theory: [Enabling aarch64 as an Android build host](https://jsteward.moe/aarch64-build-host.html) · [C/C++ toolchain for aarch64](https://jsteward.moe/toolchain-for-android.html)
- Toolchains: [AOSP prebuilts (Git at Google)](https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/) · [build-aosp-clang-for-arm64](https://github.com/tomxi1997/build-aosp-clang-for-arm64)
- Apple Silicon page-size context: [Asahi: Broken Software](https://asahilinux.org/docs/sw/broken-software/) · [AOSP 16 KB pages](https://source.android.com/docs/core/architecture/16kb-page-size/16kb)
