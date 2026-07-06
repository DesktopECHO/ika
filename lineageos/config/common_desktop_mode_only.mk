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

# The desktop shell depends on QuickStep for the taskbar, recents, and
# QUICKSTEP_SERVICE binding. Plain Launcher3 uses the same package name and can
# shadow Launcher3QuickStep if stale or inherited artifacts make it into the
# image.
PRODUCT_PACKAGES := $(filter-out Launcher3 Launcher3Go Launcher3QuickStepGo,$(PRODUCT_PACKAGES))
PRODUCT_DEXPREOPT_SPEED_APPS := $(filter-out Launcher3 Launcher3Go Launcher3QuickStepGo,$(PRODUCT_DEXPREOPT_SPEED_APPS))
PRODUCT_PACKAGES += Launcher3QuickStep
PRODUCT_DEXPREOPT_SPEED_APPS += Launcher3QuickStep

# Keep the app compatibility surface tablet-shaped. Desktop behavior is layered
# on top via the windowing overlays/settings below, but app stores and many apps
# key their phone/tablet choice from ro.build.characteristics.
PRODUCT_CHARACTERISTICS := tablet

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

# Cuttlefish init renames eth0 to buried_eth0 only when this property is empty.
# Keep it present so ethernet-only launches retain the kernel eth0 name.
PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.disable_rename_eth0=false

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

# Native (x86_64/arm64) diagnostics. vulkaninfo exercises the gfxstream guest
# driver directly; zipalign lets the ROM itself audit APK page alignment.
PRODUCT_PACKAGES += \
    vulkaninfo \
    zipalign
# The arm64 pgagnostic (GSI-style) product enforces a /system artifact-path
# requirement; allow the device zipalign binary. vulkaninfo lives on system_ext.
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \
    system/bin/zipalign

# Allow microG Android.mk files when the optional partner_gms local manifest is present.
PRODUCT_ALLOWED_ANDROIDMK_FILES += \
    vendor/partner_gms/GmsCore/Android.mk \
    vendor/partner_gms/FakeStore/Android.mk \
    vendor/partner_gms/GsfProxy/Android.mk \
    vendor/partner_gms/FDroid/Android.mk \
    vendor/partner_gms/FDroidPrivilegedExtension/Android.mk \
    vendor/partner_gms/additional_repos.xml/Android.mk
