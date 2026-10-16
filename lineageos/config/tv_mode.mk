#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

# Android TV mode. The same image runs the desktop or a 10-foot TV interface.
# Desktop is the default. IkaMode's Desktop/TV entry is the only way to
# switch: it sets persist.sys.ika.mode ("tv" or "desktop"), switches the
# Settings app, the keyboard and the Home app, and restarts Android for the
# rest. Without the property the image boots the desktop, unchanged.
#
# The TV packages below coexist with the desktop ones and are installed in both
# modes. Everything else is gated on persist.sys.ika.mode=tv, read at boot:
#   - overlays, by requiredSystemPropertyName (Ika's TV overlays here, and the
#     AOSP TV overlays through device-google-atv-ika-tv-mode.patch and
#     frameworks-opt-tv-tvsystem-ika-tv-mode.patch);
#   - the leanback, leanback-only and live TV features, and freeform
#     windowing being unavailable, by system_ext/etc/permissions/ika_tv, which
#     SystemConfig reads only in TV mode (frameworks-base-ika-mode.patch);
#   - the services that start with those features;
#   - TvSystemUI, PackageInstaller_tv and TvFrameworkPackageStubs, which
#     PackageManager scans only in TV mode, and SystemUI and PackageInstaller,
#     which it scans only in desktop mode (frameworks-base-ika-mode.patch;
#     packages-apps-TvSystemUI-ika-tv-mode.patch and the same frameworks
#     patch keep the TV builds from replacing the desktop's at build time);
#   - atv-component-overrides.xml (TvSystemUI without SystemUI's
#     KeyguardService), in system_ext/etc/sysconfig/ika_tv.
# The property has its own SELinux type (sepolicy/private), as the zygote,
# which checks the overlays, cannot read system_prop.
#
# Left out: the Google TV setup overlays and NetflixConfig, atv_generic_keylayout
# (an older Generic.kl that would replace the desktop's in both modes and map
# the gamepad triggers to GAS/BRAKE), AudioTv (its key sounds have the same
# paths as the desktop's), and init.lineage.atv.rc (it restarts adbd when
# service.adb.tcp.port changes, which Cuttlefish sets at boot; Ika's host
# manages adb).

# Lineage's TV launcher, one of the TV launchers IkaMode's Desktop/TV offers.
# Launcher3 is the default Home app (config_defaultHome in Ika's framework
# overlay, read by the Home role: frameworks-base-default-home-role.patch and
# packages-modules-Permission-default-home-role.patch), and IkaMode disables
# it in TV mode. TvProvider holds the channels and Watch Next programs that
# apps publish for its rows.
PRODUCT_PACKAGES += \
    Catapult \
    TvProvider

# TV mode's System UI and launcher are compiled ahead of time like the
# desktop's (SystemUI and Launcher3QuickStep).
PRODUCT_DEXPREOPT_SPEED_APPS += \
    Catapult \
    TvSystemUI

# The Android TV build of the Play Store, with MindTheGapps
# (prebuilts/mindthegapps/arm64/tubesky). It is MindTheGapps' arm64 build, as
# MindTheGapps has no TV build for x86-64, where its native code runs through
# the ARM native bridge: not without the bridge. PackageManager scans it in TV
# mode and the phone build in desktop mode
# (frameworks-base-ika-mode.patch). Its allowlist, for privileged permissions
# the phone build does not request, is on /product with it: Android checks an
# app against the allowlists of its own partition.
ifeq ($(LINEAGE_DESKTOP_GMS_PROVIDER),mtg)
ifneq ($(LINEAGE_DESKTOP_MTG_ARCH)_$(LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE),x86_64_false)
PRODUCT_PACKAGES += \
    Tubesky
PRODUCT_COPY_FILES += \
    vendor/lineage_desktop/prebuilts/mindthegapps/arm64/tubesky/privapp-permissions-ika-tubesky.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/permissions/privapp-permissions-ika-tubesky.xml
endif
endif

# TV Settings (com.android.tv.settings), the two-panel layout Lineage TV ships.
# Its intent filters match the desktop Settings app's, so IkaMode keeps only
# one of the two enabled: TV Settings in TV mode, Settings in desktop mode.
PRODUCT_PACKAGES += \
    TvSettingsTwoPanel \
    LineageCustomizer

# The Leanback keyboard, the default in TV mode (set by IkaMode). Its overlay
# keeps Android from enabling it by itself, which would happen in desktop mode
# as well.
PRODUCT_PACKAGES += \
    LeanbackIME \
    LineageDesktopLeanbackImeOverlay

# System services of Android TV. TvInputManagerService, TvRemoteService and
# TvInteractiveAppManagerService start only with the leanback or live TV
# feature, so in TV mode; TvKeyInputManagerService from tv-services is listed by
# its overlay, which is gated on TV mode.
PRODUCT_PACKAGES += \
    tv-services \
    tv-services-client \
    tv_input.default \
    com.android.media.tv.remoteprovider \
    libmedia_tv_tuner
PRODUCT_SYSTEM_SERVER_JARS_EXTRA += system_ext:tv-services
SYSTEM_EXT_PUBLIC_SEPOLICY_DIRS += device/google/atv/sepolicy/system_ext/public
SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += device/google/atv/sepolicy/system_ext/private

