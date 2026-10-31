package com.genymobile.scrcpy.control;

import com.genymobile.scrcpy.FakeContext;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.wrappers.ServiceManager;

import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.content.res.Resources;
import android.content.res.TypedArray;

/**
 * Background color of the current Android theme (light or dark, with the wallpaper colors), shown by the client until the display content
 * arrives.
 */
public final class ThemeBackground {

    private static final int BLACK = 0xFF000000;
    private static final int WHITE = 0xFFFFFFFF;

    private ThemeBackground() {
        // not instantiable
    }

    public static int resolve() {
        Configuration global = ServiceManager.getActivityManager().getConfiguration();
        boolean night = global != null && (global.uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        int fallback = night ? BLACK : WHITE;
        try {
            // Unlike the system context of this process, the resources of the "android" package include its enabled overlays, which hold
            // the wallpaper colors, as currently set
            PackageManager pm = FakeContext.get().getPackageManager();
            Resources res = pm.getResourcesForApplication("android");
            if (global != null) {
                Configuration config = new Configuration(res.getConfiguration());
                config.uiMode = global.uiMode;
                res.updateConfiguration(config, res.getDisplayMetrics());
            }
            Resources.Theme theme = res.newTheme();
            theme.applyStyle(android.R.style.Theme_DeviceDefault_DayNight, true);
            TypedArray a = theme.obtainStyledAttributes(new int[]{android.R.attr.colorBackground});
            try {
                return a.getColor(0, fallback) | 0xFF000000;
            } finally {
                a.recycle();
            }
        } catch (PackageManager.NameNotFoundException | RuntimeException e) {
            Ln.w("Could not resolve the theme background: " + e.getMessage());
            return fallback;
        }
    }
}
