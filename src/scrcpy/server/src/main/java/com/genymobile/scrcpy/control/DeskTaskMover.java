package com.genymobile.scrcpy.control;

import com.genymobile.scrcpy.util.Command;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.wrappers.ServiceManager;

import android.os.SystemClock;

import java.io.IOException;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

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
    // A task is moved once the Shell's task organizer knows it. Asked to move a task that the window manager has created but that
    // has not appeared to the Shell yet (its opening transition is not ready), the Shell takes the task for one in the background:
    // it starts the task again, and exits the desk in a transition that overlaps the opening one. The app's own activity changes
    // get merged into that exit animation, and its surface can stay hidden: a black window that no input reaches until it is
    // resized. A task the Shell has not listed for this long is moved anyway, for a Shell whose dump does not list its tasks.
    private static final long SHELL_KNOWS_TASK_TIMEOUT_MS = 3000;
    // A task of the organizer in the Shell's dump: "#3 task=145 listener=..."
    private static final Pattern SHELL_TASK_PATTERN = Pattern.compile("^\\s*#\\d+ task=(\\d+) listener=");

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
        // The freeform tasks waiting for the Shell to know them, and when they were first seen
        Map<Integer, Long> firstSeen = new HashMap<>();
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
                firstSeen.keySet().retainAll(taskIds);
                long now = SystemClock.uptimeMillis();
                Set<Integer> shellTasks = null;
                for (int taskId : taskIds) {
                    Integer previous = attempts.get(taskId);
                    int count = previous != null ? previous : 0;
                    Long last = lastAttempt.get(taskId);
                    if (count >= MAX_ATTEMPTS || (last != null && now - last < RETRY_INTERVAL_MS)) {
                        continue;
                    }
                    Long seen = firstSeen.get(taskId);
                    if (seen == null) {
                        seen = now;
                        firstSeen.put(taskId, seen);
                    }
                    if (now - seen < SHELL_KNOWS_TASK_TIMEOUT_MS) {
                        if (shellTasks == null) {
                            shellTasks = listShellTasks();
                        }
                        if (shellTasks != null && !shellTasks.contains(taskId)) {
                            // Not appeared to the Shell yet
                            continue;
                        }
                    }
                    attempts.put(taskId, count + 1);
                    lastAttempt.put(taskId, now);
                    moveTaskOutOfDesk(taskId);
                }
                Thread.sleep(POLL_INTERVAL_MS);
            }
        } catch (InterruptedException e) {
            // stopped
        }
    }

    // The ids of the tasks the Shell's task organizer knows, from the Shell's dump, or null when it cannot be read
    private static Set<Integer> listShellTasks() throws InterruptedException {
        String dump;
        try {
            dump = Command.execReadOutput("dumpsys", "activity", "service", "SystemUIService", "WMShell");
        } catch (IOException e) {
            Ln.w("Could not read the Shell's tasks", e);
            return null;
        }
        // The ShellTaskOrganizer section (its listeners, then its tasks), up to the next section at its indentation
        int start = dump.indexOf("\n    ShellTaskOrganizer\n");
        if (start < 0) {
            return null;
        }
        Set<Integer> taskIds = new HashSet<>();
        int lineStart = start + 1;
        boolean header = true;
        while (lineStart < dump.length()) {
            int lineEnd = dump.indexOf('\n', lineStart);
            if (lineEnd < 0) {
                lineEnd = dump.length();
            }
            String line = dump.substring(lineStart, lineEnd);
            if (!header && !line.isEmpty() && !line.startsWith("     ")) {
                break;
            }
            header = false;
            Matcher m = SHELL_TASK_PATTERN.matcher(line);
            if (m.find()) {
                taskIds.add(Integer.parseInt(m.group(1)));
            }
            lineStart = lineEnd + 1;
        }
        return taskIds;
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
