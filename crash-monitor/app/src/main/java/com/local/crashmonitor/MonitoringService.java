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
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.github.muntashirakon.adb.AdbPairingRequiredException;
import io.github.muntashirakon.adb.AdbStream;

public class MonitoringService extends Service {
    public static final String ACTION_START = "com.local.crashmonitor.START";
    public static final String ACTION_STOP = "com.local.crashmonitor.STOP";
    public static final String ACTION_START_MONITORING = "com.local.crashmonitor.START_MONITORING";
    public static final String ACTION_STOP_MONITORING = "com.local.crashmonitor.STOP_MONITORING";
    public static final String ACTION_RECONNECT = "com.local.crashmonitor.RECONNECT";
    public static final String ACTION_CLEAR = "com.local.crashmonitor.CLEAR";
    public static final String EXTRA_CLEAR_ON_START = "clear_on_start";

    public static final String PREFS = "crash_monitor_settings";
    public static final String PREF_MASTER = "master_enabled";
    public static final String PREF_MONITORING = "monitoring_enabled";
    public static final String PREF_STATE = "service_state";

    // The raw file is intentionally unmodified logcat output. The important file is a
    // second, classified view so install failures/crashes/ANRs are easy to find.
    public static final String LOG_FILE = "crash-monitor-live.txt";
    public static final String IMPORTANT_FILE = "crash-monitor-important.txt";

    private static final String CHANNEL_ID = "crash_monitor_running";
    private static final int NOTIFICATION_ID = 4646;

    private static final long RAW_MAX_BYTES = 8_000_000L;
    private static final long RAW_KEEP_BYTES = 5_000_000L;
    private static final long IMPORTANT_MAX_BYTES = 2_000_000L;
    private static final long IMPORTANT_KEEP_BYTES = 1_400_000L;

    private final ExecutorService workerExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService controlExecutor = Executors.newCachedThreadPool();
    private final Object workerLock = new Object();
    private volatile boolean stopRequested;
    private volatile boolean workerRunning;
    private volatile boolean clearOnNextConnect;
    private volatile AdbStream monitorStream;
    private static final int RECENT_DEDUPE_LIMIT = 256;
    private final ArrayDeque<String> recentLineQueue = new ArrayDeque<>();
    private final Set<String> recentLineSet = new HashSet<>();

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

        startForeground(NOTIFICATION_ID, buildNotification("System Log Monitor is ready"));

        if (ACTION_START_MONITORING.equals(action)) {
            prefs.edit().putBoolean(PREF_MONITORING, true).apply();
            clearOnNextConnect = true;
            stopRequested = false;
            closeMonitorStream();
            setState("Starting full Android logging…");
            startWorkerIfNeeded();
            return START_STICKY;
        }

        if (ACTION_STOP_MONITORING.equals(action)) {
            prefs.edit().putBoolean(PREF_MONITORING, false).apply();
            closeMonitorStream();
            setState("Ready — logging stopped. Master power is still ON.");
            return START_STICKY;
        }

        if (ACTION_CLEAR.equals(action)) {
            controlExecutor.submit(this::clearLocalLogs);
            return START_STICKY;
        }

        boolean clear = intent != null && intent.getBooleanExtra(EXTRA_CLEAR_ON_START, false);
        if (clear) clearOnNextConnect = true;

        if (ACTION_RECONNECT.equals(action)) {
            closeMonitorStream();
            controlExecutor.submit(this::disconnectForReconnect);
        }

        if (prefs.getBoolean(PREF_MONITORING, true)) {
            stopRequested = false;
            startWorkerIfNeeded();
        } else {
            setState("Ready — logging stopped. Master power is still ON.");
            controlExecutor.submit(this::ensureConnectedOnce);
        }

