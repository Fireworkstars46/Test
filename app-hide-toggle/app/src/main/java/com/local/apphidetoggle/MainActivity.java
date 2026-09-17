package com.local.apphidetoggle;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Typeface;
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
    private final ExecutorService executor = Executors.newCachedThreadPool();

    private TextView status;
    private TextView result;
    private EditText portInput;
    private EditText codeInput;
    private EditText packageInput;

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

        TextView title = text("App Hide Toggle", 26);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(title);

        TextView info = text(
                "Pair once with Android Wireless debugging. Then enter any app package name and hide/disable or show/enable it for user 0. No Shizuku or aShell is needed.",
                14);
        root.addView(info);

        status = text("Not connected", 15);
        root.addView(status);

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

        TextView packageLabel = text("App package name", 16);
        packageLabel.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(packageLabel);

        packageInput = new EditText(this);
        packageInput.setHint("Example: com.android.chrome");
        packageInput.setSingleLine(true);
        root.addView(packageInput, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(58)));

        TextView warning = text(
                "Warning: disabling Settings, One UI Home, System UI, or other core packages can make the phone difficult to use. This app refuses to disable itself.",
                13);
        root.addView(warning);

        LinearLayout actionRow = new LinearLayout(this);
        actionRow.setOrientation(LinearLayout.HORIZONTAL);
        Button hide = button("HIDE / DISABLE");
        Button show = button("SHOW / ENABLE");
        actionRow.addView(hide, new LinearLayout.LayoutParams(0, dp(60), 1));
        actionRow.addView(show, new LinearLayout.LayoutParams(0, dp(60), 1));
        root.addView(actionRow);

        hide.setOnClickListener(v -> runPackageCommand(false));
        show.setOnClickListener(v -> runPackageCommand(true));

        TextView resultLabel = text("Result", 16);
        resultLabel.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(resultLabel);

        result = text("", 13);
        result.setTypeface(Typeface.MONOSPACE);
        result.setTextIsSelectable(true);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(result);
        root.addView(scroll, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));

        setContentView(root);
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
                try { mdns.stop(); } catch (Exception ignored) { }
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
        if (p.isEmpty() || code.length() != 6) {
            toast("Enter the pairing port and 6-digit code shown by Wireless debugging.");
            return;
        }
        int port;
        try {
            port = Integer.parseInt(p);
        } catch (NumberFormatException e) {
            toast("Invalid pairing port.");
            return;
        }

        setStatus("Pairing…");
        executor.submit(() -> {
            try {
                AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
                boolean ok = manager.pair(AndroidUtils.getHostIpAddress(this), port, code);
                if (ok) {
                    runOnUiThread(() -> codeInput.setText(""));
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
                setStatus("Connected — ready.");
                return;
            }
            boolean ok;
            try {
                ok = manager.autoConnect(this, 10000);
            } catch (AdbPairingRequiredException e) {
                setStatus("Not paired yet. Open Wireless debugging → Pair device with pairing code.");
                return;
            }
            setStatus(ok ? "Connected — ready." : "Not connected. Make sure Wireless debugging is ON, then tap Connect / reconnect.");
        } catch (Throwable e) {
            setStatus("Connection error: " + shortError(e));
        }
    }

    private void runPackageCommand(boolean enable) {
        String pkg = packageInput.getText().toString().trim();
        if (pkg.isEmpty()) {
            toast("Enter an app package name first.");
            return;
        }
        if (!pkg.matches("[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+")) {
            toast("That does not look like a valid Android package name.");
            return;
        }
        if (getPackageName().equals(pkg) && !enable) {
            toast("App Hide Toggle will not disable itself.");
            return;
        }

        result.setText("");
        setStatus((enable ? "Enabling " : "Disabling ") + pkg + "…");
        executor.submit(() -> executePackageCommand(pkg, enable));
    }

    private void executePackageCommand(String pkg, boolean enable) {
        try {
            AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
            if (!manager.isConnected()) {
                setStatus("Connecting…");
                try {
                    if (!manager.autoConnect(this, 10000)) {
                        setStatus("Could not connect. Make sure Wireless debugging is ON.");
                        return;
                    }
                } catch (AdbPairingRequiredException e) {
                    setStatus("Pair this app first.");
                    return;
                }
            }

            String command = enable
                    ? "shell:pm enable --user 0 " + pkg
                    : "shell:pm disable-user --user 0 " + pkg;
            String output = runShell(manager, command);
            if (output.trim().isEmpty()) output = "Command completed with no text output.";
            final String finalOutput = output;
            runOnUiThread(() -> result.setText(finalOutput));
            setStatus(enable ? "Enabled / shown: " + pkg : "Disabled / hidden: " + pkg);
        } catch (Throwable e) {
            String msg = shortError(e);
            runOnUiThread(() -> result.setText(msg));
            setStatus("Command failed: " + msg);
        }
    }

    private String runShell(AdbConnectionManager manager, String service) throws Exception {
        AdbStream stream = manager.openStream(service);
        StringBuilder out = new StringBuilder();
        try (InputStream in = stream.openInputStream();
             BufferedReader reader = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                out.append(line).append('\n');
            }
        } finally {
            try { stream.close(); } catch (Exception ignored) { }
        }
        return out.toString();
    }

    private void setStatus(String s) {
        runOnUiThread(() -> status.setText(s));
    }

    private void toast(String s) {
        runOnUiThread(() -> Toast.makeText(this, s, Toast.LENGTH_LONG).show());
    }

    private static String shortError(Throwable e) {
        Throwable t = e;
        while (t.getCause() != null && t.getCause() != t) t = t.getCause();
        String m = t.getMessage();
        return t.getClass().getSimpleName() + (m == null ? "" : ": " + m);
    }

    @Override
    protected void onDestroy() {
        executor.shutdownNow();
        super.onDestroy();
    }
}
