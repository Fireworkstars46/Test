package com.local.apphidetoggle;

import android.app.Activity;
import android.animation.ValueAnimator;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.content.res.ColorStateList;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
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
    private final ExecutorService adbExecutor = Executors.newSingleThreadExecutor();
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
        adbExecutor.submit(this::autoConnect);
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
        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.VERTICAL);
        header.setPadding(dp(16), dp(14), dp(16), dp(8));

        TextView title = text("App Hide Toggle", 26);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        header.addView(title);

        header.addView(text(
                "Each app has two smooth switches in its row. Icon controls whether the launcher icon is shown. App controls whether the whole app is enabled.",
                14));

        status = text("Not connected", 15);
        status.setSingleLine(true);
        status.setEllipsize(android.text.TextUtils.TruncateAt.END);
        header.addView(status);

        Button openWireless = button("Open Developer options / Wireless debugging");
        openWireless.setOnClickListener(v -> {
            try {
                startActivity(new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS));
            } catch (Exception ex) {
                startActivity(new Intent(Settings.ACTION_SETTINGS));
            }
        });
        header.addView(openWireless);

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
        header.addView(pairRow);

        LinearLayout pairButtons = new LinearLayout(this);
        pairButtons.setOrientation(LinearLayout.HORIZONTAL);
        Button findPort = button("Find pair port");
        Button pair = button("Pair");
        pairButtons.addView(findPort, new LinearLayout.LayoutParams(0, dp(58), 1));
        pairButtons.addView(pair, new LinearLayout.LayoutParams(0, dp(58), 1));
        header.addView(pairButtons);
        findPort.setOnClickListener(v -> findPairingPort());
        pair.setOnClickListener(v -> pair());

        Button connect = button("Connect / reconnect");
        connect.setOnClickListener(v -> {
            setStatus("Connecting…");
            adbExecutor.submit(this::autoConnect);
        });
        header.addView(connect);

        TextView appsLabel = text("Installed apps", 17);
        appsLabel.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        header.addView(appsLabel);

        header.addView(text(
                "Switch ON = shown/enabled   •   Switch OFF = hidden/disabled",
                12));

        appCount = text("Scanning installed apps…", 13);
        header.addView(appCount);

        LinearLayout searchRow = new LinearLayout(this);
        searchRow.setOrientation(LinearLayout.HORIZONTAL);

        searchInput = new EditText(this);
        searchInput.setHint("Search app name or package");
        searchInput.setSingleLine(true);
        searchRow.addView(searchInput, new LinearLayout.LayoutParams(0, dp(58), 1));

        Button rescan = button("Rescan");
        searchRow.addView(rescan, new LinearLayout.LayoutParams(dp(110), dp(58)));
        header.addView(searchRow);

        result = text("", 12);
        result.setVisibility(View.GONE);

        appList = new ListView(this);
        appList.setVerticalScrollBarEnabled(true);
        appList.setScrollbarFadingEnabled(false);
        appList.setScrollBarStyle(View.SCROLLBARS_INSIDE_INSET);
        appList.setVerticalScrollbarPosition(View.SCROLLBAR_POSITION_RIGHT);
        appList.setSmoothScrollbarEnabled(true);
        appList.setFastScrollEnabled(true);
        appList.setClipToPadding(true);
        appList.addHeaderView(header, null, false);

        appAdapter = new AppAdapter();
        appList.setAdapter(appAdapter);



        searchInput.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) {
                appAdapter.filter(s == null ? "" : s.toString());
                appCount.setText("Showing " + appAdapter.getCount() + " of " + installedApps.size() + " installed apps.");
            }
            @Override public void afterTextChanged(Editable s) { }
        });

        rescan.setOnClickListener(v -> loadInstalledApps());

        appList.setOnApplyWindowInsetsListener((v, insets) -> {
            android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
            v.setPadding(dp(6), bars.top + dp(4), bars.right + dp(12), bars.bottom + dp(12));
            return insets;
        });

        setContentView(appList);
        appList.requestApplyInsets();
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
        adbExecutor.submit(() -> {
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

    private void toggleVisibility(AppEntry entry, boolean show) {
        if (entry == null) return;
        if (entry.busyVisibility) {
            updateVisibleRow(entry);
            return;
        }
        if (entry.launcherComponents.isEmpty()) {
            updateVisibleRow(entry);
            toast("This app has no launcher icon to hide or show.");
            return;
        }
        if (getPackageName().equals(entry.packageName) && !show) {
            updateVisibleRow(entry);
            toast("App Hide Toggle will not hide itself.");
            return;
        }
        if (show == entry.launcherShown) return;

        boolean previous = entry.launcherShown;
        entry.launcherShown = show;
        entry.busyVisibility = true;
        adbExecutor.submit(() -> executeVisibilityToggle(entry, show, previous));
    }

    private void toggleEnabled(AppEntry entry, boolean enable) {
        if (entry == null) return;
        if (entry.busyEnabled) {
            updateVisibleRow(entry);
            return;
        }
        if (getPackageName().equals(entry.packageName) && !enable) {
            updateVisibleRow(entry);
            toast("App Hide Toggle will not disable itself.");
            return;
        }
        if (enable == entry.enabled) return;

        boolean previous = entry.enabled;
        entry.enabled = enable;
        entry.busyEnabled = true;
        adbExecutor.submit(() -> executeEnabledToggle(entry, enable, previous));
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

    private void executeVisibilityToggle(AppEntry entry, boolean show, boolean previous) {
        try {
            AdbConnectionManager manager = requireConnection();
            if (manager == null) throw new IllegalStateException("Not connected");

            for (String activityName : entry.launcherComponents) {
                String component = entry.packageName + "/" + activityName;
                String command = show
                        ? "shell:pm enable --user 0 " + component
                        : "shell:pm disable-user --user 0 " + component;
                runPackageCommandWithRetry(manager, command);
            }

            runOnUiThread(() -> {
                entry.launcherShown = show;
                entry.busyVisibility = false;
                updateVisibleRow(entry);
            });
        } catch (Throwable e) {
            String msg = shortError(e);
            runOnUiThread(() -> {
                entry.launcherShown = previous;
                entry.busyVisibility = false;
                updateVisibleRow(entry);
                toast("Hide/Show failed: " + msg);
            });
        }
    }

    private void executeEnabledToggle(AppEntry entry, boolean enable, boolean previous) {
        try {
            AdbConnectionManager manager = requireConnection();
            if (manager == null) throw new IllegalStateException("Not connected");

            String command = enable
                    ? "shell:pm enable --user 0 " + entry.packageName
                    : "shell:pm disable-user --user 0 " + entry.packageName;
            runPackageCommandWithRetry(manager, command);

            runOnUiThread(() -> {
                entry.enabled = enable;
                entry.busyEnabled = false;
                updateVisibleRow(entry);
            });
        } catch (Throwable e) {
            String msg = shortError(e);
            runOnUiThread(() -> {
                entry.enabled = previous;
                entry.busyEnabled = false;
                updateVisibleRow(entry);
                toast("Enable/Disable failed: " + msg);
            });
        }
    }

    private String runPackageCommandWithRetry(AdbConnectionManager manager, String command) throws Exception {
        String output;
        try {
            output = runShell(manager, "shell:" + command);
        } catch (Exception first) {
            try {
                manager.autoConnect(this, 10000);
            } catch (Throwable ignored) {
            }
            output = runShell(manager, "shell:" + command);
        }

        String lower = output == null ? "" : output.toLowerCase(Locale.ROOT);
        if (lower.contains("securityexception")
                || lower.contains("permission denial")
                || lower.contains("unknown package")
                || lower.contains("unknown component")
                || lower.startsWith("error:")
                || lower.contains("\nerror:")
                || lower.contains("failed to")
                || lower.contains("not found")) {
            throw new IllegalStateException(output.trim());
        }
        return output == null ? "" : output;
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
        adbExecutor.shutdownNow();
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

    private static class SmoothToggle extends View {
        interface OnToggleListener {
            void onToggle(boolean checked);
        }

        private final Paint trackPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint thumbPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF trackRect = new RectF();
        private boolean checked;
        private float position;
        private ValueAnimator animator;
        private OnToggleListener listener;

        SmoothToggle(Context context) {
            super(context);
            setClickable(true);
            setFocusable(false);
            setFocusableInTouchMode(false);
            setSoundEffectsEnabled(true);
            thumbPaint.setColor(Color.WHITE);
            setOnClickListener(v -> {
                if (!isEnabled()) return;
                boolean next = !checked;
                setState(next, true);
                setEnabled(false);
                if (listener != null) listener.onToggle(next);
            });
        }

        void setOnToggleListener(OnToggleListener listener) {
            this.listener = listener;
        }

        void setState(boolean checked, boolean animate) {
            if (this.checked == checked && Math.abs(position - (checked ? 1f : 0f)) < 0.001f) {
                return;
            }
            this.checked = checked;
            float target = checked ? 1f : 0f;
            if (animator != null) animator.cancel();

            if (!animate || !isShown()) {
                position = target;
                invalidate();
                return;
            }

            animator = ValueAnimator.ofFloat(position, target);
            animator.setDuration(170);
            animator.setInterpolator(new android.view.animation.AccelerateDecelerateInterpolator());
            animator.addUpdateListener(a -> {
                position = (float) a.getAnimatedValue();
                invalidate();
            });
            animator.start();
        }

        @Override
        public void setEnabled(boolean enabled) {
            super.setEnabled(enabled);
            setAlpha(enabled ? 1f : 0.55f);
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            float w = getWidth();
            float h = getHeight();
            if (w <= 0 || h <= 0) return;

            float inset = Math.max(1f, h * 0.08f);
            float radius = h * 0.5f;
            trackRect.set(inset, inset, w - inset, h - inset);

            int offColor = Color.rgb(105, 105, 105);
            int onColor = Color.rgb(49, 132, 255);
            trackPaint.setColor(blend(offColor, onColor, position));
            canvas.drawRoundRect(trackRect, radius, radius, trackPaint);

            float thumbRadius = h * 0.39f;
            float left = inset + thumbRadius + h * 0.02f;
            float right = w - inset - thumbRadius - h * 0.02f;
            float cx = left + (right - left) * position;
            float cy = h * 0.5f;
            canvas.drawCircle(cx, cy, thumbRadius, thumbPaint);
        }

        private static int blend(int from, int to, float t) {
            t = Math.max(0f, Math.min(1f, t));
            int a = (int) (Color.alpha(from) + (Color.alpha(to) - Color.alpha(from)) * t);
            int r = (int) (Color.red(from) + (Color.red(to) - Color.red(from)) * t);
            int g = (int) (Color.green(from) + (Color.green(to) - Color.green(from)) * t);
            int b = (int) (Color.blue(from) + (Color.blue(to) - Color.blue(from)) * t);
            return Color.argb(a, r, g, b);
        }
    }

    private static class RowHolder {
        final ImageView visibilityIndicator;
        final ImageView enabledIndicator;
        final ImageView appIcon;
        final TextView name;
        final TextView pkg;
        final SmoothToggle visibilitySwitch;
        final SmoothToggle enabledSwitch;
        String boundPackage = "";

        RowHolder(ImageView visibilityIndicator, ImageView enabledIndicator, ImageView appIcon,
                  TextView name, TextView pkg, SmoothToggle visibilitySwitch, SmoothToggle enabledSwitch) {
            this.visibilityIndicator = visibilityIndicator;
            this.enabledIndicator = enabledIndicator;
            this.appIcon = appIcon;
            this.name = name;
            this.pkg = pkg;
            this.visibilitySwitch = visibilitySwitch;
            this.enabledSwitch = enabledSwitch;
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

        // These are fixed-size custom views: state changes only redraw the thumb/track.
        // They never request focus or layout, which prevents the ListView from jumping.
        holder.visibilitySwitch.setState(entry.launcherShown, false);
        holder.enabledSwitch.setState(entry.enabled, false);

        holder.visibilitySwitch.setEnabled(hasLauncher && !entry.busyVisibility);
        holder.enabledSwitch.setEnabled(!entry.busyEnabled);

        holder.visibilitySwitch.setContentDescription(
                (entry.launcherShown ? "Hide " : "Show ") + entry.label + " launcher icon");
        holder.enabledSwitch.setContentDescription(
                (entry.enabled ? "Disable " : "Enable ") + entry.label);

        holder.visibilitySwitch.setOnToggleListener(isChecked -> {
            if (isChecked == entry.launcherShown) return;
            toggleVisibility(entry, isChecked);
        });

        holder.enabledSwitch.setOnToggleListener(isChecked -> {
            if (isChecked == entry.enabled) return;
            toggleEnabled(entry, isChecked);
        });
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

                LinearLayout switches = new LinearLayout(MainActivity.this);
                switches.setOrientation(LinearLayout.HORIZONTAL);
                switches.setGravity(android.view.Gravity.CENTER_VERTICAL);

                LinearLayout iconControl = new LinearLayout(MainActivity.this);
                iconControl.setOrientation(LinearLayout.HORIZONTAL);
                iconControl.setGravity(android.view.Gravity.CENTER_VERTICAL);

                TextView iconLabel = text("Icon", 13);
                iconLabel.setPadding(0, 0, dp(7), 0);
                iconControl.addView(iconLabel);

                SmoothToggle visibilitySwitch = new SmoothToggle(MainActivity.this);
                iconControl.addView(visibilitySwitch,
                        new LinearLayout.LayoutParams(dp(52), dp(32)));

                LinearLayout appControl = new LinearLayout(MainActivity.this);
                appControl.setOrientation(LinearLayout.HORIZONTAL);
                appControl.setGravity(android.view.Gravity.CENTER_VERTICAL);

                TextView appLabel = text("App", 13);
                appLabel.setPadding(0, 0, dp(7), 0);
                appControl.addView(appLabel);

                SmoothToggle enabledSwitch = new SmoothToggle(MainActivity.this);
                appControl.addView(enabledSwitch,
                        new LinearLayout.LayoutParams(dp(52), dp(32)));

                LinearLayout.LayoutParams switchParams1 =
                        new LinearLayout.LayoutParams(0, dp(44), 1);
                switchParams1.setMargins(0, dp(2), dp(4), 0);
                switches.addView(iconControl, switchParams1);

                LinearLayout.LayoutParams switchParams2 =
                        new LinearLayout.LayoutParams(0, dp(44), 1);
                switchParams2.setMargins(dp(4), dp(2), 0, 0);
                switches.addView(appControl, switchParams2);

                content.addView(switches, new LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));

                row.addView(content, new LinearLayout.LayoutParams(
                        0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));

                holder = new RowHolder(
                        eye, enabled, appIcon, name, pkg, visibilitySwitch, enabledSwitch);
                row.setTag(holder);
                convertView = row;
            } else {
                holder = (RowHolder) convertView.getTag();
            }

            bindRow(holder, entry);
            return convertView;
        }
    }
}
