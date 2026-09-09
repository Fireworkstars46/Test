from pathlib import Path
import re

# Wake listener: preserve normal Shizuku assistant mode, add Siri API mode,
# and keep the microphone paused until the active popup actually closes.
p = Path('app/src/main/java/com/example/heychatgptassist/WakeListenerService.java')
s = p.read_text()

anchor = '    private Intent recognizerIntent;\n    private final Handler handler = new Handler(Looper.getMainLooper());'
replacement = ('    private Intent recognizerIntent;\n'
               '    private boolean stopping = false;\n'
               '    private boolean pausedForAssistant = false;\n'
               '    private final Handler handler = new Handler(Looper.getMainLooper());')
if anchor in s:
    s = s.replace(anchor, replacement, 1)
duplicate = ('\n    private boolean stopping = false;\n'
             '    private boolean pausedForAssistant = false;\n'
             '    private boolean forceSystemRecognizer = false;')
if duplicate in s:
    s = s.replace(duplicate, '\n    private boolean forceSystemRecognizer = false;', 1)

const_anchor = ('    public static final String ACTION_TEMP_VOICE_FINISHED =\n'
                '            "com.example.heychatgptassist.TEMP_VOICE_FINISHED";')
if const_anchor not in s:
    raise SystemExit('action constant anchor not found')
s = s.replace(const_anchor, const_anchor +
    '\n    public static final String ACTION_SIRI_FINISHED =\n'
    '            "com.example.heychatgptassist.SIRI_FINISHED";\n'
    '    public static final String ACTION_ASSISTANT_POPUP_OPENED =\n'
    '            "com.example.heychatgptassist.ASSISTANT_POPUP_OPENED";\n'
    '    public static final String ACTION_ASSISTANT_POPUP_CLOSED =\n'
    '            "com.example.heychatgptassist.ASSISTANT_POPUP_CLOSED";', 1)

runnable_anchor = '''    private final Runnable tempMaxSessionRunnable = () -> {
        if (!stopping && pausedForAssistant) {
            setStatus("Temporary Voice safety timeout — re-arming listener");
            rearmAfterTrigger();
        }
    };'''
if runnable_anchor not in s:
    raise SystemExit('timeout runnable anchor not found')
s = s.replace(runnable_anchor, runnable_anchor + '''
    private final Runnable assistantSessionTimeoutRunnable = () -> {
        if (!stopping && pausedForAssistant) {
            setStatus("Assistant session timeout — re-arming listener");
            rearmAfterTrigger();
        }
    };''', 1)

receive_anchor = '''            if (ACTION_TEMP_VOICE_STARTED.equals(action)) {'''
if receive_anchor not in s:
    raise SystemExit('receiver anchor not found')
new_branches = '''            if (ACTION_SIRI_FINISHED.equals(action)) {
                handler.removeCallbacks(assistantSessionTimeoutRunnable);
                setStatus("Siri text popup closed — re-arming listener");
                rearmAfterTrigger();
            } else if (ACTION_ASSISTANT_POPUP_OPENED.equals(action)) {
                if (pausedForAssistant) {
                    setStatus("ChatGPT assistant active — wake microphone paused");
                }
            } else if (ACTION_ASSISTANT_POPUP_CLOSED.equals(action)) {
                if (pausedForAssistant) {
                    handler.removeCallbacks(assistantSessionTimeoutRunnable);
                    setStatus("ChatGPT assistant closed — re-arming listener");
                    rearmAfterTrigger();
                }
            } else if (ACTION_TEMP_VOICE_STARTED.equals(action)) {'''
s = s.replace(receive_anchor, new_branches, 1)

filter_anchor = '''        filter.addAction(ACTION_TEMP_VOICE_FINISHED);'''
if filter_anchor not in s:
    raise SystemExit('receiver filter anchor not found')
s = s.replace(filter_anchor, filter_anchor + '''
        filter.addAction(ACTION_SIRI_FINISHED);
        filter.addAction(ACTION_ASSISTANT_POPUP_OPENED);
        filter.addAction(ACTION_ASSISTANT_POPUP_CLOSED);''', 1)

