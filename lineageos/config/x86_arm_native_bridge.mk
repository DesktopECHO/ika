#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE ?= true

ifeq ($(LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE),true)
LINEAGE_DESKTOP_NATIVE_BRIDGE_PREBUILT_DIR := vendor/lineage_desktop/prebuilts/native_bridge/system
LINEAGE_DESKTOP_NATIVE_BRIDGE_LIBRARY := $(LINEAGE_DESKTOP_NATIVE_BRIDGE_PREBUILT_DIR)/lib64/libndk_translation.so

ifneq (,$(wildcard $(LINEAGE_DESKTOP_NATIVE_BRIDGE_LIBRARY)))
include frameworks/libs/native_bridge_support/native_bridge_support.mk

PRODUCT_SOONG_NAMESPACES += \
    frameworks/libs/native_bridge_support/android_api/libc

PRODUCT_PACKAGES += \
    libberberis_exec_region \
    $(NATIVE_BRIDGE_PRODUCT_PACKAGES)

ifeq (,$(wildcard $(LINEAGE_DESKTOP_NATIVE_BRIDGE_PREBUILT_DIR)/lib64/libndk_translation_proxy_libm.so))
PRODUCT_PACKAGES += \
    libndk_translation_proxy_libm
endif

# Arm64 guest build of vulkaninfo (tools/vulkaninfo) plus a shell wrapper to
# run it under translation. These install to system_ext so generic_system's
# /system artifact-path requirement stays clean.
PRODUCT_PACKAGES += \
    vulkaninfo.native_bridge:64 \
    vulkaninfo_arm64

LINEAGE_DESKTOP_NATIVE_BRIDGE_COPY_FILES := \
    bin/ndk_translation_program_runner_binfmt_misc_arm64 \
    etc/binfmt_misc/arm64_dyn \
    etc/binfmt_misc/arm64_exe \
    etc/init/ndk_translation.rc \
    etc/ld.config.arm64.txt

PRODUCT_COPY_FILES += \
    $(foreach f,$(LINEAGE_DESKTOP_NATIVE_BRIDGE_COPY_FILES),$(LINEAGE_DESKTOP_NATIVE_BRIDGE_PREBUILT_DIR)/$(f):$(TARGET_COPY_OUT_SYSTEM)/$(f)) \
    $(call find-copy-subdir-files,libndk_translation*.so,$(LINEAGE_DESKTOP_NATIVE_BRIDGE_PREBUILT_DIR)/lib64,$(TARGET_COPY_OUT_SYSTEM)/lib64)

PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \
    $(TARGET_COPY_OUT_SYSTEM)/bin/arm64/% \
    $(TARGET_COPY_OUT_SYSTEM)/bin/ndk_translation_program_runner_binfmt_misc_arm64 \
    $(TARGET_COPY_OUT_SYSTEM)/etc/binfmt_misc/% \
    $(TARGET_COPY_OUT_SYSTEM)/etc/init/ndk_translation.rc \
    $(TARGET_COPY_OUT_SYSTEM)/etc/ld.config.arm64.txt \
    $(TARGET_COPY_OUT_SYSTEM)/lib64/arm64/% \
    $(TARGET_COPY_OUT_SYSTEM)/lib64/libblasV8.so \
    $(TARGET_COPY_OUT_SYSTEM)/lib64/libberberis_exec_region.so \
    $(TARGET_COPY_OUT_SYSTEM)/lib64/libndk_translation%

# Override runtime_libart's ro.dalvik.vm.native.bridge?=0 default from a
# product-owned partition so generic_system artifact checks stay clean.
PRODUCT_PRODUCT_PROPERTIES += \
    ro.dalvik.vm.native.bridge=libndk_translation.so \
    ro.dalvik.vm.isa.arm64=x86_64 \
    ro.enable.native.bridge.exec=1
else
$(warning x86 ARM64 native bridge payload missing: run vendor/lineage_desktop/scripts/update_native_bridge_prebuilts.py before building x86-64)
endif
endif
