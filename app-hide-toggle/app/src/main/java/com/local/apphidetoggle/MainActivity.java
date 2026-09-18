package com.local.apphidetoggle;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
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
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.IOException;
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
    private ListView appList;
    private AppAdapter appAdapter;

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
        root.setPadding(dp(8), 0, dp(8), 0);

        LinearLayout top = new LinearLayout(this);
        top.setOrientation(LinearLayout.VERTICAL);
        top.setPadding(dp(8), dp(10), dp(8), dp(6));

        TextView title = text("App Hide Toggle", 24);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        top.addView(title);

        status = text("Not connected", 13);
        status.setSingleLine(true);
        status.setEllipsize(android.text.TextUtils.TruncateAt.END);
        top.addView(status);

        LinearLayout setupPanel = new LinearLayout(this);
        setupPanel.setOrientation(LinearLayout.VERTICAL);
        setupPanel.setVisibility(View.GONE);

        Button setupToggle = button("Pairing / connection setup");
        setupToggle.setOnClickListener(v -> {
            boolean show = setupPanel.getVisibility() != View.VISIBLE;
            setupPanel.setVisibility(show ? View.VISIBLE : View.GONE);
            setupToggle.setText(show ? "Hide pairing setup" : "Pairing / connection setup");
        });
        top.addView(setupToggle);

        Button openWireless = button("Open Wireless debugging");
        openWireless.setOnClickListener(v -> {
            try {
                startActivity(new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS));
            } catch (Exception ex) {
                startActivity(new Intent(Settings.ACTION_SETTINGS));
            }
        });
        setupPanel.addView(openWireless);

        LinearLayout pairRow = new LinearLayout(this);
        pairRow.setOrientation(LinearLayout.HORIZONTAL);
        portInput = new EditText(this);
        portInput.setHint("Pair port");
        portInput.setInputType(InputType.TYPE_CLASS_NUMBER);
        pairRow.addView(portInput, new LinearLayout.LayoutParams(0, dp(54), 1));

        codeInput = new EditText(this);
        codeInput.setHint("6-digit code");
        codeInput.setInputType(InputType.TYPE_CLASS_NUMBER);
        pairRow.addView(codeInput, new LinearLayout.LayoutParams(0, dp(54), 1));
        setupPanel.addView(pairRow);

        LinearLayout pairButtons = new LinearLayout(this);
        pairButtons.setOrientation(LinearLayout.HORIZONTAL);
        Button findPort = button("Find pair port");
        Button pair = button("Pair");
        pairButtons.addView(findPort, new LinearLayout.LayoutParams(0, dp(54), 1));
        pairButtons.addView(pair, new LinearLayout.LayoutParams(0, dp(54), 1));
        setupPanel.addView(pairButtons);
        findPort.setOnClickListener(v -> findPairingPort());
        pair.setOnClickListener(v -> pair());

        Button connect = button("Connect / reconnect");
        connect.setOnClickListener(v -> {
            setStatus("Connecting…");
            executor.submit(this::autoConnect);
        });
        setupPanel.addView(connect);
        top.addView(setupPanel);

        LinearLayout searchRow = new LinearLayout(this);
        searchRow.setOrientation(LinearLayout.HORIZONTAL);

        searchInput = new EditText(this);
        searchInput.setHint("Search apps");
        searchInput.setSingleLine(true);
        searchRow.addView(searchInput, new LinearLayout.LayoutParams(0, dp(52), 1));

        Button rescan = button("Rescan");
        rescan.setFocusable(false);
        rescan.setFocusableInTouchMode(false);
        searchRow.addView(rescan, new LinearLayout.LayoutParams(dp(100), dp(52)));
        top.addView(searchRow);

        appCount = text("Scanning installed apps…", 12);
        top.addView(appCount);

        top.addView(text("Eye = shown/hidden   •   ✓ = enabled   •   ✕ = disabled", 11));

        result = text("", 11);
        result.setVisibility(View.GONE);

        root.addView(top, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        appList = new ListView(this);
        appList.setVerticalScrollBarEnabled(true);
        appList.setScrollbarFadingEnabled(false);
        appList.setScrollBarStyle(View.SCROLLBARS_INSIDE_INSET);
        appList.setVerticalScrollbarPosition(View.SCROLLBAR_POSITION_RIGHT);
        appList.setSmoothScrollbarEnabled(true);
        appList.setFastScrollEnabled(true);
        appList.setClipToPadding(true);
        appList.setItemsCanFocus(false);
        appList.setChoiceMode(ListView.CHOICE_MODE_NONE);
        appList.setFocusable(false);
        appList.setFocusableInTouchMode(false);

        appAdapter = new AppAdapter();
        appList.setAdapter(appAdapter);

        root.addView(appList, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));

        searchInput.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) {
                appAdapter.filter(s == null ? "" : s.toString());
                appCount.setText("Showing " + appAdapter.getCount() + " of " + installedApps.size());
            }
            @Override public void afterTextChanged(Editable s) { }
        });

        rescan.setOnClickListener(v -> loadInstalledApps());

        root.setOnApplyWindowInsetsListener((v, insets) -> {
            android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
            v.setPadding(dp(8), bars.top + dp(2), bars.right + dp(8), bars.bottom + dp(4));
            return insets;
        });

        setContentView(root);
        root.requestApplyInsets();
    }

    private void updateVisibleRow(AppEntry entry) {
        if (entry == null) return;
        for (int i = 0; i < appList.getChildCount(); i++) {
            View child = appList.getChildAt(i);
            Object tag = child.getTag();
            if (!(tag instanceof RowHolder)) continue;
            RowHolder holder = (RowHolder) tag;
            if (entry.packageName.equals(holder.boundPackage)) {
                bindRow(holder, entry);
                return;
            }
        }
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

                    Drawable appIcon;
                    try {
                        appIcon = pm.getApplicationIcon(ai);
                    } catch (Throwable ignored) {
                        appIcon = null;
                    }

                    found.add(new AppEntry(label, ai.packageName, enabled, launcherShown, components, appIcon));
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
                });
            } catch (Throwable e) {
                runOnUiThread(() -> appCount.setText("Could not scan apps: " + shortError(e)));
            }
        });
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

    private void toggleVisibility(AppEntry entry) {
        if (entry == null) return;
        if (entry.launcherComponents.isEmpty()) {
            toast("This app has no launcher icon to hide or show.");
            return;
        }
        if (getPackageName().equals(entry.packageName) && entry.launcherShown) {
            toast("App Hide Toggle will not hide itself.");
            return;
        }

        boolean show = !entry.launcherShown;
        entry.busyVisibility = true;
        updateVisibleRow(entry);
        result.setText("");
        setStatus((show ? "Showing " : "Hiding ") + entry.packageName + "…");
        executor.submit(() -> executeVisibilityToggle(entry, show));
    }

    private void toggleEnabled(AppEntry entry) {
        if (entry == null) return;
        if (getPackageName().equals(entry.packageName) && entry.enabled) {
            toast("App Hide Toggle will not disable itself.");
            return;
        }

        boolean enable = !entry.enabled;
        entry.busyEnabled = true;
        updateVisibleRow(entry);
        result.setText("");
        setStatus((enable ? "Enabling " : "Disabling ") + entry.packageName + "…");
        executor.submit(() -> executeEnabledToggle(entry, enable));
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
            if (manager == null) {
                runOnUiThread(() -> {
                    entry.busyVisibility = false;
                    updateVisibleRow(entry);
                });
                return;
            }

            StringBuilder output = new StringBuilder();
            for (String activityName : entry.launcherComponents) {
                String component = entry.packageName + "/" + activityName;
                String command = show
                        ? "shell:pm enable --user 0 " + component
                        : "shell:pm disable-user --user 0 " + component;
                String one = runPackageShellChecked(manager, command);
                if (!one.trim().isEmpty()) output.append(one);
            }

            if (output.length() == 0) {
                output.append(show ? "Launcher icon shown." : "Launcher icon hidden.");
            }

            Thread.sleep(120);
            boolean actualShown = isLauncherShownNow(entry);
            if (actualShown != show) {
                for (String activityName : entry.launcherComponents) {
                    String component = entry.packageName + "/" + activityName;
                    String command = show
                            ? "shell:pm enable --user 0 " + component
                            : "shell:pm disable-user --user 0 " + component;
                    runPackageShellChecked(manager, command);
                }
                Thread.sleep(180);
                actualShown = isLauncherShownNow(entry);
            }
            if (actualShown != show) {
                throw new IOException("Android did not apply the launcher visibility change.");
            }

            final String finalOutput = output.toString();
            runOnUiThread(() -> {
                entry.launcherShown = show;
                entry.busyVisibility = false;
                result.setText(finalOutput);
                updateVisibleRow(entry);
            });
            setStatus((show ? "Shown: " : "Hidden: ") + entry.packageName);
        } catch (Throwable e) {
            String msg = shortError(e);
            runOnUiThread(() -> {
                entry.busyVisibility = false;
                result.setText(msg);
                updateVisibleRow(entry);
            });
            setStatus("Command failed: " + msg);
        }
    }

    private void executeEnabledToggle(AppEntry entry, boolean enable) {
        try {
            AdbConnectionManager manager = requireConnection();
            if (manager == null) {
                runOnUiThread(() -> {
                    entry.busyEnabled = false;
                    updateVisibleRow(entry);
                });
                return;
            }

            String pkg = entry.packageName;
            String command = enable
                    ? "shell:pm enable --user 0 " + pkg
                    : "shell:pm disable-user --user 0 " + pkg;
            String output = runPackageShellChecked(manager, command);
            if (output.trim().isEmpty()) {
                output = enable ? "App enabled." : "App disabled.";
            }

            Thread.sleep(120);
            boolean actualEnabled = isPackageEnabledNow(pkg);
            if (actualEnabled != enable) {
                output = runPackageShellChecked(manager, command);
                Thread.sleep(180);
                actualEnabled = isPackageEnabledNow(pkg);
            }
            if (actualEnabled != enable) {
                throw new IOException("Android did not apply the enabled/disabled change.");
            }

            final String finalOutput = output;
            runOnUiThread(() -> {
                entry.enabled = enable;
                entry.busyEnabled = false;
                result.setText(finalOutput);
                updateVisibleRow(entry);
            });
            setStatus((enable ? "Enabled: " : "Disabled: ") + pkg);
        } catch (Throwable e) {
            String msg = shortError(e);
            runOnUiThread(() -> {
                entry.busyEnabled = false;
                result.setText(msg);
                updateVisibleRow(entry);
            });
            setStatus("Command failed: " + msg);
        }
    }

    private String runPackageShellChecked(AdbConnectionManager manager, String service) throws Exception {
        String output;
        try {
            output = runShell(manager, service);
        } catch (Exception first) {
            try {
                manager.autoConnect(this, 10000);
            } catch (Throwable ignored) {
            }
            output = runShell(manager, service);
        }

        String lower = output == null ? "" : output.toLowerCase(Locale.ROOT);
        if (lower.contains("securityexception")
                || lower.contains("permission denial")
                || lower.contains("unknown package")
                || lower.contains("unknown component")
                || lower.startsWith("error:")
                || lower.contains("\nerror:")
                || lower.contains("failed to")) {
            throw new IOException(output.trim());
        }
        return output == null ? "" : output;
    }

    private boolean isLauncherShownNow(AppEntry entry) {
        PackageManager pm = getPackageManager();
        for (String activityName : entry.launcherComponents) {
            try {
                ComponentName component = new ComponentName(entry.packageName, activityName);
                int state = pm.getComponentEnabledSetting(component);
                if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                        || state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT) {
                    return true;
                }
            } catch (Throwable ignored) {
            }
        }
        return false;
    }

    private boolean isPackageEnabledNow(String pkg) {
        PackageManager pm = getPackageManager();
        try {
            int state = pm.getApplicationEnabledSetting(pkg);
            if (state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                    || state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER
                    || state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED) {
                return false;
            }
            if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                return true;
            }
            ApplicationInfo ai = pm.getApplicationInfo(pkg, PackageManager.MATCH_DISABLED_COMPONENTS);
            return ai.enabled;
        } catch (Throwable ignored) {
            return false;
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
        boolean enabled;
        boolean launcherShown;
        boolean busyVisibility;
        boolean busyEnabled;
        final ArrayList<String> launcherComponents;
        final Drawable icon;

        AppEntry(String label, String packageName, boolean enabled,
                 boolean launcherShown, ArrayList<String> launcherComponents, Drawable icon) {
            this.label = label;
            this.packageName = packageName;
            this.enabled = enabled;
            this.launcherShown = launcherShown;
            this.launcherComponents = new ArrayList<>(launcherComponents);
            this.icon = icon;
        }
    }

    private static class RowHolder {
        final ImageView visibilityIndicator;
        final ImageView enabledIndicator;
        final ImageView appIcon;
        final TextView name;
        final TextView pkg;
        final Button visibilityButton;
        final Button enabledButton;
        String boundPackage = "";

        RowHolder(ImageView visibilityIndicator, ImageView enabledIndicator, ImageView appIcon,
                  TextView name, TextView pkg, Button visibilityButton, Button enabledButton) {
            this.visibilityIndicator = visibilityIndicator;
            this.enabledIndicator = enabledIndicator;
            this.appIcon = appIcon;
            this.name = name;
            this.pkg = pkg;
            this.visibilityButton = visibilityButton;
            this.enabledButton = enabledButton;
        }
    }

    private void bindRow(RowHolder holder, AppEntry entry) {
        holder.boundPackage = entry.packageName;
        holder.name.setText(entry.label);
        holder.pkg.setText(entry.packageName);
        holder.appIcon.setImageDrawable(entry.icon != null
                ? entry.icon
                : getDrawable(android.R.drawable.sym_def_app_icon));

        int tint = holder.name.getCurrentTextColor();
        holder.visibilityIndicator.setImageTintList(ColorStateList.valueOf(tint));
        holder.enabledIndicator.setImageTintList(ColorStateList.valueOf(tint));

        boolean hasLauncher = !entry.launcherComponents.isEmpty();
        holder.visibilityIndicator.setImageResource(entry.launcherShown
                ? R.drawable.ic_visibility
                : R.drawable.ic_visibility_off);
        holder.visibilityIndicator.setAlpha(hasLauncher ? 1f : 0.28f);

        holder.enabledIndicator.setImageResource(entry.enabled
                ? R.drawable.ic_check
                : R.drawable.ic_close);

        holder.visibilityButton.setText(entry.busyVisibility
                ? "Working…"
                : (entry.launcherShown ? "Hide" : "Show"));
        holder.visibilityButton.setEnabled(hasLauncher && !entry.busyVisibility);
        holder.visibilityButton.setOnClickListener(v -> toggleVisibility(entry));

        holder.enabledButton.setText(entry.busyEnabled
                ? "Working…"
                : (entry.enabled ? "Disable" : "Enable"));
        holder.enabledButton.setEnabled(!entry.busyEnabled);
        holder.enabledButton.setOnClickListener(v -> toggleEnabled(entry));
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
            RowHolder holder;

            if (convertView == null) {
                LinearLayout row = new LinearLayout(MainActivity.this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                row.setGravity(android.view.Gravity.CENTER_VERTICAL);
                row.setPadding(dp(6), dp(7), dp(8), dp(7));
                row.setMinimumHeight(dp(96));

                LinearLayout indicators = new LinearLayout(MainActivity.this);
                indicators.setOrientation(LinearLayout.VERTICAL);
                indicators.setGravity(android.view.Gravity.CENTER);

                ImageView eye = new ImageView(MainActivity.this);
                eye.setScaleType(ImageView.ScaleType.CENTER_INSIDE);
                indicators.addView(eye, new LinearLayout.LayoutParams(dp(28), dp(28)));

                ImageView enabled = new ImageView(MainActivity.this);
                enabled.setScaleType(ImageView.ScaleType.CENTER_INSIDE);
                indicators.addView(enabled, new LinearLayout.LayoutParams(dp(28), dp(28)));

                LinearLayout.LayoutParams indicatorParams = new LinearLayout.LayoutParams(dp(34), dp(64));
                indicatorParams.setMargins(0, 0, dp(5), 0);
                row.addView(indicators, indicatorParams);

                ImageView appIcon = new ImageView(MainActivity.this);
                LinearLayout.LayoutParams iconParams = new LinearLayout.LayoutParams(dp(44), dp(44));
                iconParams.setMargins(0, 0, dp(9), 0);
                row.addView(appIcon, iconParams);

                LinearLayout content = new LinearLayout(MainActivity.this);
                content.setOrientation(LinearLayout.VERTICAL);

                TextView name = text("", 15);
                name.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
                content.addView(name);

                TextView pkg = text("", 11);
                pkg.setTextIsSelectable(false);
                content.addView(pkg);

                LinearLayout buttons = new LinearLayout(MainActivity.this);
                buttons.setOrientation(LinearLayout.HORIZONTAL);

                Button visibilityButton = button("Hide");
                visibilityButton.setMinHeight(0);
                visibilityButton.setMinimumHeight(0);
                visibilityButton.setPadding(dp(4), 0, dp(4), 0);
                visibilityButton.setFocusable(false);
                visibilityButton.setFocusableInTouchMode(false);

                Button enabledButton = button("Disable");
                enabledButton.setMinHeight(0);
                enabledButton.setMinimumHeight(0);
                enabledButton.setPadding(dp(4), 0, dp(4), 0);
                enabledButton.setFocusable(false);
                enabledButton.setFocusableInTouchMode(false);

                LinearLayout.LayoutParams actionParams1 =
                        new LinearLayout.LayoutParams(0, dp(40), 1);
                actionParams1.setMargins(0, dp(2), dp(4), 0);
                buttons.addView(visibilityButton, actionParams1);

                LinearLayout.LayoutParams actionParams2 =
                        new LinearLayout.LayoutParams(0, dp(40), 1);
                actionParams2.setMargins(dp(4), dp(2), 0, 0);
                buttons.addView(enabledButton, actionParams2);

                content.addView(buttons, new LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));

                row.addView(content, new LinearLayout.LayoutParams(
                        0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));

                holder = new RowHolder(
                        eye, enabled, appIcon, name, pkg, visibilityButton, enabledButton);
                row.setTag(holder);
                convertView = row;
            } else {
                holder = (RowHolder) convertView.getTag();
            }

            holder.boundPackage = entry.packageName;
            bindRow(holder, entry);
            return convertView;
        }
    }
}
