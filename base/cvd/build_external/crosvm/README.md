# crosvm build patches

Patches applied to upstream [crosvm](https://chromium.googlesource.com/crosvm/crosvm) (pinned to `CROSVM_REV` in [`crosvm.MODULE.bazel`](crosvm.MODULE.bazel)) and to vendored Cargo dependencies pulled in by `crosvm_bin`. Wiring lives in `crosvm.MODULE.bazel`; each `crosvm_bin.annotation(crate = ..., patches = [...])` lists the patches that apply to a given crate, and the bottom `git_repository` block lists patches applied to the source tree itself.

## Patches

### gfxstream Vulkan policy

Gfxstream Vulkan is controlled by the packaged `ika` launcher instead:
`ika start --gfxstream_vulkan=auto|off|on` maps to Cuttlefish
`--gpu_context_types=...` when `--gpu_mode=gfxstream` is used. The default
`auto` policy disables gfxstream Vulkan only when the primary host Vulkan
device is llvmpipe. On Apple Silicon hosts with 16 KiB pages, `auto` keeps
gfxstream Vulkan enabled and selects the udmabuf-backed renderer path.

### Behavioral / feature patches

#### `PATCH.crosvm-composite-duplicate-components.patch`
- **Targets:** `crosvm_bin` and the source `git_repository`. File: `disk/src/composite.rs`.
- **What it does:** Introduces `OpenComponentDiskKey` (path + open-mode tuple) and a `HashMap`-backed cache so a composite disk that references the same backing component multiple times only opens the underlying file once, sharing the open handle across `ComponentDiskPart` entries.
- **Why:** Some Cuttlefish composite layouts reference the same component disk from more than one slot. Without dedup, each reference re-opens the file with conflicting locks/flags and `composite::open` fails.

#### `PATCH.disk-composite-preserve-spec-fd.patch`
- **Targets:** `disk` crate. File: `src/composite.rs`.
- **What it does:** Includes the composite disk specification file descriptor in `CompositeDiskFile::as_raw_descriptors()`.
- **Why:** The file is intentionally kept open to retain its lock. In crosvm multiprocess sandbox mode, unreported descriptors are closed by minijail; Rust then traps when `_disk_spec_file` is dropped because the owned fd was already closed.

#### `PATCH.crosvm-resize-display.patch`
- **Targets:** `crosvm_bin` and the source `git_repository`. File: `devices/src/virtio/gpu/virtio_gpu.rs`.
- **What it does:** Adds `VirtioGpu::resize_display(display_id, DisplayParameters)` that updates an existing scanout's `width`, `height`, and stored `display_params`, then flips `scanouts_updated` so the GPU thread re-syncs.
- **Why:** Upstream crosvm only supports add/remove of scanouts at runtime. Cuttlefish's `ika` launcher needs in-place resize so the host window can be resized without tearing down the display.

#### `PATCH.crosvm-resize-display-devices.patch`
- **Targets:** `devices` crate (vendored via cargo). File: `src/virtio/gpu/virtio_gpu.rs`.
- **What it does:** Same code change as `PATCH.crosvm-resize-display.patch`, but rebased onto the path layout used when `devices` is consumed as a published crate (no `devices/` prefix).
- **Why:** Bazel rebuilds both the binary (from the source git tree) and the `devices` crate (from cargo), so the same change has to be supplied twice with different prefixes.

#### `PATCH.crosvm-resize-display-vm-control.patch`
- **Targets:** `vm_control` crate. Files: `src/client.rs`, `src/gpu.rs`.
- **What it does:** Adds a `ResizeDisplay { display_id, display }` variant to `GpuControlCommand` and re-exports `do_gpu_display_resize` from `client.rs`. Pair with the `resize_display` patches so the control-socket protocol exposes the new operation end-to-end.
- **Why:** Without this, the `resize_display` capability added on the device side has no client-facing command.

#### `PATCH.vm_control-map-dmabuf-directly.patch`
- **Targets:** `vm_control` crate. File: `src/lib.rs`.
- **What it does:** Maps `VmMemorySource::Vulkan` resources directly when the exported handle is a DMA-BUF, retaining the Vulkano import path for opaque Vulkan handles.
- **Why:** Gfxstream's Apple Silicon host-visible allocations are udmabuf-backed DMA-BUFs and are already directly mappable. Importing them into a second Vulkano device-memory object needlessly transfers descriptor ownership through the Vulkan driver. The guest mapping was released on process exit, but the imported descriptors remained open in crosvm and pinned the backing pages. Direct mmap makes unregister/drop release the mapping without a second Vulkan lifetime.

### Upstream-sync patches (large)

#### `PATCH.mesa3d_util-upstream-main-20260520.patch`
- **Targets:** `mesa3d_util` crate.
- **What it does:** Adds new modules (notably `atomic_memory_sentinel.rs`) and other API surface required by the newer `rutabaga_gfx`. Effectively fast-forwards the pinned `mesa3d_util` crate to upstream `main` as of 2026-05-20.
- **Why:** The `rutabaga_gfx` upstream-sync patch below depends on `AtomicMemorySentinel` and other helpers that don't exist in the crate version Cargo resolves to. Without this patch, that one fails to compile.

#### `PATCH.rutabaga_gfx-upstream-main-20260520.patch`
- **Targets:** `rutabaga_gfx` crate.
- **What it does:** Fast-forwards `rutabaga_gfx` to upstream `main` as of 2026-05-20 — adds `cross_domain/atomic_memory_sentinel_manager.rs`, refreshes `cross_domain/{protocol,mod}.rs`, `rutabaga_core.rs`, `rutabaga_gralloc/gralloc.rs`, `rutabaga_utils.rs`, `lib.rs`.
- **Why:** Picks up bug fixes and API additions needed by both crosvm and gfxstream that haven't landed in a published crate release.

### Build-system patches (no runtime effect)

#### `PATCH.rutabaga_gfx_build_rs.patch`
- **Targets:** `rutabaga_gfx` crate. File: `build.rs`.
- **What it does:** Replaces the `pkg-config`-based discovery of `gbm` / `virglrenderer` with logic that works inside the Bazel sandbox (no `pkg-config` available; libs are vendored).
- **Why:** Without it, `cargo build` of `rutabaga_gfx` aborts during the build script because `pkg-config` can't find the host libraries (sandbox isolates them).

#### `PATCH.minijail-sys_build_rs.patch`
- **Targets:** `minijail-sys` crate. File: `build.rs`.
- **What it does:** Adds `find_minijail_root()` which scans `external/*/third_party/minijail` for `Makefile` + `libminijail.h` instead of hardcoding the canonical repo name.
- **Why:** Bazel renames external repos based on the rule version (e.g. `+_repo_rules6+crosvm`, `+_repo_rules2+crosvm`). Hardcoding any one of those breaks the build whenever Bazel bumps the rule version.

#### `PATCH.minijail-sys_common_mk.patch`
- **Targets:** Source `git_repository` (under `third_party/minijail/`). File: `common.mk`.
- **What it does:** Adds `-Wno-unused-command-line-argument` to `COMMON_CFLAGS`.
- **Why:** Bazel-driven clang invocations sometimes pass flags ignored by `cc1` (e.g. linker-only options to a compile step). With `-Werror` in `COMMON_CFLAGS`, the otherwise-harmless warning turns into a build failure.

#### `PATCH.proto_build_tools.patch`
- **Targets:** `proto_build_tools` crate. File: `src/lib.rs`.
- **What it does:** Drops the `#[path = "<out_dir>/<file>.rs"]` directive that the generator was emitting alongside each `pub mod ...;` declaration.
- **Why:** `out_dir` resolves to a temporary path inside the Bazel sandbox at codegen time. If that path is baked into the generated source, the next consumer of the crate fails to find it (the sandbox is gone). Removing the `#[path]` lets the standard `pub mod` lookup find the generated file via the build script's `OUT_DIR` env at compile time.

## How they're wired

See `crosvm.MODULE.bazel`. The relevant blocks:

| Target | Patches |
|---|---|
| `crosvm_bin.annotation(crate = "crosvm")` | `crosvm-composite-duplicate-components`, `crosvm-composite-preserve-spec-fd`, `crosvm-gpu-2d-sandbox`, `crosvm-resize-display` |
| `crosvm_bin.annotation(crate = "disk")` | `disk-composite-preserve-spec-fd` |
| `crosvm_bin.annotation(crate = "jail")` | `jail-aarch64-block-pread64`, `jail-gpu-host-graphics-libs-optional` |
| `crosvm_bin.annotation(crate = "mesa3d_util")` | `mesa3d_util-upstream-main-20260520` |
| `crosvm_bin.annotation(crate = "devices")` | `crosvm-resize-display-devices` |
| `crosvm_bin.annotation(crate = "rutabaga_gfx")` | `rutabaga_gfx_build_rs`, `rutabaga_gfx-upstream-main-20260520` |
| `crosvm_bin.annotation(crate = "minijail-sys")` | `minijail-sys_build_rs` |
| `crosvm_bin.annotation(crate = "proto_build_tools")` | `proto_build_tools` |
| `crosvm_bin.annotation(crate = "vm_control")` | `crosvm-resize-display-vm-control` |
| `git_repository(name = "crosvm")` (source tree) | `crosvm-aarch64-block-pread64-source`, `crosvm-composite-duplicate-components`, `crosvm-composite-preserve-spec-fd`, `crosvm-gpu-2d-sandbox-source`, `crosvm-resize-display`, `minijail-sys_common_mk` |

#### `PATCH.jail-aarch64-block-pread64.patch`
- **Targets:** `jail` crate. File: `seccomp/aarch64/block_device.policy`.
- **What it does:** Allows `pread64` for the ARM64 virtio block-device sandbox.
- **Why:** The ARM64 block backend can issue `pread64` after entering the device jail. Without this allow-list entry, minijail kills `pcivirtio-block` with `SIGSYS` during sandboxed boot.

#### `PATCH.crosvm-composite-preserve-spec-fd.patch`
- **Targets:** `crosvm_bin` and the source `git_repository`. File: `disk/src/composite.rs`.
- **What it does:** Includes the composite disk specification file descriptor in `CompositeDiskFile::as_raw_descriptors()`.
- **Why:** The file is intentionally kept open to retain its lock. In crosvm multiprocess sandbox mode, unreported descriptors are closed by minijail; Rust then traps when `_disk_spec_file` is dropped because the owned fd was already closed.

#### `PATCH.jail-gpu-host-graphics-libs-optional.patch`
- **Targets:** `jail` crate. File: `src/helpers.rs`.
- **What it does:** Adds a `bind_host_graphics_libs` parameter to the GPU minijail helper so callers can skip broad `/usr/lib`, `/lib`, and Mesa/Vulkan data bind mounts when they are not needed.

#### `PATCH.crosvm-gpu-2d-sandbox.patch`
- **Targets:** `crosvm` crate. Files: `src/crosvm/sys/linux/gpu.rs`, `src/crosvm/sys/linux/device_helpers.rs`.
- **What it does:** Keeps host graphics library bind mounts for the render-server jail, but skips them for the virtio GPU device when the backend is pure `2D` and for the virtio-wl device. This avoids ARM64 minijail failures on guest SwiftShader launches while keeping sandboxing enabled.

#### `PATCH.crosvm-gpu-2d-sandbox-source.patch`
- **Targets:** Source `git_repository` checkout.
- **What it does:** Equivalent full-tree version of the two crate-universe patches above for users of `@crosvm`.

#### `PATCH.crosvm-aarch64-block-pread64-source.patch`
- **Targets:** Source `git_repository` checkout.
- **What it does:** Equivalent full-tree version of `PATCH.jail-aarch64-block-pread64.patch`.
