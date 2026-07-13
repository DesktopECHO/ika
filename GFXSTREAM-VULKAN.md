# GFXSTREAM-VULKAN.md

To render, a Vulkan call made by an Android app (Chromium) has a few hops to travel:

```
Android app / Chromium (ANGLE)
   │  Vulkan API
   ▼
gfxstream GUEST encoder  (mesa3d/src/gfxstream/guest — vulkan.ranchu.so)
   │  serialized command stream over virtio-gpu
   ▼
crosvm + rutabaga        (the VMM; owns guest memory + the virtio-gpu device)
   │  dispatch to the host renderer
   ▼
gfxstream HOST renderer  (libgfxstream_backend.so)
   │  real Vulkan
   ▼
Honeykrisp               (Mesa's Apple-GPU Vulkan driver)
   │
   ▼
Apple M1 Pro GPU
```

Every link has to agree on two things: *that Vulkan is turned on*, and — the hard
part — *how a chunk of GPU memory allocated on the host becomes visible to the
guest*. Almost the entire story is about that second thing.

---

## Act I — I heard somewhere it was supposed to work!

The host — an M1 Pro (`apple,j316s` / `t6000`) on Asahi Fedora
with **16 KiB memory pages** — exposes:

- **`Apple M1 Pro (G13S C0)`**, driver `DRIVER_ID_MESA_HONEYKRISP`,
  **conformance version 1.4.0.0** — a real, conformant hardware Vulkan driver, and
  the *primary* device the loader returns (llvmpipe is only the fallback).
- All the extensions a remoting renderer needs to share images:
  `VK_EXT_image_drm_format_modifier`, `VK_EXT_external_memory_dma_buf`,
  `VK_KHR_external_memory_fd`, timeline semaphores, `VK_EXT_queue_family_foreign`.
- A **unified memory architecture**: a single heap where *every* memory type is
  `DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT`.

So the hardware path was genuinely available. But two absences turned out to
define the entire rest of the project:

- **No `VK_EXT_external_memory_host`.**
- **No `VK_ANDROID_external_memory_android_hardware_buffer`.**

These are exactly the extensions Honeykrisp *doesn't* implement (the Apple GPU
kernel UAPI doesn't expose host-pointer import), and they are precisely the ones
gfxstream's default host-visible-memory strategy relies on. The Apple GPU could
render — but the standard way of handing its memory to the guest was closed.

---

## Act II — The wall: host-visible memory

When Chromium's Vulkan backend (ANGLE) allocates a buffer it can map and write to,
gfxstream on the host has to produce **host-visible, coherent memory that the
guest can also see**. There are exactly three mechanisms, and on this machine all
three were broken in different ways:

| Path | How it works | Why it failed here |
|------|--------------|--------------------|
| **SystemBlob** | Host allocates memory, imports it as a host pointer (`VK_EXT_external_memory_host`); guest maps it directly | Honeykrisp doesn't have `external_memory_host` |
| **ExternalBlob** | Host exports a `VkDeviceMemory` as a dma-buf; crosvm maps that dma-buf into the guest | crosvm couldn't map the dma-buf (see Act III) |
| **udmabuf** | Host allocates plain RAM, wraps it as a dma-buf via `/dev/udmabuf`, shares that | Failed to initialize; and its size math assumed 4 KiB pages |

The symptom the user saw was deceptively simple: Cuttlefish **booted**, the
desktop and window chrome rendered, but the *content* of every Vulkan surface —
the inside of the Chromium window — was **solid black**.

The logs told the real story, 209,000 times over:

```
guest:  ANGLE vk_helpers.cpp (map): Internal Vulkan error (-2):
        A device memory allocation has failed.        (VK_ERROR_OUT_OF_DEVICE_MEMORY)

host:   devices::virtio::gpu: Failed to map blob … gralloc failed to import
        and map, handle type: 2 [dma-buf], size 16384: invalid gralloc backend
```

Chromium asked for memory, gfxstream exported it as a dma-buf, and **crosvm had no
way to map that dma-buf into the guest.** Everything upstream worked; the bridge
at the very bottom did not.

---

## Act III — The required backend was disabled

Why couldn't crosvm map an Apple-GPU dma-buf? Because crosvm's buffer allocator,
`rutabaga_gralloc`, has three backends and none of them applied:

- **system** — plain memory; can't import a dma-buf.
- **minigbm** — Google's own gbm implementation, with a driver backend compiled in
  per SoC: `virtio_gpu`, `i915`, `amdgpu`, `radeon`, `mediatek`, `rockchip`.
  **There is no `asahi` backend.** So `gbm_create_device()` on the
  Apple GPU's render node (`/dev/dri/renderD128`, driver `asahi`, `apple,agx-t6000`)
  fails, minigbm is silently skipped, and only the useless `system` backend
  remains → *"invalid gralloc backend."*
- **vulkano** — maps dma-bufs *through Vulkan itself* (`VK_EXT_external_memory_dma_buf`),
  which Honeykrisp fully supports. This is the one that could work.

