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

On x86_64 images an arm64 guest build is also shipped
(`vulkaninfo.native_bridge` → `/system_ext/bin/arm64/vulkaninfo`) with a
`vulkaninfo_arm64` wrapper that runs it under ndk_translation/Berberis —
the path real (translated) apps take. Diff `vulkaninfo` vs
`vulkaninfo_arm64` output to separate gfxstream driver issues from
translation issues. The arm64 (pgagnostic) ROM ships only the native
arm64 `vulkaninfo`.
