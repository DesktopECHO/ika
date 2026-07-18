# Building the LineageOS Desktop ROM on an ARM64 Host

This document explains how the **Ika** build runs on an **ARM64 (aarch64) Linux
host**, including the project's primary Apple Silicon/Fedora Asahi Remix target.
It covers the build-matrix constraints, the source patches and runtime
orchestration that make ARM64-host builds possible, the Clang prebuilt strategy,
and troubleshooting guidance.

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

1. **Source patches** that teach the build system that `linux-arm64` is a real
   host architecture and resolve toolchains from the *active* host tag instead
   of `linux-x86`.
2. **Runtime orchestration** in the build scripts that *provisions* the ARM64
   host prebuilts (Clang, Go, Rust, JDK, CMake, build-tools) and *exports* the
   environment variables those patches read, failing fast if anything is
   missing.

Neither layer works without the other: the source patches provide ARM64 host
awareness, and the scripts provide the ARM64 prebuilts and environment those
patches expect.

---

## 2. Build-matrix constraints

| ROM target | x86_64 host | ARM64 host |
|---|---|---|
| `x86_64` ROM | ✅ | ❌ (refused) |
| `arm64` ROM | ✅ (cross) | ✅ (native) |

- x86_64 ROMs can only be built on an x86_64 host, as enforced in
  [build_lineageos_desktop.sh](lineageos/scripts/build_lineageos_desktop.sh)
  and the ELF arch checks in
  [signing_common.sh](lineageos/scripts/signing_common.sh).
- ARM64 host builds run **natively** with real `linux-arm64` host prebuilts.
  The build scripts refuse symlinked `linux-x86` substitutions and log the host
  page size, but they no longer wrap the Android build in a guest VM.

---

## 3. Prerequisites for an ARM64 host

The build engine provisions most prebuilts itself, but the host must supply:

- Network access **throughout the build**—ARM64 host prebuilts (Clang, Go, Rust,
  JDK, CMake, and Clang tools) are fetched from Android, Rust, and Adoptium
  services during setup, and partial clones fetch blobs on demand during
  compilation.
- A high open-file limit—`raise_host_open_file_limit` raises it
  (`NOFILE_LIMIT`, default `4194304`; set empty to skip).
- JDK—if `javac` is not on `PATH` and no ARM64 JDK prebuilt can be fetched, the
  build stops and requests `ARM64_JDK21_PREBUILT_URL` or
  `ARM64_ANDROID_JAVA_HOME`.

---

## 4. The patch layer

All ARM64-host patches live under [lineageos/patches/](lineageos/patches/) and
are applied in [series](lineageos/patches/series) order by
[apply_source_patches.sh](lineageos/scripts/apply_source_patches.sh). The
application script verifies that every entry resolves to a file and that no
patch is orphaned.

