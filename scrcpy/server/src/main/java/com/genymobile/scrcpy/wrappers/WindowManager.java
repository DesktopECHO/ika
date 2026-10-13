package com.genymobile.scrcpy.wrappers;

import com.genymobile.scrcpy.AndroidVersions;
import com.genymobile.scrcpy.model.Size;
import com.genymobile.scrcpy.util.Ln;

import android.annotation.TargetApi;
import android.graphics.Point;
import android.os.Build;
import android.os.IInterface;
import android.view.IDisplayWindowListener;

import java.lang.reflect.Method;

public final class WindowManager {

    @SuppressWarnings("checkstyle:LineLength")
    // <https://android.googlesource.com/platform/frameworks/base.git/+/2103ff441c66772c80c8560e322dcd9a45be7dcd/core/java/android/view/WindowManager.java#692>
    public static final int DISPLAY_IME_POLICY_LOCAL = 0;
    public static final int DISPLAY_IME_POLICY_FALLBACK_DISPLAY = 1;
    public static final int DISPLAY_IME_POLICY_HIDE = 2;

    // android.os.UserHandle.USER_CURRENT
    private static final int USER_CURRENT = -2;

    private final IInterface manager;
    private Method getRotationMethod;

    private Method freezeDisplayRotationMethod;
    private int freezeDisplayRotationMethodVersion;

    private Method isDisplayRotationFrozenMethod;
    private int isDisplayRotationFrozenMethodVersion;

    private Method thawDisplayRotationMethod;
    private int thawDisplayRotationMethodVersion;

    private Method getDisplayImePolicyMethod;
    private Method setDisplayImePolicyMethod;

    static WindowManager create() {
        IInterface manager = ServiceManager.getService("window", "android.view.IWindowManager");
        return new WindowManager(manager);
    }

    private WindowManager(IInterface manager) {
        this.manager = manager;
    }

    private Method getGetRotationMethod() throws NoSuchMethodException {
        if (getRotationMethod == null) {
            Class<?> cls = manager.getClass();
            try {
                // method changed since this commit:
                // https://android.googlesource.com/platform/frameworks/base/+/8ee7285128c3843401d4c4d0412cd66e86ba49e3%5E%21/#F2
                getRotationMethod = cls.getMethod("getDefaultDisplayRotation");
            } catch (NoSuchMethodException e) {
                // old version
                getRotationMethod = cls.getMethod("getRotation");
            }
        }
        return getRotationMethod;
    }

    private Method getFreezeDisplayRotationMethod() throws NoSuchMethodException {
        if (freezeDisplayRotationMethod == null) {
            try {
                // Android 15 preview and 14 QPR3 Beta added a String caller parameter for debugging:
                // <https://android.googlesource.com/platform/frameworks/base/+/670fb7f5c0d23cf51ead25538bcb017e03ed73ac%5E%21/>
                freezeDisplayRotationMethod = manager.getClass().getMethod("freezeDisplayRotation", int.class, int.class, String.class);
                freezeDisplayRotationMethodVersion = 0;
            } catch (NoSuchMethodException e) {
                try {
                    // New method added by this commit:
                    // <https://android.googlesource.com/platform/frameworks/base/+/90c9005e687aa0f63f1ac391adc1e8878ab31759%5E%21/>
                    freezeDisplayRotationMethod = manager.getClass().getMethod("freezeDisplayRotation", int.class, int.class);
                    freezeDisplayRotationMethodVersion = 1;
                } catch (NoSuchMethodException e1) {
                    freezeDisplayRotationMethod = manager.getClass().getMethod("freezeRotation", int.class);
                    freezeDisplayRotationMethodVersion = 2;
                }
            }
        }
        return freezeDisplayRotationMethod;
    }

    private Method getIsDisplayRotationFrozenMethod() throws NoSuchMethodException {
        if (isDisplayRotationFrozenMethod == null) {
            try {
                // New method added by this commit:
                // <https://android.googlesource.com/platform/frameworks/base/+/90c9005e687aa0f63f1ac391adc1e8878ab31759%5E%21/>
                isDisplayRotationFrozenMethod = manager.getClass().getMethod("isDisplayRotationFrozen", int.class);
                isDisplayRotationFrozenMethodVersion = 0;
            } catch (NoSuchMethodException e) {
                isDisplayRotationFrozenMethod = manager.getClass().getMethod("isRotationFrozen");
                isDisplayRotationFrozenMethodVersion = 1;
            }
        }
        return isDisplayRotationFrozenMethod;
    }

