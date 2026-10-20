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

#### `PATCH.disk-qcow-zero-clusters.patch`
- **Targets:** `disk` crate. Files: `src/qcow/mod.rs`, `src/qcow/qcow_raw_file.rs`.
- **What it does:** Supports qcow2 version 3 zero clusters (L2 entry bit 0). Discarding or write-zeroing a full cluster of a qcow2 image that has a backing file now frees the cluster's storage and marks it zero, instead of allocating a cluster and writing zeroes into it. Zero clusters read as zeroes rather than from the backing file, and a later write into one starts from zeroes.
- **Why:** Cuttlefish's `overlay.img` is a qcow2 over `os_composite.img`, so every guest discard took that allocate-and-zero path. A factory reset (Settings, recovery, RescueParty) discards the whole userdata partition, which grew `overlay.img` by the partition size (64 GB by default) and filled the host disk; an `fstrim` of `/data` did the same for its free space.

#### `PATCH.gpu_display-nonblocking-dispatch.patch`
- **Targets:** `gpu_display` crate. File: `src/display_wl.c`.
- **What it does:** `dwl_context_dispatch()` reads the Wayland connection only when data is waiting (`wl_display_prepare_read`, a zero-timeout `poll`, `wl_display_read_events`) and dispatches what is pending, instead of calling the blocking `wl_display_dispatch()`.
- **Why:** The GPU worker dispatches display events once per wake when the display fd was readable, after handling the other events of that wake. A GPU control request in the same wake (adding or removing a display, as every Ika app window does) makes a `wl_display_roundtrip()` that reads and dispatches those events first, and `wl_display_dispatch()` then blocked the worker until the compositor (ika_stream) sent something, which it only does in reply to the worker. The guest's GPU requests stopped being processed: SurfaceFlinger froze, every later display request hung in crosvm's control loop, and crosvm did not exit when the guest rebooted.

#### `PATCH.gpu_display-dmabuf-in-use.patch`
- **Targets:** `gpu_display` crate. Files: `src/display_wl.c`, `src/dwl.rs`, `src/gpu_display_wl.rs`, `src/lib.rs`.
- **What it does:** Adds `dwl_surface_dmabuf_in_use()`, `GpuDisplaySurface::import_in_use()` and `GpuDisplay::import_in_use()`: whether the compositor still uses an imported dma-buf other than the one on screen (its `in_use` flag, set by `dwl_surface_flip_to()` and cleared by the compositor's `wl_buffer.release`, which nothing read before). The surface remembers the import it last flipped to.
- **Why:** `ika_stream` holds the buffer of a dma-buf frame until the console has released the frame (IKAB). The device needs to know, see the next patch. The buffer on screen is exempt because the guest may flush it again (a single-buffer scanout, or a redraw into it), which the compositor takes as the release of the earlier frame.

#### `PATCH.crosvm-flush-held-dmabuf.patch`, `PATCH.crosvm-flush-held-dmabuf-devices.patch`
- **Targets:** `crosvm_bin` (source tree, `devices/src/virtio/gpu/virtio_gpu.rs`) and the `devices` crate (`src/virtio/gpu/virtio_gpu.rs`), the same change with the two path prefixes.
- **What it does:** `VirtioGpuScanout::flush()` drops a flush whose imported dma-buf the compositor still holds (`GpuDisplay::import_in_use()`), as the copy path already drops a frame whose `wl_shm` buffer is in use.
- **Why:** With the hold, flipping to a held buffer would show the guest's next composition inside the frame the console is sampling. The guest's next flush, into another buffer of its swapchain, gets through; nothing waits.

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

#### `PATCH.rutabaga_gfx-gralloc-vulkano-fallback.patch`
- **Targets:** `rutabaga_gfx` crate. File: `src/rutabaga_gralloc/gralloc.rs`.
- **What it does:** Prefers a working minigbm backend and starts Vulkano only when minigbm initialization fails.
- **Why:** This preserves the established x86_64 path while allowing Apple Silicon hosts to use the upstream Vulkano backend.

#### `PATCH.rutabaga_gfx-cleanup-on-drop.patch`
- **Targets:** `rutabaga_gfx` crate. File: `src/rutabaga_core.rs`.
- **What it does:** Releases gfxstream contexts and resources before the renderer component is destroyed.
- **Why:** Orderly teardown reaches gfxstream's normal unbind paths instead of leaving renderer-owned resources alive during process shutdown.

#### `PATCH.rutabaga_gfx-gfxstream-3d-resource-info.patch`
- **Targets:** `rutabaga_gfx` crate. Files: `src/gfxstream.rs`, `src/rutabaga_core.rs`.
- **What it does:** Fills a gfxstream 3D resource's `info_3d` (DRM format and stride) from `stream_renderer_resource_get_info` when it is created, with no known modifier (gfxstream's images are tiled host images; the importer takes the layout from the dma-buf).
- **Why:** crosvm's `import_resource_to_display` sends a scanout to the Wayland compositor (run_cvd, then `ika_stream` and the console) as a dma-buf only when both `export_blob` and `resource3d_info` succeed. The export already worked, but the missing 3D info failed the lookup for every non-blob resource, so the console frames always went through the GPU-to-CPU readback into a `wl_shm` buffer.

