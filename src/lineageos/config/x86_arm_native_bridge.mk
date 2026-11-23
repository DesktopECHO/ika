#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE ?= true
# The ARM64 translator of the x86-64 ROM:
# digitalis (the default): Digitalis, the open ARM64 backend for AOSP's
#   Berberis, built from frameworks/libs/binary_translation (the manifest pins
#   DigitalisX64's in place of AOSP's).
# ndk_translation: Google's closed libndk_translation, taken from an Android
#   SDK system image by scripts/update_native_bridge_prebuilts.py.
LINEAGE_DESKTOP_X86_ARM_TRANSLATOR ?= digitalis

ifeq ($(LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE)_$(LINEAGE_DESKTOP_X86_ARM_TRANSLATOR),true_digitalis)
ifeq (,$(wildcard frameworks/libs/binary_translation/enable_arm64_to_x86_64.mk))
$(error LINEAGE_DESKTOP_X86_ARM_TRANSLATOR=digitalis needs DigitalisX64's frameworks/libs/binary_translation)
endif
include frameworks/libs/binary_translation/berberis_config.mk
include frameworks/libs/native_bridge_support/native_bridge_support.mk

PRODUCT_SOONG_NAMESPACES += \
    frameworks/libs/native_bridge_support/android_api/libc

PRODUCT_PACKAGES += \
    $(BERBERIS_PRODUCT_PACKAGES_ARM64_TO_X86_64)

PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \
    $(BERBERIS_DISTRIBUTION_ARTIFACTS_ARM64) \
    $(TARGET_COPY_OUT_SYSTEM)/lib64/arm64/% \
    $(TARGET_COPY_OUT_SYSTEM)/bin/arm64/% \
    $(TARGET_COPY_OUT_SYSTEM)/lib64/libblasV8.so

BUILD_BERBERIS := true
BUILD_BERBERIS_ARM64_TO_X86_64 := true
$(call soong_config_set,berberis,translation_arch,arm64_to_x86_64)

# As below: product properties override runtime_libart's default.
PRODUCT_PRODUCT_PROPERTIES += \
    ro.dalvik.vm.native.bridge=libberberis_arm64.so \
    ro.dalvik.vm.isa.arm64=x86_64 \
    ro.enable.native.bridge.exec=1 \
    ro.berberis.flags=disable-ir-check
else ifeq ($(LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE)_$(LINEAGE_DESKTOP_X86_ARM_TRANSLATOR),true_ndk_translation)
LINEAGE_DESKTOP_NATIVE_BRIDGE_PREBUILT_DIR := vendor/lineage_desktop/prebuilts/native_bridge/system
LINEAGE_DESKTOP_NATIVE_BRIDGE_LIBRARY := $(LINEAGE_DESKTOP_NATIVE_BRIDGE_PREBUILT_DIR)/lib64/libndk_translation.so

ifneq (,$(wildcard $(LINEAGE_DESKTOP_NATIVE_BRIDGE_LIBRARY)))
include frameworks/libs/native_bridge_support/native_bridge_support.mk

PRODUCT_SOONG_NAMESPACES += \
    frameworks/libs/native_bridge_support/android_api/libc

PRODUCT_PACKAGES += \
    libberberis_exec_region \
    $(filter-out libndk_translation_proxy_libm,$(NATIVE_BRIDGE_PRODUCT_PACKAGES))

# Newer Google images ship the libm proxy that matches their translator.
# Older payloads omitted it, so retain AOSP's source-built proxy as a fallback
# without creating two install rules for the same /system path.
ifeq (,$(wildcard $(LINEAGE_DESKTOP_NATIVE_BRIDGE_PREBUILT_DIR)/lib64/libndk_translation_proxy_libm.so))
PRODUCT_PACKAGES += \
    libndk_translation_proxy_libm
endif

LINEAGE_DESKTOP_NATIVE_BRIDGE_COPY_FILES := \
    bin/ndk_translation_program_runner_binfmt_misc_arm64 \
    etc/binfmt_misc/arm64_dyn \
    etc/binfmt_misc/arm64_exe \
    etc/cpuinfo.arm64.txt \
    etc/berberis/cpuinfo.arm64.txt \
    etc/init/ndk_translation.rc \
    etc/ld.config.arm64.txt

PRODUCT_COPY_FILES += \
    $(foreach f,$(LINEAGE_DESKTOP_NATIVE_BRIDGE_COPY_FILES),$(LINEAGE_DESKTOP_NATIVE_BRIDGE_PREBUILT_DIR)/$(f):$(TARGET_COPY_OUT_SYSTEM)/$(f)) \
    $(call find-copy-subdir-files,libndk_translation*.so,$(LINEAGE_DESKTOP_NATIVE_BRIDGE_PREBUILT_DIR)/lib64,$(TARGET_COPY_OUT_SYSTEM)/lib64)

PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \
    $(TARGET_COPY_OUT_SYSTEM)/bin/arm64/% \
    $(TARGET_COPY_OUT_SYSTEM)/bin/ndk_translation_program_runner_binfmt_misc_arm64 \
    $(TARGET_COPY_OUT_SYSTEM)/etc/binfmt_misc/% \
    $(TARGET_COPY_OUT_SYSTEM)/etc/cpuinfo.arm64.txt \
    $(TARGET_COPY_OUT_SYSTEM)/etc/berberis/cpuinfo.arm64.txt \
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
else ifeq ($(LINEAGE_DESKTOP_ENABLE_X86_ARM_NATIVE_BRIDGE),true)
$(error LINEAGE_DESKTOP_X86_ARM_TRANSLATOR must be digitalis or ndk_translation, not '$(LINEAGE_DESKTOP_X86_ARM_TRANSLATOR)')
endif
