# Digitalis and Google's translator compared

The x86-64 ROM runs ARM64 apps through Digitalis (github.com/DigitalisX64), the open
(Apache-2.0) ARM64 backend for AOSP's Berberis, on the same Android 16 QPR2 base as
Ika. `X86_ARM_TRANSLATOR=ndk_translation` builds the ROM with Google's closed
`libndk_translation.so` from an Android SDK system image instead (see the README's
native bridge section). This page compares the two on one host, and says how to repeat
the comparison.

## How the ROM builds Digitalis

- **Source:** the manifest takes `frameworks/libs/binary_translation` from
  DigitalisX64 at a pinned commit of its `android16` branch.
- **Product:** `config/x86_arm_native_bridge.mk` builds `libberberis_arm64.so`, its
  21 proxy libraries and the ARM64 guest libraries.
- **Vulkan proxy:** `frameworks-libs-binary-translation-vulkan-registry.patch` generates
  it from `prebuilts/vulkan_registry_android16/vk.xml`. That is Android 16's Vulkan
  registry (header 317), the same Vulkan generation as Google's prebuilt proxy.
  `native_bridge_support`'s `gen_vulkan` cannot read the Vulkan-Headers Ika pins for
  Mesa (1.4.360). It stops on the new `ubm_device`/`ubm_surface` platform types, on
  `int` now requiring `vk_platform`, and on function pointers written as
  `<proto>`/`<param>`.
- **Guest linker:** `bionic-native-bridge-keep-system-libraries.patch` keeps a system
  library loaded once a translated app has loaded it, as on an ARM device, where zygote
  has loaded most of them before the app starts. Some apps dlclose a system library and
  keep calling into it; Wuthering Waves crashed at login that way.

## The test (2026-11-23)

- **Host:** Ryzen 9 8945HS (Radeon 780M), Windows 11, Ika in WSL2.
- **Build:** ROM and host packages from bb0a3aa4. Ika on `gpu_mode` auto (Venus).
- **Translator:** Digitalis 246557a3 (the commit the manifest pins), installed as a
  Magisk module over the same ROM, which shipped Google's translator. The
  module carried Digitalis's files in `/system`, `ro.dalvik.vm.native.bridge` and
  `ro.berberis.flags` in `system.prop`, and a `service.sh` that re-registers binfmt_misc.
  Enabling or disabling it plus a guest reboot switched translators. Nothing else changed.
- **Run order:** each round followed a fresh guest reboot, with the ROM-tree build stopped.

**CPU, single thread.** The workloads are CoreMark and zstd 1.5.6 `-b` on a 19 MB tar of
NDK headers. Each was built with NDK r27c for arm64 and for x86-64 and run in the guest.
Figures are medians of 3 runs.

| Workload | libndk_translation | Digitalis | Native x86-64 |
|---|---|---|---|
| CoreMark, iterations/s | 24,691 | 15,052 (61%) | 42,940 |
| zstd -1 compress, MB/s | 478 | 334 (70%) | 818 |
| zstd -9 compress, MB/s | 61.3 | 36.8 (60%) | 134.9 |
| zstd -9 decompress, MB/s | 1,776 | 828 (47%) | 2,711 |
| Static arm64 executables | crash at start (SIGSEGV) | run | run |

The percentages are Digitalis as a share of libndk_translation. Both translators run
dynamically linked executables.

**Apps.** Angry Birds 2 and Wuthering Waves (arm64-only), 90 s after launch:

- Both ran under each translator, with no crash, and showed their own screens.
- `/proc/PID/maps` showed which translator each process loaded.

**3DMark Wild Life Extreme**, arm64 build of 2.7.5093, 2 runs each:

| | Run 1 | Run 2 |
|---|---|---|
| libndk_translation | 3,686 | 3,700 |
| Digitalis | 3,613 | 3,630 (-2%) |
| x86-64 build, same host (that morning) | 3,892 | — |

The test is GPU-bound. Translation costs about 5% of the score, and the translator
choice adds about 2% more.

## Reading it

- **Speed:** Digitalis runs CPU-bound code at 47–70% of libndk_translation's speed on
  this host. GPU-bound games barely notice.
- **Compatibility:** it ran everything tried, including static executables that
  libndk_translation cannot start.
- **Not tried:**
  - a wider set of games, in-game, rather than to their menus
  - Intel and older hosts, and Linux hosts
  - the TV Play Store
  - a ROM built with Digitalis, rather than the module overlay