start_anchor = '''        handler.removeCallbacks(tempMaxSessionRunnable);'''
s = s.replace(start_anchor, start_anchor + '\n        handler.removeCallbacks(assistantSessionTimeoutRunnable);', 1)

temp_pref = '''    private boolean getTemporaryVoiceEnabled() {
        return prefs().getBoolean(MainActivity.KEY_TEMPORARY_VOICE_ENABLED, false);
    }'''
if temp_pref not in s:
    raise SystemExit('temporary preference method not found')
s = s.replace(temp_pref, temp_pref + '''

    private boolean getSiriModeEnabled() {
        return prefs().getBoolean(MainActivity.KEY_SIRI_MODE_ENABLED, false);
    }''', 1)

# Prevent 0 ms retry loops from churning the microphone / Samsung sounds.
s = s.replace('''    private int getRestartDelayMs() {
        return getIntPref(MainActivity.KEY_RESTART_DELAY_MS,
                MainActivity.DEFAULT_RESTART_DELAY_MS, MainActivity.MAX_RESTART_DELAY_MS);
    }''', '''    private int getRestartDelayMs() {
        return Math.max(100, getIntPref(MainActivity.KEY_RESTART_DELAY_MS,
                MainActivity.DEFAULT_RESTART_DELAY_MS, MainActivity.MAX_RESTART_DELAY_MS));
    }''', 1)
s = s.replace('''    private int getBusyRetryDelayMs() {
        return getIntPref(MainActivity.KEY_BUSY_RETRY_DELAY_MS,
                MainActivity.DEFAULT_BUSY_RETRY_DELAY_MS, MainActivity.MAX_BUSY_RETRY_DELAY_MS);
    }''', '''    private int getBusyRetryDelayMs() {
        return Math.max(100, getIntPref(MainActivity.KEY_BUSY_RETRY_DELAY_MS,
                MainActivity.DEFAULT_BUSY_RETRY_DELAY_MS, MainActivity.MAX_BUSY_RETRY_DELAY_MS));
    }''', 1)
s = s.replace('''    private int getRateLimitRetryDelayMs() {
        return getIntPref(MainActivity.KEY_RATE_LIMIT_RETRY_DELAY_MS,
                MainActivity.DEFAULT_RATE_LIMIT_RETRY_DELAY_MS, MainActivity.MAX_RATE_LIMIT_RETRY_DELAY_MS);
    }''', '''    private int getRateLimitRetryDelayMs() {
        return Math.max(250, getIntPref(MainActivity.KEY_RATE_LIMIT_RETRY_DELAY_MS,
                MainActivity.DEFAULT_RATE_LIMIT_RETRY_DELAY_MS, MainActivity.MAX_RATE_LIMIT_RETRY_DELAY_MS));
    }''', 1)

old_handle = '''        if (hasWakePhrase(list)) {
            triggerAssistant();
        } else if (restartWhenNoMatch && !pausedForAssistant && !stopping) {'''
if old_handle not in s:
    raise SystemExit('recognition trigger block not found')
s = s.replace(old_handle, '''        if (hasWakePhrase(list)) {
            triggerAssistant(firstResult(list));
        } else if (restartWhenNoMatch && !pausedForAssistant && !stopping) {''', 1)

old_trigger = '''    private void triggerAssistant() {
        if (pausedForAssistant || stopping) return;
        if (getTemporaryVoiceEnabled()) triggerTemporaryVoice();
        else triggerNormalAssistant();
    }'''
if old_trigger not in s:
    raise SystemExit('triggerAssistant block not found')