        return START_STICKY;
    }

    private void startWorkerIfNeeded() {
        synchronized (workerLock) {
            if (workerRunning) return;
            workerRunning = true;
            workerExecutor.submit(this::monitorLoop);
        }
    }

    private void monitorLoop() {
        try {
            while (!stopRequested && isMasterEnabled() && isMonitoringEnabled()) {
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
                        // Clear only our files. Do not erase Android's system log buffers.
                        clearLocalLogs();
                    }

                    if (!isMonitoringEnabled()) break;

                    setState("Logging ALL ADB-visible Android log buffers");
                    // -b all includes every logcat buffer the paired ADB shell is allowed to read
                    // (main/system/crash/events/radio and any other available buffers).
                    // -T 1 starts at the newest entry, then follows new entries continuously.
                    monitorStream = manager.openStream("shell:logcat -b all -v threadtime -T 1");
                    captureStream(monitorStream);
                } catch (Throwable e) {
                    if (!stopRequested && isMasterEnabled() && isMonitoringEnabled()) {
                        appendImportant("[MONITOR] " + shortError(e));
                        setState("Reconnecting after monitor error…");
                        sleepQuietly(2000);
                    }
                } finally {
                    closeMonitorStream();
                }
            }
        } finally {
            synchronized (workerLock) {
                workerRunning = false;
            }
            if (!isMasterEnabled() || stopRequested) {
                setState("Master OFF — logging and ADB connection are off. Pairing is saved.");
            } else if (!isMonitoringEnabled()) {
                setState("Ready — logging stopped. Master power is still ON.");
            }
        }
    }

    private void captureStream(AdbStream stream) throws Exception {
        File rawFile = new File(getFilesDir(), LOG_FILE);
        File importantFile = new File(getFilesDir(), IMPORTANT_FILE);
        FileOutputStream rawOut = null;
        FileOutputStream importantOut = null;
        long rawSize = rawFile.exists() ? rawFile.length() : 0L;
        long importantSize = importantFile.exists() ? importantFile.length() : 0L;
        int linesSinceFlush = 0;

        try (InputStream in = stream.openInputStream();
             BufferedReader reader = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
            rawOut = new FileOutputStream(rawFile, true);
            importantOut = new FileOutputStream(importantFile, true);

            String line;
            while (!stopRequested && isMasterEnabled() && isMonitoringEnabled()
                    && (line = reader.readLine()) != null) {
                if (isRecentExactDuplicate(line)) continue;
                String rawLine = line + "\n";
                byte[] rawBytes = rawLine.getBytes(StandardCharsets.UTF_8);
                rawOut.write(rawBytes);
                rawSize += rawBytes.length;

                String category = classify(line);
                if (category != null) {
                    String marked = category + " " + line + "\n";
                    byte[] importantBytes = marked.getBytes(StandardCharsets.UTF_8);
                    importantOut.write(importantBytes);
                    importantSize += importantBytes.length;
                }

                linesSinceFlush++;
                if (linesSinceFlush >= 40) {
                    rawOut.flush();
                    importantOut.flush();
                    linesSinceFlush = 0;

                    if (rawSize > RAW_MAX_BYTES) {
                        rawOut.close();
                        rawOut = null;
                        trimFile(rawFile, RAW_KEEP_BYTES);
                        rawSize = rawFile.length();
                        rawOut = new FileOutputStream(rawFile, true);
                    }
                    if (importantSize > IMPORTANT_MAX_BYTES) {
                        importantOut.close();
                        importantOut = null;
                        trimFile(importantFile, IMPORTANT_KEEP_BYTES);
                        importantSize = importantFile.length();
                        importantOut = new FileOutputStream(importantFile, true);
                    }
                }
            }
        } finally {
            if (rawOut != null) {
                try { rawOut.flush(); } catch (Throwable ignored) { }
                try { rawOut.close(); } catch (Throwable ignored) { }
            }
            if (importantOut != null) {
                try { importantOut.flush(); } catch (Throwable ignored) { }
                try { importantOut.close(); } catch (Throwable ignored) { }
            }
        }
    }

    private boolean isRecentExactDuplicate(String line) {
        synchronized (recentLineQueue) {
            if (recentLineSet.contains(line)) return true;
            recentLineQueue.addLast(line);
            recentLineSet.add(line);
            while (recentLineQueue.size() > RECENT_DEDUPE_LIMIT) {
                String oldest = recentLineQueue.removeFirst();
                recentLineSet.remove(oldest);
            }
            return false;
        }
    }

    private void clearRecentDedupe() {
        synchronized (recentLineQueue) {
            recentLineQueue.clear();
            recentLineSet.clear();
        }
    }

    private String classify(String line) {
        String l = line.toLowerCase(Locale.US);

        // Install/update/package-parser failures get first priority because these often
        // explain Android's vague "App not installed" / "Invalid" messages.
        if (l.contains("install_failed") || l.contains("install_parse_failed")
                || l.contains("failed to install") || l.contains("failure [install")
                || l.contains("package installer") || l.contains("packageinstaller")
                || (l.contains("packagemanager") && (l.contains("install") || l.contains("parse") || l.contains("invalid apk")))
                || (l.contains("installd") && (l.contains("install") || l.contains("failed") || l.contains("error")))) {
            return "[INSTALL]";
        }

        if (l.contains("fatal exception") || l.contains("androidruntime")
                || l.contains("fatal signal") || l.contains("am_crash")
                || l.contains("tombstone") || l.contains("native crash")) {
            return "[CRASH]";
        }

        if (l.contains("anr in") || l.contains("am_anr")
                || l.contains("application not responding")
                || l.contains("input dispatching timed out")) {
            return "[ANR]";
        }

        if (l.contains("securityexception") || l.contains("permission denial")
                || l.contains("avc: denied") || l.contains("not allowed")
                || l.contains("permission denied")) {
            return "[SECURITY]";
        }

        // threadtime format includes a one-letter priority column. This catches generic
        // error lines that did not match the more useful categories above.
        if (line.matches(".*\\sE\\s+[^:]+:.*") || l.contains(" exception:")
                || l.contains(" error:")) {
            return "[ERROR]";
        }

        return null;
    }

    private void appendImportant(String text) {
        File f = new File(getFilesDir(), IMPORTANT_FILE);
        try (FileOutputStream out = new FileOutputStream(f, true)) {
            out.write((text + "\n").getBytes(StandardCharsets.UTF_8));
        } catch (Throwable ignored) { }
        if (f.length() > IMPORTANT_MAX_BYTES) trimFile(f, IMPORTANT_KEEP_BYTES);
    }

    private boolean isMasterEnabled() {
        return getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(PREF_MASTER, true);
    }

    private boolean isMonitoringEnabled() {
        return getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(PREF_MONITORING, true);
    }

    private void ensureConnectedOnce() {
        if (!isMasterEnabled()) return;
        try {
            AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
            if (manager.isConnected()) return;
            try {
                manager.autoConnect(this, 10000);
            } catch (AdbPairingRequiredException ignored) { }
        } catch (Throwable ignored) { }
    }

    private void disconnectForReconnect() {
        if (!isMasterEnabled()) return;
        try {
            AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
            if (manager.isConnected()) manager.disconnect();
        } catch (Throwable ignored) { }

        if (isMonitoringEnabled()) {
            stopRequested = false;
            startWorkerIfNeeded();
        } else {
            ensureConnectedOnce();
            setState("Ready — logging stopped. Master power is still ON.");
        }
    }

    private void clearLocalLogs() {
        clearRecentDedupe();
        clearFile(new File(getFilesDir(), LOG_FILE));
        clearFile(new File(getFilesDir(), IMPORTANT_FILE));
        if (isMonitoringEnabled()) setState("Logging ALL ADB-visible Android log buffers");
        else setState("Ready — logging stopped. Master power is still ON.");
    }

    private void clearFile(File f) {
        try (FileOutputStream out = new FileOutputStream(f, false)) {
            out.write(new byte[0]);
        } catch (Throwable ignored) { }
    }

    private void trimFile(File f, long keepBytes) {
        if (!f.exists() || f.length() <= keepBytes) return;
        try (FileInputStream in = new FileInputStream(f)) {
            long length = f.length();
            int keep = (int) Math.min(keepBytes, length);
            byte[] tail = new byte[keep];
            long skip = length - keep;
            while (skip > 0) {
                long n = in.skip(skip);
                if (n <= 0) break;
                skip -= n;
            }
            int off = 0;
            while (off < keep) {
                int n = in.read(tail, off, keep - off);
                if (n < 0) break;
                off += n;
            }
            try (FileOutputStream out = new FileOutputStream(f, false)) {
                out.write(Arrays.copyOf(tail, off));
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
        setState("Master OFF — logging and ADB connection are off. Pairing is saved.");
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
                "Android log monitoring",
                NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Keeps full Android log monitoring running while the app is closed.");
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

    private static String shortError(Throwable e) {
        Throwable t = e;
        while (t.getCause() != null && t.getCause() != t) t = t.getCause();
        String m = t.getMessage();
        return t.getClass().getSimpleName() + (m == null ? "" : ": " + m);
    }

    private static void sleepQuietly(long ms) {
        try { Thread.sleep(ms); }
        catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        // Keep the foreground service alive when the UI is swiped away.
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public void onDestroy() {
        closeMonitorStream();
        workerExecutor.shutdownNow();
        controlExecutor.shutdownNow();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