#### `PATCH.rutabaga_gfx-on-demand-export-and-query.patch`
- **Targets:** `rutabaga_gfx` crate. Files: `src/gfxstream.rs`, `src/rutabaga_core.rs`. Applied after `PATCH.rutabaga_gfx-gfxstream-3d-resource-info.patch`.
- **What it does:** Adds `export_blob` and `query` to the `RutabagaComponent` trait; `Rutabaga::export_blob` asks the component when no handle was cached and `Rutabaga::resource3d_info` asks it when the resource has no 3D info; gfxstream's `create_3d` no longer exports and queries eagerly; the query carries the offset and DRM modifier gfxstream reports.
- **Why:** gfxstream re-creates a color buffer with an explicit DRM format modifier when the VMM first exports it for scanout, so the layout must be read after that export, and exporting every 3D resource at creation would freeze the wrong layout and hold an fd per resource.

#### `PATCH.v4l2r-poller-no-epollin-probe.patch`
- **Targets:** `v4l2r` crate. File: `src/device/poller.rs`.
- **What it does:** `Poller::new` registers the device with no events, instead of registering `EPOLLIN`, doing a dummy `epoll_wait` and clearing the events again.
- **Why:** The `--v4l2-proxy` camera device creates a `Poller` for each guest session. On a host camera whose driver supports `read()` (`VB2_READ`: facetimehd, gspca, pwc), that `EPOLLIN` poll on a queue without buffers starts the vb2 `read()` emulator, so the queue is streaming before the guest configures it and the camera HAL's `VIDIOC_S_PARM` fails with `EBUSY`. The probe only worked around kernels 5.9 and older, where the first poll had to ask for `EPOLLIN` or `EPOLLOUT` for later frame wakeups to arrive.

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
- **Why:** FFmpeg 9 (libavcodec 63) removed `AVCodec.pix_fmts`, so the crate no longer compiled with the pinned FFmpeg 9.0.2 build. On FFmpeg 8.1 both paths return identical pixel format lists for every codec.

## How they're wired

See `crosvm.MODULE.bazel`. The relevant blocks:

| Target | Patches |
|---|---|
| `crosvm_bin.annotation(crate = "crosvm")` | `crosvm-composite-duplicate-components`, `crosvm-composite-preserve-spec-fd`, `crosvm-gpu-2d-sandbox`, `crosvm-gpu-unref-shmem-mapping`, `crosvm-resize-display`, `crosvm-flush-held-dmabuf`, `crosvm-enable-vulkano-gralloc`, `minijail-sys_common_mk` |
| `crosvm_bin.annotation(crate = "disk")` | `disk-composite-preserve-spec-fd`, `disk-qcow-zero-clusters` |
| `crosvm_bin.annotation(crate = "jail")` | `jail-aarch64-block-pread64`, `jail-gpu-host-graphics-libs-optional` |
| `crosvm_bin.annotation(crate = "devices")` | `crosvm-resize-display-devices`, `crosvm-flush-held-dmabuf-devices` |
| `crosvm_bin.annotation(crate = "rutabaga_gfx")` | `rutabaga_gfx_build_rs`, `rutabaga_gfx-gralloc-vulkano-fallback`, `rutabaga_gfx-cleanup-on-drop`, `rutabaga_gfx-gfxstream-3d-resource-info`, `rutabaga_gfx-on-demand-export-and-query` |
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

#### `PATCH.crosvm-aperfmperf.patch`, `PATCH.hypervisor-aperfmperf.patch`, `PATCH.x86_64-aperfmperf.patch`
- **Targets:** `crosvm`, `hypervisor` and `x86_64` crates. Files: `src/crosvm/{cmdline,config}.rs`, `src/crosvm/sys/linux.rs`; `src/kvm/x86_64.rs`, `src/x86_64.rs`; `src/cpuid.rs`.
- **What it does:** Adds an x86_64 `--aperfmperf` switch. Before the vCPUs are created, crosvm enables `KVM_X86_DISABLE_EXITS_APERFMPERF` (host Linux 6.17+), and the vCPUs then advertise APERF/MPERF in CPUID leaf 6. If the host kernel lacks the capability, crosvm logs a warning and the guest sees no APERF/MPERF, as before.
- **Why:** x86 guests have no cpufreq device: virt-cpufreq is aarch64-only, so the guest's `/proc/cpuinfo` reported no real frequency. With the counters the guest kernel computes each vCPU's effective MHz, read from the host core it runs on (KVM passes the raw counters through, so the value includes time the host spends in KVM for that vCPU).