    private Method getThawDisplayRotationMethod() throws NoSuchMethodException {
        if (thawDisplayRotationMethod == null) {
            try {
                // Android 15 preview and 14 QPR3 Beta added a String caller parameter for debugging:
                // <https://android.googlesource.com/platform/frameworks/base/+/670fb7f5c0d23cf51ead25538bcb017e03ed73ac%5E%21/>
                thawDisplayRotationMethod = manager.getClass().getMethod("thawDisplayRotation", int.class, String.class);
                thawDisplayRotationMethodVersion = 0;
            } catch (NoSuchMethodException e) {
                try {
                    // New method added by this commit:
                    // <https://android.googlesource.com/platform/frameworks/base/+/90c9005e687aa0f63f1ac391adc1e8878ab31759%5E%21/>
                    thawDisplayRotationMethod = manager.getClass().getMethod("thawDisplayRotation", int.class);
                    thawDisplayRotationMethodVersion = 1;
                } catch (NoSuchMethodException e1) {
                    thawDisplayRotationMethod = manager.getClass().getMethod("thawRotation");
                    thawDisplayRotationMethodVersion = 2;
                }
            }
        }
        return thawDisplayRotationMethod;
    }

    public int getRotation() {
        try {
            Method method = getGetRotationMethod();
            return (int) method.invoke(manager);
        } catch (ReflectiveOperationException e) {
            Ln.e("Could not invoke method", e);
            return 0;
        }
    }

    public void freezeRotation(int displayId, int rotation) {
        try {
            Method method = getFreezeDisplayRotationMethod();
            switch (freezeDisplayRotationMethodVersion) {
                case 0:
                    method.invoke(manager, displayId, rotation, "scrcpy#freezeRotation");
                    break;
                case 1:
                    method.invoke(manager, displayId, rotation);
                    break;
                default:
                    if (displayId != 0) {
                        Ln.e("Secondary display rotation not supported on this device");
                        return;
                    }
                    method.invoke(manager, rotation);
                    break;
            }
        } catch (ReflectiveOperationException e) {
            Ln.e("Could not invoke method", e);
        }
    }

    public boolean isRotationFrozen(int displayId) {
        try {
            Method method = getIsDisplayRotationFrozenMethod();
            switch (isDisplayRotationFrozenMethodVersion) {
                case 0:
                    return (boolean) method.invoke(manager, displayId);
                default:
                    if (displayId != 0) {
                        Ln.e("Secondary display rotation not supported on this device");
                        return false;
                    }
                    return (boolean) method.invoke(manager);
            }
        } catch (ReflectiveOperationException e) {
            Ln.e("Could not invoke method", e);
            return false;
        }
    }

    public void thawRotation(int displayId) {
        try {
            Method method = getThawDisplayRotationMethod();
            switch (thawDisplayRotationMethodVersion) {
                case 0:
                    method.invoke(manager, displayId, "scrcpy#thawRotation");
                    break;
                case 1:
                    method.invoke(manager, displayId);
                    break;
                default:
                    if (displayId != 0) {
                        Ln.e("Secondary display rotation not supported on this device");
                        return;
                    }
                    method.invoke(manager);
                    break;
            }
        } catch (ReflectiveOperationException e) {
            Ln.e("Could not invoke method", e);
        }
    }

    @TargetApi(AndroidVersions.API_30_ANDROID_11)
    public int[] registerDisplayWindowListener(IDisplayWindowListener listener) {
        try {
            return (int[]) manager.getClass().getMethod("registerDisplayWindowListener", IDisplayWindowListener.class).invoke(manager, listener);
        } catch (Exception e) {
            Ln.e("Could not register display window listener", e);
        }
        return null;
    }

    @TargetApi(AndroidVersions.API_30_ANDROID_11)
    public void unregisterDisplayWindowListener(IDisplayWindowListener listener) {
        try {
            manager.getClass().getMethod("unregisterDisplayWindowListener", IDisplayWindowListener.class).invoke(manager, listener);
        } catch (Exception e) {
            Ln.e("Could not unregister display window listener", e);
        }
    }

    @TargetApi(AndroidVersions.API_29_ANDROID_10)
    private Method getGetDisplayImePolicyMethod() throws NoSuchMethodException {
        if (getDisplayImePolicyMethod == null) {
            if (Build.VERSION.SDK_INT >= AndroidVersions.API_31_ANDROID_12) {
                getDisplayImePolicyMethod = manager.getClass().getMethod("getDisplayImePolicy", int.class);
            } else {
                getDisplayImePolicyMethod = manager.getClass().getMethod("shouldShowIme", int.class);
            }
        }
        return getDisplayImePolicyMethod;
    }

    @TargetApi(AndroidVersions.API_29_ANDROID_10)
    public int getDisplayImePolicy(int displayId) {
        try {
            Method method = getGetDisplayImePolicyMethod();
            if (Build.VERSION.SDK_INT >= AndroidVersions.API_31_ANDROID_12) {
                return (int) method.invoke(manager, displayId);
            }
            boolean shouldShowIme = (boolean) method.invoke(manager, displayId);
            return shouldShowIme ? DISPLAY_IME_POLICY_LOCAL : DISPLAY_IME_POLICY_FALLBACK_DISPLAY;
        } catch (ReflectiveOperationException e) {
            Ln.e("Could not invoke method", e);
            return -1;
        }
    }

