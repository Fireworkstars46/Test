package com.local.crashmonitor;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.InputType;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import io.github.muntashirakon.adb.android.AdbMdns;
import io.github.muntashirakon.adb.android.AndroidUtils;

public class MainActivity extends Activity {
    private static final int SAVE_REQUEST = 42;
    private static final int NOTIFICATION_PERMISSION_REQUEST = 46;
    private static final int PREVIEW_IMPORTANT_BYTES = 80_000;
    private static final int PREVIEW_RAW_BYTES = 180_000;
    private static final int PREVIEW_IMPORTANT_LINES = 100;
    private static final int PREVIEW_RAW_LINES = 300;

    private final ExecutorService executor = Executors.newCachedThreadPool();
    private final Handler handler = new Handler(Looper.getMainLooper());

    private TextView status;
    private TextView logView;
    private EditText portInput;
    private EditText codeInput;
    private Switch masterSwitch;
    private Button startMonitoringButton;
    private Button stopMonitoringButton;
    private ScrollView pageScroll;
    private boolean changingMasterProgrammatically;

    private final Runnable refreshTask = new Runnable() {
        @Override
        public void run() {
            refreshStatusAndLogs();
            handler.postDelayed(this, 1000);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        buildUi();

        SharedPreferences prefs = getSharedPreferences(MonitoringService.PREFS, MODE_PRIVATE);
        boolean enabled = prefs.getBoolean(MonitoringService.PREF_MASTER, true);
        changingMasterProgrammatically = true;
        masterSwitch.setChecked(enabled);
        changingMasterProgrammatically = false;

        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATION_PERMISSION_REQUEST);
        }