| Patch | Project | What it unlocks |
|---|---|---|
| [`build-soong-arm64-host.patch`](lineageos/patches/build-soong-arm64-host.patch) | `build/soong` | Registers `linux_arm64` as a host arch; host install paths, Clang/bindgen selection, Rust host-cross + proc-macros, JDK path handling |
| [`build-make-arm64-host.patch`](lineageos/patches/build-make-arm64-host.patch) | `build/make` | Make/kati mirror: host prebuilt tag for LLVM tools, compiler-rt/libc++ paths, `HOST_ARCH := arm64`, `USE_HOST_MUSL := true` |
| [`prebuilts-arm64-host.patch`](lineageos/patches/prebuilts-arm64-host.patch) | source root | Enables ARM64 host variants for build-tools, JDK 21, and Rust prebuilt module definitions |
| [`frameworks-libs-binary-translation-arm64-host.patch`](lineageos/patches/frameworks-libs-binary-translation-arm64-host.patch) | `frameworks/libs/binary_translation` | `berberis_all_hosts_defaults_64` so the translator builds on non-x86 hosts |
| [`clang22.patch`](lineageos/patches/clang22.patch) | source root | Cross-project Clang 22 diagnostic fixes (see §6) |
| [`external-stg-arm64-host-page-size.patch`](lineageos/patches/external-stg-arm64-host-page-size.patch) | `external/stg` | Removes jemalloc from ARM64 musl-host ABI tools so they run on 16 KiB-page hosts |
| [`external-rust-android-crates-io-arm64-host-cross.patch`](lineageos/patches/external-rust-android-crates-io-arm64-host-cross.patch) | `external/rust/android-crates-io` | Rust host-cross modules (incl. bindgen crates) for ARM64 |
| [`external-cronet-arm64-host-cross.patch`](lineageos/patches/external-cronet-arm64-host-cross.patch) | `external/cronet` | Cronet host tools/Rust host-cross; scopes x86 flags to x86 |
| [`external-sdv-vsomeip-arm64-host-cross.patch`](lineageos/patches/external-sdv-vsomeip-arm64-host-cross.patch) | `external/sdv/vsomeip` | Restricts SSE flags to x86_64 so the graph generates on ARM64 |
| [`external-musl-lfs64-compat.patch`](lineageos/patches/external-musl-lfs64-compat.patch) | `external/musl` | Public musl header modules plus weak LFS64 aliases required by the Rust musl host stdlib shim |
| [`vendor-lineage-arm64-host-tools.patch`](lineageos/patches/vendor-lineage-arm64-host-tools.patch) | `vendor/lineage` | Native ARM64 `lz4` / `pahole` for kernel builds and native `mogrify` fallback |
| [`external-trusty-lk-arm64-host.patch`](lineageos/patches/external-trusty-lk-arm64-host.patch) | `external/trusty/lk` | Records Trusty Clang host target/link flags and ARM64 host Rust proc-macro linker args |
| [`trusty-kernel-arm64-host.patch`](lineageos/patches/trusty-kernel-arm64-host.patch) | `trusty/kernel` | Env-provided host `dtc` plus Clang host target/runtime flags for Trusty host compiles |
| [`trusty-user-base-arm64-host-boringssl.patch`](lineageos/patches/trusty-user-base-arm64-host-boringssl.patch) | `trusty/user/base` | Host BoringSSL archive builds on ARM64 Linux |
| [`system-sepolicy-checkfc-arm64-getopt.patch`](lineageos/patches/system-sepolicy-checkfc-arm64-getopt.patch) | `system/sepolicy` | Preserves `getopt()`'s signed end-of-options value in the ARM64 host `checkfc` tool |

### 4.1 `build-soong-arm64-host.patch` deep dive (21 files)

Four themes:

1. **Make `linux_arm64` a first-class host target.**
   - `android/arch.go` — deduplication guard so the native build and the ARM64
     host target do not produce duplicate host `Target` entries.
   - `android/paths.go` — host install paths emit `arm64` (not hardcoded `x86`)
     when `BuildArch == Arm64`, so host tools land under `host/linux-arm64/`.
2. **Resolve toolchains from the host tag, not hardcoded x86.**
   - `cc/config/global.go` — `ClangAsanLibDir` → `${HostPrebuiltTag}`.
   - `java/config/{config,makevars}.go` — `ANDROID_JAVA8_HOME` driven by a
     `Java8Home` env var set by `soong_ui`, not a hardcoded jdk8 path.
3. **Rust host toolchain for ARM64** (the bulk — ~15 hunks). The crux is
   `rust/config/arm_linux_host.go`: Soong routes Linux host modules through
   **musl** toolchain variants, but the ARM64 `rustc` that actually runs is a
   **GNU/glibc** toolchain. So the musl-arm64 Rust toolchain is remapped —
   triple `aarch64-unknown-linux-musl` → `aarch64-unknown-linux-gnu`, musl link
   flags → glibc link flags, `Glibc()` → `true` — keeping the stdlib ABI aligned
   with `rustc` so **proc-macros load** (a wrong-ABI proc-macro can't be
   dlopened by the compiler).
4. **Build-infra robustness on ARM64 hosts.**
   - `cmd/dir_to_depfile/dir_to_depfile.go` — skip `.git` and `prebuilts/` when
     collecting Trusty `dir_srcs` dependencies so nsjail-bind-mounted toolchain
     trees do not overwhelm Ninja's dependency records.

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

On an ARM64 host, Rust host modules therefore use a glibc `rustc` under the
"musl variant" label. If the two patches drift apart, proc-macros fail to load—
which is why they must be updated together.

---

