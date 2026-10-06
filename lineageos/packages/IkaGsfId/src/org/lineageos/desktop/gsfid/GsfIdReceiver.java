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
 * GMS serves the ID from its gservices provider only to callers it approves, so
 * it is read from the provider's dump ("AndroidId: <hex>"), which this app can
 * request as the system uid.
 */
public class GsfIdReceiver extends BroadcastReceiver {
    private static final String TAG = "IkaGsfId";
    private static final String GSERVICES_AUTHORITY = "com.google.android.gsf.gservices";
    private static final String GSERVICES_PROVIDER =
            "com.google.android.gms/.gservices.provider.GservicesProvider";
    private static final Pattern ANDROID_ID =
            Pattern.compile("AndroidId:\\s*([0-9a-fA-F]{1,16})\\b");
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
        String hex;
        try {
            hex = readAndroidIdHex();
        } catch (IOException | InterruptedException | RuntimeException e) {
            Log.d(TAG, "Gservices provider dump failed: " + e);
            return true;
        }
        if (hex == null) {
            return true;
        }
        long id = Long.parseUnsignedLong(hex, 16);
        if (id == 0) {
            return true;
        }
        SystemProperties.set(PROP, Long.toUnsignedString(id));
        return false;
    }

    /** Returns the hex ID from the Gservices provider's dump, or null if it has none yet. */
    private static String readAndroidIdHex() throws IOException, InterruptedException {
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
                    new String[] {"provider", GSERVICES_PROVIDER});
        } catch (RemoteException e) {
            throw new IOException(e);
        } finally {
            reader.join(10_000);
        }
        Matcher m = ANDROID_ID.matcher(dump.toString(StandardCharsets.UTF_8));
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