And here was the twist. crosvm **deliberately disables the vulkano backend on
Linux.** A 2024 upstream commit (`8d633edf60`, *"rutabaga_gfx: gralloc: don't
always start Vulkano"*) added a single line:

```rust
let flags = RutabagaGrallocBackendFlags::new().disable_vulkano();
```

The assumption — *"Linux has gbm, so it doesn't need Vulkano"* — 
breaks on Apple Silicon. minigbm has no asahi driver.
Re-enabling it wasn't fighting a correctness decision; it was restoring
the fallback Windows already relies on, for the platform where the default
no longer holds. 

The fix is two parts, both in the crosvm build:
- Add the `vulkano` cargo feature (its `0.33.0` dep tree was already in `Cargo.lock`).
- **`PATCH.crosvm-enable-vulkano-gralloc.patch`** — remove the `.disable_vulkano()`
  call so the backend actually initializes.

With that, crosvm's `resource_map_blob` takes the `VmMemorySource::Vulkan` branch,
imports the dma-buf via Honeykrisp, and maps it into the guest.

---

## Act IV — udmabuf, and the tyranny of the 4 KiB page

Vulkano gralloc solved *mapping*. But the cleanest way to *produce* the
host-visible memory in the first place — given no `external_memory_host` — is
**udmabuf**: allocate ordinary host RAM in a `memfd`, and use the kernel's
`/dev/udmabuf` driver to wrap those pages as a dma-buf. No GPU allocator required
for the allocation; the memory is CPU RAM that the guest maps directly and the GPU
imports as a dma-buf.

gfxstream has a `VulkanAllocateHostVisibleAsUdmabuf` feature for exactly this. It
had never worked here, for three compounding reasons — each fixed by a patch:

1. **The Linux creator wasn't even built.**
   `UdmabufCreator` had a real Linux implementation and a stub, and the packaged
   host build was compiling the stub. `PATCH.gfxstream.linux_udmabuf_creator.patch`
   selects the real `UdmabufCreator_linux.cpp` on Linux hosts, so
   `open("/dev/udmabuf")` actually happens.

2. **The memfd couldn't become a udmabuf.**
   `UDMABUF_CREATE` requires the source `memfd` to be **sealed** against shrinking.
   `PATCH.gfxstream.memfd_udmabuf_seals.patch` creates the memfd with
   `MFD_ALLOW_SEALING` and applies `F_SEAL_SHRINK`/`GROW`/`SEAL`, so the kernel
   accepts it.

3. **The size math assumed 4 KiB pages.**
   gfxstream hardcoded `kPageSizeforBlob = 4096`. On a 16 KiB-page host, blob sizes
   were rounded to the wrong granularity and `UDMABUF_CREATE` rejected them with
   `EINVAL`. `PATCH.gfxstream.blob_page_size_runtime.patch` changes it to
   `getpagesize()` — inert on x86-64 (still 4096), correct on Apple Silicon.

Two more pieces made the kernel side cooperate, in `cuttlefish-host-resources`:
- **`modprobe udmabuf`** at host-resource startup, so `/dev/udmabuf` exists before
  Cuttlefish launches.
- **Tuning** the module's stingy defaults (`list_limit`, `size_limit_mb` → 8192 /
  256 MB), because a desktop compositor allocating many large host-visible buffers
  blows straight through the stock caps.

Finally, `crosvm_manager.cpp` was taught to pass the `ExternalBlob` / `SystemBlob`
renderer features (and the derived `external-blob=` / `system-blob=` crosvm params)
through to the GPU device, so the host renderer and the VMM agree on which blob
transport is in use.

---

## Act V — The black rectangle that lied

With host-visible memory finally flowing, the guest came alive — Chromium's ANGLE
reported Vulkan on Virtio-GPU GFXStream, and the previous allocation failures were
gone. But a *new* black rectangle appeared: the **host console** (the scrcpy /
`ika_stream` window showing the VM) was black, even though the guest framebuffer
and Chromium were demonstrably rendering.

This is the trap that makes graphics bugs expensive: the same symptom (black) at a
different layer. The cause was the Vulkan **WSI** (window-system integration).
Turning Vulkan on had also set `wsi=vk` on crosvm, which enabled gfxstream's
**native Vulkan swapchain** for the host display path. In udmabuf-backed mode that
path fed **zero-filled scanout frames** into `ika_stream` — the guest was fine;
the host's *view* of it was the thing that was black.

`83c6d38` fixed it by decoupling the two: **skip automatic Vulkan WSI when
`VulkanAllocateHostVisibleAsUdmabuf` is enabled.** The guest keeps its accelerated
Vulkan; the host console stays on the working GLES display/readback path. The same
commit taught the Wayland connector to pass DMA-BUF frames through with their
advertised plane offsets, and to stop handing new SHM clients zero-filled slots.

---

## Act VI — The guest's half of the deal

The host could now render and share memory, but the **guest** gfxstream driver had
its own ways of producing black surfaces, fixed in `external-mesa3d.patch`:

