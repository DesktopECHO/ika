[README](README.md) | [Using Ika](USAGE.md) | [Configuration](CONFIGURATION.md) | **Graphics** | [Building](BUILDING.md) | [Downloads](DOWNLOADS.md) | [Changelog](CHANGELOG.md)

# Graphics

Android draws with the host's GPU. Its OpenGL ES and Vulkan calls are encoded
in the guest, carried over virtio-gpu by crosvm, and run on the host's
drivers by gfxstream, or by virglrenderer in the `venus` mode. This page explains the GPU modes, how Ika chooses one,
the switches that tune them, what Apple Silicon needs, and what to do when
something looks wrong.

## GPU modes

| Mode | What it does | Use it for |
| --- | --- | --- |
| `gfxstream_guest_angle` | The default where `venus` does not suit the host (see [How Ika chooses](#how-ika-chooses)). ANGLE in the guest turns OpenGL ES into Vulkan, which gfxstream runs on the host's Vulkan driver | Everything: games, Vulkan apps, the desktop |
| `gfxstream` | gfxstream sends OpenGL ES to its own translator on the host's OpenGL driver; Vulkan is optional | Hosts whose only Vulkan driver is a software one, and titles that render wrongly through ANGLE |
| `guest_swiftshader` | The guest renders on the CPU (ANGLE and SwiftShader) | Ruling out a host GPU problem; turns [low-CPU mode](CONFIGURATION.md#low-cpu-mode) on |
| `guest_lavapipe` | The guest renders on the CPU with Mesa's lavapipe (Vulkan 1.4) and ANGLE | The same, with Vulkan 1.4 instead of SwiftShader's 1.3; turns low-CPU mode on |
| `venus` | The default on a GPU with Vulkan 1.3 or newer and ETC2 textures. Mesa's Venus Vulkan driver in the guest, over virglrenderer on the host's Vulkan driver, with ANGLE for OpenGL ES | Everything, with less of the host's CPU than gfxstream (see [Venus](#venus)) |

The two gfxstream modes differ in where OpenGL ES is translated:

|  | `gfxstream_guest_angle` | `gfxstream` |
| --- | --- | --- |
| OpenGL ES in the guest | ANGLE | gfxstream's GLES encoder |
| On the host | Vulkan only | OpenGL, and Vulkan when it is on |
| OpenGL ES version | 3.2 | 3.2, or the highest the host's OpenGL ES offers |
| Vulkan in Android | Yes | Only with [Vulkan on](#vulkan-in-gfxstream-mode) |
| Game compatibility | Better | Some games render incorrectly |
| `--gfxstream_vulkan` | Ignored: Vulkan is required | Controls Vulkan |

```text
gfxstream_guest_angle:  app GLES -> ANGLE -> Vulkan -> gfxstream -> host Vulkan driver -> GPU
gfxstream:              app GLES -> gfxstream GLES encoder -> host OpenGL translator -> GPU
```

Cuttlefish accepts other modes too (`gfxstream_guest_angle_host_swiftshader`,
`gfxstream_guest_angle_host_lavapipe`, `drm_virgl`); Ika passes them through
without its own settings and does not test them.

### Vulkan version

Android tells apps the Vulkan version its driver offers
(`android.hardware.vulkan.version`, which Google Play also filters on): 1.4
with `guest_lavapipe`, 1.3 with `guest_swiftshader`, and with
`gfxstream_guest_angle`, `venus` and `gfxstream` with [Vulkan
on](#vulkan-in-gfxstream-mode) the version of the host's first Vulkan device:
1.4 on current RADV, ANV and Honeykrisp, 1.3 on GPUs such as Broadwell's, and
1.1 on a Vulkan 1.2 GPU such as Haswell's, as Android has no 1.2 level. With
OpenGL ES only, Android has no Vulkan driver and declares no Vulkan features.
Ika's ROM installs each guest Vulkan driver as its own package, and the host
tools activate the one the guest loads and select the matching version.

### How Ika chooses

With `gpu_mode` at `auto`, the default, `ika start` looks at the host's
Vulkan devices:

- `gfxstream` when every Vulkan device `vulkaninfo --summary` lists is a
  software one (llvmpipe, lavapipe or SwiftShader), or gfxstream would pick
  llvmpipe over the GPU: it is much lighter on the CPU there. gfxstream ranks
  a device by its type and its Vulkan version, so a GPU with an older Vulkan
  loses to llvmpipe: a Haswell GPU offers Vulkan 1.2, llvmpipe 1.4. In
  `gfxstream` mode that host renders OpenGL ES on its GPU instead; a 1080p
  video that dropped 62% of its frames with `gfxstream_guest_angle` dropped
  1%.
- `venus` when the first Vulkan device is a GPU with Vulkan 1.3 or newer and
  ETC2 compressed textures, as Venus's guest sees them. Android expects ETC2
  of a Vulkan device, and Chromium's GPU process quits without it; gfxstream
  emulates ETC2 itself, Venus does not. crosvm starts Venus's host side with
  `vk_require_etc2=true` and `vk_require_astc=true`, which make RADV emulate
  both, so Ika asks `vulkaninfo` with the same settings. Broadwell's and
  Apple Silicon's drivers have ETC2 of their own; Haswell's cannot offer it
  at all.
- `gfxstream_guest_angle` otherwise.

`--gpu_mode=` on the command line wins over all three. A mode named in
`gpu_mode` in the `[gpu]` section of `ika.ini` replaces the last two: a host
of the first kind still uses `gfxstream`.

```bash
ika restart --gpu_mode=gfxstream
ika restart --gpu_mode=gfxstream_guest_angle
```

The start line says which path Android renders through, and
`~/ika/ikastart.log` logs each choice Ika made, with the reason when `auto`
does not pick `venus`.

## Vulkan in gfxstream mode

`--gfxstream_vulkan=auto|on|off` (`gfxstream_vulkan` in `[gpu]`,
`GFXSTREAM_VULKAN`) decides whether Android has Vulkan in the `gfxstream`
mode. The other modes ignore it.

| Value | Effect |
| --- | --- |
| `auto` (default) | Vulkan stays on, except when the host's first Vulkan device is llvmpipe, or gfxstream would pick llvmpipe over the GPU: then Android has OpenGL ES only, and no Vulkan driver |
| `on` | OpenGL ES and Vulkan |
| `off` | OpenGL ES only, and no Vulkan driver in Android |

A `--gpu_context_types=` option of your own wins over it.

## Host cached memory

`host_cached_memory = on` in `[gpu]` (`--host_cached_memory=on`,
`IKA_HOST_CACHED_MEMORY=on`) changes where the guest's host-visible Vulkan
memory comes from. Android writes its uploads, such as textures and vertex
data, straight into that memory. When the host driver would give it a
write-combined type, which is slow for those writes on some drivers, gfxstream
takes a cached coherent type of the same heap instead (its
`VulkanPreferHostCachedMemory` feature).

It applies to the modes with Vulkan, and only where the driver's type is
host-visible, uncached and not device-local, and a cached coherent type exists
in the same heap. It changes nothing where every type is device-local, as on
Apple Silicon. Memory shared with a color buffer or a buffer, and dedicated
allocations, keep their type.

It is off by default, as its effect on the Mesa drivers Ika runs on is not
known: try it on yours, for example with GFXBench's offscreen tests in Android
before and after, and keep it if it helps.

## Venus

`--gpu_mode=venus` runs Android's Vulkan on Mesa's Venus driver, which sends
the Vulkan calls to virglrenderer on the host and the host's own Vulkan driver,
with ANGLE for OpenGL ES; buffers are allocated through crosvm's cross-domain
context. Ika's ROM has it from Mesa 26.3 on.

```bash
ika restart --gpu_mode=venus
```

On an AMD host (Radeon 780M, RADV) and on an M1 Pro (Honeykrisp) Android
draws its desktop and Chromium's pages, with Vulkan 1.4 and OpenGL ES 3.2
through ANGLE. Apps see every Vulkan device the host has, llvmpipe included,
each named "Virtio-GPU Venus (...)". Upstream tests it on Intel (ANV) and
Qualcomm (Turnip) hosts.

It is the default on a host whose GPU suits it (see
[How Ika chooses](#how-ika-chooses)), Apple Silicon included; Ika has not
tested it on NVIDIA's GPUs. Against `gfxstream_guest_angle` on a
Radeon 780M, a WebGL page with 12,800 draw calls a frame ran at 60 fps instead
of 24, and crosvm and the render server used about 40% less of the host's CPU,
for WebGL and video alike; a Broadwell MacBook Air was faster with it too. On
Intel's Broadwell and Haswell GPUs ANGLE over Venus offers OpenGL ES 3.1, not
3.2, as their drivers cannot sample ASTC textures; gfxstream emulates them.

On an M1 Pro Venus used 20 to 40% less of the host's CPU than
`gfxstream_guest_angle` and scrolled without dropped frames, but games ran a
little slower: Asphalt 9 averaged 56.5 fps instead of 59.5, with 6.3% of its
frames taking 24 ms or longer instead of 1.5%. Honeykrisp compresses the
textures Venus's guest creates, losslessly, which halves the speed of random
reads from textures whose content does not compress; gfxstream's end up
uncompressed. For games there, `--gpu_mode=gfxstream_guest_angle`, or
`gpu_mode = gfxstream_guest_angle` in `ika.ini`.

What Ika changes for it:

- crosvm maps Venus's GPU memory into the guest within one region it
  registers at the first mapping (fixed blob mapping), as Asahi's muvm does.
  On arm64 hosts without stage-2 forced write-back, Apple Silicon among them,
  KVM refuses a separate memory slot for each such buffer, so every mapping
  failed there.
- crosvm loads the `libvirglrenderer` of Ika's package, not the system's:
  Debian 13's older one made the guest's Venus driver stop at Vulkan 1.3.
- Where the host driver refuses a raised queue priority, as Honeykrisp does,
  virglrenderer creates the device at medium priority instead of failing:
  SurfaceFlinger asks ANGLE for a high-priority context.

## What Ika adds for some hosts

- **AMD (RADV):** in the gfxstream modes, Ika adds `syncshaders` to
  `RADV_DEBUG`, keeping options you set there, so that RADV's asynchronous
  shader compilation cannot run incomplete transform-feedback pipelines. On
  Vega and older GPUs, gfxstream also allocates Vulkan memory as device memory
  only (`VulkanAllocateDeviceMemoryOnly`), against host-visible memory
  corruption. Cuttlefish warns when an AMD host's kernel is older than 6.13.
- **WSL2:** the GPU through Ika's own build of Mesa Dozen, a Vulkan layer and
  a D3D12 shim; see [WSL2](#wsl2).
- **Every host:** the gfxstream modes run with `EGL_PLATFORM=surfaceless`
  unless you set it, and with gfxstream's renderer features
  `MinimalLogging:disabled` and `VulkanBatchedDescriptorSetUpdate:disabled`
  (`gpu_renderer_features` in `[gpu]`).

## Apple Silicon

### What the host needs

- Fedora Asahi Remix with its 16 KB-page kernel. The kernel must have the
  fix of [AsahiLinux/linux#548](https://github.com/AsahiLinux/linux/pull/548),
  as Fedora's `7.1.6-400.asahi.fc44.aarch64+16k` and later do: without it,
  the GPU keeps the memory Android shared with it until the host reboots.
- Mesa 26.1 or newer, for the Honeykrisp Vulkan driver.
- The `udmabuf` kernel module. `ika-base` enables the
  `cuttlefish-host-resources` service, which loads it at boot and raises its
  limits to 8192 buffers of up to 256 MB. Other values go in
  `/etc/sysconfig/cuttlefish-host-resources` (Fedora, Arch Linux) or
  `/etc/default/cuttlefish-host-resources` (Debian, Ubuntu).

Android boots its 16 KB kernel on 16 KB hosts (`kernel_page_size` in
`[system]`).

### How it works

Honeykrisp has neither `VK_EXT_external_memory_host` nor
`VK_ANDROID_external_memory_android_hardware_buffer`, the extensions gfxstream
normally uses to share host memory with the guest. On Apple Silicon hosts with
16 KB pages, Ika uses the path the Apple GPU supports instead:

- gfxstream allocates the guest's host-visible memory as a sealed memfd,
  wraps it as a DMA-BUF with `/dev/udmabuf` and exports it to crosvm
  (`ExternalBlob` on, `SystemBlob` off, `VulkanAllocateHostVisibleAsUdmabuf`
  and `VulkanUseDedicatedAhbMemoryType` on). These four features take Ika's
  values whatever `gpu_renderer_features` says. Blob sizes follow the host's
  page size.
- crosvm imports those DMA-BUFs through Vulkan, with rutabaga's Vulkano
  gralloc backend, as minigbm has no driver for the Apple GPU. Vulkano starts
  only when minigbm cannot, so other hosts keep minigbm.
- The host display path does not use gfxstream's Vulkan swapchain, which
  would show blank frames with udmabuf memory.
- The console gets each frame as a DMA-BUF: the shown color buffer is
  re-created with an explicit DRM format modifier the first time crosvm
  exports it, which Asahi, radeonsi, iris and NVIDIA all import.
- In the guest, gfxstream's Vulkan driver passes DRM-modifier queries through
  to the host, and keeps the layout of imported hardware buffers across
  `vkCmdPipelineBarrier2` ownership transfers.
- Android gets OpenGL ES 3.2 here too. ANGLE offers geometry and tessellation
  shaders, which 3.2 requires, only if it can count primitives for
  `GL_PRIMITIVES_GENERATED`, and Honeykrisp has no
  `VK_EXT_primitives_generated_query`, so ANGLE would stop at 3.1. When the
  host GPU lacks that extension but has pipeline statistics queries, as
  Honeykrisp does, the host tools turn on ANGLE's
  `allowPipelineStatisticsForPrimitivesGeneratedQuery`, which counts them with
  a pipeline statistics query instead.
- gfxstream runs with glibc's `arena_max=4` and `trim_threshold=131072`, to
  keep its memory use down.

`ika start` notes the host's udmabuf count, and `ika stop` compares it with
the count after Android stops: on a leak, it writes a warning to
`~/ika/ikastart.log`. It needs read access to
`/sys/kernel/debug/dma_buf/bufinfo`, or `sudo` without a password.

## WSL2

On WSL2 the only way to the GPU is Direct3D 12, through `/dev/dxg` and the
libraries in `/usr/lib/wsl/lib`. Mesa's Dozen driver offers it as Vulkan, and
gfxstream renders on that. `ika-base`, in its Debian, RPM and Arch packages,
carries its own Dozen on x86_64: Mesa 26.3.0-rc2 with the patches in [tools/wsl/mesa](tools/wsl/mesa), built by
`build-dozen.sh` with only X11 for a window system, and installed under
`/usr/lib/cuttlefish-common/wsl/dozen`. It offers Vulkan 1.3. Venus cannot run
on it: Dozen cannot export its memory as dma-bufs.

### What the host needs

- KVM in WSL: virtualization on in the firmware, Windows' Virtual Machine
  Platform, `nestedVirtualization=true` under `[wsl2]` in
  `%UserProfile%\.wslconfig`, and, on some AMD hosts, Virtualization-based
  Security off. `ls /dev/kvm` checks it.
- A Windows GPU driver with WSL support. `VK_DRIVER_FILES=/usr/lib/cuttlefish-common/wsl/dozen/dzn_icd.json vulkaninfo --summary`
  lists a `DRIVER_ID_MESA_DOZEN` device named after the GPU.
- The WSL kernel has no udmabuf: set `enable_gpu_udmabuf = false` in `[gpu]`.

### What Ika does

When `/dev/dxg` exists and `vulkaninfo` lists a Dozen GPU, Ika sets, before
choosing the GPU mode:

- `VK_DRIVER_FILES` to Ika's Dozen and Ika's Lavapipe. Lavapipe is there for
  the instance extensions gfxstream needs and Dozen does not list
  (`VK_KHR_external_memory_capabilities` and the like). A `VK_DRIVER_FILES`
  of your own wins.
- `MESA_VK_DEVICE_SELECT=<vendor>:<device>!`, which hides every other device.
  gfxstream would otherwise pick Lavapipe, which supports more of what it
  looks for. A `MESA_VK_DEVICE_SELECT` of your own wins.
- `IKA_DZN_FIX=1`, which turns on the `VK_LAYER_IKA_dzn_fix` Vulkan layer
  ([tools/wsl/ika_dzn_fix.c](tools/wsl/ika_dzn_fix.c)). It works around
  Dozen's gaps:
  - It works around a crash in Dozen's
    `vkGetPhysicalDeviceImageFormatProperties2`.
  - It offers `VK_EXT_provoking_vertex`, without which ANGLE stops at OpenGL
    ES 2.0. Flat-shaded values come from the first vertex.
  - For Android's Vulkan, it offers `samplerYcbcrConversion`, which
    Chromium's Vulkan backends need. The conversion is skipped, so YCbCr
    images are sampled as they are.
  - For Android's Vulkan, it creates images and views of the 4:2:0 YUV formats
    Dozen cannot sample, such as YV12's three-plane one (D3D12 has none), as
    RGBA8. Ika's gfxstream keeps such a buffer as RGBA8 too, converted from the
    guest's YUV bytes, so a software video decoder's frames show with their
    colors; SurfaceFlinger aborted on them before, restarting Android.
  - It offers `fullDrawIndexUint32` and the full 32-bit index range, which
    D3D12 has but Dozen does not report. Chrome draws with Skia Graphite on
    Dawn, and Dawn's Vulkan backend requires the feature: without it Chrome
    exits at start ("GPU process isn't usable").
  - It pushes push constants again after a switch to another pipeline
    layout. Dozen loses them on that switch, and ANGLE pushes them once per
    render pass, so SurfaceFlinger drew no textures in a frame that began
    with an untextured draw, and the display went black. Ika's Dozen has
    this fix too; the layer keeps it for the distribution's.
  - It keeps gfxstream's ETC2 and ASTC emulation from binding other images
    into a dedicated allocation, which removes the D3D12 device. Ika's
    gfxstream has this fix too.

Ika's gfxstream decodes ASTC textures on the CPU on Dozen, which has no ASTC,
as they are uploaded, instead of with its compute shaders. Those are the main
suspect in GPU hangs on WSL2 (a Radeon 780M, with Asphalt 8 and 9): Windows
reset the GPU, D3D12 removed the device and the whole VM ended. An image whose
ASTC data reaches it some way the CPU cannot decode, such as an image-to-image
copy, is still decoded on the GPU, with an "ASTC image ... decoding it on the
GPU" warning in crosvm's log. The start of the log says which: "ASTC textures
decoded on the CPU (Mesa Dozen)", and each Vulkan device's line has "CPU
decoding:on".
- The `libd3d12.so` shim ([tools/wsl/d3d12_shim.c](tools/wsl/d3d12_shim.c))
  first in `LD_LIBRARY_PATH`. It makes every Vulkan instance in crosvm share
  one D3D12 device. WSL allows about ten D3D12 devices per process, and a
  released device's GPU address space is not given back, so after about a
  hundred Android apps a device per instance runs out.

The console and app windows draw with OpenGL through Mesa's D3D12 driver
(`GALLIUM_DRIVER=d3d12`), unless you set a `GALLIUM_DRIVER`. Mesa's OpenGL
otherwise falls back to llvmpipe on WSL2, drawing every frame of the window
on the CPU: Zink, OpenGL on Dozen, refuses for lack of robustness2's
`nullDescriptor`. Where Ika found a Dozen GPU, the windows use Ika's own build
of that driver, from the same Mesa release with
[d3d12-uma-cached-upload.patch](tools/wsl/mesa/d3d12-uma-cached-upload.patch),
built by `build-d3d12-gl.sh` and installed with its EGL (`libEGL_mesa` and
`libgallium`) under `/usr/lib/cuttlefish-common/wsl/mesa-gl`, which they load
through `__EGL_VENDOR_LIBRARY_FILENAMES`; an EGL vendor file of your own wins.
Distributions' Mesa stages texture uploads in write-combined memory, which
WSL2 maps uncached: writing it ran at 383 MB/s against 13 GB/s for write-back
memory on a Radeon 780M, so each frame of a 1080p video took the window 25 ms
of CPU to upload, 70% of a core in all. Ika's build stages them in
write-back memory on integrated GPUs, where the window takes 14%.

`gpu_mode = auto` then picks `gfxstream_guest_angle`, as Venus needs the
dma-bufs Dozen cannot export. The start log has a `WSL2:` line when Ika set
this up.

On WSLg the console and app windows also load Ika's build of libdecor's GTK
plugin, which draws their title bar and shadow
([tools/wsl/libdecor](tools/wsl/libdecor), set through `LIBDECOR_PLUGIN_DIR`
unless you set it). WSLg shows each of those as a window of its own and only
removes it when it is destroyed, while the plugin hides them in fullscreen by
unmapping them: a fullscreen window kept a translucent title bar and frame on
top. Ika's build destroys them instead.

| Variable | Effect |
| --- | --- |
| `IKA_WSL_GPU_FIX=0` | Ika sets none of the above |
| `IKA_SYSTEM_DOZEN=1` | Uses the distribution's Dozen instead of Ika's |
| `DISABLE_IKA_DZN_FIX=1` | Turns the layer off |
| `IKA_DZN_FAKE_YCBCR=0` | The layer does not offer `samplerYcbcrConversion` |
| `IKA_D3D12_SHIM_DISABLE=1` | The shim creates a device for each instance |
| `IKA_D3D12_DRED=1` | The shim turns on D3D12's DRED. When the device is removed, it logs why, the GPU work in flight and the D3D12 call that removed it, to crosvm's log and `/tmp/ika-dred.log` |
| `IKA_DZN_TRACE_REMOVAL=1` | With `IKA_D3D12_DRED=1`, the layer also logs the first Vulkan call after which the device was removed |
| `IKA_ASTC_DECODE=gpu` or `cpu` | gfxstream decodes ASTC textures on the GPU or on the CPU, on any host. Without it, the CPU on Dozen and the GPU elsewhere |

### Limits on WSL2

- `adb screencap` comes out black. The console shows the screen.
- Each D3D12 device has a 4 GB window for shader-visible descriptor heaps,
  shared by every Android app.
- The GPU device runs in crosvm's second process, the one that maps
  `libvulkan_dzn.so`. crosvm installs its own crash handler, so use `prlimit`
  to get core dumps from it.

## Known limitations

- **Compressed textures through ANGLE on Apple Silicon:** some titles draw
  their compressed textures as block noise or stripes in gameplay with guest
  ANGLE on Honeykrisp; menus are fine. `--gpu_mode=gfxstream` renders them
  correctly.
- **Lost color buffers:** gfxstream's renderer can lose color buffers when apps
  are restarted repeatedly: screenshots come out magenta or black, or a stale
  frame stays. Restarting Android clears it.
- **Data-buffer hardware buffers:** the `gfxstream` mode cannot create
  `AHardwareBuffer`s used as data buffers; apps that need them work in
  `gfxstream_guest_angle`.
- **Program binaries in `gfxstream` mode:** programs loaded with
  `glProgramBinary` report that they are not linked, so apps compile their
  shaders from source.
- **Host image copy:** `VK_EXT_host_image_copy` is not offered to Android;
  uploads go through staging buffers.
- **Several GPUs:** gfxstream picks the host GPU it scores best (discrete
  before integrated), while Ika's software-driver and RADV checks look at
  `vulkaninfo`'s first device, so on a host with several GPUs the two can
  differ.

[lineageos/docs/app-compatibility.md](lineageos/docs/app-compatibility.md)
lists how individual games render in each mode.

## Troubleshooting

- **Check what Ika chose:** the start line names the graphics path, and
  `~/ika/ikastart.log` has the GPU decisions: the mode `auto` picked and
  why, Vulkan in `gfxstream` mode,
  the Apple Silicon setup, the RADV settings, host cached memory and the
  reason for low-CPU mode.
- **Logs:** `~/ika/cuttlefish/instances/cvd-1/logs/launcher.log` has
  Cuttlefish's checks and crosvm's and gfxstream's output, with `logcat` and
  `kernel.log` beside it; `cuttlefish_config.json` in the instance folder has
  the settings Android ran with.
- **Vulkan devices:** `vulkaninfo --summary` on the host, and
  `adb shell vulkaninfo --summary` in Android.
- **Rule out the host GPU:** `ika restart --gpu_mode=guest_swiftshader`
  renders on the CPU. If the problem goes away, it is in the host's driver or
  in gfxstream.
- **A game renders wrongly:** try the other gfxstream mode,
  `ika restart --gpu_mode=gfxstream`, and back with
  `--gpu_mode=gfxstream_guest_angle`.
- **Black Vulkan surfaces on Apple Silicon:** check that `/dev/udmabuf`
  exists and that `systemctl status cuttlefish-host-resources` is active.

## Where the changes are

- The ROM's patches, guest Mesa included:
  [lineageos/patches/README.md](lineageos/patches/README.md).
- gfxstream's host patches:
  [base/cvd/build_external/gfxstream/gfxstream.MODULE.bazel](base/cvd/build_external/gfxstream/gfxstream.MODULE.bazel),
  with a comment for each.
- crosvm's patches:
  [base/cvd/build_external/crosvm/README.md](base/cvd/build_external/crosvm/README.md).
- Ika's GPU settings: the GPU functions in [tools/ika](tools/ika).
- The WSL2 layer and shim: [tools/wsl](tools/wsl).