new_trigger = '''    private void triggerAssistant(String heard) {
        if (pausedForAssistant || stopping) return;
        if (getSiriModeEnabled()) triggerSiriMode(extractQueryAfterWakePhrase(heard));
        else triggerNormalAssistant();
    }

    private String extractQueryAfterWakePhrase(String heard) {
        if (heard == null) return "";
        String wake = getWakePhrase();
        if (wake == null || wake.trim().isEmpty()) return "";
        String lowerHeard = heard.toLowerCase(Locale.US);
        String lowerWake = wake.toLowerCase(Locale.US).trim();
        int index = lowerHeard.indexOf(lowerWake);
        if (index < 0) return "";
        int start = Math.min(heard.length(), index + wake.length());
        String rest = heard.substring(start).trim();
        return rest.replaceFirst("^[\\s,.:;!?-]+", "").trim();
    }

    private void triggerSiriMode(String query) {
        beginAssistantPause();
        handler.removeCallbacks(assistantSessionTimeoutRunnable);
        handler.postDelayed(assistantSessionTimeoutRunnable, 2L * 60L * 1000L);
        setStatus("Siri text mode — opening response popup");
        try {
            Intent open = new Intent(this, SiriModeActivity.class);
            open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            if (query != null && !query.trim().isEmpty()) {
                open.putExtra(SiriModeActivity.EXTRA_QUERY, query.trim());
            }
            startActivity(open);
        } catch (Throwable t) {
            setStatus("Could not open Siri text popup — re-arming listener");
            rearmAfterTrigger();
        }
    }'''
s = s.replace(old_trigger, new_trigger, 1)

old_rearm_schedule = '''        if (rearmDelayMs <= 0) handler.post(rearmRunnable);
        else handler.postDelayed(rearmRunnable, rearmDelayMs);'''
if old_rearm_schedule not in s:
    raise SystemExit('normal assistant rearm schedule not found')
s = s.replace(old_rearm_schedule, '''        handler.removeCallbacks(assistantSessionTimeoutRunnable);
        handler.postDelayed(assistantSessionTimeoutRunnable, 2L * 60L * 1000L);''', 1)

rearm_anchor = '''        handler.removeCallbacks(tempMaxSessionRunnable);
        pausedForAssistant = false;'''
if rearm_anchor not in s:
    raise SystemExit('rearm anchor not found')
s = s.replace(rearm_anchor, '''        handler.removeCallbacks(tempMaxSessionRunnable);
        handler.removeCallbacks(assistantSessionTimeoutRunnable);
        pausedForAssistant = false;''', 1)

old_partial = '''    @Override public void onPartialResults(Bundle partialResults) {
        handleRecognitionBundle(partialResults, false);
    }'''
if old_partial not in s:
    raise SystemExit('partial results method not found')
s = s.replace(old_partial, '''    @Override public void onPartialResults(Bundle partialResults) {
        if (getSiriModeEnabled()) {
            if (partialResults != null) {
                ArrayList<String> list = partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
                rememberHeard(list);
            }
        } else {
            handleRecognitionBundle(partialResults, false);
        }
    }''', 1)

p.write_text(s)

# Main UI: replace unreliable accessibility text scraping with explicit Siri/API mode.
p = Path('app/src/main/java/com/example/heychatgptassist/MainActivity.java')
s = p.read_text()

const_anchor = '    public static final String KEY_TEMPORARY_VOICE_ENABLED = "temporary_voice_enabled";'
if const_anchor not in s:
    raise SystemExit('MainActivity preference anchor not found')
s = s.replace(const_anchor, const_anchor + '''
    public static final String KEY_SIRI_MODE_ENABLED = "siri_mode_enabled";
    public static final String KEY_OPENAI_API_KEY = "openai_api_key";''', 1)

field_anchor = '    private CheckBox temporaryVoiceToggle;'
if field_anchor not in s:
    raise SystemExit('MainActivity field anchor not found')
s = s.replace(field_anchor, field_anchor + '''
    private CheckBox siriModeToggle;
    private EditText apiKeyInput;''', 1)

s = s.replace('Hey ChatGPT Assist v1.3', 'Hey ChatGPT Assist v1.8')
s = s.replace(
    'Always-listening assistant with smoother microphone handling, optional response text, and an experimental Temporary Voice mode that keeps finished Voice chats out of normal history.',
    'Always-listening assistant with the original ChatGPT popup plus an optional Siri-style API mode that shows the real answer as text and speaks it.')

shizuku_anchor = '        Shizuku.addRequestPermissionResultListener(shizukuPermissionListener);\n'
if shizuku_anchor in s:
    s = s.replace(shizuku_anchor, shizuku_anchor +
        '        prefs().edit().putBoolean(KEY_TEMPORARY_VOICE_ENABLED, false).apply();\n', 1)

