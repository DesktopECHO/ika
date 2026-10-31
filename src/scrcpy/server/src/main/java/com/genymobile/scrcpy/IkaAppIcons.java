package com.genymobile.scrcpy;

import com.genymobile.scrcpy.device.Device;

import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.content.res.Resources;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import android.util.DisplayMetrics;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintWriter;

/**
 * Renders the launcher icon of every launchable app to OUTPUT_DIR/PACKAGE.png,
 * and lists the launchable games in OUTPUT_DIR/games.list, for Ika's desktop
 * menu entries. It runs through app_process like the server:
 *
 *   CLASSPATH=JAR app_process / com.genymobile.scrcpy.IkaAppIcons OUTPUT_DIR SIZE
 *
 * Android draws the icons itself, so adaptive icons come out masked and layered
 * as the launcher shows them.
 */
public final class IkaAppIcons {

    private IkaAppIcons() {
        // not instantiable
    }

    public static void main(String... args) {
        int status = 0;
        try {
            run(args);
        } catch (Throwable t) {
            System.err.println("ERROR: " + t);
            status = 1;
        } finally {
            // Like the server, exit explicitly: the Android SDK may leave
            // non-daemon threads running.
            System.exit(status);
        }
    }

    private static void run(String... args) throws IOException {
        if (args.length != 2) {
            throw new IllegalArgumentException("usage: IkaAppIcons OUTPUT_DIR SIZE");
        }
        File outputDir = new File(args[0]);
        int size = Integer.parseInt(args[1]);
        if (!outputDir.isDirectory() && !outputDir.mkdirs()) {
            throw new IOException("Could not create " + outputDir);
        }

        Looper.prepareMainLooper();
        Workarounds.apply();

        PackageManager pm = FakeContext.get().getPackageManager();
        int rendered = 0;
        StringBuilder games = new StringBuilder();
        for (ApplicationInfo appInfo : pm.getInstalledApplications(0)) {
            if (!appInfo.enabled) {
                continue;
            }
            // The same launchable-app filter as the app list (Device.listApps())
            Intent launchIntent = Device.getLaunchIntent(pm, appInfo.packageName);
            if (launchIntent == null) {
                continue;
            }
            if (isGame(appInfo)) {
                games.append(appInfo.packageName).append('\n');
            }
            try {
                Drawable icon = loadIcon(pm, launchIntent, appInfo);
                writePng(render(icon, size), new File(outputDir, appInfo.packageName + ".png"));
                ++rendered;
            } catch (Exception e) {
                System.err.println("WARN: " + appInfo.packageName + ": " + e);
            }
        }
        try (PrintWriter out = new PrintWriter(new File(outputDir, "games.list"), "UTF-8")) {
            out.print(games);
        }
        System.out.println("Rendered " + rendered + " app icons");
    }

    /**
     * Apps that declare android:appCategory="game", or the older isGame flag:
     * the same apps that Android's game mode service treats as games.
     */
    @SuppressWarnings("deprecation")
    private static boolean isGame(ApplicationInfo appInfo) {
        return appInfo.category == ApplicationInfo.CATEGORY_GAME
                || (appInfo.flags & ApplicationInfo.FLAG_IS_GAME) != 0;
    }

    private static Drawable loadIcon(PackageManager pm, Intent launchIntent, ApplicationInfo appInfo)
            throws PackageManager.NameNotFoundException {
        ResolveInfo resolveInfo = pm.resolveActivity(launchIntent, 0);
        if (resolveInfo != null && resolveInfo.activityInfo != null) {
            ActivityInfo activityInfo = resolveInfo.activityInfo;
            int iconResource = activityInfo.getIconResource();
            if (iconResource != 0) {
                // Load the highest-density variant so that icons stay sharp at
                // desktop sizes, whatever the guest display density is.
                Resources resources = pm.getResourcesForApplication(activityInfo.applicationInfo);
                try {
                    Drawable icon = resources.getDrawableForDensity(iconResource, DisplayMetrics.DENSITY_XXXHIGH, null);
                    if (icon != null) {
                        return icon;
                    }
                } catch (Resources.NotFoundException e) {
                    // fall back below
                }
            }
            return resolveInfo.loadIcon(pm);
        }
        return pm.getApplicationIcon(appInfo);
    }

    private static Bitmap render(Drawable drawable, int size) {
        Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        drawable.setBounds(0, 0, size, size);
        drawable.draw(canvas);
        return bitmap;
    }

    private static void writePng(Bitmap bitmap, File file) throws IOException {
        try (OutputStream out = new FileOutputStream(file)) {
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) {
                throw new IOException("PNG encoding failed");
            }
        } finally {
            bitmap.recycle();
        }
    }
}
