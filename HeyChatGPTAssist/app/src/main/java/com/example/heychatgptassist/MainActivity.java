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
import android.view.View;
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
    public static final String KEY_TEMPORARY_VOICE_ENABLED = "temporary_voice_enabled";

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
    public static final int MAX_COMPLETE_SILENCE_MS = 120000;

    public static final String KEY_POSSIBLY_COMPLETE_SILENCE_MS = "possibly_complete_silence_ms";
    public static final int DEFAULT_POSSIBLY_COMPLETE_SILENCE_MS = 1800;
    public static final int MAX_POSSIBLY_COMPLETE_SILENCE_MS = 120000;

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
                    "Delay between hearing the wake phrase and starting the assistant action. 0 = immediate."),
            new TimingSpec(KEY_REARM_DELAY_MS,
                    "Re-arm after assistant opens (ms)", DEFAULT_REARM_DELAY_MS, MAX_REARM_DELAY_MS,
                    "Normal assistant mode only. 0 = immediate. Temporary Voice pauses the wake listener while Voice is active."),
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
                    "Longer values can reduce privacy-icon blinking. Some speech engines may ignore this value."),
            new TimingSpec(KEY_POSSIBLY_COMPLETE_SILENCE_MS,
                    "Possibly-complete silence timeout (ms)", DEFAULT_POSSIBLY_COMPLETE_SILENCE_MS, MAX_POSSIBLY_COMPLETE_SILENCE_MS,
                    "Early silence timing. Some speech engines may ignore this value."),
            new TimingSpec(KEY_MIN_SPEECH_MS,
                    "Minimum speech length (ms)", DEFAULT_MIN_SPEECH_MS, MAX_MIN_SPEECH_MS,
                    "Minimum speech timing sent to Android recognition. Some engines may ignore it.")
    };

    private TextView status;
    private TextView diagnostics;
    private TextView shizukuStatus;
    private TextView selectedKey;
    private TextView companionStatus;
    private TextView temporaryVoiceStatus;
    private EditText phraseInput;
    private CheckBox responseTextToggle;
    private CheckBox temporaryVoiceToggle;
    private final Map<String, EditText> timingInputs = new LinkedHashMap<>();

    private final Handler uiHandler = new Handler(Looper.getMainLooper());
    private final Runnable diagnosticUpdater = new Runnable() {
        @Override public void run() {
            updateDiagnostics();
            updateShizukuStatus();
            updateCompanionStatus();
            updateTemporaryVoiceStatus();
            uiHandler.postDelayed(this, 1500);
        }
    };

    private final Shizuku.OnRequestPermissionResultListener shizukuPermissionListener =
            (requestCode, grantResult) -> {
                if (requestCode != REQ_SHIZUKU) return;
                status.setText(grantResult == PackageManager.PERMISSION_GRANTED
                        ? "Status: Shizuku permission granted"
                        : "Status: Shizuku permission denied");
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

        TextView title = addHeading(root, "Hey ChatGPT Assist v1.3", 25);
        title.setPadding(0, 0, 0, dp(4));
        addNote(root, "Always-listening assistant with smoother microphone handling, optional response text, and an experimental Temporary Voice mode that keeps finished Voice chats out of normal history.");

        status = addHeading(root, "Status: stopped", 17);
        addHeading(root, "Always listening: ON", 16);

        addHeading(root, "Activation phrase", 20);
        phraseInput = new EditText(this);
        phraseInput.setSingleLine(true);
        phraseInput.setHint("Example: Hey ChatGPT");
        phraseInput.setText(getWakePhrase());
        root.addView(phraseInput, fullWidth());
        addButton(root, "SAVE ACTIVATION PHRASE", v -> saveWakePhrase(true));

        addHeading(root, "Siri-style response text", 20);
        addNote(root, "When ChatGPT exposes its live response text through Android Accessibility, the companion can mirror it into a small panel. The Accessibility service is restricted to the ChatGPT app.");
        responseTextToggle = new CheckBox(this);
        responseTextToggle.setText("Show ChatGPT response text popup");
        responseTextToggle.setChecked(prefs().getBoolean(KEY_RESPONSE_TEXT_ENABLED, true));
        responseTextToggle.setOnCheckedChangeListener((buttonView, checked) -> {
            prefs().edit().putBoolean(KEY_RESPONSE_TEXT_ENABLED, checked).apply();
            updateCompanionStatus();
        });
        root.addView(responseTextToggle);

        companionStatus = new TextView(this);
        companionStatus.setTextSize(14);
        root.addView(companionStatus);

        addHeading(root, "Temporary Voice", 20);
        addNote(root, "When enabled, saying the wake phrase opens ChatGPT, starts a fresh Temporary chat, and then starts Voice. It uses the same Accessibility companion. Voice is not started unless the helper reaches the Temporary control first. This mode opens the ChatGPT app rather than the small Android assistant popup because ChatGPT does not expose a supported Temporary-mode flag for that popup.");
        temporaryVoiceToggle = new CheckBox(this);
        temporaryVoiceToggle.setText("Always use Temporary Chat for wake-phrase Voice");
        temporaryVoiceToggle.setChecked(prefs().getBoolean(KEY_TEMPORARY_VOICE_ENABLED, false));
        temporaryVoiceToggle.setOnCheckedChangeListener((buttonView, checked) -> {
            prefs().edit().putBoolean(KEY_TEMPORARY_VOICE_ENABLED, checked).apply();
            updateTemporaryVoiceStatus();
        });
        root.addView(temporaryVoiceToggle);

        temporaryVoiceStatus = new TextView(this);
        temporaryVoiceStatus.setTextSize(14);
        root.addView(temporaryVoiceStatus);

        addButton(root, "OPEN ACCESSIBILITY SETTINGS", v -> openAccessibilitySettings());
        addNote(root, "One-time setup: turn on ‘Hey ChatGPT Assist response text’ in Accessibility. That same service handles both response-text mirroring and Temporary Voice automation.");

        addHeading(root, "Timing settings", 20);
        addNote(root, "Every listener delay/timing value is editable below. Values are milliseconds.");
        for (TimingSpec spec : TIMING_SPECS) addTimingField(root, spec);
        addButton(root, "SAVE ALL TIMING SETTINGS", v -> saveAllTimingSettings(true));

        addButton(root, "START ALWAYS LISTENING", v -> {
            saveWakePhrase(false);
            saveAllTimingSettings(false);
            requestAndStart();
        });
        addButton(root, "STOP VOICE LISTENING", v -> {
            stopService(new Intent(this, WakeListenerService.class));
            status.setText("Status: stopped");
            updateDiagnostics();
        });

        diagnostics = new TextView(this);
        diagnostics.setTextSize(14);
        root.addView(diagnostics);

        selectedKey = new TextView(this);
        selectedKey.setTextSize(15);
        selectedKey.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(selectedKey);
        updateSelectedKeyText();

        shizukuStatus = new TextView(this);
        shizukuStatus.setTextSize(15);
        root.addView(shizukuStatus);

        addButton(root, "GRANT / CHECK SHIZUKU PERMISSION", v -> requestShizukuPermission());
        addButton(root, "TEST ASSIST KEY 219", v -> testKey(219));
        addButton(root, "USE KEY 219", v -> setSelectedKey(219));
        addButton(root, "TEST VOICE ASSIST KEY 231", v -> testKey(231));
        addButton(root, "USE KEY 231", v -> setSelectedKey(231));
        addButton(root, "OPEN SHIZUKU", v -> openShizuku());

        addNote(root, "Normal mode keeps the side-button-style Android assistant behavior. Temporary Voice is separate and only takes over the wake action while its toggle is enabled.");
        Space bottomSpacer = new Space(this);
        root.addView(bottomSpacer, new LinearLayout.LayoutParams(1, dp(96)));

        setContentView(scroll);
        root.requestApplyInsets();
        updateDiagnostics();
        updateShizukuStatus();
        updateCompanionStatus();
        updateTemporaryVoiceStatus();
    }

    private SharedPreferences prefs() {
        return getSharedPreferences(PREFS, MODE_PRIVATE);
    }

    private LinearLayout.LayoutParams fullWidth() {
        return new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private TextView addHeading(LinearLayout root, String text, int size) {
        TextView view = new TextView(this);
        view.setText("\n" + text);
        view.setTextSize(size);
        view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(view);
        return view;
    }

    private TextView addNote(LinearLayout root, String text) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(13);
        root.addView(view);
        return view;
    }

    private Button addButton(LinearLayout root, String text, View.OnClickListener listener) {
        Button button = new Button(this);
        button.setText(text);
        button.setOnClickListener(listener);
        root.addView(button);
        return button;
    }

    private void addTimingField(LinearLayout root, TimingSpec spec) {
        TextView label = addHeading(root, spec.label, 16);
        label.setPadding(0, 0, 0, 0);

        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setInputType(InputType.TYPE_CLASS_NUMBER);
        input.setHint("0 to " + spec.maxValue);
        input.setText(String.valueOf(getTimingValue(spec)));
        timingInputs.put(spec.key, input);
        root.addView(input, fullWidth());

        addNote(root, spec.help + " Default = " + spec.defaultValue + " ms. Range 0–" + spec.maxValue + " ms.");
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

    private boolean isCompanionAccessibilityEnabled() {
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

    private void updateCompanionStatus() {
        if (companionStatus == null) return;
        boolean feature = prefs().getBoolean(KEY_RESPONSE_TEXT_ENABLED, true);
        boolean service = isCompanionAccessibilityEnabled();
        String last = prefs().getString(ChatGPTTextAccessibilityService.KEY_LAST_CAPTURED_TEXT, "");
        String text = "Response text: " + (feature ? "ON" : "OFF") +
                " | Accessibility: " + (service ? "enabled" : "needs setup");
        if (!last.isEmpty()) {
            String preview = last.length() > 120 ? last.substring(0, 120) + "…" : last;
            text += "\nLast captured: " + preview;
        }
        companionStatus.setText(text);
    }

    private void updateTemporaryVoiceStatus() {
        if (temporaryVoiceStatus == null) return;
        boolean enabled = prefs().getBoolean(KEY_TEMPORARY_VOICE_ENABLED, false);
        boolean service = isCompanionAccessibilityEnabled();
        String automation = prefs().getString(
                ChatGPTTextAccessibilityService.KEY_TEMP_AUTOMATION_STATUS, "Ready");
        temporaryVoiceStatus.setText("Temporary Voice: " + (enabled ? "ON" : "OFF") +
                " | Accessibility: " + (service ? "enabled" : "needs setup") +
                "\n" + automation);
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
        return prefs().getInt(KEY_ASSIST_KEYCODE, DEFAULT_ASSIST_KEYCODE);
    }

    private void setSelectedKey(int keyCode) {
        prefs().edit().putInt(KEY_ASSIST_KEYCODE, keyCode).apply();
        updateSelectedKeyText();
        Toast.makeText(this, "Normal wake mode will use key " + keyCode, Toast.LENGTH_SHORT).show();
    }

    private void updateSelectedKeyText() {
        if (selectedKey == null) return;
        int key = getSelectedKey();
        String name = key == 219 ? "Assist" : key == 231 ? "Voice Assist" : "Custom";
        selectedKey.setText("\nNormal wake action: " + name + " key " + key);
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
        SharedPreferences p = prefs();
        String listener = p.getString(WakeListenerService.KEY_LISTENER_STATUS, "Not started");
        String heard = p.getString(WakeListenerService.KEY_LAST_HEARD, "");
        String text = "\nListener details: " + listener;
        if (!heard.isEmpty()) text += "\nLast heard: " + heard;
        if (diagnostics != null) diagnostics.setText(text);
    }

    private String getWakePhrase() {
        return prefs().getString(KEY_WAKE_PHRASE, DEFAULT_WAKE_PHRASE);
    }

    private void saveWakePhrase(boolean showToast) {
        String phrase = phraseInput.getText().toString().trim();
        if (phrase.isEmpty()) phrase = DEFAULT_WAKE_PHRASE;
        phraseInput.setText(phrase);
        prefs().edit().putString(KEY_WAKE_PHRASE, phrase).apply();
        if (showToast) Toast.makeText(this, "Activation phrase saved: " + phrase, Toast.LENGTH_SHORT).show();
    }

    private TimingSpec findTimingSpec(String key) {
        for (TimingSpec spec : TIMING_SPECS) if (spec.key.equals(key)) return spec;
        return null;
    }

    private int getTimingValue(TimingSpec spec) {
        int value = prefs().getInt(spec.key, spec.defaultValue);
        return Math.max(0, Math.min(spec.maxValue, value));
    }

    private int getTimingValue(String key) {
        TimingSpec spec = findTimingSpec(key);
        return spec == null ? 0 : getTimingValue(spec);
    }

    private void saveAllTimingSettings(boolean showToast) {
        SharedPreferences.Editor editor = prefs().edit();
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
        if (prefs().getBoolean(KEY_TEMPORARY_VOICE_ENABLED, false) && !isCompanionAccessibilityEnabled()) {
            status.setText("Status: enable the Accessibility companion for Temporary Voice first");
            openAccessibilitySettings();
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
