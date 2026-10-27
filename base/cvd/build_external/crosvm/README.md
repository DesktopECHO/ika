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

#### `PATCH.gpu_display-release-import-order.patch`, `PATCH.crosvm-unref-display-imports-devices.patch`
- **Targets:** `gpu_display` crate (`src/lib.rs`, `src/gpu_display_android.rs`) and `devices` crate (`src/virtio/gpu/virtio_gpu.rs`). A backport of upstream crosvm f1d0ffe ("devices: virtio: gpu: Track import surface_id") without its tests and the stub display's test support. The `devices` patch is named to sort after the other `virtio_gpu.rs` patches.
- **What it does:** A resource keeps its display import per surface (`surface_id` to `import_id`) instead of a single one, and `unref_resource()` releases them all when the guest frees the resource. `DisplayT::release_import()` and `GpuDisplay::release_import()` take `(surface_id, import_id)`, the order the backends implement; the generic layer had them swapped, which went unnoticed because nothing called it. The Android backend no longer adds an empty map when it releases an import of a surface it has none for.
- **Why:** Nothing released a display import, so the compositor (`ika_stream`) kept every scanout buffer the guest had ever shown, and its memory, until the VM stopped: three dma-bufs for each app window opened and closed. `display_wl.c` also keeps at most 64 imports (`MAX_BUFFER_COUNT`).

#### `PATCH.crosvm-media-errors.patch`
- **Targets:** `devices` crate. File: `src/virtio/media/decoder_adapter.rs`. Made on top of `PATCH.crosvm-media-decoder-input-size.patch` and `PATCH.crosvm-media-decoder-visible-size.patch`, and named to sort after them.
- **What it does:** The virtio-media video decoder logs a `NotifyError` or `ResetCompleted` event from the backend and carries on, where both were `todo!()`. A failed `decode()` logs the backend's error before the guest gets `EIO`.
- **Why:** When the VA-API backend fails to decode a buffer, it fails that `decode()` call and queues `NotifyError`. The `todo!()` panicked, and the panic took crosvm and the VM down: an H.264 stream with a level cros-codecs rejects did it on its first frame. The cause was never logged: `decode()` dropped the backend's error.

