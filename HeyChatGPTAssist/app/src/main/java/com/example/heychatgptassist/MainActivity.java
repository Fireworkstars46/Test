package com.example.heychatgptassist;

import android.Manifest;
import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.InputType;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Space;
import android.widget.TextView;
import android.widget.Toast;

import java.util.LinkedHashMap;
import java.util.Map;

import rikka.shizuku.Shizuku;

public class MainActivity extends Activity {
    private static final int REQ_MIC = 100;
    private static final int REQ_SHIZUKU = 200;

    public static final String PREFS = "hey_chatgpt_prefs";
    public static final String KEY_WAKE_PHRASE = "wake_phrase";
    public static final String DEFAULT_WAKE_PHRASE = "Hey ChatGPT";
    public static final String KEY_ASSIST_KEYCODE = "assist_keycode";
    public static final int DEFAULT_ASSIST_KEYCODE = 231;

    public static final String KEY_RESPONSE_TEXT_ENABLED = "response_text_enabled";

    public static final String KEY_TRIGGER_DELAY_MS = "trigger_delay_ms";
    public static final int DEFAULT_TRIGGER_DELAY_MS = 100;
    public static final int MAX_TRIGGER_DELAY_MS = 5000;

    public static final String KEY_REARM_DELAY_MS = "rearm_delay_ms";
    public static final int DEFAULT_REARM_DELAY_MS = 500;
    public static final int MAX_REARM_DELAY_MS = 5000;

    public static final String KEY_INITIAL_LISTEN_DELAY_MS = "initial_listen_delay_ms";
    public static final int DEFAULT_INITIAL_LISTEN_DELAY_MS = 100;
    public static final int MAX_INITIAL_LISTEN_DELAY_MS = 5000;

    public static final String KEY_RESTART_DELAY_MS = "restart_delay_ms";
    public static final int DEFAULT_RESTART_DELAY_MS = 100;
    public static final int MAX_RESTART_DELAY_MS = 5000;

    public static final String KEY_BUSY_RETRY_DELAY_MS = "busy_retry_delay_ms";
    public static final int DEFAULT_BUSY_RETRY_DELAY_MS = 100;
    public static final int MAX_BUSY_RETRY_DELAY_MS = 5000;

    public static final String KEY_RATE_LIMIT_RETRY_DELAY_MS = "rate_limit_retry_delay_ms";
    public static final int DEFAULT_RATE_LIMIT_RETRY_DELAY_MS = 250;
    public static final int MAX_RATE_LIMIT_RETRY_DELAY_MS = 10000;

    public static final String KEY_COMPLETE_SILENCE_MS = "complete_silence_ms";
    public static final int DEFAULT_COMPLETE_SILENCE_MS = 3500;
    public static final int MAX_COMPLETE_SILENCE_MS = 15000;

    public static final String KEY_POSSIBLY_COMPLETE_SILENCE_MS = "possibly_complete_silence_ms";
    public static final int DEFAULT_POSSIBLY_COMPLETE_SILENCE_MS = 1800;
    public static final int MAX_POSSIBLY_COMPLETE_SILENCE_MS = 15000;

    public static final String KEY_MIN_SPEECH_MS = "min_speech_ms";
    public static final int DEFAULT_MIN_SPEECH_MS = 500;
    public static final int MAX_MIN_SPEECH_MS = 10000;

    private static class TimingSpec {
        final String key;
        final String label;
        final int defaultValue;
        final int maxValue;
        final String help;

        TimingSpec(String key, String label, int defaultValue, int maxValue, String help) {
            this.key = key;
            this.label = label;
            this.defaultValue = defaultValue;
            this.maxValue = maxValue;
            this.help = help;
        }
    }

