package org.lineageos.desktop.mode;

import android.app.ActivityTaskManager;
import android.app.role.RoleManager;
import android.content.BroadcastReceiver;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.FeatureInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.RemoteException;
import android.os.SystemProperties;
import android.os.UserManager;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.Log;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;
import java.util.function.Consumer;

/**
 * Ika's mode, TV or desktop, kept in persist.sys.ika.mode ("tv" or "desktop"; desktop when it is
 * unset). Only Desktop/TV (SwitcherActivity) changes it, once the user confirms.
 *
 * The parts that are set up only at boot read the property: the TV features (SystemConfig), the
 * TV overlays, TV services and windowing, so a switch always restarts Android. This app applies
 * the rest for the mode Android booted in: the Settings app (TV Settings or the desktop's; they
 * answer the same intents, so only one is enabled), the keyboard (the Leanback keyboard in TV
 * mode, the previous one otherwise) and the launchers: Launcher3 is off in TV mode and the TV
 * launchers on the desktop. TV mode's Home app is the TV launcher chosen in Desktop/TV, such as
 * Catapult or a TV launcher from Google Play, and the desktop's comes back when switching back to
 * it. Choosing a Home app never changes the mode on its own.
 */
final class ModeController {
    static final String TAG = "IkaMode";
    /** Runs every switch in order, off the main thread. */
    static final Executor EXECUTOR = Executors.newSingleThreadExecutor();

    private static final String MODE_PROP = "persist.sys.ika.mode";
    private static final String MODE_TV = "tv";
    private static final String MODE_DESKTOP = "desktop";

    static final String TV_LAUNCHER = "org.lineageos.tv.launcher";
    static final String DESKTOP_LAUNCHER = "com.android.launcher3";
    private static final String TV_SETTINGS = "com.android.tv.settings";
    private static final String DESKTOP_SETTINGS = "com.android.settings";
    private static final String LEANBACK = "android.software.leanback";
    private static final String LEANBACK_IME_PACKAGE = "com.android.inputmethod.leanback";
    private static final String LEANBACK_IME =
            LEANBACK_IME_PACKAGE + "/.service.LeanbackImeService";

    private static final String PREFS = "mode";
    private static final String KEY_APPLIED_MODE = "applied_mode";
    private static final String KEY_DESKTOP_IME = "desktop_ime";
    private static final String KEY_TV_HOME = "tv_home";
    private static final String KEY_DESKTOP_HOME = "desktop_home";
    private static final String KEY_TV_LAUNCHERS_OFF = "tv_launchers_off";

    // Disabled apps too, and before the user is unlocked, when this app first applies the mode.
    private static final int MATCH_ALL = PackageManager.MATCH_DISABLED_COMPONENTS
            | PackageManager.MATCH_DIRECT_BOOT_AWARE | PackageManager.MATCH_DIRECT_BOOT_UNAWARE;

    private ModeController() {}

    /** Whether Android booted in TV mode. */
    static boolean isTvMode() {
        return MODE_TV.equals(SystemProperties.get(MODE_PROP, MODE_DESKTOP));
    }

    /** Applies the mode Android booted in and brings back its Play Store update. */
    static void apply(Context context) {
        boolean tv = isTvMode();
        if (!tv) {
            startClean(context);
        }
        apply(context, tv);
        PlayStoreUpdates.restore(context, tv);
        PlayStoreUpdates.forget(context, tv);
    }