#### `PATCH.crosvm-media-direct-decode.patch`
- **Targets:** `devices` crate. Files: `src/virtio/video/decoder/backend/mod.rs`, `src/virtio/video/decoder/backend/vaapi.rs`, `src/virtio/media/decoder_adapter.rs`. Made on top of the three `crosvm-media-*` patches above.
- **What it does:** The VA-API backend decodes straight into the guest's CAPTURE buffers where it can. The adapter makes each buffer's memfd a DMA-BUF with udmabuf and hands it over as a `VirtioObject` resource, which the backend imports in the layout of the driver's own NV12 decoder surfaces, Intel Y tiles (`I915_FORMAT_MOD_Y_TILED`), and it syncs each picture before the guest learns it is ready. It imports with DRM PRIME 2, or with the older DRM PRIME (`VASurfaceAttribExternalBuffers`, tiling as a flag) for drivers that ignore the former, i965 among them. Haswell and older GPUs with two memory channels write the tiles bit-6 swizzled (bit 6 flipped where bit 9 is set). The guest asks for the layout with the CAPTURE format `IKYT` (TRY_FMT, then S_FMT); the adapter answers with `IKYT`, or `IKYS` for swizzled tiles, only when the backend gives a layout for the stream: the VA display's render node is driven by i915 on a GPU that shares the CPU's last-level cache (`I915_PARAM_HAS_LLC`), the driver's surfaces export as one NV12 buffer in Y tiles with the chroma plane after whole rows of tiles, the stream is 8-bit 4:2:0, and a self-test, run once when the first session opens, decoded an embedded 176x144 H.264 frame that way into the picture software decoders make: it tries DRM PRIME 2, then DRM PRIME, and reads the picture as unswizzled and as swizzled tiles, and the first combination that comes out right is how sessions decode. Otherwise G_FMT, S_FMT and the copy are as before. crosvm logs the self-test's outcome and why a stream is copied.
- **Why:** The backend decoded into its own surfaces and copied each picture into guest memory through a VA image, which un-tiles Y-tiled surfaces on the CPU (iHD's `CpuSwizzleBlt`): crosvm's media worker took about 17% of a CPU for 1080p30 H.264 on a Broadwell MacBook Air, and the guest copied the picture again into its YV12 block. The self-test decodes because reading an imported surface back with `vaGetImage` gives zeros on iHD and i965, and i965 (2.4) takes a DRM PRIME 2 import without complaint and decodes into memory of its own. Other GPUs are left alone: their layouts are not what the guest un-tiles, and without a shared cache what the GPU writes to memory is not what the CPU reads.

#### `PATCH.crosvm-media-last-buffer.patch`
- **Targets:** `devices` crate. File: `src/virtio/media/decoder_adapter.rs`. Made on top of the four `crosvm-media-*` patches above, and named to sort after them.
- **What it does:** The adapter keeps one CAPTURE buffer away from the backend, to return empty with `V4L2_BUF_FLAG_LAST` when a drain (`V4L2_DEC_CMD_STOP`) completes. Once it has returned that buffer, the next CAPTURE buffer the guest queues is kept aside for the next drain. A buffer queued while a completed drain waits for one is returned with the LAST flag at once, through an eventfd in the session's poller that has `next_event()` hand it out before reading the backend.
- **Why:** The adapter went on treating the returned buffer as the one kept aside, so when the guest queued it again it went to the backend, and the next drain returned it while the backend still had it. Android's V4L2 HAL queues the empty LAST buffer straight back, and the FFmpeg backend then refused it as "already ready for use": Chrome's H.264 playback stopped the second time a looping clip ended, in 11 of 29 one-minute runs on an M1 Pro MacBook Pro. The VA-API backend does not check, so there the buffer could be in the backend and in the guest at once. A buffer queued while a drain waited for one was dropped (an upstream `TODO`), which would have stalled the queue for a guest that queues the LAST buffer again only after its next drain.

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

#### `PATCH.crosvm-fixed-blob-mapping-virglrenderer.patch`
- **Targets:** `crosvm_bin`. File: `src/crosvm/sys/linux/gpu.rs`.
- **What it does:** Keeps `fixed_blob_mapping` for the virglrenderer backend (`--gpu_mode=venus`) when crosvm is built with Vulkano and Vulkan is on; upstream turns it off then, because opaque-fd blobs need a Vulkan import that fixed mapping cannot do.
- **Why:** Fixed blob mapping maps each blob into one shared region registered at the first mapping, instead of a KVM memory slot per blob. arm64 KVM refuses a new memory slot over a cacheable `VM_PFNMAP` mapping (a dma-buf or udmabuf `mmap`) on hosts without FEAT_S2FWB, Apple Silicon among them, so every Venus blob mapping failed there and SurfaceFlinger crashed. Asahi's muvm maps GPU memory the same way. Venus's blobs are dma-bufs or shm on the drivers Ika runs on.

#### `PATCH.crosvm-fixed-blob-mapping-dmabuf-devices.patch`
- **Targets:** `devices` crate. File: `src/virtio/gpu/virtio_gpu.rs`.
- **What it does:** With fixed blob mapping, maps a dma-buf blob that also carries Vulkan info directly, instead of through a Vulkan import.
- **Why:** The cross-domain buffers the Vulkano gralloc allocates carry Vulkan info, so they took the Vulkan import path, which fixed mapping cannot take: in Venus mode on Apple Silicon the guest could not map buffers the CPU reads, such as screenshots.

#### `PATCH.rutabaga_gfx-gralloc-vulkano-fallback.patch`
- **Targets:** `rutabaga_gfx` crate. File: `src/rutabaga_gralloc/gralloc.rs`.
- **What it does:** Prefers a working minigbm backend and starts Vulkano only when minigbm initialization fails.
- **Why:** This preserves the established x86_64 path while allowing Apple Silicon hosts to use the upstream Vulkano backend.

#### `PATCH.rutabaga_gfx-vulkano-linear-images.patch`
- **Targets:** `rutabaga_gfx` crate. File: `src/rutabaga_gralloc/vulkano_gralloc.rs`.
- **What it does:** Creates the images Vulkano gralloc measures and allocates with linear tiling.
- **Why:** `get_image_memory_requirements` reads each plane's stride and offset with `vkGetImageSubresourceLayout`, which Vulkan allows only for linear or DRM-modifier images, and vulkano 0.33 defaults to optimal tiling, so every query failed with `OptimalTilingNotSupported`. The cross-domain context, which the guest's minigbm allocates through in `--gpu_mode=venus`, uses this backend on hosts whose GPU the bundled minigbm has no driver for (AMD, Apple Silicon); every guest buffer allocation failed there. Upstream has the same code but disables Vulkano gralloc on Linux.

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

#### `PATCH.virtio-media-mmap-offset-step.patch`
- **Targets:** `virtio-media` crate. File: `src/mmap.rs`.
- **What it does:** The offsets `MmapMappingManager` allocates for MMAP buffers, which the guest passes to `mmap()`, are 64 KiB apart instead of 4 KiB.
- **Why:** `mmap()` takes only offsets that are a multiple of the guest's page size. The 4 KiB steps put three buffers in four at offsets a guest with 16 KiB pages (the kernel Ika boots on Apple Silicon hosts) cannot map, so its V4L2 decoder failed on its second input buffer and Chrome fell back to software decoding. 64 KiB is the largest arm64 page size. The `--v4l2-proxy` camera was not affected: its offsets come from the host's driver.

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
| `crosvm_bin.annotation(crate = "devices")` | `crosvm-media-decoder-input-size`, `crosvm-media-decoder-visible-size`, `crosvm-media-errors`, `crosvm-media-direct-decode`, `crosvm-media-last-buffer`, `crosvm-resize-display-devices`, `crosvm-flush-held-dmabuf-devices` |
| `crosvm_bin.annotation(crate = "virtio-media")` | `virtio-media-mmap-offset-step` |
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
