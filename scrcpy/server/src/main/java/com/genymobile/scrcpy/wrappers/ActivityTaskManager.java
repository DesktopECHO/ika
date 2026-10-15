package com.genymobile.scrcpy.wrappers;

import android.os.IInterface;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

public final class ActivityTaskManager {

    private final IInterface manager;
    private Method getAllRootTaskInfosOnDisplayMethod;
    private Field topActivityField;
    private Field taskIdField;
    private Field childTaskIdsField;
    private Field configurationField;
    private Field windowConfigurationField;
    private Method getWindowingModeMethod;

    // android.app.WindowConfiguration.WINDOWING_MODE_FREEFORM
    private static final int WINDOWING_MODE_FREEFORM = 5;

    static ActivityTaskManager create() {
        IInterface manager = ServiceManager.getService("activity_task", "android.app.IActivityTaskManager");
        return new ActivityTaskManager(manager);
    }

    private ActivityTaskManager(IInterface manager) {
        this.manager = manager;
    }

    private Method getGetAllRootTaskInfosOnDisplayMethod() throws NoSuchMethodException {
        if (getAllRootTaskInfosOnDisplayMethod == null) {
            // Available since Android 12
            getAllRootTaskInfosOnDisplayMethod = manager.getClass().getMethod("getAllRootTaskInfosOnDisplay", int.class);
        }
        return getAllRootTaskInfosOnDisplayMethod;
    }

    /**
     * Return the number of root tasks on the display that hold an activity.
     */
    public int getActivityTaskCount(int displayId) throws ReflectiveOperationException {
        List<?> infos = (List<?>) getGetAllRootTaskInfosOnDisplayMethod().invoke(manager, displayId);
        int count = 0;
        if (infos != null) {
            for (Object info : infos) {
                if (topActivityField == null) {
                    // RootTaskInfo extends TaskInfo, which declares the public field
                    topActivityField = info.getClass().getField("topActivity");
                }
                if (topActivityField.get(info) != null) {
                    ++count;
                }
            }
        }
        return count;
    }

    /**
     * Return the ids of the tasks in freeform on the display that hold an activity: the child tasks of a freeform root task (a desk), or the
     * root task itself if it has none.
     */
    public List<Integer> getFreeformTaskIds(int displayId) throws ReflectiveOperationException {
        List<?> infos = (List<?>) getGetAllRootTaskInfosOnDisplayMethod().invoke(manager, displayId);
        List<Integer> taskIds = new ArrayList<>();
        if (infos == null) {
            return taskIds;
        }
        for (Object info : infos) {
            if (topActivityField == null) {
                Class<?> cls = info.getClass();
                topActivityField = cls.getField("topActivity");
                taskIdField = cls.getField("taskId");
                childTaskIdsField = cls.getField("childTaskIds");
                configurationField = cls.getField("configuration");
            }
            if (topActivityField.get(info) == null) {
                continue;
            }
            Object configuration = configurationField.get(info);
            if (windowConfigurationField == null) {
                windowConfigurationField = configuration.getClass().getField("windowConfiguration");
            }
            Object windowConfiguration = windowConfigurationField.get(configuration);
            if (getWindowingModeMethod == null) {
                getWindowingModeMethod = windowConfiguration.getClass().getMethod("getWindowingMode");
            }
            if ((int) getWindowingModeMethod.invoke(windowConfiguration) != WINDOWING_MODE_FREEFORM) {
                continue;
            }
            int[] childTaskIds = (int[]) childTaskIdsField.get(info);
            if (childTaskIds != null && childTaskIds.length > 0) {
                for (int childTaskId : childTaskIds) {
                    taskIds.add(childTaskId);
                }
            } else {
                taskIds.add(taskIdField.getInt(info));
            }
        }
        return taskIds;
    }
}
