package com.example.heychatgptassist;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.graphics.Typeface;
import android.text.InputType;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import rikka.shizuku.Shizuku;

public class MainActivity extends Activity {
    private static final int REQ_MIC = 100;
    private static final int REQ_SHIZUKU = 200;

    public static final String PREFS = "hey_chatgpt_prefs";
    public static final String KEY_WAKE_PHRASE = "wake_phrase";
    public static final String DEFAULT_WAKE_PHRASE = "Hey ChatGPT";
    public static final String KEY_ASSIST_KEYCODE = "assist_keycode";
    public static final int DEFAULT_ASSIST_KEYCODE = 231;

    public static final String KEY_TRIGGER_DELAY_MS = "trigger_delay_ms";
    public static final int DEFAULT_TRIGGER_DELAY_MS = 100;
    public static final int MAX_TRIGGER_DELAY_MS = 1000;

    public static final String KEY_REARM_DELAY_MS = "rearm_delay_ms";
    public static final int DEFAULT_REARM_DELAY_MS = 500;
    public static final int MAX_REARM_DELAY_MS = 5000;

    private TextView status;
    private TextView diagnostics;
    private TextView shizukuStatus;
    private TextView selectedKey;
    private EditText phraseInput;
    private EditText delayInput;
    private EditText rearmInput;

