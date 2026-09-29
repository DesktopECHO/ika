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

#### `PATCH.crosvm-gpu-unref-shmem-mapping.patch`
- **Targets:** `crosvm_bin`. File: `devices/src/virtio/gpu/virtio_gpu.rs`.
- **What it does:** Removes a resource's shared-memory mapping when the guest unreferences the virtio-gpu resource.
- **Why:** A guest may release a resource without an explicit blob-unmap request; without this cleanup, the hypervisor mapping outlives the resource and can accumulate stale mappings.

#### `PATCH.crosvm-resize-display-devices.patch`
- **Targets:** `devices` crate (vendored via cargo). File: `src/virtio/gpu/virtio_gpu.rs`.
- **What it does:** Same code change as `PATCH.crosvm-resize-display.patch`, but rebased onto the path layout used when `devices` is consumed as a published crate (no `devices/` prefix).
- **Why:** Bazel rebuilds both the binary (from the source git tree) and the `devices` crate (from cargo), so the same change has to be supplied twice with different prefixes.

#### `PATCH.crosvm-resize-display-vm-control.patch`
- **Targets:** `vm_control` crate. Files: `src/client.rs`, `src/gpu.rs`.
- **What it does:** Adds a `ResizeDisplay { display_id, display }` variant to `GpuControlCommand` and re-exports `do_gpu_display_resize` from `client.rs`. Pair with the `resize_display` patches so the control-socket protocol exposes the new operation end-to-end.
- **Why:** Without this, the `resize_display` capability added on the device side has no client-facing command.

#### `PATCH.crosvm-enable-vulkano-gralloc.patch`
- **Targets:** `crosvm_bin`. Files: `src/crosvm/sys/linux.rs`, `src/crosvm/sys/linux/gpu.rs`.
- **What it does:** Keeps rutabaga's Vulkano gralloc backend available and preserves an explicit `external_blob` request.
- **Why:** Minigbm has no Asahi driver. On Apple Silicon Linux, Vulkano is therefore the fallback that imports gfxstream dma-bufs through Honeykrisp. Rutabaga 0.1.80 now provides the cross-domain and atomic-memory support that previously required the removed `mesa3d_util` and `rutabaga_gfx` upstream-sync overlays.

#### Fixed-blob mappings
- **Targets:** `base`, `vm_control`, and `crosvm` crates. Files: `src/sys/linux/mmap.rs`, `src/sys/linux.rs`, and `src/crosvm/sys/linux/gpu.rs`.
- **What it does:** Creates the GPU BAR shared-memory arena read/write and only disables fixed-blob mapping when Vulkano is actually selected, not merely compiled into crosvm.
- **Why:** The shared-memory arena must permit writable mappings. A Vulkano-enabled build using GLES-only rendering can still use fixed-blob mapping.

#### `PATCH.rutabaga_gfx-gralloc-vulkano-fallback.patch`
- **Targets:** `rutabaga_gfx` crate. File: `src/rutabaga_gralloc/gralloc.rs`.
- **What it does:** Prefers a working minigbm backend and starts Vulkano only when minigbm initialization fails.
- **Why:** This preserves the established x86_64 path while allowing Apple Silicon hosts to use the upstream Vulkano backend.

#### `PATCH.rutabaga_gfx-cleanup-on-drop.patch`
- **Targets:** `rutabaga_gfx` crate. File: `src/rutabaga_core.rs`.
- **What it does:** Releases gfxstream contexts and resources before the renderer component is destroyed.
- **Why:** Orderly teardown reaches gfxstream's normal unbind paths instead of leaving renderer-owned resources alive during process shutdown.

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

#### `PATCH.ffmpeg-supported-config.patch`
- **Targets:** `ffmpeg` crate. Files: `build.rs`, `src/avcodec.rs`. Applied after `PATCH.ffmpeg-pkg-config-includes.patch`, which crate_universe guarantees only because it applies annotation patches in sorted name order; keep the names sorting that way.
- **What it does:** `build.rs` sets the `ffmpeg_codec_supported_config` cfg when pkg-config reports libavcodec 61.13.100 (FFmpeg 7.1) or newer, and `AvCodec::pixel_format_iter()` then reads the codec's pixel formats through `avcodec_get_supported_config()` instead of the `AVCodec.pix_fmts` field. Older FFmpeg keeps using the field.
- **Why:** FFmpeg 9 (libavcodec 63, shipped by Arch) removed `AVCodec.pix_fmts`, so the crate no longer compiled there. On FFmpeg 8.1 both paths return identical pixel format lists for every codec.

## How they're wired

See `crosvm.MODULE.bazel`. The relevant blocks:

| Target | Patches |
|---|---|
| `crosvm_bin.annotation(crate = "base")` | `base-fixed-blob-arena-protection` |
| `crosvm_bin.annotation(crate = "crosvm")` | `crosvm-composite-duplicate-components`, `crosvm-composite-preserve-spec-fd`, `crosvm-gpu-2d-sandbox`, `crosvm-gpu-unref-shmem-mapping`, `crosvm-resize-display`, `crosvm-enable-vulkano-gralloc`, `crosvm-fixed-blob-vulkan-condition`, `minijail-sys_common_mk` |
| `crosvm_bin.annotation(crate = "disk")` | `disk-composite-preserve-spec-fd` |
| `crosvm_bin.annotation(crate = "jail")` | `jail-aarch64-block-pread64`, `jail-gpu-host-graphics-libs-optional` |
| `crosvm_bin.annotation(crate = "devices")` | `crosvm-resize-display-devices` |
| `crosvm_bin.annotation(crate = "rutabaga_gfx")` | `rutabaga_gfx_build_rs`, `rutabaga_gfx-gralloc-vulkano-fallback`, `rutabaga_gfx-cleanup-on-drop` |
| `crosvm_bin.annotation(crate = "minijail-sys")` | `minijail-sys_build_rs` |
| `crosvm_bin.annotation(crate = "proto_build_tools")` | `proto_build_tools` |
| `crosvm_bin.annotation(crate = "vm_control")` | `crosvm-resize-display-vm-control`, `vm-control-fixed-blob-arena-protection` |
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
