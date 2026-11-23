# Android 16's Vulkan registry

`vk.xml` is `registry/vk.xml` from AOSP's `platform/external/vulkan-headers`,
branch `android16-qpr2-release` (Vulkan header 1.4.317), unchanged. It is
Khronos's, under Apache-2.0 or MIT, as its header says.

The ARM translator (Digitalis, in `frameworks/libs/binary_translation`)
generates its Vulkan proxy from a registry with `native_bridge_support`'s
`gen_vulkan`. That tool cannot read the newer registry in
`external/vulkan-headers` (Ika pins a newer Vulkan-Headers for Mesa): it stops
on new platform types and on function pointers written as `<proto>` and
`<param>`. `frameworks-libs-binary-translation-vulkan-registry.patch` points
the generator at this file instead, so the proxy covers the Vulkan of Android
16's own loader and API surface.
