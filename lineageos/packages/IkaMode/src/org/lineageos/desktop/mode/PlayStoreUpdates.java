package org.lineageos.desktop.mode;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ApplicationInfo;
import android.content.pm.IPackageDataObserver;
import android.content.pm.IPackageDeleteObserver;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Where the image has the TV build of the Play Store next to the phone build, each mode boots its
 * own build, but an update that Play installs in one mode would replace the other mode's build
 * too. Before a switch, the update is saved for the mode it came from and removed; after the
 * switch, the new mode's saved update, when it is newer than the build the image has, is installed
 * again, so that Play is as it was the last time in that mode.
 *
 * Play's data goes at each switch: the two builds can't use each other's. The phone build crashes
 * when opened on the TV build's data, and the TV build can't reach Google's servers (DF-DFERH-01)
 * on the phone build's. The account stays, as Google Play services keeps it.
 *
 * The TV build's native code is arm64 only, and inside its APK. A built-in app takes its ABI from
 * native code next to its APK, so Android would run Tubesky with the device's own ABI, which
 * can't load it on x86-64. In TV mode, the Play Store is therefore always an update, installed as
 * arm64: its saved update, or the image's build when that is as new. It goes in before the
 * reboot to TV mode, so Android starts it as arm64 from the first moment; Tubesky's signing key
 * follows on from Phonesky's, so it can update it.
 */
final class PlayStoreUpdates {
    private static final String TAG = ModeController.TAG;
    private static final String PLAY_STORE = "com.android.vending";
    // The Android TV build of the Play Store, which images with MindTheGapps carry next to the
    // phone build.
    private static final File TV_PLAY_STORE = new File("/product/priv-app/Tubesky");
    private static final File TV_PLAY_STORE_APK = new File(TV_PLAY_STORE, "Tubesky.apk");
    private static final String VERSION = "version";
    private static final String RESTORED = "org.lineageos.desktop.mode.PLAY_STORE_RESTORED";
    // Tubesky's native code is arm64 only; x86-64 hosts run it through the ARM native bridge.
    private static final String TV_PLAY_STORE_ABI = "arm64-v8a";
    private static final long TIMEOUT_SECONDS = 120;

    private PlayStoreUpdates() {}

