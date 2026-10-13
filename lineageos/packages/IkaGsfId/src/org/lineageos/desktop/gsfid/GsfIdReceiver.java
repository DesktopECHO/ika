package org.lineageos.desktop.gsfid;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.os.RemoteException;
import android.os.ServiceManager;
import android.os.SystemClock;
import android.os.SystemProperties;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Publishes the Google Services Framework Android ID, in decimal, as
 * sys.ika.gsf_android_id: the number Google's device registration page asks for.
 * GMS check-in assigns the ID, so this retries once a minute from boot until the
 * ID is there.
 *
 * GMS serves the ID from its gservices provider only to callers it approves,
 * and leaves it out of that provider's dump on user builds. Its GCM service,
 * which signs in to Google's push server with the ID, prints it in its dump
 * ("DeviceID: <decimal>") on user and userdebug builds; this app can request
 * that dump as the system uid.
 */
public class GsfIdReceiver extends BroadcastReceiver {
    private static final String TAG = "IkaGsfId";
    private static final String GSERVICES_AUTHORITY = "com.google.android.gsf.gservices";
    private static final String GCM_SERVICE = "com.google.android.gms/.gcm.GcmService";
    private static final Pattern DEVICE_ID = Pattern.compile("DeviceID:\\s*([0-9]{1,20})\\b");
    private static final String PROP = "sys.ika.gsf_android_id";
    private static final String ACTION_POLL = "org.lineageos.desktop.gsfid.POLL";
    private static final long POLL_INTERVAL_MS = 60_000;

    @Override
    public void onReceive(Context context, Intent intent) {
        // The dump can take a while when GMS has to start first.
        PendingResult result = goAsync();
        new Thread(() -> {
            try {
                if (shouldRetry(context)) {
                    schedulePoll(context);
                }
            } catch (RuntimeException e) {
                Log.d(TAG, "GSF Android ID lookup failed: " + e);
            } finally {
                result.finish();
            }
        }).start();
    }

    /**
     * Publishes the ID if it is available. Returns true to try again later: GMS is installed but
     * check-in hasn't assigned an ID yet, or the dump failed. Returns false when the property is
     * set or GMS isn't on the device, so there is nothing to wait for.
     */
    private static boolean shouldRetry(Context context) {
        if (!SystemProperties.get(PROP).isEmpty()) {
            return false;
        }
        if (context.getPackageManager().resolveContentProvider(GSERVICES_AUTHORITY, 0) == null) {
            return false;
        }
        String decimal;
        try {
            decimal = readDeviceId();
        } catch (IOException | InterruptedException | RuntimeException e) {
            Log.d(TAG, "GCM service dump failed: " + e);
            return true;
        }
        if (decimal == null) {
            return true;
        }
        long id = Long.parseUnsignedLong(decimal);
        if (id == 0) {
            return true;
        }
        SystemProperties.set(PROP, Long.toUnsignedString(id));
        return false;
    }

    /** Returns the decimal ID from the GCM service's dump, or null if it has none yet. */
    private static String readDeviceId() throws IOException, InterruptedException {
        IBinder activity = ServiceManager.getService(Context.ACTIVITY_SERVICE);
        if (activity == null) {
            return null;
        }
        ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
        ByteArrayOutputStream dump = new ByteArrayOutputStream();
        // Read while the dump is written, so a full pipe can't block the writer.
        Thread reader = new Thread(() -> {
            try (InputStream in = new ParcelFileDescriptor.AutoCloseInputStream(pipe[0])) {
                in.transferTo(dump);
            } catch (IOException e) {
                Log.d(TAG, "Reading the dump failed: " + e);
            }
        });
        reader.start();
        try (ParcelFileDescriptor writeEnd = pipe[1]) {
            activity.dump(writeEnd.getFileDescriptor(),
                    new String[] {"service", GCM_SERVICE});
        } catch (RemoteException e) {
            throw new IOException(e);
        } finally {
            reader.join(10_000);
        }
        Matcher m = DEVICE_ID.matcher(dump.toString(StandardCharsets.UTF_8));
        return m.find() ? m.group(1) : null;
    }

    private static void schedulePoll(Context context) {
        Intent poll = new Intent(context, GsfIdReceiver.class).setAction(ACTION_POLL);
        PendingIntent pending = PendingIntent.getBroadcast(
                context, 0, poll, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        context.getSystemService(AlarmManager.class).setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + POLL_INTERVAL_MS,
                pending);
    }
}
