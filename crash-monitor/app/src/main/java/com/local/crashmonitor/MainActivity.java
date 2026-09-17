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
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
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

    private final ExecutorService executor = Executors.newCachedThreadPool();
    private final Handler handler = new Handler(Looper.getMainLooper());

    private TextView status;
    private TextView logView;
    private EditText portInput;
    private EditText codeInput;
    private Switch masterSwitch;
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

        TextView masterHelp = text(
                "When ON, monitoring runs as a foreground service even if you close or swipe away this app. " +
                "It only stops when you turn this setting OFF (or Android is force-stopped). Pairing stays saved.",
                13);
        root.addView(masterHelp);

        status = text("Starting…", 15);
        root.addView(status);

        masterSwitch.setOnCheckedChangeListener((buttonView, isChecked) -> {
            if (changingMasterProgrammatically) return;
            getSharedPreferences(MonitoringService.PREFS, MODE_PRIVATE)
                    .edit()
                    .putBoolean(MonitoringService.PREF_MASTER, isChecked)
                    .apply();
            if (isChecked) {
                startMonitorService(true, MonitoringService.ACTION_START);
                toast("Master ON — monitoring will keep running when the app is closed.");
            } else {
                Intent stop = new Intent(this, MonitoringService.class);
                stop.setAction(MonitoringService.ACTION_STOP);
                try {
                    startService(stop);
                } catch (Throwable e) {
                    stopService(new Intent(this, MonitoringService.class));
                }
                getSharedPreferences(MonitoringService.PREFS, MODE_PRIVATE)
                        .edit()
                        .putString(MonitoringService.PREF_STATE,
                                "Master OFF — monitoring and ADB connection are off. Pairing is saved.")
                        .apply();
                status.setText("Master OFF — monitoring and ADB connection are off. Pairing is saved.");
            }
        });

        Button openWireless = button("Open Developer options / Wireless debugging");
        openWireless.setOnClickListener(v -> {
            try {
                startActivity(new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS));
            } catch (Exception e) {
                startActivity(new Intent(Settings.ACTION_SETTINGS));
            }
        });
        root.addView(openWireless);

        TextView pairHelp = text(
                "Pairing is only needed once. If this app is already paired, you can leave the boxes below alone.",
                13);
        root.addView(pairHelp);

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

        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.HORIZONTAL);
        Button clear = button("Clear");
        Button copy = button("Copy");
        Button save = button("Save TXT");
        actions.addView(clear, new LinearLayout.LayoutParams(0, dp(54), 1));
        actions.addView(copy, new LinearLayout.LayoutParams(0, dp(54), 1));
        actions.addView(save, new LinearLayout.LayoutParams(0, dp(54), 1));
        root.addView(actions);

        clear.setOnClickListener(v -> {
            clearLocalLog();
            if (masterSwitch.isChecked()) startMonitorService(false, MonitoringService.ACTION_CLEAR);
            refreshStatusAndLogs();
        });
        copy.setOnClickListener(v -> copyLogs());
        save.setOnClickListener(v -> saveLogs());

        TextView label = text("Crash log", 16);
        label.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(label);

        logView = text("", 12);
        logView.setTypeface(Typeface.MONOSPACE);
        logView.setTextIsSelectable(true);
        ScrollView logScroll = new ScrollView(this);
        logScroll.setFillViewport(true);
        logScroll.addView(logView);
        root.addView(logScroll, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));

        setContentView(root);
    }

    private void startMonitorService(boolean clear, String action) {
        Intent service = new Intent(this, MonitoringService.class);
        service.setAction(action);
        service.putExtra(MonitoringService.EXTRA_CLEAR_ON_START, clear);
        try {
            startForegroundService(service);
        } catch (Throwable e) {
            toast("Could not start background monitoring: " + shortError(e));
        }
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
        catch (NumberFormatException e) {
            toast("Invalid pairing port.");
            return;
        }

        status.setText("Pairing…");
        executor.submit(() -> {
            try {
                AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
                boolean ok = manager.pair(AndroidUtils.getHostIpAddress(this), port, code);
                runOnUiThread(() -> {
                    if (ok) {
                        status.setText("Paired successfully. Monitoring will connect automatically.");
                        codeInput.setText("");
                        if (masterSwitch.isChecked()) {
                            startMonitorService(false, MonitoringService.ACTION_RECONNECT);
                        }
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
                enabled ? "Monitoring service starting…" : "Master OFF — monitoring and ADB connection are off. Pairing is saved.");
        status.setText(state);
        logView.setText(readLogs());
    }

    private String readLogs() {
        File f = new File(getFilesDir(), MonitoringService.LOG_FILE);
        if (!f.exists()) return "";
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] data = new byte[(int) Math.min(f.length(), 1_500_000L)];
            int off = 0;
            while (off < data.length) {
                int n = in.read(data, off, data.length - off);
                if (n < 0) break;
                off += n;
            }
            return new String(data, 0, off, StandardCharsets.UTF_8);
        } catch (Exception e) {
            return "[Could not read log: " + shortError(e) + "]";
        }
    }

    private void clearLocalLog() {
        File f = new File(getFilesDir(), MonitoringService.LOG_FILE);
        if (f.exists()) f.delete();
        logView.setText("");
    }

    private void copyLogs() {
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        cm.setPrimaryClip(ClipData.newPlainText("Crash Monitor log", readLogs()));
        toast("Crash log copied.");
    }

    private void saveLogs() {
        Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("text/plain");
        i.putExtra(Intent.EXTRA_TITLE, "crash-monitor-log.txt");
        startActivityForResult(i, SAVE_REQUEST);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == SAVE_REQUEST && resultCode == RESULT_OK && data != null) {
            Uri uri = data.getData();
            if (uri == null) return;
            try (OutputStream out = getContentResolver().openOutputStream(uri)) {
                if (out != null) out.write(readLogs().getBytes(StandardCharsets.UTF_8));
                toast("Crash log saved.");
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
        // Do NOT stop MonitoringService here. Closing/swiping the UI must not stop monitoring.
        super.onDestroy();
    }
}