## 5. Runtime orchestration

`configure_arm64_host_build` in
[build_exec.sh](lineageos/scripts/lib/build_exec.sh) is the other half
of the contract. It runs only on ARM64 hosts and provisions exactly what the
patches assume, failing fast if anything is missing:

```text
ensure_arm64_go_prebuilt                       # prebuilts/go/linux-arm64
prebuilts/build-tools/linux-arm64 + ninja      # required from source sync
ensure_arm64_rust_prebuilt / ensure_arm64_rust_tool_bridges
                                                # GNU rustc host toolchain
ensure_linux_arm64_clang_prebuilt / ensure_linux_arm64_clang_ready
                                                # fetch + verify ARM64 Clang (§6)
ensure_linux_arm64_clang_trusty_dirgroup       # Trusty dirgroup wiring
ensure_linux_x86_clang_arm64_soong_compat      # x86-path overlay (§6.2)
ensure_arm64_clang_tools_prebuilt
ensure_arm64_native_cmake_prebuilt
ensure_arm64_native_jdk21_prebuilt / ensure_arm64_jdk8_prebuilt
                                                # feeds ANDROID_JAVA*_HOME
ensure_no_arm64_x86_prebuilt_substitutions     # guard against x86 shadowing
raise_host_open_file_limit
```

### The patch ⇄ runtime contract

| Patch expects (reads) | Script provides (sets) |
|---|---|
| `ANDROID_JAVA8_HOME = ${Java8Home}` | JDK 8/21 prebuilts + `OVERRIDE_ANDROID_JAVA_HOME` |
| `linux-arm64` host Clang via `HostPrebuiltTag` | `ensure_linux_arm64_clang_prebuilt` / `ensure_linux_arm64_clang_ready` |
| `prebuilts/build-tools/linux-arm64` enabled | hard `die` if `…/bin/ninja` missing |
| GNU Rust host toolchain | `ensure_arm64_rust_prebuilt` + `ensure_arm64_rust_tool_bridges` |
| arm64 install paths not shadowed by x86 | `ensure_no_arm64_x86_prebuilt_substitutions` |

Relevant env knobs (defaults in the header of
[build_lineageos_desktop.sh](lineageos/scripts/build_lineageos_desktop.sh)):
`NOFILE_LIMIT`, `ARM64_JDK21_PREBUILT_URL`, `ARM64_ANDROID_JAVA_HOME`.

---

## 6. The ARM64 Clang story ("clang missing, had to update")

### 6.1 The branch ships no ARM64 host Clang

`lineage-23.2` ships `prebuilts/clang/host/linux-x86` but **not**
`prebuilts/clang/host/linux-arm64`. On an ARM64 host the host C/C++ compiler is
simply absent, so the build cannot start.

[`ensure_linux_arm64_clang_prebuilt`](lineageos/scripts/lib/prebuilts.sh) fixes
this by **fetching** the ARM64 host Clang from
`android.googlesource.com/platform/prebuilts/clang/host/linux-arm64` at a pinned
ref, and installing it under `prebuilts/clang/host/linux-arm64/<payload>`. The
pins live in the
[build script header](lineageos/scripts/build_lineageos_desktop.sh):

```
clang_prebuilt_git_ref     = mirror-goog-llvm-r596125-release   # branch/tag
clang_prebuilt_version     = clang-r584948b                     # payload (LLVM/Clang 22)
```

Override with `ARM64_CLANG_PREBUILT_GIT_REF` / `ARM64_CLANG_PREBUILT_VERSION`
(and the matching `X86_*` variables for x86 hosts).
[`ensure_linux_arm64_clang_ready`](lineageos/scripts/lib/prebuilts.sh) then
verifies that the payload is a real ARM64 ELF with libc++ headers and creates the
`lib/libc++.so → aarch64-unknown-linux-musl/libc++.so` symlink Soong expects.

### 6.2 Soong still references the `linux-x86` Clang path

Parts of Soong still reference the `linux-x86` Clang *metadata* path. Rather than
ship a real x86 compiler,
[`ensure_linux_x86_clang_arm64_soong_compat`](lineageos/scripts/lib/prebuilts.sh)
builds an **overlay** at `prebuilts/clang/host/linux-x86/<payload>` from symlinks
into the ARM64 payload, remapping the x86 triple names Soong expects
(`i386-/x86_64-unknown-linux-gnu`) onto the ARM64 `…-musl` equivalents. It is
rebuilt each run and refuses to clobber a genuine non-ARM64 payload.

