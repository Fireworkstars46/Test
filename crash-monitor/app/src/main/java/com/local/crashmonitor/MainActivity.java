package com.local.crashmonitor;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputType;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import io.github.muntashirakon.adb.AdbPairingRequiredException;
import io.github.muntashirakon.adb.AdbStream;
import io.github.muntashirakon.adb.android.AdbMdns;
import io.github.muntashirakon.adb.android.AndroidUtils;

public class MainActivity extends Activity {
    private static final int SAVE_REQUEST = 42;
    private final ExecutorService executor = Executors.newCachedThreadPool();
    private final StringBuilder logBuffer = new StringBuilder();
    private TextView status;
    private TextView logView;
    private EditText portInput;
    private EditText codeInput;
    private Button startButton;
    private Button stopButton;
    private volatile boolean monitoring;
    private volatile AdbStream monitorStream;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        buildUi();
        setStatus("Checking Wireless debugging connection…");
        executor.submit(this::autoConnect);
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

        status = text("Not connected", 15);
        root.addView(status);

        TextView help = text("No Shizuku needed. Pair this app once with Android Wireless debugging, then it can read crash logs from other apps.", 14);
        root.addView(help);

        Button openWireless = button("Open Developer options / Wireless debugging");
        openWireless.setOnClickListener(v -> {
            try {
                startActivity(new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS));
            } catch (Exception e) {
                startActivity(new Intent(Settings.ACTION_SETTINGS));
            }
        });
        root.addView(openWireless);

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

        Button connect = button("Connect / reconnect");
        connect.setOnClickListener(v -> {
            setStatus("Connecting…");
            executor.submit(this::autoConnect);
        });
        root.addView(connect);

        LinearLayout monitorButtons = new LinearLayout(this);
        monitorButtons.setOrientation(LinearLayout.HORIZONTAL);
        startButton = button("Start monitoring");
        stopButton = button("Stop");
        stopButton.setEnabled(false);
        monitorButtons.addView(startButton, new LinearLayout.LayoutParams(0, dp(58), 1));
        monitorButtons.addView(stopButton, new LinearLayout.LayoutParams(0, dp(58), 1));
        root.addView(monitorButtons);
        startButton.setOnClickListener(v -> executor.submit(this::startMonitoring));
        stopButton.setOnClickListener(v -> stopMonitoring());

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
            synchronized (logBuffer) { logBuffer.setLength(0); }
            logView.setText("");
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

    private void setStatus(String s) {
        runOnUiThread(() -> status.setText(s));
    }

    private void toast(String s) {
        runOnUiThread(() -> Toast.makeText(this, s, Toast.LENGTH_LONG).show());
    }

    private void findPairingPort() {
        setStatus("Finding Wireless debugging pairing port…");
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
                try { mdns.stop(); } catch (Exception ignored) {}
            }
            int found = port.get();
            if (found > 0) {
                runOnUiThread(() -> portInput.setText(String.valueOf(found)));
                setStatus("Pairing port found: " + found + ". Enter the 6-digit code, then tap Pair.");
            } else {
                setStatus("Pairing port not found. Keep 'Pair device with pairing code' open and enter its port manually.");
            }
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
        setStatus("Pairing…");
        executor.submit(() -> {
            try {
                AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
                boolean ok = manager.pair(AndroidUtils.getHostIpAddress(this), port, code);
                if (ok) {
                    setStatus("Paired. Connecting…");
                    autoConnect();
                } else {
                    setStatus("Pairing failed. Generate a new pairing code and try again.");
                }
            } catch (Throwable e) {
                setStatus("Pairing error: " + shortError(e));
            }
        });
    }

    private void autoConnect() {
        try {
            AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
            if (manager.isConnected()) {
                setStatus("Connected — ready to monitor crashes.");
                return;
            }
            boolean ok;
            try {
                ok = manager.autoConnect(this, 10000);
            } catch (AdbPairingRequiredException e) {
                setStatus("Not paired yet. Open Wireless debugging → Pair device with pairing code.");
                return;
            }
            if (ok) setStatus("Connected — ready to monitor crashes.");
            else setStatus("Not connected. Make sure Wireless debugging is ON, then tap Connect / reconnect.");
        } catch (Throwable e) {
            setStatus("Connection error: " + shortError(e));
        }
    }

    private void startMonitoring() {
        if (monitoring) return;
        try {
            AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
            if (!manager.isConnected()) {
                setStatus("Connecting before monitoring…");
                try {
                    if (!manager.autoConnect(this, 10000)) {
                        setStatus("Could not connect. Pair first or turn Wireless debugging back on.");
                        return;
                    }
                } catch (AdbPairingRequiredException e) {
                    setStatus("Pair this app first.");
                    return;
                }
            }

            clearDeviceCrashBuffer(manager);
            monitoring = true;
            runOnUiThread(() -> {
                startButton.setEnabled(false);
                stopButton.setEnabled(true);
            });
            setStatus("Monitoring crashes… now reproduce the crash.");

            monitorStream = manager.openStream("shell:logcat -b crash -v threadtime");
            try (InputStream in = monitorStream.openInputStream();
                 BufferedReader reader = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
                String line;
                while (monitoring && (line = reader.readLine()) != null) {
                    appendLog(line + "\n");
                }
            }
        } catch (Throwable e) {
            if (monitoring) appendLog("\n[Monitor error] " + shortError(e) + "\n");
        } finally {
            monitoring = false;
            runOnUiThread(() -> {
                startButton.setEnabled(true);
                stopButton.setEnabled(false);
            });
            setStatus("Monitoring stopped.");
        }
    }

    private void clearDeviceCrashBuffer(AdbConnectionManager manager) {
        try {
            AdbStream s = manager.openStream("shell:logcat -b crash -c");
            try (InputStream in = s.openInputStream()) {
                byte[] buf = new byte[256];
                while (in.read(buf) >= 0) { }
            } finally {
                try { s.close(); } catch (Exception ignored) { }
            }
        } catch (Exception ignored) { }
        synchronized (logBuffer) { logBuffer.setLength(0); }
        runOnUiThread(() -> logView.setText(""));
    }

    private void stopMonitoring() {
        monitoring = false;
        AdbStream s = monitorStream;
        monitorStream = null;
        if (s != null) {
            executor.submit(() -> {
                try { s.close(); } catch (Exception ignored) { }
            });
        }
        setStatus("Monitoring stopped.");
    }

    private void appendLog(String s) {
        final String snapshot;
        synchronized (logBuffer) {
            logBuffer.append(s);
            if (logBuffer.length() > 600000) logBuffer.delete(0, 100000);
            snapshot = logBuffer.toString();
        }
        runOnUiThread(() -> logView.setText(snapshot));
    }

    private String getLogs() {
        synchronized (logBuffer) { return logBuffer.toString(); }
    }

    private void copyLogs() {
        String logs = getLogs();
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        cm.setPrimaryClip(ClipData.newPlainText("Crash Monitor log", logs));
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
                if (out != null) out.write(getLogs().getBytes(StandardCharsets.UTF_8));
                toast("Crash log saved.");
            } catch (Exception e) {
                toast("Save failed: " + shortError(e));
            }
        }
    }

    private static String shortError(Throwable e) {
        Throwable t = e;
        while (t.getCause() != null && t.getCause() != t) t = t.getCause();
        String m = t.getMessage();
        return t.getClass().getSimpleName() + (m == null ? "" : ": " + m);
    }

    @Override
    protected void onDestroy() {
        stopMonitoring();
        executor.shutdownNow();
        super.onDestroy();
    }
}