    @TargetApi(AndroidVersions.API_29_ANDROID_10)
    private Method getSetDisplayImePolicyMethod() throws NoSuchMethodException {
        if (setDisplayImePolicyMethod == null) {
            if (Build.VERSION.SDK_INT >= AndroidVersions.API_31_ANDROID_12) {
                setDisplayImePolicyMethod = manager.getClass().getMethod("setDisplayImePolicy", int.class, int.class);
            } else {
                setDisplayImePolicyMethod = manager.getClass().getMethod("setShouldShowIme", int.class, boolean.class);
            }
        }
        return setDisplayImePolicyMethod;
    }

    @TargetApi(AndroidVersions.API_29_ANDROID_10)
    public void setDisplayImePolicy(int displayId, int displayImePolicy) {
        try {
            Method method = getSetDisplayImePolicyMethod();
            if (Build.VERSION.SDK_INT >= AndroidVersions.API_31_ANDROID_12) {
                method.invoke(manager, displayId, displayImePolicy);
            } else if (displayImePolicy != DISPLAY_IME_POLICY_HIDE) {
                method.invoke(manager, displayId, displayImePolicy == DISPLAY_IME_POLICY_LOCAL);
            } else {
                Ln.w("DISPLAY_IME_POLICY_HIDE is not supported before Android 12");
            }
        } catch (ReflectiveOperationException e) {
            Ln.e("Could not invoke method", e);
        }
    }

    /**
     * Return the size forced on a display (as by "wm size"), or {@code null} if it has its initial size.
     */
    public Size getForcedDisplaySize(int displayId) {
        try {
            Point initial = new Point();
            Point base = new Point();
            manager.getClass().getMethod("getInitialDisplaySize", int.class, Point.class).invoke(manager, displayId, initial);
            manager.getClass().getMethod("getBaseDisplaySize", int.class, Point.class).invoke(manager, displayId, base);
            return base.equals(initial) ? null : new Size(base.x, base.y);
        } catch (ReflectiveOperationException e) {
            Ln.e("Could not read the display size", e);
            return null;
        }
    }

    /**
     * Return the physical size of a display, or {@code null} if unknown.
     */
    public Size getInitialDisplaySize(int displayId) {
        try {
            Point initial = new Point();
            manager.getClass().getMethod("getInitialDisplaySize", int.class, Point.class).invoke(manager, displayId, initial);
            return new Size(initial.x, initial.y);
        } catch (ReflectiveOperationException e) {
            Ln.e("Could not read the initial display size", e);
            return null;
        }
    }

    /**
     * Force the size of a display (as "wm size"), or restore its initial size if {@code size} is {@code null}.
     */
    public boolean setForcedDisplaySize(int displayId, Size size) {
        try {
            if (size != null) {
                manager.getClass().getMethod("setForcedDisplaySize", int.class, int.class, int.class)
                        .invoke(manager, displayId, size.getWidth(), size.getHeight());
            } else {
                manager.getClass().getMethod("clearForcedDisplaySize", int.class).invoke(manager, displayId);
            }
            return true;
        } catch (ReflectiveOperationException e) {
            Ln.e("Could not set the display size", e);
            return false;
        }
    }

    /**
     * Return the density forced on a display (as by "wm density"), or 0 if it has its initial density.
     */
    public int getForcedDisplayDensity(int displayId) {
        try {
            int initial = (int) manager.getClass().getMethod("getInitialDisplayDensity", int.class).invoke(manager, displayId);
            int base = (int) manager.getClass().getMethod("getBaseDisplayDensity", int.class).invoke(manager, displayId);
            return base == initial ? 0 : base;
        } catch (ReflectiveOperationException e) {
            Ln.e("Could not read the display density", e);
            return 0;
        }
    }

    /**
     * Force the density of a display (as "wm density"), or restore its initial density if {@code density} is 0.
     */
    public boolean setForcedDisplayDensity(int displayId, int density) {
        try {
            if (density > 0) {
                manager.getClass().getMethod("setForcedDisplayDensityForUser", int.class, int.class, int.class)
                        .invoke(manager, displayId, density, USER_CURRENT);
            } else {
                manager.getClass().getMethod("clearForcedDisplayDensityForUser", int.class, int.class)
                        .invoke(manager, displayId, USER_CURRENT);
            }
            return true;
        } catch (ReflectiveOperationException e) {
            Ln.e("Could not set the display density", e);
            return false;
        }
    }

    /**
     * Turn off (as "wm scaling off") or restore Android's scaling of a forced display size to the physical display.
     */
    public boolean setDisplayScalingDisabled(int displayId, boolean disabled) {
        try {
            // 0: FORCE_SCALING_MODE_AUTO, 1: FORCE_SCALING_MODE_DISABLED
            manager.getClass().getMethod("setForcedDisplayScalingMode", int.class, int.class).invoke(manager, displayId, disabled ? 1 : 0);
            return true;
        } catch (ReflectiveOperationException e) {
            Ln.e("Could not set the display scaling mode", e);
            return false;
        }
    }
}
