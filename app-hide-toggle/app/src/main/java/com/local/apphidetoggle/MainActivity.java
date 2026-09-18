package com.local.apphidetoggle;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Typeface;
import android.os.Bundle;
import android.provider.Settings;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Locale;
import java.util.Set;
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
    private final ArrayList<AppEntry> installedApps = new ArrayList<>();

    private TextView status;
    private TextView result;
    private EditText portInput;
    private EditText codeInput;
    private EditText searchInput;
    private TextView appCount;
    private TextView selectedApp;
    private ListView appList;
    private AppAdapter appAdapter;
    private Button visibilityToggleButton;
    private Button enabledToggleButton;
    private ScrollView pageScroll;
    private String selectedPackage = "";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        buildUi();
        setStatus("Checking Wireless debugging connection…");
        executor.submit(this::autoConnect);
        loadInstalledApps();
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

        root.addView(text(
                "Pair once with Android Wireless debugging. Tap an app below. The first button toggles its launcher icon between Shown and Hidden. The second button toggles the whole app between Enabled and Disabled.",
                14));

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

        TextView appsLabel = text("Installed apps", 17);
        appsLabel.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(appsLabel);

        appCount = text("Scanning installed apps…", 13);
        root.addView(appCount);

        LinearLayout searchRow = new LinearLayout(this);
        searchRow.setOrientation(LinearLayout.HORIZONTAL);

        searchInput = new EditText(this);
        searchInput.setHint("Search app name or package");
        searchInput.setSingleLine(true);
        searchRow.addView(searchInput, new LinearLayout.LayoutParams(0, dp(58), 1));

        Button rescan = button("Rescan");
        searchRow.addView(rescan, new LinearLayout.LayoutParams(dp(110), dp(58)));
        root.addView(searchRow);

        appList = new ListView(this);
        appList.setNestedScrollingEnabled(true);
        appList.setVerticalScrollBarEnabled(true);
        appList.setScrollbarFadingEnabled(false);
        appList.setScrollBarStyle(View.SCROLLBARS_INSIDE_OVERLAY);
        appList.setVerticalScrollbarPosition(View.SCROLLBAR_POSITION_RIGHT);
        appAdapter = new AppAdapter();
        appList.setAdapter(appAdapter);

        int windowHeight = getWindowManager().getCurrentWindowMetrics().getBounds().height();
        int listHeight = Math.max(dp(220), Math.min(dp(520), (int) (windowHeight * 0.55f)));
        root.addView(appList, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, listHeight));

        appList.setOnItemClickListener((parent, view, position, id) -> {
            AppEntry entry = appAdapter.getItem(position);
            selectedPackage = entry.packageName;
            updateSelectedAppText();
        });

        searchInput.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) {
                appAdapter.filter(s == null ? "" : s.toString());
                appCount.setText("Showing " + appAdapter.getCount() + " of " + installedApps.size() + " installed apps.");
            }
            @Override public void afterTextChanged(Editable s) { }
        });

        rescan.setOnClickListener(v -> loadInstalledApps());

        selectedApp = text("No app selected", 14);
        selectedApp.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        selectedApp.setTextIsSelectable(true);
        root.addView(selectedApp);

        root.addView(text(
                "Warning: hiding or disabling Settings, One UI Home, System UI, or other core apps can make the phone difficult to use. This app refuses to hide or disable itself.",
                13));

        LinearLayout actionRow = new LinearLayout(this);
        actionRow.setOrientation(LinearLayout.HORIZONTAL);
        visibilityToggleButton = button("Hide / Show");
        enabledToggleButton = button("Disable / Enable");
        actionRow.addView(visibilityToggleButton, new LinearLayout.LayoutParams(0, dp(60), 1));
        actionRow.addView(enabledToggleButton, new LinearLayout.LayoutParams(0, dp(60), 1));
        root.addView(actionRow);

        visibilityToggleButton.setEnabled(false);
        enabledToggleButton.setEnabled(false);
        visibilityToggleButton.setOnClickListener(v -> toggleSelectedVisibility());
        enabledToggleButton.setOnClickListener(v -> toggleSelectedEnabled());

        TextView resultLabel = text("Result", 16);
        resultLabel.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(resultLabel);

        result = text("", 13);
        result.setTypeface(Typeface.MONOSPACE);
        result.setTextIsSelectable(true);
        result.setMinHeight(dp(90));
        root.addView(result);

        pageScroll = new ScrollView(this);
        pageScroll.setFillViewport(true);
        pageScroll.setVerticalScrollBarEnabled(true);
        pageScroll.setScrollbarFadingEnabled(false);
        pageScroll.setScrollBarStyle(View.SCROLLBARS_INSIDE_OVERLAY);
        pageScroll.setVerticalScrollbarPosition(View.SCROLLBAR_POSITION_RIGHT);
        pageScroll.setClipToPadding(true);
        pageScroll.setOnApplyWindowInsetsListener((v, insets) -> {
            android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
            v.setPadding(dp(6), bars.top + dp(4), bars.right + dp(12), bars.bottom + dp(12));
            return insets;
        });
        pageScroll.addView(root, new ScrollView.LayoutParams(
                ScrollView.LayoutParams.MATCH_PARENT,
                ScrollView.LayoutParams.WRAP_CONTENT));
        setContentView(pageScroll);
        pageScroll.requestApplyInsets();
    }

    private void loadInstalledApps() {
        runOnUiThread(() -> appCount.setText("Scanning installed apps…"));
        executor.submit(() -> {
            ArrayList<AppEntry> found = new ArrayList<>();
            Set<String> seenPackages = new HashSet<>();
            PackageManager pm = getPackageManager();

            try {
                Map<String, ArrayList<String>> launcherComponents = new HashMap<>();
                Intent launcherQuery = new Intent(Intent.ACTION_MAIN);
                launcherQuery.addCategory(Intent.CATEGORY_LAUNCHER);
                List<ResolveInfo> launchers = pm.queryIntentActivities(
                        launcherQuery, PackageManager.MATCH_DISABLED_COMPONENTS);
                for (ResolveInfo ri : launchers) {
                    if (ri.activityInfo == null || ri.activityInfo.packageName == null
                            || ri.activityInfo.name == null) continue;
                    launcherComponents
                            .computeIfAbsent(ri.activityInfo.packageName, k -> new ArrayList<>())
                            .add(ri.activityInfo.name);
                }

                List<ApplicationInfo> apps = pm.getInstalledApplications(PackageManager.MATCH_DISABLED_COMPONENTS);
                for (ApplicationInfo ai : apps) {
                    if ((ai.flags & ApplicationInfo.FLAG_INSTALLED) == 0) continue;
                    if (!seenPackages.add(ai.packageName)) continue;

                    String label;
                    try {
                        CharSequence cs = pm.getApplicationLabel(ai);
                        label = cs == null ? ai.packageName : cs.toString();
                    } catch (Throwable ignored) {
                        label = ai.packageName;
                    }

                    boolean enabled = ai.enabled;
                    try {
                        int state = pm.getApplicationEnabledSetting(ai.packageName);
                        if (state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                                || state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER
                                || state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED) {
                            enabled = false;
                        } else if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                            enabled = true;
                        }
                    } catch (Throwable ignored) {
                    }

                    ArrayList<String> components = launcherComponents.get(ai.packageName);
                    if (components == null) components = new ArrayList<>();

                    boolean launcherShown = false;
                    for (String activityName : components) {
                        try {
                            int componentState = pm.getComponentEnabledSetting(
                                    new ComponentName(ai.packageName, activityName));
                            boolean componentDisabled =
                                    componentState == PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                                    || componentState == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER
                                    || componentState == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED;
                            if (!componentDisabled) {
                                launcherShown = true;
                                break;
                            }
                        } catch (Throwable ignored) {
                            launcherShown = true;
                            break;
                        }
                    }

                    found.add(new AppEntry(label, ai.packageName, enabled, launcherShown, components));
                }

                found.sort(Comparator
                        .comparing((AppEntry e) -> e.label.toLowerCase(Locale.ROOT))
                        .thenComparing(e -> e.packageName));

                runOnUiThread(() -> {
                    installedApps.clear();
                    installedApps.addAll(found);
                    appAdapter.setApps(installedApps);
                    String q = searchInput.getText().toString();
                    appAdapter.filter(q);
                    appCount.setText("Showing " + appAdapter.getCount() + " of " + installedApps.size() + " installed apps.");
                    updateSelectedAppText();
                });
            } catch (Throwable e) {
                runOnUiThread(() -> appCount.setText("Could not scan apps: " + shortError(e)));
            }
        });
    }

    private void updateSelectedAppText() {
        if (selectedPackage.isEmpty()) {
            selectedApp.setText("No app selected");
            visibilityToggleButton.setEnabled(false);
            visibilityToggleButton.setText("Hide / Show");
            enabledToggleButton.setEnabled(false);
            enabledToggleButton.setText("Disable / Enable");
            return;
        }

        for (AppEntry entry : installedApps) {
            if (entry.packageName.equals(selectedPackage)) {
                String iconState = entry.launcherComponents.isEmpty()
                        ? "No launcher icon"
                        : (entry.launcherShown ? "Shown" : "Hidden");
                String appState = entry.enabled ? "Enabled" : "Disabled";
                selectedApp.setText("Selected: " + entry.label
                        + "\nIcon: " + iconState + "   •   App: " + appState
                        + "\n" + entry.packageName);

                visibilityToggleButton.setEnabled(!entry.launcherComponents.isEmpty());
                visibilityToggleButton.setText(entry.launcherShown ? "Hide app" : "Show app");
                enabledToggleButton.setEnabled(true);
                enabledToggleButton.setText(entry.enabled ? "Disable app" : "Enable app");
                return;
            }
        }

        selectedPackage = "";
        selectedApp.setText("No app selected");
        visibilityToggleButton.setEnabled(false);
        visibilityToggleButton.setText("Hide / Show");
        enabledToggleButton.setEnabled(false);
        enabledToggleButton.setText("Disable / Enable");
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

            setStatus(ok
                    ? "Connected — ready."
                    : "Not connected. Make sure Wireless debugging is ON, then tap Connect / reconnect.");
        } catch (Throwable e) {
            setStatus("Connection error: " + shortError(e));
        }
    }

    private AppEntry findSelectedEntry() {
        for (AppEntry entry : installedApps) {
            if (entry.packageName.equals(selectedPackage)) return entry;
        }
        return null;
    }

    private void toggleSelectedVisibility() {
        AppEntry entry = findSelectedEntry();
        if (entry == null) {
            toast("Tap an app in the installed-app list first.");
            return;
        }
        if (entry.launcherComponents.isEmpty()) {
            toast("This app has no launcher icon to hide or show.");
            return;
        }
        if (getPackageName().equals(entry.packageName) && entry.launcherShown) {
            toast("App Hide Toggle will not hide itself.");
            return;
        }

        boolean show = !entry.launcherShown;
        result.setText("");
        setStatus((show ? "Showing " : "Hiding ") + entry.packageName + "…");
        executor.submit(() -> executeVisibilityToggle(entry, show));
    }

    private void toggleSelectedEnabled() {
        AppEntry entry = findSelectedEntry();
        if (entry == null) {
            toast("Tap an app in the installed-app list first.");
            return;
        }
        if (getPackageName().equals(entry.packageName) && entry.enabled) {
            toast("App Hide Toggle will not disable itself.");
            return;
        }

        boolean enable = !entry.enabled;
        result.setText("");
        setStatus((enable ? "Enabling " : "Disabling ") + entry.packageName + "…");
        executor.submit(() -> executeEnabledToggle(entry.packageName, enable));
    }

    private AdbConnectionManager requireConnection() throws Exception {
        AdbConnectionManager manager = AdbConnectionManager.getInstance(this);
        if (!manager.isConnected()) {
            setStatus("Connecting…");
            try {
                if (!manager.autoConnect(this, 10000)) {
                    setStatus("Could not connect. Make sure Wireless debugging is ON.");
                    return null;
                }
            } catch (AdbPairingRequiredException e) {
                setStatus("Pair this app first.");
                return null;
            }
        }
        return manager;
    }

    private void executeVisibilityToggle(AppEntry entry, boolean show) {
        try {
            AdbConnectionManager manager = requireConnection();
            if (manager == null) return;

            StringBuilder output = new StringBuilder();
            for (String activityName : entry.launcherComponents) {
                String component = entry.packageName + "/" + activityName;
                String command = show
                        ? "shell:pm enable --user 0 " + component
                        : "shell:pm disable-user --user 0 " + component;
                String one = runShell(manager, command);
                if (!one.trim().isEmpty()) output.append(one);
            }

            if (output.length() == 0) {
                output.append(show ? "Launcher icon shown." : "Launcher icon hidden.");
            }
            final String finalOutput = output.toString();
            runOnUiThread(() -> result.setText(finalOutput));
            setStatus((show ? "Shown: " : "Hidden: ") + entry.packageName);
            loadInstalledApps();
        } catch (Throwable e) {
            String msg = shortError(e);
            runOnUiThread(() -> result.setText(msg));
            setStatus("Command failed: " + msg);
        }
    }

    private void executeEnabledToggle(String pkg, boolean enable) {
        try {
            AdbConnectionManager manager = requireConnection();
            if (manager == null) return;

            String command = enable
                    ? "shell:pm enable --user 0 " + pkg
                    : "shell:pm disable-user --user 0 " + pkg;
            String output = runShell(manager, command);
            if (output.trim().isEmpty()) {
                output = enable ? "App enabled." : "App disabled.";
            }

            final String finalOutput = output;
            runOnUiThread(() -> result.setText(finalOutput));
            setStatus((enable ? "Enabled: " : "Disabled: ") + pkg);
            loadInstalledApps();
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

    private static class AppEntry {
        final String label;
        final String packageName;
        final boolean enabled;
        final boolean launcherShown;
        final ArrayList<String> launcherComponents;

        AppEntry(String label, String packageName, boolean enabled,
                 boolean launcherShown, ArrayList<String> launcherComponents) {
            this.label = label;
            this.packageName = packageName;
            this.enabled = enabled;
            this.launcherShown = launcherShown;
            this.launcherComponents = new ArrayList<>(launcherComponents);
        }
    }

    private class AppAdapter extends BaseAdapter {
        private final ArrayList<AppEntry> source = new ArrayList<>();
        private final ArrayList<AppEntry> visible = new ArrayList<>();

        void setApps(List<AppEntry> apps) {
            source.clear();
            source.addAll(apps);
            visible.clear();
            visible.addAll(apps);
            notifyDataSetChanged();
        }

        void filter(String query) {
            String q = query == null ? "" : query.trim().toLowerCase(Locale.ROOT);
            visible.clear();

            if (q.isEmpty()) {
                visible.addAll(source);
            } else {
                for (AppEntry e : source) {
                    if (e.label.toLowerCase(Locale.ROOT).contains(q)
                            || e.packageName.toLowerCase(Locale.ROOT).contains(q)) {
                        visible.add(e);
                    }
                }
            }

            notifyDataSetChanged();
        }

        @Override public int getCount() { return visible.size(); }
        @Override public AppEntry getItem(int position) { return visible.get(position); }
        @Override public long getItemId(int position) { return position; }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            AppEntry entry = getItem(position);

            LinearLayout row = new LinearLayout(MainActivity.this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(android.view.Gravity.CENTER_VERTICAL);
            row.setPadding(dp(8), dp(8), dp(8), dp(8));
            row.setMinimumHeight(dp(62));

            ImageView icon = new ImageView(MainActivity.this);
            try {
                icon.setImageDrawable(getPackageManager().getApplicationIcon(entry.packageName));
            } catch (Throwable ignored) {
                icon.setImageResource(android.R.drawable.sym_def_app_icon);
            }

            LinearLayout.LayoutParams iconParams = new LinearLayout.LayoutParams(dp(46), dp(46));
            iconParams.setMargins(0, 0, dp(10), 0);
            row.addView(icon, iconParams);

            LinearLayout texts = new LinearLayout(MainActivity.this);
            texts.setOrientation(LinearLayout.VERTICAL);

            String iconState = entry.launcherComponents.isEmpty()
                    ? "No icon"
                    : (entry.launcherShown ? "Shown" : "Hidden");
            String appState = entry.enabled ? "Enabled" : "Disabled";
            TextView name = text(entry.label + "  [Icon: " + iconState + " | App: " + appState + "]", 15);
            name.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
            texts.addView(name);

            TextView pkg = text(entry.packageName, 12);
            pkg.setTextIsSelectable(false);
            texts.addView(pkg);

            row.addView(texts, new LinearLayout.LayoutParams(
                    0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));

            return row;
        }
    }
}
