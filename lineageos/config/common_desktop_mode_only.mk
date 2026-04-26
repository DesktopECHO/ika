#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

# Keep the desktop product self-contained when layered over official LineageOS.
LINEAGE_SKIP_SETUPWIZARD := true
LINEAGE_SKIP_JELLY := true
ifeq ($(TARGET_BUILD_VARIANT),userdebug)
WITH_ADB_INSECURE := true
endif
WITH_GMS := true

$(call inherit-product, vendor/lineage/config/common_full_tablet_wifionly.mk)

# Override the tablet-flavored characteristics inherited from the wifi-only base.
# The desktop image is not a tablet; leaving PRODUCT_CHARACTERISTICS=tablet biases
# Launcher3 grid selection, font scale, and several SystemUI assets toward tablet
# defaults that the desktop overlays then have to undo one by one.
PRODUCT_CHARACTERISTICS := default

TARGET_FORCE_OTA_PACKAGE := true
TARGET_DISABLE_EPPE := true
TARGET_NO_KERNEL_OVERRIDE := true
USE_SOONG_DEFINED_SYSTEM_IMAGE := false

# vendor/lineage/config/common.mk honors this product's setup wizard skip flag.

$(call inherit-product, vendor/lineage_desktop/config/desktop_windowing_policy.mk)

PRODUCT_PRODUCT_PROPERTIES += \
    persist.sys.strictmode.disable=true \
    ro.config.media_vol_default=12 \
    ro.setupwizard.mode=DISABLED \
    debug.sf.nobootanimation=1 \
    pm.dexopt.first-boot=speed-profile \
    pm.dexopt.install=speed-profile

# Seed per-display windowing settings (R7). DisplayWindowSettingsProvider reads
# this on first boot and persists into /data/system/display_settings.xml; the
# entry keys the Cuttlefish default display to WINDOWING_MODE_FREEFORM and
# shouldShowSystemDecors=true so the desktop contract survives a factory reset.
PRODUCT_COPY_FILES += \
    vendor/lineage_desktop/prebuilts/display_settings/display_settings.xml:$(TARGET_COPY_OUT_VENDOR)/etc/display_settings.xml

# Host-window-resize listener (R5). /usr/bin/ika sets
# vendor.cuttlefish.display.size (and optionally .dpi) when the user resizes
# the Cuttlefish host window; init triggers cvd_display_resize.sh, which fans
# the new geometry into WindowManager via `cmd window size`/`cmd window
# density`. The script runs under the existing set_adb SELinux domain.
PRODUCT_COPY_FILES += \
    vendor/lineage_desktop/prebuilts/cvd_display_resize/cvd_display_resize.sh:$(TARGET_COPY_OUT_SYSTEM_EXT)/bin/cvd_display_resize.sh \
    vendor/lineage_desktop/prebuilts/cvd_display_resize/cvd_display_resize.rc:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/init/cvd_display_resize.rc

PRODUCT_PACKAGES += \
    LineageDesktopConnectivityOverlay \
    LineageDesktopFrameworkResOverlay \
    LineageDesktopLineageSettingsProviderOverlay \
    LineageDesktopNetworkStackOverlay \
    LineageDesktopSettingsOverlay \
    LineageDesktopSettingsProviderOverlay \
    LineageDesktopSystemUIOverlay

# Allow microG Android.mk files when the optional partner_gms local manifest is present.
PRODUCT_ALLOWED_ANDROIDMK_FILES += \
    vendor/partner_gms/GmsCore/Android.mk \
    vendor/partner_gms/FakeStore/Android.mk \
    vendor/partner_gms/GsfProxy/Android.mk \
    vendor/partner_gms/FDroid/Android.mk \
    vendor/partner_gms/FDroidPrivilegedExtension/Android.mk \
    vendor/partner_gms/additional_repos.xml/Android.mk
