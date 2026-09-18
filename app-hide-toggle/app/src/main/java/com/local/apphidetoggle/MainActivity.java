package com.local.apphidetoggle;

import android.app.Activity;
import android.app.AlertDialog;
import android.animation.ValueAnimator;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.LauncherActivityInfo;
import android.content.pm.LauncherApps;
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
import android.os.Process;
import android.net.Uri;
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
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Date;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Locale;
import java.text.SimpleDateFormat;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeoutException;
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
    private static final int REQUEST_SAVE_TEST_REPORT = 9047;
    private static final String PREF_LAUNCHER_CACHE = "launcher_component_cache_v1";
    private String latestTestReport = "";

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
        loadInstalledApps(false);
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

        Button testMode = button("Test mode");
        testMode.setOnClickListener(v -> showTestModeDialog());
        header.addView(testMode);

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

        Button rescan = button("Full scan");
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

        rescan.setOnClickListener(v -> loadInstalledApps(true));

        appList.setOnApplyWindowInsetsListener((v, insets) -> {
            android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
            v.setPadding(dp(6), bars.top + dp(4), bars.right + dp(12), bars.bottom + dp(12));
            return insets;
        });

        setContentView(appList);
        appList.requestApplyInsets();
    }

    private void showTestModeDialog() {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(20), dp(8), dp(20), dp(8));

        TextView info = text(
                "Safe test never changes App Hide Toggle or any other app. Full toggle test lets you choose a normal user app, briefly tests Icon OFF/ON and App OFF/ON, then restores it.",
                14);
        box.addView(info);

        TextView testResult = text("Not tested yet.", 13);
        testResult.setTypeface(Typeface.MONOSPACE);
        testResult.setTextIsSelectable(true);
        box.addView(testResult);

        Button safeRun = button("Run safe connection test");
        box.addView(safeRun);

        Button fullRun = button("Run full toggle test…");
        box.addView(fullRun);

        Button saveReport = button("Save Test Report");
        saveReport.setEnabled(false);
        saveReport.setOnClickListener(v -> saveLatestTestReport());
        box.addView(saveReport);

        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("Test mode")
                .setView(box)
                .setNegativeButton("Close", null)
                .create();

        safeRun.setOnClickListener(v -> {
            safeRun.setEnabled(false);
            fullRun.setEnabled(false);
            saveReport.setEnabled(false);
            latestTestReport = "";
            testResult.setText("⏳ Starting safe test…");
            adbExecutor.submit(() ->
                    runSafeSelfTest(testResult, safeRun, fullRun, saveReport));
        });

        fullRun.setOnClickListener(v ->
                chooseFullTestApp(testResult, safeRun, fullRun, saveReport));

        dialog.show();
    }

    private void runSafeSelfTest(TextView testResult,
                                 Button safeButton,
                                 Button fullButton,
                                 Button saveButton) {
        ArrayList<String> lines = new ArrayList<>();
        int passed = 0;
        int failed = 0;

        try {
            int count = getPackageManager()
                    .getInstalledApplications(PackageManager.MATCH_DISABLED_COMPONENTS)
                    .size();
            if (count > 0) {
                lines.add("✅ App scanner: PASS (" + count + " apps visible)");
                passed++;
            } else {
                lines.add("❌ App scanner: FAIL (0 apps)");
                failed++;
            }
        } catch (Throwable e) {
            lines.add("❌ App scanner: FAIL — " + shortError(e));
            failed++;
        }
        publishTestResult(testResult, lines, passed, failed, true);

        AdbConnectionManager manager = null;
        try {
            manager = AdbConnectionManager.getInstance(this);
            if (!manager.isConnected()) {
                lines.add("⏳ Wireless ADB: connecting…");
                publishTestResult(testResult, lines, passed, failed, true);
                boolean ok = manager.autoConnect(this, 3500);
                lines.remove(lines.size() - 1);
                if (!ok) throw new IllegalStateException("Could not connect");
            }
            lines.add("✅ Wireless ADB: PASS");
            passed++;
        } catch (AdbPairingRequiredException e) {
            lines.add("❌ Wireless ADB: FAIL — pairing required");
            failed++;
        } catch (Throwable e) {
            lines.add("❌ Wireless ADB: FAIL — " + shortError(e));
            failed++;
        }
        publishTestResult(testResult, lines, passed, failed, true);

        if (manager != null && manager.isConnected()) {
            try {
                String output = runAdbCommandWithMarker(
                        manager, "pm path " + getPackageName(), 1500);
                if (output.toLowerCase(Locale.ROOT).contains("package:")) {
                    lines.add("✅ ADB shell + Package Manager: PASS");
                    passed++;
                } else {
                    lines.add("❌ ADB shell + Package Manager: FAIL — "
                            + compactReply(output));
                    failed++;
                }
            } catch (Throwable e) {
                lines.add("❌ ADB shell + Package Manager: FAIL — " + shortError(e));
                failed++;
            }
        } else {
            lines.add("⏭ ADB shell + Package Manager: SKIPPED");
        }

        lines.add("ℹ Safe test made no app/component state changes.");
        lines.add(failed == 0
                ? "✅ RESULT: Connection and command path are working."
                : "❌ RESULT: One or more safe checks failed.");

        publishTestResult(testResult, lines, passed, failed, false);
        runOnUiThread(() -> {
            safeButton.setEnabled(true);
            fullButton.setEnabled(true);
            saveButton.setEnabled(!latestTestReport.isEmpty());
        });
    }

    private void chooseFullTestApp(TextView testResult,
                                   Button safeButton,
                                   Button fullButton,
                                   Button saveButton) {
        ArrayList<AppEntry> candidates = new ArrayList<>();
        PackageManager pm = getPackageManager();

        for (AppEntry entry : installedApps) {
            if (entry == null
                    || getPackageName().equals(entry.packageName)
                    || entry.launcherComponents.isEmpty()) {
                continue;
            }
            try {
                ApplicationInfo ai = pm.getApplicationInfo(
                        entry.packageName, PackageManager.MATCH_DISABLED_COMPONENTS);
                boolean system = (ai.flags & ApplicationInfo.FLAG_SYSTEM) != 0
                        || (ai.flags & ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0;
                if (!system) candidates.add(entry);
            } catch (Throwable ignored) {
            }
        }

        if (candidates.isEmpty()) {
            toast("No enabled user app with a launcher icon is available for the full test.");
            return;
        }

        String[] labels = new String[candidates.size()];
        for (int i = 0; i < candidates.size(); i++) {
            AppEntry e = candidates.get(i);
            labels[i] = e.label + "\n" + e.packageName;
        }

        new AlertDialog.Builder(this)
                .setTitle("Choose a test app")
                .setMessage("The selected app will briefly have its icon hidden, then shown, then the app disabled and re-enabled. It is restored at the end.")
                .setItems(labels, (d, which) -> {
                    AppEntry target = candidates.get(which);
                    safeButton.setEnabled(false);
                    fullButton.setEnabled(false);
                    saveButton.setEnabled(false);
                    latestTestReport = "";
                    testResult.setText("⏳ Full toggle test: " + target.label + "…");
                    adbExecutor.submit(() ->
                            runFullToggleTest(target, testResult,
                                    safeButton, fullButton, saveButton));
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void runFullToggleTest(AppEntry target,
                                   TextView testResult,
                                   Button safeButton,
                                   Button fullButton,
                                   Button saveButton) {
        ArrayList<String> lines = new ArrayList<>();
        int passed = 0;
        int failed = 0;
        boolean packageWasDisabled = false;
        boolean componentsWereDisabled = false;
        final boolean originalEnabled = target.enabled;
        final boolean originalLauncherShown = target.launcherShown;

        lines.add("Test app: " + target.label);
        lines.add("Package: " + target.packageName);
        publishTestResult(testResult, lines, passed, failed, true);

        AdbConnectionManager manager = null;
        try {
            manager = requireConnection();
            if (manager == null) throw new IllegalStateException("Not connected");
            lines.add("✅ Wireless ADB: PASS");
            passed++;
        } catch (Throwable e) {
            lines.add("❌ Wireless ADB: FAIL — " + shortError(e));
            failed++;
        }
        publishTestResult(testResult, lines, passed, failed, true);

        if (manager != null) {
            try {
                for (String activityName : target.launcherComponents) {
                    applyComponentState(manager,
                            new ComponentName(target.packageName, activityName), false);
                }
                componentsWereDisabled = true;
                lines.add("✅ Icon OFF: PASS");
                passed++;
            } catch (Throwable e) {
                lines.add("❌ Icon OFF: FAIL — " + shortError(e));
                failed++;
            }
            publishTestResult(testResult, lines, passed, failed, true);

            try {
                for (String activityName : target.launcherComponents) {
                    applyComponentState(manager,
                            new ComponentName(target.packageName, activityName), true);
                }
                componentsWereDisabled = false;
                lines.add("✅ Icon ON: PASS");
                passed++;
            } catch (Throwable e) {
                lines.add("❌ Icon ON: FAIL — " + shortError(e));
                failed++;
            }
            publishTestResult(testResult, lines, passed, failed, true);

            try {
                applyPackageState(manager, target.packageName, false);
                packageWasDisabled = true;
                lines.add("✅ App OFF: PASS");
                passed++;
            } catch (Throwable e) {
                lines.add("❌ App OFF: FAIL — " + shortError(e));
                failed++;
            }
            publishTestResult(testResult, lines, passed, failed, true);

            try {
                applyPackageState(manager, target.packageName, true);
                packageWasDisabled = false;
                lines.add("✅ App ON: PASS");
                passed++;
            } catch (Throwable e) {
                lines.add("❌ App ON: FAIL — " + shortError(e));
                failed++;
            }

            boolean restoreOk = true;
            try {
                applyPackageState(manager, target.packageName, originalEnabled);
                packageWasDisabled = !originalEnabled;
            } catch (Throwable e) {
                restoreOk = false;
                lines.add("❌ Restore app: FAIL — " + shortError(e));
                failed++;
            }
            try {
                for (String activityName : target.launcherComponents) {
                    applyComponentState(manager,
                            new ComponentName(target.packageName, activityName),
                            originalLauncherShown);
                }
                componentsWereDisabled = !originalLauncherShown;
            } catch (Throwable e) {
                restoreOk = false;
                lines.add("❌ Restore icon: FAIL — " + shortError(e));
                failed++;
            }
            if (restoreOk) {
                lines.add("✅ Final restore: PASS");
                passed++;
            }
        }

        lines.add(failed == 0
                ? "✅ RESULT: Full Icon/App toggle test passed."
                : "❌ RESULT: One or more full toggle checks failed.");

        publishTestResult(testResult, lines, passed, failed, false);

        runOnUiThread(() -> {
            target.enabled = originalEnabled;
            target.launcherShown = originalLauncherShown;
            target.busyEnabled = false;
            target.busyVisibility = false;
            updateVisibleRow(target);
            safeButton.setEnabled(true);
            fullButton.setEnabled(true);
            saveButton.setEnabled(!latestTestReport.isEmpty());
        });
    }

    private void publishTestResult(TextView target,
                                   ArrayList<String> lines,
                                   int passed,
                                   int failed,
                                   boolean running) {
        StringBuilder text = new StringBuilder();
        for (String line : lines) {
            if (text.length() > 0) text.append('\n');
            text.append(line);
        }
        if (text.length() > 0) text.append("\n\n");
        text.append("Passed: ").append(passed)
                .append("   Failed: ").append(failed);
        if (running) text.append("\nTesting…");

        String finalText = text.toString();
        if (!running) {
            String version = "unknown";
            try {
                version = getPackageManager()
                        .getPackageInfo(getPackageName(), 0)
                        .versionName;
            } catch (Throwable ignored) {
            }
            String when = new SimpleDateFormat(
                    "yyyy-MM-dd HH:mm:ss", Locale.US).format(new Date());
            latestTestReport =
                    "App Hide Toggle Test Report\n"
                    + "Version: " + version + "\n"
                    + "Generated: " + when + "\n\n"
                    + finalText + "\n";
        }
        runOnUiThread(() -> target.setText(finalText));
    }

    private void saveLatestTestReport() {
        if (latestTestReport == null || latestTestReport.trim().isEmpty()) {
            toast("Run the self-test first.");
            return;
        }

        String stamp = new SimpleDateFormat(
                "yyyy-MM-dd_HH-mm-ss", Locale.US).format(new Date());
        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("text/plain");
        intent.putExtra(Intent.EXTRA_TITLE,
                "AppHideToggle-Test-Report-" + stamp + ".txt");
        try {
            startActivityForResult(intent, REQUEST_SAVE_TEST_REPORT);
        } catch (Throwable e) {
            toast("Could not open file picker: " + shortError(e));
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQUEST_SAVE_TEST_REPORT || resultCode != RESULT_OK
                || data == null) {
            return;
        }

        Uri uri = data.getData();
        if (uri == null) {
            toast("No save location selected.");
            return;
        }

        try (OutputStream out = getContentResolver().openOutputStream(uri, "w")) {
            if (out == null) throw new IllegalStateException("Could not open output file");
            out.write(latestTestReport.getBytes(StandardCharsets.UTF_8));
            out.flush();
            toast("Test report saved.");
        } catch (Throwable e) {
            toast("Could not save test report: " + shortError(e));
        }
    }

    private void loadInstalledApps(boolean deepAdbScan) {
        runOnUiThread(() -> appCount.setText(deepAdbScan
                ? "Full scanning with Wireless ADB…"
                : "Scanning installed apps…"));
        executor.submit(() -> {
            ArrayList<AppEntry> found = new ArrayList<>();
            Set<String> seenPackages = new HashSet<>();
            PackageManager pm = getPackageManager();

            try {
                Map<String, ArrayList<String>> launcherComponents = new HashMap<>();
                Intent launcherQuery = new Intent(Intent.ACTION_MAIN);
                launcherQuery.addCategory(Intent.CATEGORY_LAUNCHER);
                int launcherFlags = PackageManager.MATCH_DISABLED_COMPONENTS
                        | PackageManager.MATCH_DISABLED_UNTIL_USED_COMPONENTS
                        | PackageManager.MATCH_ALL;
                List<ResolveInfo> launchers = pm.queryIntentActivities(
                        launcherQuery, launcherFlags);
                for (ResolveInfo ri : launchers) {
                    if (ri.activityInfo == null || ri.activityInfo.packageName == null
                            || ri.activityInfo.name == null) continue;
                    ArrayList<String> list = launcherComponents
                            .computeIfAbsent(ri.activityInfo.packageName, k -> new ArrayList<>());
                    if (!list.contains(ri.activityInfo.name)) list.add(ri.activityInfo.name);
                }

                // LauncherApps is the same class of launcher-facing API used by home
                // screens. Merge its visible launcher activities too, because Samsung
                // can return a slightly different set from PackageManager.queryIntentActivities.
                try {
                    LauncherApps launcherApps =
                            (LauncherApps) getSystemService(Context.LAUNCHER_APPS_SERVICE);
                    if (launcherApps != null) {
                        List<LauncherActivityInfo> launcherInfos =
                                launcherApps.getActivityList(null, Process.myUserHandle());
                        for (LauncherActivityInfo info : launcherInfos) {
                            if (info == null || info.getComponentName() == null) continue;
                            ComponentName cn = info.getComponentName();
                            String pkg = cn.getPackageName();
                            String cls = cn.getClassName();
                            if (pkg == null || cls == null) continue;
                            ArrayList<String> list = launcherComponents
                                    .computeIfAbsent(pkg, k -> new ArrayList<>());
                            if (!list.contains(cls)) list.add(cls);
                        }
                    }
                } catch (Throwable ignored) {
                }

                int adbLauncherTargets = 0;
                String deepScanNote = "";
                if (deepAdbScan) {
                    try {
                        Map<String, ArrayList<String>> adbLaunchers =
                                queryLauncherComponentsViaAdb();
                        for (Map.Entry<String, ArrayList<String>> item : adbLaunchers.entrySet()) {
                            ArrayList<String> list = launcherComponents.computeIfAbsent(
                                    item.getKey(), k -> new ArrayList<>());
                            for (String activity : item.getValue()) {
                                if (!list.contains(activity)) list.add(activity);
                            }
                        }
                        adbLauncherTargets = adbLaunchers.size();
                        deepScanNote = "ADB resolver found " + adbLauncherTargets
                                + " launcher packages. ";
                    } catch (Throwable e) {
                        deepScanNote = "ADB deep scan unavailable ("
                                + shortError(e) + "); local/cache scan used. ";
                    }
                }

                final int finalAdbLauncherTargets = adbLauncherTargets;
                final String finalDeepScanNote = deepScanNote;

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
                    else components = new ArrayList<>(components);

                    // Keep known launcher components across scans/restarts. Once this app
                    // hides a launcher activity, Samsung may omit it from normal resolver
                    // queries; the cache lets Full scan still find and restore it.
                    for (String cached : loadCachedLauncherComponents(ai.packageName)) {
                        if (!components.contains(cached)) components.add(cached);
                    }

                    // Samsung can occasionally omit an otherwise launchable activity from
                    // the bulk resolver query. Add the package's concrete launch component
                    // as a fallback while it is still visible.
                    try {
                        Intent launchIntent = pm.getLaunchIntentForPackage(ai.packageName);
                        if (launchIntent != null && launchIntent.getComponent() != null) {
                            String activity = launchIntent.getComponent().getClassName();
                            if (activity != null && !components.contains(activity)) {
                                components.add(activity);
                            }
                        }
                    } catch (Throwable ignored) {
                    }

                    if (!components.isEmpty()) {
                        saveCachedLauncherComponents(ai.packageName, components);
                    }

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
                    int launcherTargets = 0;
                    for (AppEntry e : installedApps) {
                        if (!e.launcherComponents.isEmpty()) launcherTargets++;
                    }
                    if (deepAdbScan) {
                        appCount.setText("Full scan complete — "
                                + finalDeepScanNote
                                + installedApps.size() + " apps, "
                                + launcherTargets + " with launcher targets. Showing "
                                + appAdapter.getCount() + ".");
                    } else {
                        appCount.setText("Showing " + appAdapter.getCount()
                                + " of " + installedApps.size()
                                + " installed apps. Launcher targets: "
                                + launcherTargets + ".");
                    }
                });
            } catch (Throwable e) {
                runOnUiThread(() -> appCount.setText("Could not scan apps: " + shortError(e)));
            }
        });
    }

    private Map<String, ArrayList<String>> queryLauncherComponentsViaAdb()
            throws Exception {
        AdbConnectionManager manager = requireConnection();
        if (manager == null) throw new IllegalStateException("Wireless ADB not connected");

        // Ask Android's shell PackageManager for the launcher-facing resolver list.
        // Do not pass --query-flags here: query-activities does not support that
        // option on this Samsung build and it makes the deep scan fail.
        String command =
                "cmd package query-activities --brief --components --user 0 "
                + "-a android.intent.action.MAIN "
                + "-c android.intent.category.LAUNCHER";
        String output = runAdbCommandWithMarker(manager, command, 4000);

        Map<String, ArrayList<String>> result = new HashMap<>();
        if (output == null) return result;

        for (String rawLine : output.split("\\r?\\n")) {
            String line = rawLine == null ? "" : rawLine.trim();
            if (line.isEmpty() || line.startsWith("No activities")) continue;
            int slash = line.indexOf('/');
            if (slash <= 0 || slash >= line.length() - 1) continue;

            String pkg = line.substring(0, slash).trim();
            String activity = line.substring(slash + 1).trim();
            if (pkg.isEmpty() || activity.isEmpty()) continue;
            if (activity.startsWith(".")) activity = pkg + activity;

            ArrayList<String> list = result.computeIfAbsent(
                    pkg, k -> new ArrayList<>());
            if (!list.contains(activity)) list.add(activity);
            saveCachedLauncherComponents(pkg, list);
        }
        return result;
    }

    private ArrayList<String> loadCachedLauncherComponents(String packageName) {
        ArrayList<String> out = new ArrayList<>();
        try {
            SharedPreferences prefs = getSharedPreferences(PREF_LAUNCHER_CACHE, MODE_PRIVATE);
            String raw = prefs.getString(packageName, "");
            if (raw == null || raw.isEmpty()) return out;
            for (String part : raw.split("\\u001F", -1)) {
                if (part != null && !part.isEmpty() && !out.contains(part)) out.add(part);
            }
        } catch (Throwable ignored) {
        }
        return out;
    }

    private void saveCachedLauncherComponents(String packageName, List<String> components) {
        if (packageName == null || packageName.isEmpty()
                || components == null || components.isEmpty()) return;
        try {
            StringBuilder raw = new StringBuilder();
            for (String component : components) {
                if (component == null || component.isEmpty()) continue;
                if (raw.length() > 0) raw.append('\u001F');
                raw.append(component);
            }
            if (raw.length() > 0) {
                getSharedPreferences(PREF_LAUNCHER_CACHE, MODE_PRIVATE)
                        .edit()
                        .putString(packageName, raw.toString())
                        .apply();
            }
        } catch (Throwable ignored) {
        }
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
                ok = manager.autoConnect(this, 3500);
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

        saveCachedLauncherComponents(entry.packageName, entry.launcherComponents);
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
                if (!manager.autoConnect(this, 3500)) {
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
                ComponentName component = new ComponentName(entry.packageName, activityName);
                applyComponentState(manager, component, show);
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

            applyPackageState(manager, entry.packageName, enable);

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

    private void applyComponentState(AdbConnectionManager manager,
                                     ComponentName component,
                                     boolean show) throws Exception {
        String flat = component.getPackageName() + "/" + component.getClassName();
        Throwable last = null;

        for (int attempt = 0; attempt < 2; attempt++) {
            AdbStream stream = null;
            try {
                String command = show
                        ? "pm enable --user 0 " + flat
                        : "pm disable --user 0 " + flat;
                stream = manager.openStream("shell:" + command);
                try { Thread.sleep(140); } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            } catch (Throwable e) {
                last = e;
            } finally {
                if (stream != null) {
                    try { stream.close(); } catch (Throwable ignored) { }
                }
            }

            try {
                Boolean disabled = queryComponentDisabledViaAdb(manager, component);
                if (disabled != null && (show ? !disabled : disabled)) {
                    return;
                }
            } catch (Throwable e) {
                last = e;
            }

            // Samsung has accepted the per-user component state on some apps even
            // when the regular disable command reported oddly. Use it only as a
            // second hide attempt, then verify through dumpsys instead of trusting stdout.
            if (!show) {
                AdbStream fallback = null;
                try {
                    fallback = manager.openStream(
                            "shell:pm disable-user --user 0 " + flat);
                    try { Thread.sleep(140); } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                } catch (Throwable e) {
                    last = e;
                } finally {
                    if (fallback != null) {
                        try { fallback.close(); } catch (Throwable ignored) { }
                    }
                }

                try {
                    Boolean disabled = queryComponentDisabledViaAdb(manager, component);
                    if (Boolean.TRUE.equals(disabled)) return;
                } catch (Throwable e) {
                    last = e;
                }
            }

            if (attempt == 0) {
                try { manager.autoConnect(this, 3500); } catch (Throwable ignored) { }
            }
        }

        if (last instanceof Exception) throw (Exception) last;
        throw new IllegalStateException(
                show ? "Android did not re-enable the launcher icon."
                     : "Android did not hide the launcher icon.");
    }

    private Boolean queryComponentDisabledViaAdb(AdbConnectionManager manager,
                                                 ComponentName component)
            throws Exception {
        String output = runAdbCommandWithMarker(
                manager, "dumpsys package " + component.getPackageName(), 4000);
        if (output == null || output.trim().isEmpty()) return null;

        String target = normalizeComponentClass(
                component.getPackageName(), component.getClassName());

        boolean inUser0 = false;
        boolean inDisabled = false;
        boolean sawDisabledSection = false;

        for (String raw : output.split("\\r?\\n")) {
            String line = raw == null ? "" : raw.trim();
            if (line.startsWith("User 0:")) {
                inUser0 = true;
                inDisabled = false;
                continue;
            }
            if (inUser0 && line.startsWith("User ") && !line.startsWith("User 0:")) {
                break;
            }
            if (!inUser0) continue;

            if ("disabledComponents:".equals(line)) {
                inDisabled = true;
                sawDisabledSection = true;
                continue;
            }

            if (inDisabled) {
                if (line.endsWith(":")
                        || line.startsWith("enabledComponents")
                        || line.startsWith("grantedPermissions")
                        || line.startsWith("runtime permissions")) {
                    inDisabled = false;
                    continue;
                }
                if (line.isEmpty()) continue;

                String normalized = normalizeComponentClass(
                        component.getPackageName(), line);
                if (target.equals(normalized)) return true;
            }
        }

        return sawDisabledSection ? Boolean.FALSE : null;
    }

    private String normalizeComponentClass(String pkg, String value) {
        if (value == null) return "";
        String s = value.trim();
        int slash = s.indexOf('/');
        if (slash >= 0 && slash < s.length() - 1) s = s.substring(slash + 1);
        if (s.startsWith(".")) s = pkg + s;
        return s;
    }

    private void applyPackageState(AdbConnectionManager manager,
                                   String pkg,
                                   boolean enable) throws Exception {
        String command = enable
                ? "pm enable --user 0 " + pkg
                : "pm disable-user --user 0 " + pkg;
        String expected = enable ? "enabled" : "disabled-user";

        Throwable last = null;
        for (int attempt = 0; attempt < 2; attempt++) {
            try {
                String output = runPmStateCommand(manager, command, 1500);
                if (pmReplyHasState(output, expected)) return;
                last = new IllegalStateException(
                        "Unexpected Android reply: " + compactReply(output));
            } catch (Throwable e) {
                last = e;
            }

            if (attempt == 0) {
                try { manager.autoConnect(this, 3500); } catch (Throwable ignored) { }
            }
        }

        if (last instanceof Exception) throw (Exception) last;
        throw new IllegalStateException("Android did not confirm app enabled state.");
    }

    private String runPmStateCommand(AdbConnectionManager manager,
                                     String command,
                                     long timeoutMs) throws Exception {
        return runAdbCommandWithMarker(manager, command, timeoutMs);
    }

    private String runAdbCommandWithMarker(AdbConnectionManager manager,
                                           String command,
                                           long timeoutMs) throws Exception {
        final String marker = "__AHT_DONE__";
        final AdbStream stream = manager.openStream(
                "shell:" + command + "; echo " + marker);

        Future<String> future = executor.submit(() -> {
            StringBuilder out = new StringBuilder();
            try (InputStream in = stream.openInputStream();
                 BufferedReader reader = new BufferedReader(
                         new InputStreamReader(in, StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    if (line.contains(marker)) return out.toString();
                    out.append(line).append('\n');
                }
            }
            return out.toString();
        });

        try {
            return future.get(timeoutMs, TimeUnit.MILLISECONDS);
        } catch (TimeoutException e) {
            future.cancel(true);
            throw new IllegalStateException("ADB command timed out");
        } finally {
            try { stream.close(); } catch (Throwable ignored) { }
        }
    }

    private boolean pmReplyHasState(String output, String expected) {
        return pmReplyHasAnyState(output, expected);
    }

    private boolean pmReplyHasAnyState(String output, String... expectedStates) {
        String lower = output == null ? "" : output.toLowerCase(Locale.ROOT);

        // Samsung's 'pm' stdout is inconsistent across commands/builds. If it
        // explicitly reports the requested state, accept it immediately.
        for (String expected : expectedStates) {
            if (expected != null
                    && lower.contains("new state: " + expected.toLowerCase(Locale.ROOT))) {
                return true;
            }
        }

        // Reject only explicit command failures. Reaching our completion marker
        // without one of these means the shell command itself finished normally.
        if (lower.contains("securityexception")
                || lower.contains("permission denial")
                || lower.contains("unknown package")
                || lower.contains("unknown component")
                || lower.contains("not found")
                || lower.contains("error:")
                || lower.contains("failed")) {
            return false;
        }

        return true;
    }

    private String compactReply(String output) {
        if (output == null || output.trim().isEmpty()) return "(no reply)";
        String oneLine = output.trim().replace('\n', ' ').replace('\r', ' ');
        return oneLine.length() <= 180 ? oneLine : oneLine.substring(0, 180) + "…";
    }

    private boolean isComponentInDesiredState(ComponentName component, boolean shown) {
        try {
            int state = getPackageManager().getComponentEnabledSetting(component);
            boolean disabled =
                    state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                    || state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER
                    || state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED;
            return shown ? !disabled : disabled;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private boolean isPackageInDesiredState(String pkg, boolean enabled) {
        try {
            int state = getPackageManager().getApplicationEnabledSetting(pkg);
            boolean actualEnabled;
            if (state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                    || state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER
                    || state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED) {
                actualEnabled = false;
            } else if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                actualEnabled = true;
            } else {
                ApplicationInfo ai = getPackageManager().getApplicationInfo(
                        pkg, PackageManager.MATCH_DISABLED_COMPONENTS);
                actualEnabled = ai.enabled;
            }
            return actualEnabled == enabled;
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

        holder.visibilitySwitch.setEnabled(hasLauncher);
        holder.enabledSwitch.setEnabled(true);

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
