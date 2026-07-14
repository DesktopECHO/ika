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

PRODUCT_NAME := lineage_desktop_cf_arm64_pgagnostic
PRODUCT_BRAND := LineageOS
PRODUCT_MANUFACTURER := DesktopECHO
PRODUCT_MODEL := Ika LineageOS Desktop ARM64
