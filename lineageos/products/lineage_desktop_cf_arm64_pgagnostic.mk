#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

# Desktop VMs do not expose usable UWB/Thread radio backends; keep those HALs/features out.
CF_VENDOR_NO_UWB := true
CF_VENDOR_NO_THREADNETWORK := true

$(call inherit-product, device/google/cuttlefish/ika_arm64/desktop/aosp_cf.mk)
LINEAGE_DESKTOP_MTG_ARCH := arm64
$(call inherit-product, vendor/lineage_desktop/config/common_desktop_mode_only.mk)

# ARM64 is the only desktop image that boots real 4K/16K kernels. Keep
# platform prebuilts honest while letting PackageManager/linker backcompat wrap
# third-party 4K APK native libraries at install/load time.
PRODUCT_CHECK_PREBUILT_MAX_PAGE_SIZE := true
PRODUCT_PRODUCT_PROPERTIES += \
    bionic.linker.16kb.app_compat.enabled=true \
    pm.16kb.app_compat.disabled=false

# The 16 KB ARM64 guest kernel advertises userfaultfd support, but its
# UFFDIO_MOVE ioctl stalls under load, so ART takes a SIGBUS while the
# concurrent mark-compact collector relocates the heap. Left at "default" the
# build resolves this from the kernel version and turns CMC on. Pin it off so
# ART uses the concurrent-copying collector, and so dexpreopt and odrefresh
# agree with the runtime instead of recompiling the boot image on every boot.
PRODUCT_ENABLE_UFFD_GC := false

PRODUCT_NAME := lineage_desktop_cf_arm64_pgagnostic
PRODUCT_BRAND := LineageOS
PRODUCT_MANUFACTURER := DesktopECHO
PRODUCT_MODEL := Ika Virtual Desktop