    /**
     * Saves the Play Store's update for the mode Android is leaving and removes it. Returns
     * whether the Play Store is down to the image's build, or was already: the switch stops
     * otherwise, as the update would run in the other mode.
     */
    static boolean leave(Context context, boolean tv) {
        if (!TV_PLAY_STORE.isDirectory()) {
            return true;
        }
        PackageManager pm = context.getPackageManager();
        ApplicationInfo info;
        long version;
        try {
            info = pm.getApplicationInfo(PLAY_STORE, 0);
            version = pm.getPackageInfo(PLAY_STORE, 0).getLongVersionCode();
        } catch (PackageManager.NameNotFoundException e) {
            return true;
        }
        if ((info.flags & ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0) {
            return true;
        }
        // Without a copy, the update is only downloaded again: the switch goes on.
        save(context, tv, info, version);
        return remove(pm);
    }

    /**
     * Brings back the Play Store of the mode Android is in, or is about to switch to: the saved
     * update when it is newer than what is installed and, for TV mode, the TV build as arm64.
     * Returns whether that worked; the saved copy stays until Android boots in the mode.
     */
    static boolean restore(Context context, boolean tv) {
        if (!TV_PLAY_STORE.isDirectory()) {
            return true;
        }
        PackageManager pm = context.getPackageManager();
        File dir = dir(context, tv);
        long saved = savedVersion(dir);
        File[] apks = dir.listFiles((d, name) -> name.endsWith(".apk"));
        try {
            ApplicationInfo info = pm.getApplicationInfo(PLAY_STORE, 0);
            if (!tv) {
                return saved <= pm.getPackageInfo(PLAY_STORE, 0).getLongVersionCode()
                        || install(context, apks, null);
            }
            if ((info.flags & ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
                    && TV_PLAY_STORE_ABI.equals(info.primaryCpuAbi)) {
                return true;
            }
        } catch (PackageManager.NameNotFoundException e) {
            return true;
        }
        PackageInfo image = pm.getPackageArchiveInfo(TV_PLAY_STORE_APK.getPath(), 0);
        if (image != null && saved <= image.getLongVersionCode()) {
            apks = new File[] {TV_PLAY_STORE_APK};
        }
        return install(context, apks, TV_PLAY_STORE_ABI);
    }

    /**
     * Drops the saved update of the mode Android booted in, which is installed: Play's next update
     * in this mode replaces it.
     */
    static void forget(Context context, boolean tv) {
        delete(dir(context, tv));
    }

    private static long savedVersion(File dir) {
        try {
            return Long.parseLong(new String(
                    Files.readAllBytes(new File(dir, VERSION).toPath()),
                    StandardCharsets.UTF_8).trim());
        } catch (IOException | NumberFormatException e) {
            return -1;
        }
    }

    /** Clears the Play Store's data, before a switch. Returns whether it is gone. */
    static boolean clearData(Context context) {
        if (!TV_PLAY_STORE.isDirectory()) {
            return true;
        }
        CountDownLatch cleared = new CountDownLatch(1);
        boolean[] succeeded = new boolean[1];
        context.getPackageManager().clearApplicationUserData(PLAY_STORE,
                new IPackageDataObserver.Stub() {
                    @Override
                    public void onRemoveCompleted(String packageName, boolean success) {
                        succeeded[0] = success;
                        cleared.countDown();
                    }
                });
        try {
            if (!cleared.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                Log.w(TAG, "Timed out clearing the Play Store's data");
                return false;
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
        if (!succeeded[0]) {
            Log.w(TAG, "Could not clear the Play Store's data");
        }
        return succeeded[0];
    }

    private static void save(Context context, boolean tv, ApplicationInfo info, long version) {
        File dir = dir(context, tv);
        File staging = new File(dir.getParentFile(), dir.getName() + ".new");
        delete(staging);
        try {
            if (!staging.mkdirs()) {
                throw new IOException("cannot create " + staging);
            }
            for (String apk : apks(info)) {
                File source = new File(apk);
                Files.copy(source.toPath(), new File(staging, source.getName()).toPath());
            }
            Files.write(new File(staging, VERSION).toPath(),
                    Long.toString(version).getBytes(StandardCharsets.UTF_8));
            delete(dir);
            if (!staging.renameTo(dir)) {
                throw new IOException("cannot rename " + staging);
            }
        } catch (IOException e) {
            Log.w(TAG, "Could not save the Play Store update", e);
            delete(staging);
        }
    }

    private static List<String> apks(ApplicationInfo info) {
        List<String> apks = new ArrayList<>();
        apks.add(info.sourceDir);
        if (info.splitSourceDirs != null) {
            for (String split : info.splitSourceDirs) {
                apks.add(split);
            }
        }
        return apks;
    }

    private static boolean remove(PackageManager pm) {
        CountDownLatch removed = new CountDownLatch(1);
        boolean[] succeeded = new boolean[1];
        // Removing an update rolls back to the image's build, for all users;
        // DELETE_SYSTEM_APP would instead uninstall the app for this user and
        // keep the update.
        pm.deletePackage(PLAY_STORE, new IPackageDeleteObserver.Stub() {
            @Override
            public void packageDeleted(String packageName, int returnCode) {
                succeeded[0] = returnCode == PackageManager.DELETE_SUCCEEDED;
                if (!succeeded[0]) {
                    Log.w(TAG, "Could not remove the Play Store update: " + returnCode);
                }
                removed.countDown();
            }
        }, PackageManager.DELETE_ALL_USERS | PackageManager.DELETE_KEEP_DATA);
        try {
            if (!removed.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                Log.w(TAG, "Timed out removing the Play Store update");
                return false;
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
        return succeeded[0];
    }

    /**
     * Installs APKS as an update of the Play Store, with ABI when it isn't null. Returns whether
     * it was installed.
     */
    private static boolean install(Context context, File[] apks, String abi) {
        if (apks == null || apks.length == 0) {
            return false;
        }
        PackageInstaller installer = context.getPackageManager().getPackageInstaller();
        PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(PLAY_STORE);
        params.abiOverride = abi;
        int id;
        try {
            id = installer.createSession(params);
        } catch (IOException e) {
            Log.w(TAG, "Could not install the Play Store", e);
            return false;
        }
        CountDownLatch done = new CountDownLatch(1);
        int[] status = {PackageInstaller.STATUS_FAILURE};
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent intent) {
                status[0] = intent.getIntExtra(PackageInstaller.EXTRA_STATUS,
                        PackageInstaller.STATUS_FAILURE);
                if (status[0] != PackageInstaller.STATUS_SUCCESS) {
                    Log.w(TAG, "Could not install the Play Store: "
                            + intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE));
                }
                done.countDown();
            }
        };
        context.registerReceiver(receiver, new IntentFilter(RESTORED),
                Context.RECEIVER_NOT_EXPORTED);
        try (PackageInstaller.Session session = installer.openSession(id)) {
            for (File apk : apks) {
                try (InputStream in = new FileInputStream(apk);
                        OutputStream out = session.openWrite(apk.getName(), 0, apk.length())) {
                    in.transferTo(out);
                    session.fsync(out);
                }
            }
            session.commit(PendingIntent.getBroadcast(context, id,
                    new Intent(RESTORED).setPackage(context.getPackageName()),
                    PendingIntent.FLAG_MUTABLE).getIntentSender());
            if (!done.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                Log.w(TAG, "Timed out installing the Play Store");
                return false;
            }
            if (status[0] == PackageInstaller.STATUS_SUCCESS) {
                Log.i(TAG, "Installed the Play Store" + (abi != null ? " as " + abi : ""));
                return true;
            }
            return false;
        } catch (IOException e) {
            Log.w(TAG, "Could not install the Play Store", e);
            return false;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        } finally {
            context.unregisterReceiver(receiver);
        }
    }

    // Device-protected, as Android starts in it; only the system can read it.
    private static File dir(Context context, boolean tv) {
        return new File(context.createDeviceProtectedStorageContext().getFilesDir(),
                "play-store-update-" + (tv ? "tv" : "desktop"));
    }

    private static void delete(File file) {
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                delete(child);
            }
        }
        file.delete();
    }
}