start = s.find('        addHeading(root, "Siri-style response text", 20);')
end = s.find('        addHeading(root, "Temporary Voice", 20);')
if start < 0 or end < 0 or end <= start:
    raise SystemExit('response text UI section not found')
new_section = '''        addHeading(root, "Siri text mode", 20);
        addNote(root, "When ON, the wake phrase opens our small Siri-style popup instead of the official ChatGPT assistant popup. It listens for your question, sends it to the OpenAI Responses API using GPT-5.6 Luna, shows the exact answer only inside that popup, and reads it aloud with Android text-to-speech. These API conversations do not appear in your normal ChatGPT chat history. API usage is billed separately from ChatGPT Plus.");
        siriModeToggle = new CheckBox(this);
        siriModeToggle.setText("Use Siri text mode for wake phrase");
        siriModeToggle.setChecked(prefs().getBoolean(KEY_SIRI_MODE_ENABLED, false));
        siriModeToggle.setOnCheckedChangeListener((buttonView, checked) -> {
            prefs().edit().putBoolean(KEY_SIRI_MODE_ENABLED, checked).apply();
            updateCompanionStatus();
        });
        root.addView(siriModeToggle);

        apiKeyInput = new EditText(this);
        apiKeyInput.setSingleLine(true);
        apiKeyInput.setHint("OpenAI API key (sk-…)");
        apiKeyInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        apiKeyInput.setText(prefs().getString(KEY_OPENAI_API_KEY, ""));
        root.addView(apiKeyInput, fullWidth());
        addButton(root, "SAVE SIRI MODE / API KEY", v -> {
            String key = apiKeyInput.getText().toString().trim();
            prefs().edit()
                    .putBoolean(KEY_SIRI_MODE_ENABLED, siriModeToggle.isChecked())
                    .putString(KEY_OPENAI_API_KEY, key)
                    .apply();
            Toast.makeText(this, key.isEmpty() ? "Siri mode saved — API key is missing" : "Siri mode and API key saved", Toast.LENGTH_SHORT).show();
            updateCompanionStatus();
        });

        companionStatus = new TextView(this);
        companionStatus.setTextSize(14);
        root.addView(companionStatus);

'''
s = s[:start] + new_section + s[end:]

s = s.replace('        temporaryVoiceToggle.setText("Always use Temporary Chat for wake-phrase Voice");',
              '        temporaryVoiceToggle.setText("Automatic Temporary Chat unavailable with assistant popup");')
s = s.replace('        temporaryVoiceToggle.setChecked(prefs().getBoolean(KEY_TEMPORARY_VOICE_ENABLED, false));',
              '        temporaryVoiceToggle.setChecked(false);\n        temporaryVoiceToggle.setEnabled(false);')
listener_pattern = re.compile(
    r'\n        temporaryVoiceToggle\.setOnCheckedChangeListener\(\(buttonView, checked\) -> \{\n'
    r'            prefs\(\)\.edit\(\)\.putBoolean\(KEY_TEMPORARY_VOICE_ENABLED, checked\)\.apply\(\);\n'
    r'            updateTemporaryVoiceStatus\(\);\n'
    r'        \}\);')
s = listener_pattern.sub('', s, count=1)
s = s.replace(
    'When enabled, saying the wake phrase opens ChatGPT, starts a fresh Temporary chat, and then starts Voice. It uses the same Accessibility companion. Voice is not started unless the helper reaches the Temporary control first. This mode opens the ChatGPT app rather than the small Android assistant popup because ChatGPT does not expose a supported Temporary-mode flag for that popup.',
    'Automatic Temporary Chat stays disabled because it requires opening the full ChatGPT app. Siri text mode is already history-free on the ChatGPT side because it uses the separate API rather than creating a ChatGPT app conversation.')
s = s.replace(
    'One-time setup: turn on ‘Hey ChatGPT Assist response text’ in Accessibility. That same service handles both response-text mirroring and Temporary Voice automation.',
    'For NORMAL mode only: keep ‘Hey ChatGPT Assist response text’ enabled in Accessibility. v1.8 no longer reads or displays response text from Accessibility; it only detects when the real ChatGPT assistant popup closes so the wake microphone can resume cleanly. Siri text mode does not need Accessibility for its answer text.')
