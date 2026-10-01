package com.genymobile.scrcpy.video;

import com.genymobile.scrcpy.device.Size;
import com.genymobile.scrcpy.util.Ln;

import android.media.MediaCodecInfo;

/**
 * The video sizes an encoder advertises.
 * <p/>
 * A resizable capture (a new virtual display following its window) can grow beyond what the encoder takes. Scaling the video down to
 * an advertised size keeps the stream alive instead of failing every frame.
 */
public final class EncoderSizeLimit {

    private final MediaCodecInfo.VideoCapabilities videoCapabilities;

    private Size lastLoggedSize;

    public EncoderSizeLimit(MediaCodecInfo.VideoCapabilities videoCapabilities) {
        assert videoCapabilities != null;
        this.videoCapabilities = videoCapabilities;
    }

    private boolean isSupported(Size size) {
        return videoCapabilities.isSizeSupported(size.getWidth(), size.getHeight());
    }

    /**
     * Scale a size down, keeping its aspect ratio, until the encoder supports it.
     *
     * @param size the requested video size
     * @param alignment the alignment of the result
     * @return {@code size} if supported, else the largest smaller size with the same aspect ratio that is supported, else {@code size}
     * (to let the encoder report the error)
     */
    public synchronized Size fit(Size size, int alignment) {
        if (isSupported(size)) {
            lastLoggedSize = null;
            return size;
        }

        for (int maxSize = size.getMax() - alignment; maxSize >= alignment; maxSize -= alignment) {
            Size candidate = size.limit(maxSize).round(alignment);
            if (isSupported(candidate)) {
                if (!size.equals(lastLoggedSize)) {
                    lastLoggedSize = size;
                    Ln.i("Encoder does not support " + size.getWidth() + "x" + size.getHeight() + ", scaling video to " + candidate.getWidth()
                            + "x" + candidate.getHeight());
                }
                return candidate;
            }
        }

        if (!size.equals(lastLoggedSize)) {
            lastLoggedSize = size;
            Ln.w("Encoder advertises no size for " + size.getWidth() + "x" + size.getHeight());
        }
        return size;
    }
}