- **DRM format modifiers.** When the host advertises modifier support (Honeykrisp
  does), a guest image query must stay on the host pass-through path. The original
  code fell into a linear-emulation fallback that stripped `COLOR_ATTACHMENT` /
  `INPUT_ATTACHMENT` usage — which is exactly how a render target ends up unable to
  be rendered to, i.e. black. This is carried in `external-mesa3d.patch`.
- **AHardwareBuffer layout on sync2 barriers.** Android doesn't pass the current
  `VkImageLayout` for imported AHBs. On a queue-family ownership transfer with
  `oldLayout == UNDEFINED`, the contents are discarded. ResourceTracker already
  worked around this for the legacy barrier path; the patch extends it to every
  modern sync2 entry point that carries a `VkDependencyInfo` with image
  barriers -- `vkCmdPipelineBarrier2`/`KHR` (the path ANGLE actually uses),
  plus `vkCmdSetEvent2`/`KHR` and `vkCmdWaitEvents2`/`KHR` for native Vulkan
  apps that synchronize with events instead of barriers.
- **Extension exposure** (`1f93451`). Advertise the gfxstream Vulkan extensions
  whose backing feature structs and encoder paths already exist — 16-bit storage,
  `maintenance5`, host image copy, KHR vertex-attribute-divisor,
  external-memory-acquire-unmodified — so Android's Vulkan profile and benchmark
  detection see the real capabilities, *without* re-enabling native WSI and
  undoing the console fix.

---

## The payoff

After rebuilding and reinstalling the host package and the guest ROM:

```
--gfxstream_vulkan=auto
→ Chromium: ANGLE Vulkan 1.4.341 via Virtio-GPU GFXStream on Apple M1 Pro
→ previous VK_ERROR_OUT_OF_DEVICE_MEMORY and context-init failures: gone
```

`auto` now leaves Cuttlefish's normal GLES+Vulkan context selection intact on
Apple Silicon. The launcher only adds the 16 KiB-specific udmabuf/ExternalBlob
memory configuration; `on` remains available as an explicit context override.

Android's Vulkan, inside a VM, accelerated by the Apple Silicon GPU.

---

## Why it was hard (and what it means)

The **remoting infrastructure had one load-bearing assumption
baked in at three layers**: *the host can hand GPU memory to the guest via
`external_memory_host` or via gbm.* Apple Silicon has neither. So the fix wasn't a
single flag; it was rerouting the host-visible-memory bridge onto the one path the
hardware does support — **udmabuf-backed dma-bufs, mapped through the GPU's own
Vulkan (Vulkano)** — and then paying off every place that had assumed 4 KiB pages,
a bundled gbm driver, host-pointer import, or native WSI.

The through-line: this Linux host behaves like **Windows**, not like a normal
Linux GPU host. Most of the effort was convincing four codebases of that one fact.

### Loose threads

- ~~**The crosvm vulkano change is currently unconditional.**~~ Resolved by
  `PATCH.rutabaga_gfx-gralloc-vulkano-fallback.patch`: rutabaga's gralloc now
  only *starts* Vulkano when minigbm failed to initialize (so x86-64 hosts keep
  the tested minigbm path and skip the Vulkan-instance startup cost upstream
  disabled the backend for), and only *selects* Vulkano for allocations when it
  actually initialized (upstream picked it whenever the feature was compiled
  in, even after a failed init). Same binary, right backend on each platform;
  `PATCH.crosvm-enable-vulkano-gralloc.patch` still removes
  `.disable_vulkano()` so the gate — not a hardcoded flag — decides.
- The gfxstream patches (`getpagesize()`, memfd seals, Linux UdmabufCreator) are
  inert or standard on x86-64 and safe to keep global.
---

## Change inventory

| Change | Layer | Purpose |
|--------|-------|---------|
| `PATCH.crosvm-enable-vulkano-gralloc.patch` + `vulkano` feature | crosvm | Give crosvm a gralloc backend that can map the Apple GPU's dma-bufs |
| `PATCH.gfxstream.linux_udmabuf_creator.patch` | gfxstream host | Build the real Linux udmabuf creator instead of the stub |
| `PATCH.gfxstream.memfd_udmabuf_seals.patch` | gfxstream host | Seal memfds so `UDMABUF_CREATE` accepts them |
| `PATCH.gfxstream.blob_page_size_runtime.patch` | gfxstream host | 16 KiB-page-correct blob sizing (`getpagesize()`) |
| `crosvm_manager.cpp` | cuttlefish host | Pass ExternalBlob/SystemBlob features + blob params to crosvm; keep console off native WSI |
| `wayland_*` + `ika_stream` (`83c6d38`) | cuttlefish host | Host console on GLES readback; DMA-BUF frames with correct offsets; no zero-filled SHM |
| `modprobe.d` + `cuttlefish-host-resources.sh` | host provisioning | Load and tune the udmabuf kernel module |
| `external-mesa3d.patch` | guest mesa3d | DRM-modifier passthrough, AHB sync2 layout, extension exposure |
| `tools/ika` | launcher | Apple-Silicon-16K gating: udmabuf-backed ExternalBlob, SystemBlob off |