        if (enabled) startMonitorService(false, MonitoringService.ACTION_START);
        updateMonitoringButtons();
    }

    private int dp(int n) {
        return (int) (n * getResources().getDisplayMetrics().density + 0.5f);
    }

    private TextView text(String value, float sp) {
        TextView v = new TextView(this);
        v.setText(value);
        v.setTextSize(sp);
        v.setPadding(0, dp(5), 0, dp(5));
        return v;
    }

    private Button button(String label) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        return b;
    }

    private void buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(16), dp(14), dp(16), dp(14));

        TextView title = text("Crash Monitor", 26);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(title);
        root.addView(text("Full Android log + crash / install failure detector", 14));

        LinearLayout masterRow = new LinearLayout(this);
        masterRow.setOrientation(LinearLayout.HORIZONTAL);
        masterRow.setGravity(android.view.Gravity.CENTER_VERTICAL);
        TextView masterLabel = text("Settings — Master power", 17);
        masterLabel.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        masterRow.addView(masterLabel, new LinearLayout.LayoutParams(0, dp(54), 1));
        masterSwitch = new Switch(this);
        masterSwitch.setTextOff("OFF");
        masterSwitch.setTextOn("ON");
        masterSwitch.setShowText(true);
        masterRow.addView(masterSwitch, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, dp(54)));
        root.addView(masterRow);

        root.addView(text(
                "Master ON keeps the background service alive even if you close or swipe away the app. " +
                "Start/Stop below controls logging. Master OFF shuts down the service and ADB connection, while keeping pairing saved.",
                13));

        status = text("Starting…", 15);
        root.addView(status);

        masterSwitch.setOnCheckedChangeListener((buttonView, isChecked) -> {
            if (changingMasterProgrammatically) return;
            getSharedPreferences(MonitoringService.PREFS, MODE_PRIVATE)
                    .edit().putBoolean(MonitoringService.PREF_MASTER, isChecked).apply();
            if (isChecked) {
                startMonitorService(false, MonitoringService.ACTION_START);
                toast("Master ON — background service stays running when the app is closed.");
            } else {
                Intent stop = new Intent(this, MonitoringService.class);
                stop.setAction(MonitoringService.ACTION_STOP);
                try { startService(stop); }
                catch (Throwable e) { stopService(new Intent(this, MonitoringService.class)); }
                getSharedPreferences(MonitoringService.PREFS, MODE_PRIVATE).edit()
                        .putString(MonitoringService.PREF_STATE,
                                "Master OFF — logging and ADB connection are off. Pairing is saved.").apply();
                status.setText("Master OFF — logging and ADB connection are off. Pairing is saved.");
            }
            updateMonitoringButtons();
        });

        Button openWireless = button("Open Developer options / Wireless debugging");
        openWireless.setOnClickListener(v -> {
            try { startActivity(new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)); }
            catch (Exception e) { startActivity(new Intent(Settings.ACTION_SETTINGS)); }
        });
        root.addView(openWireless);

        root.addView(text("Pairing is only needed once. If this app is already paired, leave these boxes alone.", 13));

        LinearLayout pairRow = new LinearLayout(this);
        pairRow.setOrientation(LinearLayout.HORIZONTAL);
        portInput = new EditText(this);
        portInput.setHint("Pair port");
        portInput.setInputType(InputType.TYPE_CLASS_NUMBER);
        pairRow.addView(portInput, new LinearLayout.LayoutParams(0, dp(58), 1));
        codeInput = new EditText(this);
        codeInput.setHint("6-digit code");
        codeInput.setInputType(InputType.TYPE_CLASS_NUMBER);
        pairRow.addView(codeInput, new LinearLayout.LayoutParams(0, dp(58), 1));
        root.addView(pairRow);

        LinearLayout pairButtons = new LinearLayout(this);
        pairButtons.setOrientation(LinearLayout.HORIZONTAL);
        Button findPort = button("Find pair port");
        Button pair = button("Pair");
        pairButtons.addView(findPort, new LinearLayout.LayoutParams(0, dp(58), 1));
        pairButtons.addView(pair, new LinearLayout.LayoutParams(0, dp(58), 1));
        root.addView(pairButtons);
        findPort.setOnClickListener(v -> findPairingPort());
        pair.setOnClickListener(v -> pair());

        Button reconnect = button("Connect / reconnect");
        reconnect.setOnClickListener(v -> {
            if (!masterSwitch.isChecked()) {
                toast("Turn Master power ON first.");
                return;
            }
            startMonitorService(false, MonitoringService.ACTION_RECONNECT);
            status.setText("Reconnecting…");
        });
        root.addView(reconnect);

        LinearLayout monitorRow = new LinearLayout(this);
        monitorRow.setOrientation(LinearLayout.HORIZONTAL);
        startMonitoringButton = button("Start monitoring");
        stopMonitoringButton = button("Stop");
        monitorRow.addView(startMonitoringButton, new LinearLayout.LayoutParams(0, dp(58), 1));
        monitorRow.addView(stopMonitoringButton, new LinearLayout.LayoutParams(0, dp(58), 1));
        root.addView(monitorRow);

        startMonitoringButton.setOnClickListener(v -> {
            if (!masterSwitch.isChecked()) {
                toast("Turn Master power ON first.");
                return;
            }
            getSharedPreferences(MonitoringService.PREFS, MODE_PRIVATE).edit()
                    .putBoolean(MonitoringService.PREF_MONITORING, true).apply();
            startMonitorService(true, MonitoringService.ACTION_START_MONITORING);
            status.setText("Starting full Android logging…");
            updateMonitoringButtons();
        });

        stopMonitoringButton.setOnClickListener(v -> {
            if (!masterSwitch.isChecked()) return;
            getSharedPreferences(MonitoringService.PREFS, MODE_PRIVATE).edit()
                    .putBoolean(MonitoringService.PREF_MONITORING, false).apply();
            startMonitorService(false, MonitoringService.ACTION_STOP_MONITORING);
            status.setText("Ready — logging stopped. Master power is still ON.");
            updateMonitoringButtons();
        });

        root.addView(text(
                "While monitoring is ON, it records every ADB-visible logcat buffer. Important lines are copied into categories: [INSTALL], [CRASH], [ANR], [SECURITY], and [ERROR].",
                12));

        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.HORIZONTAL);
        Button clear = button("Clear");
        Button copy = button("Copy latest");
        Button save = button("Save full TXT");
        actions.addView(clear, new LinearLayout.LayoutParams(0, dp(54), 1));
        actions.addView(copy, new LinearLayout.LayoutParams(0, dp(54), 1));
        actions.addView(save, new LinearLayout.LayoutParams(0, dp(54), 1));
        root.addView(actions);

        clear.setOnClickListener(v -> {
            if (masterSwitch.isChecked()) startMonitorService(false, MonitoringService.ACTION_CLEAR);
            else clearLocalFiles();
            logView.setText("");
        });
        copy.setOnClickListener(v -> copyLogs());
        save.setOnClickListener(v -> saveLogs());

        TextView label = text("Important events + latest raw log (preview)", 16);
        label.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(label);

        logView = text("", 11);
        logView.setTypeface(Typeface.MONOSPACE);
        logView.setTextIsSelectable(true);

        // Use one full-page scroll instead of a smaller nested log scroller.
        // This makes the log section expand with its content, so in split-screen
        // you can scroll the whole app continuously from the controls through
        // the complete preview without getting trapped inside a short log box.
        int viewportHeight = getWindowManager().getCurrentWindowMetrics().getBounds().height();
        logView.setMinHeight(Math.max(dp(220), viewportHeight));
        root.addView(logView, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        pageScroll = new ScrollView(this);
        pageScroll.setFillViewport(true);
        pageScroll.setVerticalScrollBarEnabled(true);
        pageScroll.setScrollbarFadingEnabled(false);
        pageScroll.setScrollBarStyle(View.SCROLLBARS_INSIDE_INSET);
        pageScroll.setVerticalScrollbarPosition(View.SCROLLBAR_POSITION_RIGHT);
        // Keep the scrollbar away from the curved/display edge so it stays visible
        // in full-screen and Samsung split-screen layouts.
        pageScroll.setClipToPadding(true);
        pageScroll.setOnApplyWindowInsetsListener((v, insets) -> {
            android.graphics.Insets bars = insets.getInsets(android.view.WindowInsets.Type.systemBars());
            v.setPadding(dp(6), bars.top + dp(4), bars.right + dp(12), bars.bottom + dp(12));
            return insets;
        });
        pageScroll.requestApplyInsets();
        pageScroll.addView(root, new ScrollView.LayoutParams(
                ScrollView.LayoutParams.MATCH_PARENT,
                ScrollView.LayoutParams.WRAP_CONTENT));

        setContentView(pageScroll);
    }

    private void updateMonitoringButtons() {
        if (startMonitoringButton == null || stopMonitoringButton == null || masterSwitch == null) return;
        SharedPreferences prefs = getSharedPreferences(MonitoringService.PREFS, MODE_PRIVATE);
        boolean master = prefs.getBoolean(MonitoringService.PREF_MASTER, true);
        boolean monitoring = prefs.getBoolean(MonitoringService.PREF_MONITORING, true);
        startMonitoringButton.setEnabled(master && !monitoring);
        stopMonitoringButton.setEnabled(master && monitoring);
    }

    private void startMonitorService(boolean clear, String action) {
        Intent service = new Intent(this, MonitoringService.class);
        service.setAction(action);
        service.putExtra(MonitoringService.EXTRA_CLEAR_ON_START, clear);
        try { startForegroundService(service); }
        catch (Throwable e) { toast("Could not start background monitoring: " + shortError(e)); }
    }

    private void findPairingPort() {
        status.setText("Finding Wireless debugging pairing port…");
        executor.submit(() -> {
            AtomicInteger port = new AtomicInteger(-1);
            CountDownLatch latch = new CountDownLatch(1);
            AdbMdns mdns = new AdbMdns(this, AdbMdns.SERVICE_TYPE_TLS_PAIRING, (host, foundPort) -> {
                port.set(foundPort);
                latch.countDown();
            });
            try {
                mdns.start();
                latch.await(30, TimeUnit.SECONDS);
            } catch (Exception ignored) {
            } finally {
                try { mdns.stop(); } catch (Exception ignored) { }
            }
            int found = port.get();
            runOnUiThread(() -> {
                if (found > 0) {
                    portInput.setText(String.valueOf(found));
                    status.setText("Pairing port found: " + found + ". Enter the 6-digit code, then tap Pair.");
                } else {
                    status.setText("Pairing port not found. Keep 'Pair device with pairing code' open and enter its port manually.");
                }
            });
        });
    }

    private void pair() {
        String p = portInput.getText().toString().trim();
        String code = codeInput.getText().toString().trim();
        if (p.isEmpty() || code.length() < 6) {
            toast("Enter the pairing port and 6-digit code shown by Wireless debugging.");
            return;
        }
        int port;
        try { port = Integer.parseInt(p); }
        catch (NumberFormatException e) { toast("Invalid pairing port."); return; }

        status.setText("Pairing…");
        executor.submit(() -> {
            try {
                AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
                boolean ok = manager.pair(AndroidUtils.getHostIpAddress(this), port, code);
                runOnUiThread(() -> {
                    if (ok) {
                        status.setText("Paired successfully. Crash Monitor will reconnect automatically.");
                        codeInput.setText("");
                        if (masterSwitch.isChecked()) startMonitorService(false, MonitoringService.ACTION_RECONNECT);
                    } else {
                        status.setText("Pairing failed. Generate a new pairing code and try again.");
                    }
                });
            } catch (Throwable e) {
                runOnUiThread(() -> status.setText("Pairing error: " + shortError(e)));
            }
        });
    }

    private void refreshStatusAndLogs() {
        SharedPreferences prefs = getSharedPreferences(MonitoringService.PREFS, MODE_PRIVATE);
        boolean enabled = prefs.getBoolean(MonitoringService.PREF_MASTER, true);
        if (masterSwitch.isChecked() != enabled) {
            changingMasterProgrammatically = true;
            masterSwitch.setChecked(enabled);
            changingMasterProgrammatically = false;
        }
        String state = prefs.getString(MonitoringService.PREF_STATE,
                enabled ? "Crash Monitor service starting…" : "Master OFF — logging and ADB connection are off. Pairing is saved.");
        status.setText(state);
        String preview = readPreview();
        if (!preview.contentEquals(logView.getText())) {
            int oldScrollY = pageScroll == null ? 0 : pageScroll.getScrollY();
            logView.setText(preview);
            if (pageScroll != null) {
                pageScroll.post(() -> pageScroll.scrollTo(0, oldScrollY));
            }
        }
        updateMonitoringButtons();
    }

    private String readPreview() {
        String important = dedupeExactLines(keepLastLines(
                readTail(new File(getFilesDir(), MonitoringService.IMPORTANT_FILE), PREVIEW_IMPORTANT_BYTES),
                PREVIEW_IMPORTANT_LINES));
        String raw = dedupeExactLines(keepLastLines(
                readTail(new File(getFilesDir(), MonitoringService.LOG_FILE), PREVIEW_RAW_BYTES),
                PREVIEW_RAW_LINES));

        // Important events are copied from the raw log. Hide those exact lines from
        // the raw preview so the same event is not shown twice on screen.
        Set<String> importantLines = new HashSet<>();
        for (String line : important.split("\n")) {
            String normalized = stripCategoryPrefix(line);
            if (!normalized.trim().isEmpty()) importantLines.add(normalized);
        }

        StringBuilder filteredRaw = new StringBuilder();
        Set<String> seenRaw = new HashSet<>();
        for (String line : raw.split("\n")) {
            if (line.trim().isEmpty()) continue;
            if (importantLines.contains(line)) continue;
            // Do not show the same exact raw line twice in the on-screen preview.
            if (!seenRaw.add(line)) continue;
            filteredRaw.append(line).append('\n');
        }

        StringBuilder out = new StringBuilder();
        out.append("=== IMPORTANT EVENTS — LATEST ").append(PREVIEW_IMPORTANT_LINES).append(" LINES MAX ===\n");
        out.append(important.isEmpty() ? "(none detected yet)\n" : important);
        out.append("\n=== RAW LOG — LATEST ").append(PREVIEW_RAW_LINES)
                .append(" LINES MAX (important duplicates omitted) ===\n");
        out.append(filteredRaw.length() == 0 ? "(no additional raw log data yet)\n" : filteredRaw);
        out.append("\n[Screen preview is capped for smooth scrolling. Save full TXT keeps the complete log.]\n");
        return out.toString();
    }

    private String dedupeExactLines(String text) {
        if (text == null || text.isEmpty()) return "";
        Set<String> seen = new HashSet<>();
        StringBuilder out = new StringBuilder();
        for (String line : text.split("\n")) {
            if (line.trim().isEmpty()) continue;
            if (seen.add(line)) out.append(line).append('\n');
        }
        return out.toString();
    }

    private String stripCategoryPrefix(String line) {
        if (line == null) return "";
        if (line.matches("^\\[[A-Z]+\\]\\s+.*")) {
            int end = line.indexOf("] ");
            if (end >= 0 && end + 2 < line.length()) return line.substring(end + 2);
        }
        return line;
    }

    private String keepLastLines(String text, int maxLines) {
        if (text == null || text.isEmpty()) return "";
        String[] lines = text.split("\n");
        int start = Math.max(0, lines.length - maxLines);
        StringBuilder out = new StringBuilder();
        for (int i = start; i < lines.length; i++) {
            out.append(lines[i]).append('\n');
        }
        return out.toString();
    }

    private String readTail(File f, int maxBytes) {
        if (!f.exists() || f.length() == 0) return "";
        try (FileInputStream in = new FileInputStream(f)) {
            long length = f.length();
            int take = (int) Math.min((long) maxBytes, length);
            long skip = length - take;
            while (skip > 0) {
                long n = in.skip(skip);
                if (n <= 0) break;
                skip -= n;
            }
            byte[] data = new byte[take];
            int off = 0;
            while (off < data.length) {
                int n = in.read(data, off, data.length - off);
                if (n < 0) break;
                off += n;
            }
            return new String(data, 0, off, StandardCharsets.UTF_8);
        } catch (Exception e) {
            return "[Could not read log: " + shortError(e) + "]\n";
        }
    }

    private void copyLogs() {
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        cm.setPrimaryClip(ClipData.newPlainText("Crash Monitor latest log", readPreview()));
        toast("Latest important events + raw log copied. Use Save full TXT for the complete log.");
    }

    private void saveLogs() {
        Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("text/plain");
        i.putExtra(Intent.EXTRA_TITLE, "crash-monitor-full-log.txt");
        startActivityForResult(i, SAVE_REQUEST);
    }

    private void writeFileTo(OutputStream out, File f) throws Exception {
        if (!f.exists() || f.length() == 0) return;
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] buf = new byte[32 * 1024];
            int n;
            while ((n = in.read(buf)) >= 0) if (n > 0) out.write(buf, 0, n);
        }
    }

    private void writeFullExport(OutputStream out) throws Exception {
        out.write("=== IMPORTANT EVENTS (classified) ===\n".getBytes(StandardCharsets.UTF_8));
        writeFileTo(out, new File(getFilesDir(), MonitoringService.IMPORTANT_FILE));
        out.write("\n=== FULL RAW ADB-VISIBLE ANDROID LOGCAT ===\n".getBytes(StandardCharsets.UTF_8));
        writeFileTo(out, new File(getFilesDir(), MonitoringService.LOG_FILE));
    }

    private void clearLocalFiles() {
        clearFile(new File(getFilesDir(), MonitoringService.LOG_FILE));
        clearFile(new File(getFilesDir(), MonitoringService.IMPORTANT_FILE));
    }

    private void clearFile(File f) {
        try (FileOutputStream out = new FileOutputStream(f, false)) { out.write(new byte[0]); }
        catch (Exception ignored) { }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == SAVE_REQUEST && resultCode == RESULT_OK && data != null) {
            Uri uri = data.getData();
            if (uri == null) return;
            try (OutputStream out = getContentResolver().openOutputStream(uri)) {
                if (out != null) writeFullExport(out);
                toast("Full log saved.");
            } catch (Exception e) {
                toast("Save failed: " + shortError(e));
            }
        }
    }

    private void toast(String s) {
        Toast.makeText(this, s, Toast.LENGTH_LONG).show();
    }

    private static String shortError(Throwable e) {
        Throwable t = e;
        while (t.getCause() != null && t.getCause() != t) t = t.getCause();
        String m = t.getMessage();
        return t.getClass().getSimpleName() + (m == null ? "" : ": " + m);
    }

    @Override
    protected void onResume() {
        super.onResume();
        handler.removeCallbacks(refreshTask);
        handler.post(refreshTask);
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(refreshTask);
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacks(refreshTask);
        executor.shutdownNow();
        super.onDestroy();
    }
}