s = s.replace(
    'Normal mode keeps the side-button-style Android assistant behavior. Temporary Voice is separate and only takes over the wake action while its toggle is enabled.',
    'Normal mode keeps the original Side-button-style ChatGPT assistant popup. Siri text mode uses our own popup with API answer text and Android speech. No legacy accessibility text overlay is shown.')

method_pattern = re.compile(
    r'    private void updateCompanionStatus\(\) \{.*?\n    \}\n\n    private void updateTemporaryVoiceStatus\(\)',
    re.S)
replacement = '''    private void updateCompanionStatus() {
        if (companionStatus == null) return;
        boolean siri = prefs().getBoolean(KEY_SIRI_MODE_ENABLED, false);
        boolean hasKey = !prefs().getString(KEY_OPENAI_API_KEY, "").trim().isEmpty();
        boolean accessibility = isCompanionAccessibilityEnabled();
        companionStatus.setText("Siri text mode: " + (siri ? "ON" : "OFF") +
                " | API key: " + (hasKey ? "saved" : "missing") +
                "\\nNormal-popup detector: " + (accessibility ? "enabled" : "needs Accessibility setup"));
    }

    private void updateTemporaryVoiceStatus()'''
# Use a function replacement so re.sub does not reinterpret the Java "\\n"
# escape as a literal newline inside the generated Java string.
s, count = method_pattern.subn(lambda _m: replacement, s, count=1)
if count != 1:
    raise SystemExit('updateCompanionStatus method not found')

p.write_text(s)

# Manifest: API networking + translucent Siri popup activity.
p = Path('app/src/main/AndroidManifest.xml')
s = p.read_text()
if 'android.permission.INTERNET' not in s:
    s = s.replace('    <uses-permission android:name="android.permission.RECORD_AUDIO" />',
                  '    <uses-permission android:name="android.permission.INTERNET" />\n    <uses-permission android:name="android.permission.RECORD_AUDIO" />', 1)
activity_anchor = '''        <activity
            android:name=".MainActivity"'''
if activity_anchor not in s:
    raise SystemExit('manifest activity anchor not found')
s = s.replace(activity_anchor, '''        <activity
            android:name=".SiriModeActivity"
            android:exported="false"
            android:excludeFromRecents="true"
            android:theme="@style/SiriPopupTheme" />

        <activity
            android:name=".MainActivity"''', 1)
p.write_text(s)

# Accessibility is now only a popup lifecycle detector.
p = Path('app/src/main/res/xml/accessibility_service_config.xml')
p.write_text('''<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:description="@string/accessibility_description"
    android:accessibilityEventTypes="typeWindowStateChanged|typeWindowContentChanged|typeWindowsChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:notificationTimeout="80"
    android:canRetrieveWindowContent="true"
    android:accessibilityFlags="flagDefault|flagIncludeNotImportantViews|flagReportViewIds|flagRetrieveInteractiveWindows" />
''')

# Transparent popup theme.
p = Path('app/src/main/res/values/styles.xml')
s = p.read_text()
if 'SiriPopupTheme' not in s:
    s = s.replace('</resources>', '''    <style name="SiriPopupTheme" parent="android:style/Theme.Material.NoActionBar">
        <item name="android:windowIsTranslucent">true</item>
        <item name="android:windowBackground">@android:color/transparent</item>
        <item name="android:windowNoTitle">true</item>
        <item name="android:backgroundDimEnabled">false</item>
        <item name="android:windowDisablePreview">true</item>
    </style>
</resources>''')
p.write_text(s)

p = Path('app/build.gradle')
s = p.read_text()
if 'versionCode 13' not in s or 'versionName "1.3"' not in s:
    raise SystemExit('Expected baseline v1.3 version fields not found')
s = s.replace('versionCode 13', 'versionCode 18', 1)
s = s.replace('versionName "1.3"', 'versionName "1.8"', 1)
p.write_text(s)
