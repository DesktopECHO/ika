#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

# Central product-level desktop contract. Runtime Settings defaults and source
# guards reinforce these values, but the product policy starts here.
LINEAGE_DESKTOP_WINDOWING_POLICY := desktop_only_freeform

# persist.wm.debug.* are AOSP test knobs that may be renamed or removed in a
# future release; SettingsProvider seeds and the cuttlefish set_adb.sh boot
# script reapply equivalent runtime settings so the desktop contract still
# holds if a future AOSP rev drops one of these.
PRODUCT_SYSTEM_PROPERTIES += \
    persist.wm.debug.enter_desktop_by_default_on_freeform_display=true \
    persist.wm.debug.force_desktop_first_on_default_display_for_testing=true

PRODUCT_ARTIFACT_PATH_REQUIREMENT_SYSPROP_ALLOWED_LIST += \
    persist.wm.debug.enter_desktop_by_default_on_freeform_display \
    persist.wm.debug.force_desktop_first_on_default_display_for_testing

PRODUCT_PRODUCT_PROPERTIES += \
    persist.wm.debug.desktop_experience_devopts=true \
    persist.wm.debug.enable_drag_to_maximize=true
