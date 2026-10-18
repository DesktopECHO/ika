#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

# Desktop VMs do not expose usable UWB/Thread radio backends; keep those HALs/features out.
CF_VENDOR_NO_UWB := true
CF_VENDOR_NO_THREADNETWORK := true

$(call inherit-product, device/google/cuttlefish/ika_x86_64/desktop/aosp_cf.mk)
LINEAGE_DESKTOP_MTG_ARCH := x86_64
$(call inherit-product, vendor/lineage_desktop/config/common_desktop_mode_only.mk)
$(call inherit-product, vendor/lineage_desktop/config/x86_arm_native_bridge.mk)

# The x86_64 bootloader leaves a write-combining MTRR over all of memory, which
# makes Linux map device memory uncached; remove it at early-init. Its SELinux
# domain is in sepolicy/vendor (config/hw_video_decode.mk adds the directory).
PRODUCT_COPY_FILES += \
    vendor/lineage_desktop/prebuilts/mtrr_fixup/ika_mtrr_fixup.sh:$(TARGET_COPY_OUT_VENDOR)/bin/ika_mtrr_fixup.sh \
    vendor/lineage_desktop/prebuilts/mtrr_fixup/ika_mtrr_fixup.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/ika_mtrr_fixup.rc

PRODUCT_NAME := lineage_desktop_cf_x86_64
PRODUCT_BRAND := LineageOS
PRODUCT_MANUFACTURER := DesktopECHO
PRODUCT_MODEL := Ika Android
