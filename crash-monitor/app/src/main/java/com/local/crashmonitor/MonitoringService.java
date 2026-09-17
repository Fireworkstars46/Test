package com.local.crashmonitor;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.IBinder;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.github.muntashirakon.adb.AdbPairingRequiredException;
import io.github.muntashirakon.adb.AdbStream;

public class MonitoringService extends Service {
    public static final String ACTION_START = "com.local.crashmonitor.START";
    public static final String ACTION_STOP = "com.local.crashmonitor.STOP";
    public static final String ACTION_RECONNECT = "com.local.crashmonitor.RECONNECT";
    public static final String ACTION_CLEAR = "com.local.crashmonitor.CLEAR";
    public static final String EXTRA_CLEAR_ON_START = "clear_on_start";

    public static final String PREFS = "crash_monitor_settings";
    public static final String PREF_MASTER = "master_enabled";
    public static final String PREF_STATE = "service_state";
    public static final String LOG_FILE = "crash-monitor-live.txt";

    private static final String CHANNEL_ID = "crash_monitor_running";
    private static final int NOTIFICATION_ID = 4646;
    private static final long MAX_LOG_BYTES = 1_500_000L;
    private static final long KEEP_LOG_BYTES = 1_000_000L;

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Object workerLock = new Object();
    private volatile boolean stopRequested;
    private volatile boolean workerRunning;
    private volatile boolean clearOnNextConnect;
    private volatile AdbStream monitorStream;

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        String action = intent == null ? ACTION_START : intent.getAction();

        if (ACTION_STOP.equals(action)) {
            prefs.edit().putBoolean(PREF_MASTER, false).apply();
            stopEverything();
            return START_NOT_STICKY;
        }

        if (!prefs.getBoolean(PREF_MASTER, true)) {
            stopEverything();
            return START_NOT_STICKY;
        }

        startForeground(NOTIFICATION_ID, buildNotification("Monitoring is enabled"));

        if (ACTION_CLEAR.equals(action)) {
            executor.submit(this::clearAllLogs);
            return START_STICKY;
        }

        boolean clear = intent != null && intent.getBooleanExtra(EXTRA_CLEAR_ON_START, false);
        if (clear) clearOnNextConnect = true;

        if (ACTION_RECONNECT.equals(action)) {
            closeMonitorStream();
        }

        startWorkerIfNeeded();
        return START_STICKY;
    }

    private void startWorkerIfNeeded() {
        synchronized (workerLock) {
            if (workerRunning) return;
            workerRunning = true;
            stopRequested = false;
            executor.submit(this::monitorLoop);
        }
    }

    private void monitorLoop() {
        try {
            while (!stopRequested && isMasterEnabled()) {
                try {
                    setState("Connecting to Wireless debugging…");
                    AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
                    if (!manager.isConnected()) {
                        try {
                            if (!manager.autoConnect(this, 10000)) {
                                setState("Waiting for Wireless debugging…");
                                sleepQuietly(3000);
                                continue;
                            }
                        } catch (AdbPairingRequiredException e) {
                            setState("Pairing required — open Crash Monitor to pair once.");
                            sleepQuietly(4000);
                            continue;
                        }
                    }

                    if (clearOnNextConnect) {
                        clearOnNextConnect = false;
                        clearDeviceCrashBuffer(manager);
                        clearLocalLog();
                    }

                    setState("Monitoring crashes in background");
                    monitorStream = manager.openStream("shell:logcat -b crash -v threadtime");
                    try (InputStream in = monitorStream.openInputStream();
                         BufferedReader reader = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
                        String line;
                        while (!stopRequested && isMasterEnabled() && (line = reader.readLine()) != null) {
                            appendLog(line + "\n");
                        }
                    } finally {
                        closeMonitorStream();
                    }
                } catch (Throwable e) {
                    if (!stopRequested && isMasterEnabled()) {
                        setState("Reconnecting after monitor error…");
                        sleepQuietly(2000);
                    }
                }
            }
        } finally {
            synchronized (workerLock) {
                workerRunning = false;
            }
            if (!isMasterEnabled() || stopRequested) {
                setState("Master OFF — monitoring stopped. Pairing is saved.");
            }
        }
    }

    private boolean isMasterEnabled() {
        return getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(PREF_MASTER, true);
    }

    private void clearAllLogs() {
        try {
            AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
            if (manager.isConnected()) clearDeviceCrashBuffer(manager);
        } catch (Throwable ignored) { }
        clearLocalLog();
        setState("Monitoring crashes in background");
    }

    private void clearDeviceCrashBuffer(AdbConnectionManager manager) {
        AdbStream s = null;
        try {
            s = manager.openStream("shell:logcat -b crash -c");
            try (InputStream in = s.openInputStream()) {
                byte[] buf = new byte[256];
                while (in.read(buf) >= 0) { }
            }
        } catch (Throwable ignored) {
        } finally {
            if (s != null) {
                try { s.close(); } catch (Throwable ignored) { }
            }
        }
    }

    private void appendLog(String text) {
        try {
            File f = new File(getFilesDir(), LOG_FILE);
            try (FileOutputStream out = new FileOutputStream(f, true)) {
                out.write(text.getBytes(StandardCharsets.UTF_8));
            }
            trimLogIfNeeded(f);
        } catch (Throwable ignored) { }
    }

    private void clearLocalLog() {
        try {
            File f = new File(getFilesDir(), LOG_FILE);
            try (FileOutputStream out = new FileOutputStream(f, false)) {
                out.write(new byte[0]);
            }
        } catch (Throwable ignored) { }
    }

    private void trimLogIfNeeded(File f) {
        if (!f.exists() || f.length() <= MAX_LOG_BYTES) return;
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] all = new byte[(int) f.length()];
            int off = 0;
            while (off < all.length) {
                int n = in.read(all, off, all.length - off);
                if (n < 0) break;
                off += n;
            }
            int keep = (int) Math.min(KEEP_LOG_BYTES, off);
            byte[] tail = Arrays.copyOfRange(all, off - keep, off);
            try (FileOutputStream out = new FileOutputStream(f, false)) {
                out.write(tail);
            }
        } catch (Throwable ignored) { }
    }

    private void stopEverything() {
        stopRequested = true;
        closeMonitorStream();
        try {
            AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
            if (manager.isConnected()) manager.disconnect();
        } catch (Throwable ignored) { }
        setState("Master OFF — monitoring stopped. Pairing is saved.");
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    private void closeMonitorStream() {
        AdbStream s = monitorStream;
        monitorStream = null;
        if (s != null) {
            try { s.close(); } catch (Throwable ignored) { }
        }
    }

    private void setState(String state) {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString(PREF_STATE, state).apply();
        try {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            nm.notify(NOTIFICATION_ID, buildNotification(state));
        } catch (Throwable ignored) { }
    }

    private void createNotificationChannel() {
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "Crash monitoring",
                NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Keeps Crash Monitor running while the app is closed.");
        nm.createNotificationChannel(channel);
    }

    private Notification buildNotification(String text) {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(
                this,
                0,
                open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        return new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_launcher)
                .setContentTitle("Crash Monitor")
                .setContentText(text)
                .setContentIntent(pi)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build();
    }

    private static void sleepQuietly(long ms) {
        try { Thread.sleep(ms); }
        catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        // Intentionally do nothing. The foreground service remains running when the UI is swiped away.
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public void onDestroy() {
        closeMonitorStream();
        executor.shutdownNow();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
