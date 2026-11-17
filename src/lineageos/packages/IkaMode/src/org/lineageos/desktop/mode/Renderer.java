package org.lineageos.desktop.mode;

import android.app.Activity;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES20;

import java.util.function.Consumer;

/**
 * The GPU's renderer as OpenGL ES names it (GL_RENDERER), which is what apps see whether the
 * GPU is reached through Vulkan (ANGLE) or OpenGL ES only.
 */
final class Renderer {
    // Read once, on the main thread's side: the first read takes about 80 ms, for a context.
    private static String sName;
    private static boolean sRead;

    private Renderer() {
    }

    /**
     * Calls BACK on ACTIVITY's main thread with the renderer's name, or null if there is no
     * OpenGL ES. The first time, it is read on a thread of its own.
     */
    static void read(Activity activity, Consumer<String> back) {
        if (sRead) {
            back.accept(sName);
            return;
        }
        new Thread(() -> {
            String name = query();
            activity.runOnUiThread(() -> {
                sName = name;
                sRead = true;
                back.accept(name);
            });
        }, "Renderer").start();
    }

    /**
     * The name as two lines: what is before its first parenthesis, and what is inside it, when
     * that parenthesis closes at the end. Otherwise the whole name, with no second line.
     */
    static String[] split(String name) {
        name = name.trim();
        int open = name.indexOf('(');
        if (open > 0) {
            int depth = 0;
            for (int i = open; i < name.length(); i++) {
                char c = name.charAt(i);
                if (c == '(') {
                    depth++;
                } else if (c == ')' && --depth == 0) {
                    if (i == name.length() - 1) {
                        return new String[] {name.substring(0, open).trim(),
                                name.substring(open + 1, i).trim()};
                    }
                    break;
                }
            }
        }
        return new String[] {name, null};
    }

    /**
     * Reads GL_RENDERER in an OpenGL ES 2 context on a 1x1 pixel off-screen surface. The display
     * is left initialized, as the app's own drawing shares it.
     */
    private static String query() {
        EGLDisplay display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        if (display == EGL14.EGL_NO_DISPLAY
                || !EGL14.eglInitialize(display, new int[2], 0, new int[2], 1)) {
            return null;
        }
        EGLConfig[] configs = new EGLConfig[1];
        int[] count = new int[1];
        if (!EGL14.eglChooseConfig(display, new int[] {
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_NONE}, 0, configs, 0, 1, count, 0) || count[0] == 0) {
            return null;
        }
        EGLContext context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                new int[] {EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE}, 0);
        if (context == EGL14.EGL_NO_CONTEXT) {
            return null;
        }
        EGLSurface surface = EGL14.eglCreatePbufferSurface(display, configs[0], new int[] {
                EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE}, 0);
        String name = null;
        if (surface != EGL14.EGL_NO_SURFACE) {
            if (EGL14.eglMakeCurrent(display, surface, surface, context)) {
                name = GLES20.glGetString(GLES20.GL_RENDERER);
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
                        EGL14.EGL_NO_CONTEXT);
            }
            EGL14.eglDestroySurface(display, surface);
        }
        EGL14.eglDestroyContext(display, context);
        EGL14.eglReleaseThread();
        return name == null || name.trim().isEmpty() ? null : name;
    }
}
