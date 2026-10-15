package com.genymobile.scrcpy.control;

import com.genymobile.scrcpy.util.Command;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.wrappers.ServiceManager;

import android.os.SystemClock;

import java.io.IOException;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Keeps the tasks of a Cuttlefish display out of desktop mode, so that the app fills the window.
 * <p/>
 * The guest reports every Cuttlefish display as internal, so the WM Shell puts the apps started there into a desk, as freeform windows. The
 * tasks found in freeform are moved out of the desk into fullscreen with the WM Shell command.
 */
final class DeskTaskMover {

    private static final long POLL_INTERVAL_MS = 250;
    // The Shell can put a task back into a desk, for example when the display is resized
    private static final long RETRY_INTERVAL_MS = 1000;
    private static final int MAX_ATTEMPTS = 5;

    private final int displayId;
    private Thread thread;

    DeskTaskMover(int displayId) {
        this.displayId = displayId;
    }

    synchronized void start() {
        thread = new Thread(this::run, "desk-task-mover");
        thread.setDaemon(true);
        thread.start();
    }

    synchronized void stop() {
        if (thread != null) {
            thread.interrupt();
        }
    }

    private void run() {
        // The tasks asked to move while they stay in freeform: attempts, and the time of the last one
        Map<Integer, Integer> attempts = new HashMap<>();
        Map<Integer, Long> lastAttempt = new HashMap<>();
        try {
            while (!Thread.currentThread().isInterrupted()) {
                List<Integer> taskIds;
                try {
                    taskIds = ServiceManager.getActivityTaskManager().getFreeformTaskIds(displayId);
                } catch (Exception | AssertionError e) {
                    Ln.w("Could not list the tasks of display " + displayId + "; apps may open in a desk", e);
                    return;
                }
                attempts.keySet().retainAll(taskIds);
                lastAttempt.keySet().retainAll(taskIds);
                long now = SystemClock.uptimeMillis();
                for (int taskId : taskIds) {
                    Integer previous = attempts.get(taskId);
                    int count = previous != null ? previous : 0;
                    Long last = lastAttempt.get(taskId);
                    if (count < MAX_ATTEMPTS && (last == null || now - last >= RETRY_INTERVAL_MS)) {
                        attempts.put(taskId, count + 1);
                        lastAttempt.put(taskId, now);
                        moveTaskOutOfDesk(taskId);
                    }
                }
                Thread.sleep(POLL_INTERVAL_MS);
            }
        } catch (InterruptedException e) {
            // stopped
        }
    }

    private static void moveTaskOutOfDesk(int taskId) throws InterruptedException {
        Ln.i("Move task " + taskId + " out of its desk");
        try {
            Command.exec("dumpsys", "activity", "service", "SystemUIService", "WMShell", "desktopmode", "moveTaskOutOfDesk",
                    String.valueOf(taskId));
        } catch (IOException e) {
            Ln.w("Could not move task " + taskId + " out of its desk", e);
        }
    }
}