### 6.3 Why the Clang 22 update was needed

The pinned payload `clang-r584948b` is **Clang/LLVM 22**, newer than the version
against which the `lineage-23.2` source tree was written. Clang 22 promotes new
warnings to errors (for example, `-Wunterminated-string-initialization`), which
breaks otherwise valid source.
[`clang22.patch`](lineageos/patches/clang22.patch) is the consolidated fix
across `external/musl`, `external/icu`, bionic, Trusty,
`device/generic/goldfish`, `hardware/ril`, and `frameworks/native`, adding
`-Wno-…` suppressions and rewriting a few constructs. For example, the
`xdigits[16]` string initializer in musl's `vfprintf.c` becomes an explicit
character array.

The update therefore has two coupled parts: fetching and pinning an ARM64 host
Clang because the branch does not provide one, and patching the source with
`clang22.patch` so it compiles with Clang 22. Any later pin update requires
rechecking that patch against the new diagnostics.

---

## 7. Building

```bash
# Native ARM64 ROM on an ARM64 host
./lineageos/scripts/build_lineageos_desktop.sh arm64

# Incremental rebuild (skip sync + patch, reuse the tree)
REBUILD=1 ./lineageos/scripts/rebuild_cf_desktop_arm64.sh
```

The build appends a row to `buildtimes.log` with its start time, end time,
duration, architecture, and status. A successful ARM64 run writes the bundle to
`lineageos-arm64/`.

---

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `missing ARM64 build tools prebuilt` / `…ninja` | Source sync did not provide `prebuilts/build-tools/linux-arm64`; check the sync result and network access to `android.googlesource.com`. |
| `ARM64 host needs JDK 21…` | No `javac` and no fetchable JDK; set `ARM64_JDK21_PREBUILT_URL` or `ARM64_ANDROID_JAVA_HOME`. |
| Clang 22 diagnostic errors in a new project after a rebase | `clang22.patch` needs a new `-Wno-…`/rewrite for that project. |
| Rust proc-macro fails to load / ABI mismatch | The Soong/Make musl⇄glibc split (§4.3) drifted; verify `arm_linux_host.go` still maps the Rust triple to `…-gnu`. |
| `refusing to use non-ARM64 Clang payload on ARM64 host` | A stale/real x86 Clang is sitting in the x86 path; remove it so the overlay (§6.2) can be rebuilt. |
| Oversized Ninja dependencies / slow Trusty dependency scan | Ensure the `dir_to_depfile` skip in `build-soong-arm64-host.patch` (§4.1) is fully applied. |

---

## 9. Reference map and external resources

In-tree:

- Engine: [build_lineageos_desktop.sh](lineageos/scripts/build_lineageos_desktop.sh) · ARM64 setup: [build_exec.sh](lineageos/scripts/lib/build_exec.sh) · prebuilts: [prebuilts.sh](lineageos/scripts/lib/prebuilts.sh)
- Patches: [apply_source_patches.sh](lineageos/scripts/apply_source_patches.sh) · [patches/series](lineageos/patches/series) · [patches/README.md](lineageos/patches/README.md)
- Arch enforcement: [signing_common.sh](lineageos/scripts/signing_common.sh)

External resources (Google does not officially support ARM64 build hosts; these
are community references):

- Theory: [Enabling aarch64 as an Android build host](https://jsteward.moe/aarch64-build-host.html) · [C/C++ toolchain for aarch64](https://jsteward.moe/toolchain-for-android.html)
- Toolchains: [AOSP ARM64 Clang prebuilts](https://android.googlesource.com/platform/prebuilts/clang/host/linux-arm64/) · [build-aosp-clang-for-arm64](https://github.com/tomxi1997/build-aosp-clang-for-arm64)
- Apple Silicon page-size context: [Asahi: Broken Software](https://asahilinux.org/docs/sw/broken-software/) · [AOSP 16 KB pages](https://source.android.com/docs/core/architecture/16kb-page-size/16kb)
