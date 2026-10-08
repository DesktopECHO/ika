package com.genymobile.scrcpy.display;

import com.genymobile.scrcpy.model.Size;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.wrappers.ServiceManager;
import com.genymobile.scrcpy.wrappers.WindowManager;

/**
 * Resizes the main display to follow the client window (flex display without a new virtual display).
 * <p/>
 * The physical display keeps its size: the requested size is forced on it (as "wm size"), and when it fits, Android's scaling is turned off
 * so that it is drawn 1:1 in the physical frame instead of stretched to fill it. The client then shows that region unscaled.
 * <p/>
 * The listener is notified once the display has reached a requested size and its new configuration has been dispatched.
 */
public final class PrimaryDisplayResizer {

    public interface Listener {
        void onDisplayReady(int displayId, Size size);
    }

    // Must match FLEX_DISPLAY_MIN_WIDTH/HEIGHT in the client
    private static final int MIN_WIDTH = 360;
    private static final int MIN_HEIGHT = 540;

    private static final int DISPLAY_ID = 0;

    private final int dpi;
    private final Listener listener;
    private final DisplayMonitor displayMonitor = new DisplayMonitor();

    private Size physicalSize;
    private Boolean scalingDisabled;
    private boolean densityApplied;

    // The size the client waits for, null if none
    private Size pendingSize;

    public PrimaryDisplayResizer(int dpi, Listener listener) {
        this.dpi = dpi;
        this.listener = listener;
    }

    public void start() {
        DisplayInfo info = ServiceManager.getDisplayManager().getDisplayInfo(DISPLAY_ID);
        if (info != null) {
            displayMonitor.setSessionDisplayProperties(new DisplayProperties(info.getSize(), info.getRotation()));
        }
        displayMonitor.start(DISPLAY_ID, props -> checkReady());
    }

    public void stop() {
        displayMonitor.stopAndRelease();
    }

    public static Size clamp(int width, int height) {
        return new Size(Math.max(width, MIN_WIDTH), Math.max(height, MIN_HEIGHT));
    }

    public void resize(int width, int height) {
        Size size = clamp(width, height);
        WindowManager wm = ServiceManager.getWindowManager();

        if (physicalSize == null) {
            physicalSize = wm.getInitialDisplaySize(DISPLAY_ID);
        }
        boolean fits = physicalSize != null && size.getWidth() <= physicalSize.getWidth() && size.getHeight() <= physicalSize.getHeight();
        if (scalingDisabled == null || scalingDisabled != fits) {
            // Before the size, so that the new size is never shown stretched
            if (wm.setDisplayScalingDisabled(DISPLAY_ID, fits)) {
                scalingDisabled = fits;
            }
        }

        if (!densityApplied && dpi > 0) {
            wm.setForcedDisplayDensity(DISPLAY_ID, dpi);
            densityApplied = true;
        }

        DisplayInfo info = ServiceManager.getDisplayManager().getDisplayInfo(DISPLAY_ID);
        if (info != null && size.equals(info.getSize())) {
            // Nothing will change, the display is already ready
            synchronized (this) {
                pendingSize = null;
            }
            listener.onDisplayReady(DISPLAY_ID, size);
            return;
        }

        synchronized (this) {
            pendingSize = size;
        }
        Ln.i("Resize main display to " + size.getWidth() + "x" + size.getHeight() + (dpi > 0 ? "/" + dpi : ""));
        if (!wm.setForcedDisplaySize(DISPLAY_ID, size)) {
            synchronized (this) {
                pendingSize = null;
            }
        }
    }

    private void checkReady() {
        DisplayInfo info = ServiceManager.getDisplayManager().getDisplayInfo(DISPLAY_ID);
        if (info == null) {
            return;
        }
        Size size = info.getSize();
        synchronized (this) {
            if (!size.equals(pendingSize)) {
                // Not there yet (or not requested)
                return;
            }
            pendingSize = null;
        }
        listener.onDisplayReady(DISPLAY_ID, size);
    }
}
