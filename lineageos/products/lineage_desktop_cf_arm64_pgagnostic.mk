#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

# Desktop VMs do not expose usable UWB/Thread radio backends; keep those HALs/features out.
CF_VENDOR_NO_UWB := true
CF_VENDOR_NO_THREADNETWORK := true

$(call inherit-product, device/google/cuttlefish/vsoc_arm64_pgagnostic/desktop/aosp_cf.mk)
$(call inherit-product, vendor/lineage_desktop/config/common_desktop_mode_only.mk)

# Android Virtualization Framework (parity with the x86_64 desktop product,
# which pulls this in via the Cuttlefish desktop aosp_cf.mk).
$(call inherit-product, packages/modules/Virtualization/apex/product_packages.mk)

PRODUCT_NAME := lineage_desktop_cf_arm64_pgagnostic
PRODUCT_BRAND := LineageOS
PRODUCT_MANUFACTURER := DesktopECHO
PRODUCT_MODEL := Ika LineageOS desktop (ARMv8)
