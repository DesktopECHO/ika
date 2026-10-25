[README](README.md) | [Using Ika](USAGE.md) | [Configuration](CONFIGURATION.md) | **Graphics** | [Building](BUILDING.md) | [Downloads](DOWNLOADS.md) | [Changelog](CHANGELOG.md)

# Graphics

Android draws with the host's GPU. Its OpenGL ES and Vulkan calls are encoded
in the guest, carried over virtio-gpu by crosvm, and run on the host's
drivers by gfxstream. This page explains the GPU modes, how Ika chooses one,
the switches that tune them, what Apple Silicon needs, and what to do when
something looks wrong.

## GPU modes

| Mode | What it does | Use it for |
| --- | --- | --- |
| `gfxstream_guest_angle` | The default. ANGLE in the guest turns OpenGL ES into Vulkan, which gfxstream runs on the host's Vulkan driver | Everything: games, Vulkan apps, the desktop |
| `gfxstream` | gfxstream sends OpenGL ES to its own translator on the host's OpenGL driver; Vulkan is optional | Hosts whose only Vulkan driver is a software one, and titles that render wrongly through ANGLE |
| `guest_swiftshader` | The guest renders on the CPU (ANGLE and SwiftShader) | Ruling out a host GPU problem; turns [low-CPU mode](CONFIGURATION.md#low-cpu-mode) on |
| `venus` | Mesa's Venus Vulkan driver in the guest, over virglrenderer | Not available: Ika's ROM does not support it (see [Venus](#venus)) |

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
`gfxstream_guest_angle_host_lavapipe`, `guest_lavapipe`, `drm_virgl`); Ika
passes them through without its own settings and does not test them.

### How Ika chooses

`ika start` uses `gfxstream_guest_angle`, unless every Vulkan device
`vulkaninfo --summary` lists is a software one (llvmpipe, lavapipe or
SwiftShader), or gfxstream would pick llvmpipe over the GPU: then it uses
`gfxstream`, which is much lighter on the CPU there. gfxstream ranks a
device by its type and its Vulkan version, so a GPU with an older Vulkan
loses to llvmpipe: a Haswell GPU offers Vulkan 1.2, llvmpipe 1.4. In
`gfxstream` mode that host renders OpenGL ES on its GPU instead; a 1080p
video that dropped 62% of its frames with `gfxstream_guest_angle` dropped 1%.
`--gpu_mode=` on the command line wins over both; `gpu_mode` in the `[gpu]`
section of `ika.ini` (`auto` unless set, which is `gfxstream_guest_angle`)
sets the mode for hosts with a hardware Vulkan driver.

```bash
ika restart --gpu_mode=gfxstream
ika restart --gpu_mode=gfxstream_guest_angle
```

The start line says which path Android renders through, and
`~/ika/ikastart.log` logs each choice Ika made.

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

`--gpu_mode=venus` runs Android's Vulkan on Mesa's Venus driver over
virglrenderer, with ANGLE for OpenGL ES. Ika's host tools carry the mode, but
it needs a ROM that declares Venus support in its `android-info.txt` (`venus`
in `gpu_mode_candidates`, or `vulkan_venus_apex=supported`), and Ika's ROM does
not: `ika start --gpu_mode=venus` says so and stops. Venus is not available on
Apple Silicon. Upstream tests it on Intel (ANV) and Qualcomm (Turnip) hosts.

## What Ika adds for some hosts

- **AMD (RADV):** in the gfxstream modes, Ika adds `syncshaders` to
  `RADV_DEBUG`, keeping options you set there, so that RADV's asynchronous
  shader compilation cannot run incomplete transform-feedback pipelines. On
  Vega and older GPUs, gfxstream also allocates Vulkan memory as device memory
  only (`VulkanAllocateDeviceMemoryOnly`), against host-visible memory
  corruption. Cuttlefish warns when an AMD host's kernel is older than 6.13.
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
  `~/ika/ikastart.log` has the GPU decisions: Vulkan in `gfxstream` mode,
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