# The arm64 pgagnostic (GSI-style) product enforces a /system artifact-path
# requirement. mediatuner starts only when the Tuner Resource Manager asks for
# it, which needs a tuner HAL and its feature.
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \
    system/priv-app/TvProvider/% \
    system/priv-app/PackageInstaller_tv/% \
    system/framework/com.android.media.tv.remoteprovider.jar \
    system/etc/permissions/com.android.media.tv.remoteprovider.xml \
    system/bin/mediatuner \
    system/etc/init/mediatuner.rc \
    system/lib%/libmedia_tv_tuner.so \
    system/lib%/libtunerservice.so \
    system/lib%/android.hardware.tv.tuner@1.0.so \
    system/lib%/android.hardware.tv.tuner@1.1.so \
    system/lib%/tv_tuner_aidl_interface-ndk.so \
    system/lib%/tv_tuner_resource_manager_aidl_interface-ndk.so

# Android TV's SystemUI, package installer and stubs for intents a TV does
# not handle. TvSystemUI and PackageInstaller_tv share the package names of
# SystemUI and PackageInstaller; each mode boots with its own.
PRODUCT_PACKAGES += \
    TvSystemUI \
    PackageInstaller_tv \
    TvFrameworkPackageStubs
PRODUCT_COPY_FILES += \
    device/google/atv/atv-component-overrides.xml:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/sysconfig/ika_tv/atv-component-overrides.xml

# TV overlays, all static and applied only in TV mode.
PRODUCT_PACKAGES += \
    TvFrameworkOverlay \
    TvNetworkStackOverlay \
    TvSettingsProviderOverlay \
    TvWifiOverlay \
    LineageDesktopTvFrameworkResOverlay \
    LineageDesktopTvLineageSdkOverlay

# Features of TV mode, read by SystemConfig only when persist.sys.ika.mode=tv.
# Kept out of the top-level permissions directories on purpose: the build
# turns <unavailable-feature> entries found there into compile-time constants.
PRODUCT_COPY_FILES += \
    vendor/lineage_desktop/prebuilts/tv_mode/ika_tv_features.xml:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/permissions/ika_tv/ika_tv_features.xml

# Desktop/TV: switches the mode (its Settings app, keyboard, launcher and Home
# app) and restarts Android, and chooses the TV launcher in TV mode.
PRODUCT_PACKAGES += IkaMode
SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += vendor/lineage_desktop/sepolicy/private

# Remotes and gamepads, in both modes: Lineage TV's layouts for common remotes
# and controllers (vendor IDs no stock layout covers), and the gamepad feature.
PRODUCT_SOONG_NAMESPACES += device/lineage/atv
PRODUCT_PACKAGES += \
    Vendor_0110_Product_0508.idc \
    Vendor_0110_Product_0508.kl \
    Vendor_0957_Product_0005.idc \
    Vendor_0957_Product_0005.kl \
    Vendor_18d1_Product_9450.idc \
    Vendor_18d1_Product_9450.kl \
    Vendor_18d1_Product_9400.kl \
    Vendor_0955_Product_7212.idc \
    Vendor_0955_Product_7213.idc \
    Vendor_0955_Product_7214.idc \
    Vendor_0955_Product_7217.idc \
    Vendor_0955_Product_7212.kl \
    Vendor_0955_Product_7213.kl \
    Vendor_0955_Product_7214.kl \
    Vendor_0955_Product_7217.kl \
    Vendor_045e_Product_0b05.kl \
    Vendor_045e_Product_0b13.kl \
    Vendor_000d_Product_3838.idc \
    Vendor_000d_Product_3839.idc \
    Vendor_7545_Product_0021.idc \
    Vendor_000d_Product_3838.kl \
    Vendor_000d_Product_3839.kl \
    Vendor_7545_Product_0021.kl \
    Vendor_0002_Product_0002.kl \
    Vendor_005d_Product_0001.kl \
    Vendor_005d_Product_0002.kl \
    Vendor_0484_Product_5738.kl \
    Vendor_0508_Product_0110.kl \
    Vendor_0957_Product_0006.kl \
    Vendor_0c45_Product_1109.kl \
    Vendor_1915_Product_0001.kl \
    Vendor_7045_Product_1820.kl \
    Vendor_7545_Product_0180.kl \
    Vendor_7545_Product_0190.kl \
    Vendor_0508_Product_0110.idc \
    Vendor_0957_Product_0004.idc \
    Vendor_1d5a_Product_c082.idc \
    Vendor_248a_Product_8266.idc \
    Vendor_7545_Product_0180.idc \
    Vendor_0957_Product_0004.kl \
    Vendor_1d5a_Product_c081.kl \
    Vendor_1d5a_Product_c082.kl \
    Vendor_248a_Product_8266.kl
PRODUCT_COPY_FILES += \
    frameworks/base/data/keyboards/Vendor_28de_Product_1102.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/Vendor_28de_Product_1106.kl \
    frameworks/base/data/keyboards/Vendor_28de_Product_1102.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/Vendor_28de_Product_1142.kl \
    frameworks/native/data/etc/android.hardware.gamepad.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/permissions/android.hardware.gamepad.xml
