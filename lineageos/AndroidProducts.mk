#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/products/lineage_desktop_cf_arm64_pgagnostic.mk \
    $(LOCAL_DIR)/products/lineage_desktop_cf_x86_64.mk

COMMON_LUNCH_CHOICES := \
    lineage_desktop_cf_arm64_pgagnostic-bp4a-userdebug \
    lineage_desktop_cf_arm64_pgagnostic-bp4a-user \
    lineage_desktop_cf_x86_64-bp4a-userdebug \
    lineage_desktop_cf_x86_64-bp4a-user