    private static final TimingSpec[] TIMING_SPECS = new TimingSpec[] {
            new TimingSpec(KEY_TRIGGER_DELAY_MS,
                    "Assistant trigger delay (ms)", DEFAULT_TRIGGER_DELAY_MS, MAX_TRIGGER_DELAY_MS,
                    "Delay between hearing the wake phrase and sending the Assist key. 0 = immediate."),
            new TimingSpec(KEY_REARM_DELAY_MS,
                    "Re-arm after assistant opens (ms)", DEFAULT_REARM_DELAY_MS, MAX_REARM_DELAY_MS,
                    "How soon the wake listener starts trying again after opening ChatGPT. 0 = immediate."),
            new TimingSpec(KEY_INITIAL_LISTEN_DELAY_MS,
                    "Initial listener start delay (ms)", DEFAULT_INITIAL_LISTEN_DELAY_MS, MAX_INITIAL_LISTEN_DELAY_MS,
                    "Delay before the first microphone listening session starts."),
            new TimingSpec(KEY_RESTART_DELAY_MS,
                    "Normal listener restart delay (ms)", DEFAULT_RESTART_DELAY_MS, MAX_RESTART_DELAY_MS,
                    "Delay after a normal timeout or no-match before listening starts again."),
            new TimingSpec(KEY_BUSY_RETRY_DELAY_MS,
                    "Microphone/recognizer busy retry (ms)", DEFAULT_BUSY_RETRY_DELAY_MS, MAX_BUSY_RETRY_DELAY_MS,
                    "Retry delay when Android temporarily says the microphone or recognizer is busy."),
            new TimingSpec(KEY_RATE_LIMIT_RETRY_DELAY_MS,
                    "Too-many-requests retry (ms)", DEFAULT_RATE_LIMIT_RETRY_DELAY_MS, MAX_RATE_LIMIT_RETRY_DELAY_MS,
                    "Backoff used when Android speech recognition reports too many requests."),
            new TimingSpec(KEY_COMPLETE_SILENCE_MS,
                    "Complete-silence timeout (ms)", DEFAULT_COMPLETE_SILENCE_MS, MAX_COMPLETE_SILENCE_MS,
                    "Speech-recognizer silence timing. Some Android speech engines may ignore this value."),
            new TimingSpec(KEY_POSSIBLY_COMPLETE_SILENCE_MS,
                    "Possibly-complete silence timeout (ms)", DEFAULT_POSSIBLY_COMPLETE_SILENCE_MS, MAX_POSSIBLY_COMPLETE_SILENCE_MS,
                    "Speech-recognizer early silence timing. Some Android speech engines may ignore this value."),
            new TimingSpec(KEY_MIN_SPEECH_MS,
                    "Minimum speech length (ms)", DEFAULT_MIN_SPEECH_MS, MAX_MIN_SPEECH_MS,
                    "Minimum speech timing sent to the Android recognizer. Some engines may ignore it.")
    };

    private TextView status;
    private TextView diagnostics;
    private TextView shizukuStatus;
    private TextView selectedKey;
    private TextView responseTextStatus;
    private EditText phraseInput;
    private CheckBox responseTextToggle;
    private final Map<String, EditText> timingInputs = new LinkedHashMap<>();

    private final Handler uiHandler = new Handler(Looper.getMainLooper());
    private final Runnable diagnosticUpdater = new Runnable() {
        @Override public void run() {
            updateDiagnostics();
            updateShizukuStatus();
            updateResponseTextStatus();
            uiHandler.postDelayed(this, 1500);
        }
    };