    /**
     * The desktop starts clean: the recent apps go as the user is unlocked, so that the desktop
     * doesn't open their windows again and the taskbar doesn't show them. Only as Android starts:
     * this app can also start again later, when its process has gone.
     */
    private static void startClean(Context context) {
        if (context.getSystemService(UserManager.class).isUserUnlocked()) {
            return;
        }
        context.registerReceiver(new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent intent) {
                c.unregisterReceiver(this);
                try {
                    ActivityTaskManager.getService().removeAllVisibleRecentTasks();
                    Log.i(TAG, "Cleared the recent apps");
                } catch (RemoteException e) {
                    Log.w(TAG, "Could not clear the recent apps", e);
                }
            }
        }, new IntentFilter(Intent.ACTION_USER_UNLOCKED));
    }

    private static void apply(Context context, boolean tv) {
        PackageManager pm = context.getPackageManager();
        // Enable before disabling, so that one Settings app is always there. A Settings screen
        // that is open stays until it is closed.
        setPackageEnabled(pm, tv ? TV_SETTINGS : DESKTOP_SETTINGS, true);
        setPackageEnabled(pm, tv ? DESKTOP_SETTINGS : TV_SETTINGS, false);
        // The other mode's launcher is off. The desktop shell has nothing to show in TV mode,
        // and the whole app is off there, not only its Home activity, which its Quickstep
        // service, still bound by SystemUI, needs. The TV launcher is off on the desktop, so
        // that it is no Home app to choose there.
        setPackageEnabled(pm, tv ? TV_LAUNCHER : DESKTOP_LAUNCHER, true);
        setPackageEnabled(pm, tv ? DESKTOP_LAUNCHER : TV_LAUNCHER, false);
        // So are the other TV launchers, such as those from Google Play, which would otherwise
        // start in a window on the desktop.
        SharedPreferences prefs = prefs(context);
        if (tv) {
            restoreTvLaunchers(pm, prefs);
        } else {
            turnOffTvLaunchers(pm, prefs);
        }

        String mode = tv ? MODE_TV : MODE_DESKTOP;
        // A new device starts in desktop mode, with the image's own defaults.
        if (!mode.equals(prefs.getString(KEY_APPLIED_MODE, MODE_DESKTOP))) {
            ContentResolver cr = context.getContentResolver();
            if (tv) {
                useLeanbackIme(context, cr, prefs);
                // Lineage's TV key handler and TV apps wait for TV setup, which Ika skips.
                Settings.Secure.putInt(cr, Settings.Secure.TV_USER_SETUP_COMPLETE, 1);
            } else {
                restoreDesktopIme(cr, prefs);
            }
            prefs.edit().putString(KEY_APPLIED_MODE, mode).commit();
        }
    }

    /**
     * Switches to TV mode, or back to desktop mode, and restarts Android in it, as Desktop/TV
     * does once the user confirms. HOME becomes the Home app; without it, the mode's Home app
     * comes back: the one it had last time, or its own launcher.
     */
    static void switchTo(Context context, boolean tv, String home) {
        // First, as the other mode's Play Store must not start with this mode's update or data.
        // The TV Play Store goes in before the reboot, so that Android starts it as arm64 from the
        // first moment in TV mode.
        if (!PlayStoreUpdates.leave(context, !tv)) {
            switchFailed(context);
            return;
        }
        if (!PlayStoreUpdates.clearData(context)
                || (tv && !PlayStoreUpdates.restore(context, true))) {
            PlayStoreUpdates.restore(context, !tv);
            switchFailed(context);
            return;
        }
        PackageManager pm = context.getPackageManager();
        SharedPreferences prefs = prefs(context);
        List<String> holders = homeHolders(context);
        if (!holders.isEmpty()) {
            prefs.edit().putString(tv ? KEY_DESKTOP_HOME : KEY_TV_HOME, holders.get(0)).commit();
        }
        String launcher = tv ? TV_LAUNCHER : DESKTOP_LAUNCHER;
        if (home == null) {
            home = prefs.getString(tv ? KEY_TV_HOME : KEY_DESKTOP_HOME, launcher);
        }
        // A disabled app cannot hold the role: each launcher is off in the other mode.
        setPackageEnabled(pm, launcher, true);
        if (tv) {
            restoreTvLaunchers(pm, prefs);
        }
        if (!isEnabled(pm, home)) {
            home = launcher;
        }
        String newHome = home;
        setHome(context, newHome, success -> {
            if (!success && !newHome.equals(launcher)) {
                setHome(context, launcher, fallback -> restartIn(context, tv, fallback));
                return;
            }
            restartIn(context, tv, success);
        });
    }

    /** Makes PACKAGE_NAME the Home app, without changing the mode. */
    static void setHome(Context context, String packageName, Consumer<Boolean> callback) {
        context.getSystemService(RoleManager.class).addRoleHolderAsUser(RoleManager.ROLE_HOME,
                packageName, 0, context.getUser(), EXECUTOR, success -> {
                    if (!success) {
                        Log.w(TAG, "Could not make " + packageName + " the Home app");
                    }
                    callback.accept(success);
                });
    }

    /** The Home app, first if there are several. */
    static List<String> homeHolders(Context context) {
        try {
            return context.getSystemService(RoleManager.class)
                    .getRoleHoldersAsUser(RoleManager.ROLE_HOME, context.getUser());
        } catch (RuntimeException e) {
            Log.w(TAG, "Cannot read the Home app", e);
            return new ArrayList<>();
        }
    }

    /**
     * The TV launchers: Home apps made for TV, which declare the leanback feature or have a TV
     * launcher entry, and Catapult. TV Settings' Home is only there for when there is no other.
     * Each mode's launchers are off in the other mode, so disabled apps count too.
     */
    static List<String> tvLaunchers(PackageManager pm) {
        List<String> launchers = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (ResolveInfo info : pm.queryIntentActivities(
                new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), MATCH_ALL)) {
            String packageName = info.activityInfo.packageName;
            if (TV_SETTINGS.equals(packageName) || !seen.add(packageName)) {
                continue;
            }
            if (TV_LAUNCHER.equals(packageName) || isTvApp(pm, packageName)) {
                launchers.add(packageName);
            }
        }
        return launchers;
    }

    private static boolean isTvApp(PackageManager pm, String packageName) {
        try {
            PackageInfo info = pm.getPackageInfo(packageName,
                    PackageManager.GET_CONFIGURATIONS | MATCH_ALL);
            if (info.reqFeatures != null) {
                for (FeatureInfo feature : info.reqFeatures) {
                    if (LEANBACK.equals(feature.name)) {
                        return true;
                    }
                }
            }
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
        return !pm.queryIntentActivities(new Intent(Intent.ACTION_MAIN)
                        .addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER).setPackage(packageName),
                MATCH_ALL).isEmpty();
    }

    /**
     * Turns off the TV launchers other than Catapult, which apply() turns off itself, and keeps
     * them, so that TV mode turns them back on. One the user turned off stays theirs.
     */
    private static void turnOffTvLaunchers(PackageManager pm, SharedPreferences prefs) {
        Set<String> off = new HashSet<>(prefs.getStringSet(KEY_TV_LAUNCHERS_OFF, Set.of()));
        List<String> turnOff = new ArrayList<>();
        for (String packageName : tvLaunchers(pm)) {
            if (!TV_LAUNCHER.equals(packageName) && isEnabled(pm, packageName)) {
                turnOff.add(packageName);
            }
        }
        if (turnOff.isEmpty()) {
            return;
        }
        // Kept first, so that none is left off for good.
        off.addAll(turnOff);
        prefs.edit().putStringSet(KEY_TV_LAUNCHERS_OFF, off).commit();
        for (String packageName : turnOff) {
            Log.i(TAG, "Turning off the TV launcher " + packageName + " on the desktop");
            setPackageEnabled(pm, packageName, false);
        }
    }

    /** Turns the TV launchers that turnOffTvLaunchers() turned off back on. */
    private static void restoreTvLaunchers(PackageManager pm, SharedPreferences prefs) {
        Set<String> off = prefs.getStringSet(KEY_TV_LAUNCHERS_OFF, Set.of());
        if (off.isEmpty()) {
            return;
        }
        for (String packageName : off) {
            setPackageEnabled(pm, packageName, true);
        }
        prefs.edit().remove(KEY_TV_LAUNCHERS_OFF).commit();
    }

    private static void restartIn(Context context, boolean tv, boolean homeSet) {
        if (!homeSet) {
            // Staying in this mode: the TV Play Store, already in for the switch, goes, and this
            // mode's update comes back.
            if (tv) {
                PlayStoreUpdates.leave(context, true);
            }
            PlayStoreUpdates.restore(context, !tv);
            return;
        }
        Log.i(TAG, "Switching to " + (tv ? MODE_TV : MODE_DESKTOP) + " mode");
        SystemProperties.set(MODE_PROP, tv ? MODE_TV : MODE_DESKTOP);
        apply(context, tv);
        context.getSystemService(PowerManager.class).reboot(null);
    }

    private static void switchFailed(Context context) {
        new Handler(Looper.getMainLooper()).post(() -> Toast.makeText(context,
                R.string.switch_failed, Toast.LENGTH_LONG).show());
    }

    // Device-protected, so that it can be read before the user is unlocked.
    private static SharedPreferences prefs(Context context) {
        return context.createDeviceProtectedStorageContext()
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static boolean isEnabled(PackageManager pm, String packageName) {
        try {
            return pm.getApplicationInfo(packageName, MATCH_ALL).enabled;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    private static void setPackageEnabled(PackageManager pm, String packageName,
            boolean enabled) {
        try {
            int state = pm.getApplicationEnabledSetting(packageName);
            if (enabled && state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED) {
                pm.setApplicationEnabledSetting(packageName,
                        PackageManager.COMPONENT_ENABLED_STATE_DEFAULT,
                        PackageManager.DONT_KILL_APP);
            } else if (!enabled && state != PackageManager.COMPONENT_ENABLED_STATE_DISABLED) {
                pm.setApplicationEnabledSetting(packageName,
                        PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                        PackageManager.DONT_KILL_APP);
            }
        } catch (IllegalArgumentException e) {
            // Not installed.
        }
    }

    private static void useLeanbackIme(Context context, ContentResolver cr,
            SharedPreferences prefs) {
        try {
            context.getPackageManager().getPackageInfo(LEANBACK_IME_PACKAGE, 0);
        } catch (PackageManager.NameNotFoundException e) {
            return;
        }
        String current = Settings.Secure.getString(cr, Settings.Secure.DEFAULT_INPUT_METHOD);
        if (LEANBACK_IME.equals(current)) {
            return;
        }
        prefs.edit().putString(KEY_DESKTOP_IME, current).commit();
        List<String> enabled = enabledImes(cr);
        if (!containsIme(enabled, LEANBACK_IME)) {
            enabled.add(LEANBACK_IME);
            Settings.Secure.putString(cr, Settings.Secure.ENABLED_INPUT_METHODS,
                    String.join(":", enabled));
        }
        setDefaultIme(cr, LEANBACK_IME);
    }

    private static void restoreDesktopIme(ContentResolver cr, SharedPreferences prefs) {
        List<String> enabled = enabledImes(cr);
        enabled.removeIf(entry -> imeId(entry).equals(LEANBACK_IME));
        Settings.Secure.putString(cr, Settings.Secure.ENABLED_INPUT_METHODS,
                String.join(":", enabled));
        String current = Settings.Secure.getString(cr, Settings.Secure.DEFAULT_INPUT_METHOD);
        if (!LEANBACK_IME.equals(current)) {
            return;
        }
        String desktop = prefs.getString(KEY_DESKTOP_IME, null);
        if (desktop == null || !containsIme(enabled, desktop)) {
            desktop = enabled.isEmpty() ? "" : imeId(enabled.get(0));
        }
        setDefaultIme(cr, desktop);
    }

    private static void setDefaultIme(ContentResolver cr, String ime) {
        Settings.Secure.putString(cr, Settings.Secure.DEFAULT_INPUT_METHOD, ime);
        // The previous keyboard's subtype does not apply to this one.
        Settings.Secure.putString(cr, Settings.Secure.SELECTED_INPUT_METHOD_SUBTYPE, "-1");
    }

    /** The entries of ENABLED_INPUT_METHODS: an IME ID, each optionally followed by ";subtype". */
    private static List<String> enabledImes(ContentResolver cr) {
        List<String> entries = new ArrayList<>();
        String value = Settings.Secure.getString(cr, Settings.Secure.ENABLED_INPUT_METHODS);
        if (!TextUtils.isEmpty(value)) {
            for (String entry : value.split(":")) {
                if (!entry.isEmpty()) {
                    entries.add(entry);
                }
            }
        }
        return entries;
    }

    private static boolean containsIme(List<String> entries, String ime) {
        for (String entry : entries) {
            if (imeId(entry).equals(ime)) {
                return true;
            }
        }
        return false;
    }

    private static String imeId(String entry) {
        int subtypes = entry.indexOf(';');
        return subtypes < 0 ? entry : entry.substring(0, subtypes);
    }
}