    private final Handler uiHandler = new Handler(Looper.getMainLooper());
    private final Runnable diagnosticUpdater = new Runnable() {
        @Override public void run() {
            updateDiagnostics();
            updateShizukuStatus();
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

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(40, 32, 40, 64);
        root.setGravity(Gravity.TOP);
        scroll.addView(root, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView title = new TextView(this);
        title.setText("Hey ChatGPT Assist v0.8");
        title.setTextSize(25);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(title);

        TextView desc = new TextView(this);
        desc.setText("\nAlways-listening mode. The old 45-second post-trigger pause is removed. After opening ChatGPT, the listener automatically re-arms and keeps retrying if Android temporarily reports the microphone/recognizer as busy.");
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
        savePhrase.setText("Save activation phrase");
        savePhrase.setOnClickListener(v -> saveWakePhrase());
        root.addView(savePhrase);

        TextView delayLabel = new TextView(this);
        delayLabel.setText("\nAssistant trigger delay (milliseconds):");
        delayLabel.setTextSize(16);
        delayLabel.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(delayLabel);

        delayInput = new EditText(this);
        delayInput.setSingleLine(true);
        delayInput.setInputType(InputType.TYPE_CLASS_NUMBER);
        delayInput.setHint("0 to 1000");
        delayInput.setText(String.valueOf(getTriggerDelayMs()));
        root.addView(delayInput, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView delayHelp = new TextView(this);
        delayHelp.setText("0 = fastest. Default = 100 ms. Allowed range: 0–1000 ms.");
        delayHelp.setTextSize(13);
        root.addView(delayHelp);

        Button saveDelay = new Button(this);
        saveDelay.setText("Save trigger delay");
        saveDelay.setOnClickListener(v -> saveTriggerDelay());
        root.addView(saveDelay);

        TextView rearmLabel = new TextView(this);
        rearmLabel.setText("\nRe-arm delay after opening assistant (milliseconds):");
        rearmLabel.setTextSize(16);
        rearmLabel.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(rearmLabel);

        rearmInput = new EditText(this);
        rearmInput.setSingleLine(true);
        rearmInput.setInputType(InputType.TYPE_CLASS_NUMBER);
        rearmInput.setHint("0 to 5000");
        rearmInput.setText(String.valueOf(getRearmDelayMs()));
        root.addView(rearmInput, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView rearmHelp = new TextView(this);
        rearmHelp.setText("How quickly the wake listener starts trying again after a trigger. Default = 500 ms. 0 = immediate. If ChatGPT has trouble hearing you, raise this a little.");
        rearmHelp.setTextSize(13);
        root.addView(rearmHelp);

        Button saveRearm = new Button(this);
        saveRearm.setText("Save re-arm delay");
        saveRearm.setOnClickListener(v -> saveRearmDelay());
        root.addView(saveRearm);

        Button start = new Button(this);
        start.setText("START ALWAYS LISTENING");
        start.setOnClickListener(v -> {
            saveWakePhrase();
            saveTriggerDelay();
            saveRearmDelay();
            requestAndStart();
        });
        root.addView(start);

        Button stop = new Button(this);
        stop.setText("Stop voice listening");
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
        grantShizuku.setText("Grant / check Shizuku permission");
        grantShizuku.setOnClickListener(v -> requestShizukuPermission());
        root.addView(grantShizuku);

        Button test219 = new Button(this);
        test219.setText("TEST ASSIST KEY 219");
        test219.setOnClickListener(v -> testKey(219));
        root.addView(test219);

        Button use219 = new Button(this);
        use219.setText("Use key 219");
        use219.setOnClickListener(v -> setSelectedKey(219));
        root.addView(use219);

        Button test231 = new Button(this);
        test231.setText("TEST VOICE ASSIST KEY 231");
        test231.setOnClickListener(v -> testKey(231));
        root.addView(test231);

        Button use231 = new Button(this);
        use231.setText("Use key 231");
        use231.setOnClickListener(v -> setSelectedKey(231));
        root.addView(use231);

        Button openShizuku = new Button(this);
        openShizuku.setText("Open Shizuku");
        openShizuku.setOnClickListener(v -> openShizuku());
        root.addView(openShizuku);

        TextView note = new TextView(this);
        note.setText("\nAlways-listening mode keeps the foreground listener service alive and automatically restarts speech recognition after normal timeouts, no-match results, and temporary busy errors. Android can still temporarily reserve the microphone for another app; when that happens this app keeps retrying automatically instead of waiting 45 seconds.\n\nYour trigger and re-arm delay settings are saved permanently.");
        note.setTextSize(13);
        root.addView(note);

        setContentView(scroll);
        updateDiagnostics();
        updateShizukuStatus();
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

    private void saveWakePhrase() {
        String phrase = phraseInput.getText().toString().trim();
        if (phrase.isEmpty()) phrase = DEFAULT_WAKE_PHRASE;
        phraseInput.setText(phrase);
        getSharedPreferences(PREFS, MODE_PRIVATE)
                .edit().putString(KEY_WAKE_PHRASE, phrase).apply();
        Toast.makeText(this, "Activation phrase saved: " + phrase, Toast.LENGTH_SHORT).show();
    }

    private int getTriggerDelayMs() {
        int value = getSharedPreferences(PREFS, MODE_PRIVATE)
                .getInt(KEY_TRIGGER_DELAY_MS, DEFAULT_TRIGGER_DELAY_MS);
        return Math.max(0, Math.min(MAX_TRIGGER_DELAY_MS, value));
    }

    private void saveTriggerDelay() {
        int value = DEFAULT_TRIGGER_DELAY_MS;
        try {
            String raw = delayInput.getText().toString().trim();
            if (!raw.isEmpty()) value = Integer.parseInt(raw);
        } catch (NumberFormatException ignored) {}

        value = Math.max(0, Math.min(MAX_TRIGGER_DELAY_MS, value));
        delayInput.setText(String.valueOf(value));
        getSharedPreferences(PREFS, MODE_PRIVATE)
                .edit().putInt(KEY_TRIGGER_DELAY_MS, value).apply();
        Toast.makeText(this, "Trigger delay saved: " + value + " ms", Toast.LENGTH_SHORT).show();
    }

    private int getRearmDelayMs() {
        int value = getSharedPreferences(PREFS, MODE_PRIVATE)
                .getInt(KEY_REARM_DELAY_MS, DEFAULT_REARM_DELAY_MS);
        return Math.max(0, Math.min(MAX_REARM_DELAY_MS, value));
    }

    private void saveRearmDelay() {
        int value = DEFAULT_REARM_DELAY_MS;
        try {
            String raw = rearmInput.getText().toString().trim();
            if (!raw.isEmpty()) value = Integer.parseInt(raw);
        } catch (NumberFormatException ignored) {}

        value = Math.max(0, Math.min(MAX_REARM_DELAY_MS, value));
        rearmInput.setText(String.valueOf(value));
        getSharedPreferences(PREFS, MODE_PRIVATE)
                .edit().putInt(KEY_REARM_DELAY_MS, value).apply();
        Toast.makeText(this, "Re-arm delay saved: " + value + " ms", Toast.LENGTH_SHORT).show();
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
        status.setText("Status: always listening for ‘" + getWakePhrase() + "’ — trigger " + getTriggerDelayMs() + " ms, re-arm " + getRearmDelayMs() + " ms");
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_MIC && grantResults.length > 0 &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            requestAndStart();
        }
    }
}