    private final Shizuku.OnRequestPermissionResultListener shizukuPermissionListener =
            (requestCode, grantResult) -> {
                if (requestCode != REQ_SHIZUKU) return;
                if (grantResult == PackageManager.PERMISSION_GRANTED) {
                    status.setText("Status: Shizuku permission granted");
                } else {
                    status.setText("Status: Shizuku permission denied");
                }
                updateShizukuStatus();
            };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Shizuku.addRequestPermissionResultListener(shizukuPermissionListener);

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setClipToPadding(false);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.TOP);

        final int sidePadding = dp(20);
        final int normalTopPadding = dp(16);
        final int normalBottomPadding = dp(40);
        root.setPadding(sidePadding, normalTopPadding, sidePadding, normalBottomPadding);
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
            v.setPadding(sidePadding, normalTopPadding + bars.top,
                    sidePadding, normalBottomPadding + bars.bottom);
            return insets;
        });

        scroll.addView(root, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView title = new TextView(this);
        title.setText("Hey ChatGPT Assist v1.1");
        title.setTextSize(25);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(title);

        TextView desc = new TextView(this);
        desc.setText("\nAlways-listening assistant plus optional Siri-style response text over the real ChatGPT assistant popup.");
        desc.setTextSize(15);
        root.addView(desc);

        status = new TextView(this);
        status.setText("\nStatus: stopped");
        status.setTextSize(17);
        status.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(status);

        TextView always = new TextView(this);
        always.setText("\nAlways listening: ON");
        always.setTextSize(16);
        always.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(always);

        TextView phraseLabel = new TextView(this);
        phraseLabel.setText("\nActivation phrase:");
        phraseLabel.setTextSize(16);
        phraseLabel.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(phraseLabel);

        phraseInput = new EditText(this);
        phraseInput.setSingleLine(true);
        phraseInput.setHint("Example: Hey ChatGPT");
        phraseInput.setText(getWakePhrase());
        root.addView(phraseInput, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        Button savePhrase = new Button(this);
        savePhrase.setText("SAVE ACTIVATION PHRASE");
        savePhrase.setOnClickListener(v -> saveWakePhrase(true));
        root.addView(savePhrase);

        TextView responseTitle = new TextView(this);
        responseTitle.setText("\nSiri-style response text");
        responseTitle.setTextSize(20);
        responseTitle.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(responseTitle);

        TextView responseHelp = new TextView(this);
        responseHelp.setText("This keeps the real ChatGPT assistant popup. When ChatGPT exposes its live text through Android Accessibility, this app mirrors that text into a small panel above the popup. The Accessibility service is restricted to the ChatGPT package.");
        responseHelp.setTextSize(13);
        root.addView(responseHelp);

        responseTextToggle = new CheckBox(this);
        responseTextToggle.setText("Show ChatGPT response text popup");
        responseTextToggle.setChecked(getSharedPreferences(PREFS, MODE_PRIVATE)
                .getBoolean(KEY_RESPONSE_TEXT_ENABLED, true));
        responseTextToggle.setOnCheckedChangeListener((buttonView, isChecked) -> {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                    .putBoolean(KEY_RESPONSE_TEXT_ENABLED, isChecked).apply();
            updateResponseTextStatus();
        });
        root.addView(responseTextToggle);

        responseTextStatus = new TextView(this);
        responseTextStatus.setTextSize(14);
        root.addView(responseTextStatus);

        Button accessibility = new Button(this);
        accessibility.setText("OPEN ACCESSIBILITY SETTINGS");
        accessibility.setOnClickListener(v -> openAccessibilitySettings());
        root.addView(accessibility);

        TextView accessibilityNote = new TextView(this);
        accessibilityNote.setText("One-time setup: in Accessibility, turn on ‘Hey ChatGPT Assist response text’. Android will show an Accessibility warning because this feature needs permission to read ChatGPT's on-screen response text.");
        accessibilityNote.setTextSize(13);
        root.addView(accessibilityNote);

        TextView timingTitle = new TextView(this);
        timingTitle.setText("\nTiming settings");
        timingTitle.setTextSize(20);
        timingTitle.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(timingTitle);

        TextView timingIntro = new TextView(this);
        timingIntro.setText("Every listener delay/timing value is editable below. Values are milliseconds.");
        timingIntro.setTextSize(13);
        root.addView(timingIntro);

        for (TimingSpec spec : TIMING_SPECS) addTimingField(root, spec);

        Button saveTiming = new Button(this);
        saveTiming.setText("SAVE ALL TIMING SETTINGS");
        saveTiming.setOnClickListener(v -> saveAllTimingSettings(true));
        root.addView(saveTiming);

        Button start = new Button(this);
        start.setText("START ALWAYS LISTENING");
        start.setOnClickListener(v -> {
            saveWakePhrase(false);
            saveAllTimingSettings(false);
            requestAndStart();
        });
        root.addView(start);

        Button stop = new Button(this);
        stop.setText("STOP VOICE LISTENING");
        stop.setOnClickListener(v -> {
            stopService(new Intent(this, WakeListenerService.class));
            status.setText("Status: stopped");
            updateDiagnostics();
        });
        root.addView(stop);

        diagnostics = new TextView(this);
        diagnostics.setText("\nListener details: not started");
        diagnostics.setTextSize(14);
        root.addView(diagnostics);

        selectedKey = new TextView(this);
        selectedKey.setTextSize(15);
        selectedKey.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(selectedKey);
        updateSelectedKeyText();

        shizukuStatus = new TextView(this);
        shizukuStatus.setText("\nShizuku: checking…");
        shizukuStatus.setTextSize(15);
        root.addView(shizukuStatus);

        Button grantShizuku = new Button(this);
        grantShizuku.setText("GRANT / CHECK SHIZUKU PERMISSION");
        grantShizuku.setOnClickListener(v -> requestShizukuPermission());
        root.addView(grantShizuku);

        Button test219 = new Button(this);
        test219.setText("TEST ASSIST KEY 219");
        test219.setOnClickListener(v -> testKey(219));
        root.addView(test219);

        Button use219 = new Button(this);
        use219.setText("USE KEY 219");
        use219.setOnClickListener(v -> setSelectedKey(219));
        root.addView(use219);

        Button test231 = new Button(this);
        test231.setText("TEST VOICE ASSIST KEY 231");
        test231.setOnClickListener(v -> testKey(231));
        root.addView(test231);

        Button use231 = new Button(this);
        use231.setText("USE KEY 231");
        use231.setOnClickListener(v -> setSelectedKey(231));
        root.addView(use231);

        Button openShizuku = new Button(this);
        openShizuku.setText("OPEN SHIZUKU");
        openShizuku.setOnClickListener(v -> openShizuku());
        root.addView(openShizuku);

        TextView note = new TextView(this);
        note.setText("\nResponse text depends on what the installed ChatGPT assistant exposes to Android Accessibility. The normal wake/assistant behavior works independently, so turning this feature off does not affect your existing setup.");
        note.setTextSize(13);
        root.addView(note);

        Space bottomSpacer = new Space(this);
        root.addView(bottomSpacer, new LinearLayout.LayoutParams(1, dp(96)));

        setContentView(scroll);
        root.requestApplyInsets();
        updateDiagnostics();
        updateShizukuStatus();
        updateResponseTextStatus();
    }

    private void addTimingField(LinearLayout root, TimingSpec spec) {
        TextView label = new TextView(this);
        label.setText("\n" + spec.label + ":");
        label.setTextSize(16);
        label.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(label);

        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setInputType(InputType.TYPE_CLASS_NUMBER);
        input.setHint("0 to " + spec.maxValue);
        input.setText(String.valueOf(getTimingValue(spec)));
        timingInputs.put(spec.key, input);
        root.addView(input, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView help = new TextView(this);
        help.setText(spec.help + " Default = " + spec.defaultValue + " ms. Range 0–" + spec.maxValue + " ms.");
        help.setTextSize(13);
        root.addView(help);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    @Override protected void onResume() {
        super.onResume();
        uiHandler.removeCallbacks(diagnosticUpdater);
        uiHandler.post(diagnosticUpdater);
    }

    @Override protected void onPause() {
        uiHandler.removeCallbacks(diagnosticUpdater);
        super.onPause();
    }

    @Override protected void onDestroy() {
        uiHandler.removeCallbacks(diagnosticUpdater);
        Shizuku.removeRequestPermissionResultListener(shizukuPermissionListener);
        super.onDestroy();
    }

    private void openAccessibilitySettings() {
        try {
            startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS));
        } catch (Throwable t) {
            Toast.makeText(this, "Could not open Accessibility settings", Toast.LENGTH_LONG).show();
        }
    }

    private boolean isResponseAccessibilityEnabled() {
        String enabled = Settings.Secure.getString(
                getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        if (enabled == null) return false;

        ComponentName wanted = new ComponentName(this, ChatGPTTextAccessibilityService.class);
        TextUtils.SimpleStringSplitter splitter = new TextUtils.SimpleStringSplitter(':');
        splitter.setString(enabled);
        while (splitter.hasNext()) {
            ComponentName found = ComponentName.unflattenFromString(splitter.next());
            if (wanted.equals(found)) return true;
        }
        return false;
    }

    private void updateResponseTextStatus() {
        if (responseTextStatus == null) return;
        boolean feature = getSharedPreferences(PREFS, MODE_PRIVATE)
                .getBoolean(KEY_RESPONSE_TEXT_ENABLED, true);
        boolean service = isResponseAccessibilityEnabled();
        String last = getSharedPreferences(PREFS, MODE_PRIVATE)
                .getString(ChatGPTTextAccessibilityService.KEY_LAST_CAPTURED_TEXT, "");
        String text = "Response text: " + (feature ? "ON" : "OFF") +
                " | Accessibility: " + (service ? "enabled" : "needs setup");
        if (!last.isEmpty()) {
            String preview = last.length() > 120 ? last.substring(0, 120) + "…" : last;
            text += "\nLast captured: " + preview;
        }
        responseTextStatus.setText(text);
    }

    private void requestShizukuPermission() {
        try {
            if (!ShizukuBridge.isRunning()) {
                status.setText("Status: Shizuku is not running");
                return;
            }
            if (ShizukuBridge.hasPermission()) {
                status.setText("Status: Shizuku permission already granted");
                return;
            }
            Shizuku.requestPermission(REQ_SHIZUKU);
            status.setText("Status: waiting for Shizuku permission…");
        } catch (Throwable t) {
            status.setText("Status: Shizuku permission error: " + t.getClass().getSimpleName());
        }
    }

    private void openShizuku() {
        try {
            Intent launch = getPackageManager().getLaunchIntentForPackage("moe.shizuku.privileged.api");
            if (launch != null) startActivity(launch);
            else Toast.makeText(this, "Shizuku is not installed", Toast.LENGTH_LONG).show();
        } catch (Throwable t) {
            Toast.makeText(this, "Could not open Shizuku", Toast.LENGTH_LONG).show();
        }
    }

    private void updateShizukuStatus() {
        if (shizukuStatus != null) shizukuStatus.setText("\nShizuku: " + ShizukuBridge.statusText());
    }

    private int getSelectedKey() {
        return getSharedPreferences(PREFS, MODE_PRIVATE)
                .getInt(KEY_ASSIST_KEYCODE, DEFAULT_ASSIST_KEYCODE);
    }

    private void setSelectedKey(int keyCode) {
        getSharedPreferences(PREFS, MODE_PRIVATE)
                .edit().putInt(KEY_ASSIST_KEYCODE, keyCode).apply();
        updateSelectedKeyText();
        Toast.makeText(this, "Wake phrase will use key " + keyCode, Toast.LENGTH_SHORT).show();
    }

    private void updateSelectedKeyText() {
        if (selectedKey == null) return;
        int key = getSelectedKey();
        String name = key == 219 ? "Assist" : key == 231 ? "Voice Assist" : "Custom";
        selectedKey.setText("\nWake action: " + name + " key " + key);
    }

    private void testKey(int keyCode) {
        if (!ShizukuBridge.isRunning()) {
            status.setText("Status: Shizuku is not running");
            return;
        }
        if (!ShizukuBridge.hasPermission()) {
            status.setText("Status: grant Shizuku permission first");
            requestShizukuPermission();
            return;
        }
        status.setText("Status: sending Android key " + keyCode + "…");
        new Thread(() -> {
            ShizukuBridge.Result result = ShizukuBridge.sendKeyEvent(keyCode);
            runOnUiThread(() -> status.setText("Status: " + result.message));
        }, "shizuku-key-test").start();
    }

    private void updateDiagnostics() {
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        String listener = prefs.getString(WakeListenerService.KEY_LISTENER_STATUS, "Not started");
        String heard = prefs.getString(WakeListenerService.KEY_LAST_HEARD, "");
        String text = "\nListener details: " + listener;
        if (!heard.isEmpty()) text += "\nLast heard: " + heard;
        if (diagnostics != null) diagnostics.setText(text);
    }

    private String getWakePhrase() {
        return getSharedPreferences(PREFS, MODE_PRIVATE)
                .getString(KEY_WAKE_PHRASE, DEFAULT_WAKE_PHRASE);
    }

    private void saveWakePhrase(boolean showToast) {
        String phrase = phraseInput.getText().toString().trim();
        if (phrase.isEmpty()) phrase = DEFAULT_WAKE_PHRASE;
        phraseInput.setText(phrase);
        getSharedPreferences(PREFS, MODE_PRIVATE)
                .edit().putString(KEY_WAKE_PHRASE, phrase).apply();
        if (showToast) Toast.makeText(this, "Activation phrase saved: " + phrase, Toast.LENGTH_SHORT).show();
    }

    private TimingSpec findTimingSpec(String key) {
        for (TimingSpec spec : TIMING_SPECS) if (spec.key.equals(key)) return spec;
        return null;
    }

    private int getTimingValue(TimingSpec spec) {
        int value = getSharedPreferences(PREFS, MODE_PRIVATE).getInt(spec.key, spec.defaultValue);
        return Math.max(0, Math.min(spec.maxValue, value));
    }

    private int getTimingValue(String key) {
        TimingSpec spec = findTimingSpec(key);
        return spec == null ? 0 : getTimingValue(spec);
    }

    private void saveAllTimingSettings(boolean showToast) {
        SharedPreferences.Editor editor = getSharedPreferences(PREFS, MODE_PRIVATE).edit();
        for (TimingSpec spec : TIMING_SPECS) {
            EditText input = timingInputs.get(spec.key);
            int value = spec.defaultValue;
            if (input != null) {
                try {
                    String raw = input.getText().toString().trim();
                    if (!raw.isEmpty()) value = Integer.parseInt(raw);
                } catch (NumberFormatException ignored) {}
            }
            value = Math.max(0, Math.min(spec.maxValue, value));
            if (input != null) input.setText(String.valueOf(value));
            editor.putInt(spec.key, value);
        }
        editor.apply();
        if (showToast) Toast.makeText(this, "All timing settings saved", Toast.LENGTH_SHORT).show();
    }

    private void requestAndStart() {
        if (!ShizukuBridge.hasPermission()) {
            status.setText("Status: Shizuku must be running and authorized");
            requestShizukuPermission();
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQ_MIC);
            return;
        }
        Intent service = new Intent(this, WakeListenerService.class);
        startForegroundService(service);
        status.setText("Status: always listening for ‘" + getWakePhrase() + "’ — trigger " +
                getTimingValue(KEY_TRIGGER_DELAY_MS) + " ms, re-arm " +
                getTimingValue(KEY_REARM_DELAY_MS) + " ms, busy retry " +
                getTimingValue(KEY_BUSY_RETRY_DELAY_MS) + " ms");
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_MIC && grantResults.length > 0 &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED) requestAndStart();
    }
}
