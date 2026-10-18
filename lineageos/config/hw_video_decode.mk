#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

# Hardware video decoding. `ika start` adds a crosvm virtio-media decoder
# backed by the host's VA-API driver when the host has one (--hw_video_decode),
# and the guest sees it as a V4L2 stateful decoder at /dev/videoN. The V4L2
# Codec2 HAL serves it to MediaCodec as c2.v4l2.*.decoder, ranked ahead of the
# c2.android.* software decoders.
#
# The HAL lists only the codecs a device decodes when it starts, so a VM started
# without the decoder (--hw_video_decode=off, or a host without VA-API) lists
# none and Android decodes in software as before. virtio-media takes MMAP buffers
# only, so the HAL copies the bitstream in and every picture out
# (external-v4l2_codec2-virtio-media.patch).

PRODUCT_SOONG_NAMESPACES += external/v4l2_codec2

PRODUCT_PACKAGES += \
    android.hardware.media.c2-service-v4l2

PRODUCT_COPY_FILES += \
    vendor/lineage_desktop/prebuilts/v4l2_codec2/media_codecs_c2.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_c2.xml \
    vendor/lineage_desktop/prebuilts/v4l2_codec2/android.hardware.media.c2-extended-seccomp_policy:$(TARGET_COPY_OUT_VENDOR)/etc/seccomp_policy/android.hardware.media.c2-extended-seccomp_policy

# The codecs crosvm's decoder handles; each is listed only if the host decodes it.
PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.v4l2_codec2.decoder.supported.h264=true \
    ro.vendor.v4l2_codec2.decoder.supported.hevc=true \
    ro.vendor.v4l2_codec2.decoder.supported.vp8=true \
    ro.vendor.v4l2_codec2.decoder.supported.vp9=true \
    ro.vendor.v4l2_codec2.decode_concurrent_instances=8

# The service runs in the mediacodec domain, which may already use video
# devices; it only needs its executable labelled.
BOARD_VENDOR_SEPOLICY_DIRS += vendor/lineage_desktop/sepolicy/vendor
