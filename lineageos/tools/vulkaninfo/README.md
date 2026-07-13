# vulkaninfo

Khronos `vulkaninfo` vendored from
[KhronosGroup/Vulkan-Tools](https://github.com/KhronosGroup/Vulkan-Tools)
tag `v1.4.341`, chosen to match `external/vulkan-headers`
(`VK_HEADER_VERSION 341`). Replaces the earlier home-grown `vkextcheck`
extension enumerator with the full upstream report: instance/device
extensions, features, properties, limits, memory heaps/types, queue
families, format properties, and all the pNext-chain extension structs.

Files taken verbatim from `vulkaninfo/` in that repo:
`vulkaninfo.cpp`, `vulkaninfo.h`, `vulkaninfo_functions.h`,
`outputprinter.h`, `generated/vulkaninfo.hpp`, `vulkaninfo.md`, `LICENSE`.

Build notes (`Android.bp` is local):

- No `VK_USE_PLATFORM_ANDROID_KHR`: upstream's Android WSI path is
  native-activity glue that needs an `ANativeWindow`; a console binary has
  none, so it is built platform-less and skips surface enumeration only.
- Vulkan is loaded via `dlopen("libvulkan.so")` (upstream fallback path),
  not linked, so no `libvulkan` dependency.
- `compile_multilib: "64"` keeps it native x86_64 on the Cuttlefish
  desktop product — no arm64/Berberis translation — so it talks to the
  gfxstream guest driver directly.

To update: bump `external/vulkan-headers`, copy the same files from the
matching Vulkan-Tools tag (the generated header must match
`VK_HEADER_VERSION` exactly).

Usage on device: `vulkaninfo`, `vulkaninfo --summary`,
`vulkaninfo --json` (see `vulkaninfo.md`).

Both desktop ROMs ship only the native 64-bit binary: x86_64 `vulkaninfo` on
the x86_64 ROM and arm64 `vulkaninfo` on the arm64 (pgagnostic) ROM.
