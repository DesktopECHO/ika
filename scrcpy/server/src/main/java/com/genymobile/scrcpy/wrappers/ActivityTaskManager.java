package com.genymobile.scrcpy.wrappers;

import android.os.IInterface;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.List;

public final class ActivityTaskManager {

    private final IInterface manager;
    private Method getAllRootTaskInfosOnDisplayMethod;
    private Field topActivityField;

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
}
