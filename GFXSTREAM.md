# Gfxstream GPU Modes

Both `gfxstream` and `gfxstream_guest_angle` use gfxstream and the physical
host GPU, but they translate OpenGL ES differently.

| | `gfxstream` | `gfxstream_guest_angle` |
|---|---|---|
| Guest OpenGL driver | gfxstream EGL emulation | Android ANGLE |
| GLES conversion | GLES to gfxstream's host OpenGL translator | GLES to ANGLE to Vulkan |
| Host API | Primarily OpenGL; optionally Vulkan | Vulkan only |
| crosvm setting | `gles=true` | `gles=false` |
| Compatibility | The current GLES translator breaks some games | Better game compatibility |
| Performance | Potentially less translation overhead | Usually excellent, but workload-dependent |
| `--gfxstream_vulkan` | Controls the optional Vulkan context | Ignored; Vulkan is required |

The `gfxstream` rendering path is:

```text
Game GLES -> gfxstream GLES encoder -> host OpenGL translator -> physical GPU
```

The `gfxstream_guest_angle` rendering path is:

```text
Game GLES -> guest ANGLE -> Vulkan -> gfxstream Vulkan -> host Vulkan driver -> physical GPU
```

`gfxstream_guest_angle` is Ika's default because guest ANGLE avoids compatibility
problems in gfxstream's direct GLES translator. For example, Beach Buggy Racing
loses its 3D pass in direct `gfxstream` mode but works with
`gfxstream_guest_angle`, where ANGLE handles GLES and gfxstream transports
Vulkan.

To explicitly select the default mode on a system with a working hardware
Vulkan driver, run:

```bash
ika restart --gpu_mode=gfxstream_guest_angle
```
