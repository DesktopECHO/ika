#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

# Desktop VMs do not expose usable UWB/Thread radio backends; keep those HALs/features out.
CF_VENDOR_NO_UWB := true
CF_VENDOR_NO_THREADNETWORK := true

$(call inherit-product, device/google/cuttlefish/vsoc_x86_64_sandybridge/desktop/aosp_cf.mk)
$(call inherit-product, vendor/lineage_desktop/config/common_desktop_mode_only.mk)
$(call inherit-product, vendor/lineage_desktop/config/x86_arm_native_bridge.mk)

PRODUCT_NAME := lineage_desktop_cf_x86_64
PRODUCT_BRAND := LineageOS
PRODUCT_MANUFACTURER := DesktopECHO
PRODUCT_MODEL := Ika LineageOS desktop (x86-64)
