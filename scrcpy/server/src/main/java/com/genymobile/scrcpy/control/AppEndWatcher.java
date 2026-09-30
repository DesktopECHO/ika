package com.genymobile.scrcpy.control;

import com.genymobile.scrcpy.device.Device;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.wrappers.ServiceManager;

import android.os.SystemClock;

/**
 * Reports when the app on a new virtual display is gone: after the display has
 * held an activity, it stays without one for EMPTY_GRACE_MS. That covers the app
 * finishing, being killed (Android removes the task of a foreground activity it
 * cannot restore), and being moved to another display. A task Android keeps
 * while restarting the app stays on the display and does not count.
 */
final class AppEndWatcher {

    private static final long POLL_INTERVAL_MS = 500;
    // Covers apps that finish one activity just before starting the next
    private static final long EMPTY_GRACE_MS = 1000;

    private final Runnable onAppEnded;
    private volatile int displayId = Device.DISPLAY_ID_NONE;
    private Thread thread;

    AppEndWatcher(Runnable onAppEnded) {
        this.onAppEnded = onAppEnded;
    }

    void setDisplayId(int displayId) {
        this.displayId = displayId;
    }

    synchronized void start() {
        if (thread == null) {
            thread = new Thread(this::run, "app-end-watcher");
            thread.setDaemon(true);
            thread.start();
        }
    }

    synchronized void stop() {
        if (thread != null) {
            thread.interrupt();
        }
    }

    private void run() {
        boolean seenActivity = false;
        long emptySince = 0;
        try {
            while (!Thread.currentThread().isInterrupted()) {
                Thread.sleep(POLL_INTERVAL_MS);
                int id = displayId;
                if (id == Device.DISPLAY_ID_NONE) {
                    continue;
                }

                int count;
                try {
                    count = ServiceManager.getActivityTaskManager().getActivityTaskCount(id);
                } catch (Exception | AssertionError e) {
                    Ln.w("Could not list the tasks of display " + id + "; app end detection disabled", e);
                    return;
                }

                if (count > 0) {
                    seenActivity = true;
                    emptySince = 0;
                } else if (seenActivity) {
                    long now = SystemClock.uptimeMillis();
                    if (emptySince == 0) {
                        emptySince = now;
                    } else if (now - emptySince >= EMPTY_GRACE_MS) {
                        Ln.i("No app left on display " + id);
                        onAppEnded.run();
                        return;
                    }
                }
            }
        } catch (InterruptedException e) {
            // stopped
        }
    }
}
