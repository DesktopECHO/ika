package org.lineageos.desktop.mode;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ApplicationInfo;
import android.content.pm.IPackageDeleteObserver;
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
 * too. Before a switch, the update is saved for the mode it came from and removed, keeping Play's
 * data; after the switch, the new mode's saved update, when it is newer than the build the image
 * has, is installed again, so that Play is as it was the last time in that mode.
 */
final class PlayStoreUpdates {
    private static final String TAG = ModeController.TAG;
    private static final String PLAY_STORE = "com.android.vending";
    // The Android TV build of the Play Store, which images with MindTheGapps carry next to the
    // phone build.
    private static final File TV_PLAY_STORE = new File("/product/priv-app/Tubesky");
    private static final String VERSION = "version";
    private static final String RESTORED = "org.lineageos.desktop.mode.PLAY_STORE_RESTORED";
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
     * Installs the saved update of the mode Android booted in, when it is newer than the Play
     * Store there is, and then drops the copy: Play's next update in this mode replaces it.
     */
    static void restore(Context context, boolean tv) {
        File dir = dir(context, tv);
        if (!TV_PLAY_STORE.isDirectory() || !dir.isDirectory()) {
            return;
        }
        try {
            long saved = Long.parseLong(new String(
                    Files.readAllBytes(new File(dir, VERSION).toPath()),
                    StandardCharsets.UTF_8).trim());
            long installed = context.getPackageManager().getPackageInfo(PLAY_STORE, 0)
                    .getLongVersionCode();
            if (saved > installed) {
                install(context, dir);
            }
        } catch (IOException | NumberFormatException | PackageManager.NameNotFoundException e) {
            Log.w(TAG, "Could not restore the Play Store update", e);
        }
        delete(dir);
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
        pm.deletePackage(PLAY_STORE, new IPackageDeleteObserver.Stub() {
            @Override
            public void packageDeleted(String packageName, int returnCode) {
                succeeded[0] = returnCode == PackageManager.DELETE_SUCCEEDED;
                if (!succeeded[0]) {
                    Log.w(TAG, "Could not remove the Play Store update: " + returnCode);
                }
                removed.countDown();
            }
        }, PackageManager.DELETE_SYSTEM_APP | PackageManager.DELETE_KEEP_DATA);
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

    private static void install(Context context, File dir) throws IOException {
        PackageInstaller installer = context.getPackageManager().getPackageInstaller();
        PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(PLAY_STORE);
        int id = installer.createSession(params);
        CountDownLatch done = new CountDownLatch(1);
        int[] status = {PackageInstaller.STATUS_FAILURE};
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent intent) {
                status[0] = intent.getIntExtra(PackageInstaller.EXTRA_STATUS,
                        PackageInstaller.STATUS_FAILURE);
                if (status[0] != PackageInstaller.STATUS_SUCCESS) {
                    Log.w(TAG, "Could not restore the Play Store update: "
                            + intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE));
                }
                done.countDown();
            }
        };
        context.registerReceiver(receiver, new IntentFilter(RESTORED),
                Context.RECEIVER_NOT_EXPORTED);
        try (PackageInstaller.Session session = installer.openSession(id)) {
            File[] files = dir.listFiles((d, name) -> name.endsWith(".apk"));
            if (files == null || files.length == 0) {
                session.abandon();
                return;
            }
            for (File apk : files) {
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
                Log.w(TAG, "Timed out restoring the Play Store update");
            } else if (status[0] == PackageInstaller.STATUS_SUCCESS) {
                Log.i(TAG, "Restored the Play Store update");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
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
