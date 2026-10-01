package com.genymobile.scrcpy.video;

import com.genymobile.scrcpy.device.ConfigurationException;
import com.genymobile.scrcpy.device.Size;

import android.view.Surface;

import java.io.IOException;

/**
 * A video source which can be rendered on a Surface for encoding.
 */
public abstract class SurfaceCapture {

    public interface CaptureListener {
        void onInvalidated();
    }

    private CaptureListener listener;
    private EncoderSizeLimit encoderSizeLimit;

    /**
     * Notify the listener that the capture has been invalidated (for example, because its size changed).
     */
    protected void invalidate() {
        listener.onInvalidated();
    }

    /**
     * Set the sizes the encoder advertises, to scale the video down to them in {@link #prepare()} (set by the encoder before
     * {@link #init()}).
     *
     * @param encoderSizeLimit the encoder sizes, or {@code null} for no limit
     */
    public void setEncoderSizeLimit(EncoderSizeLimit encoderSizeLimit) {
        this.encoderSizeLimit = encoderSizeLimit;
    }

    /**
     * Scale a video size down, keeping its aspect ratio, until the encoder supports it.
     *
     * @param size the video size
     * @param alignment the alignment of the result
     * @return {@code size} if the encoder supports it (or no limit is set), else the largest smaller size it supports
     */
    protected Size fitToEncoder(Size size, int alignment) {
        return encoderSizeLimit == null ? size : encoderSizeLimit.fit(size, alignment);
    }

    /**
     * Called once before the first capture starts.
     */
    public final void init(CaptureListener listener) throws ConfigurationException, IOException {
        this.listener = listener;
        init();
    }

    /**
     * Called once before the first capture starts.
     */
    protected abstract void init() throws ConfigurationException, IOException;

    /**
     * Called after the last capture ends (if and only if {@link #init()} has been called).
     */
    public abstract void release();

    /**
     * Called once before each capture starts, before {@link #getSize()}.
     */
    public void prepare() throws ConfigurationException, IOException {
        // empty by default
    }

    /**
     * Start the capture to the target surface.
     *
     * @param surface the surface which will be encoded
     */
    public abstract void start(Surface surface) throws IOException;

    /**
     * Stop the capture.
     */
    public void stop() {
        // Do nothing by default
    }

    /**
     * Return the video size
     *
     * @return the video size
     */
    public abstract Size getSize();

    /**
     * Set the maximum capture size (set by the encoder if it does not support the current size).
     *
     * @param maxSize Maximum size
     */
    public abstract boolean setMaxSize(int maxSize);

    /**
     * Indicate if the capture has been closed internally.
     *
     * @return {@code true} is the capture is closed, {@code false} otherwise.
     */
    public boolean isClosed() {
        return false;
    }

    /**
     * Manually request to invalidate (typically a user request).
     * <p>
     * The capture implementation is free to ignore the request and do nothing.
     */
    public abstract void requestInvalidate();
}
