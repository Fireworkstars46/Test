package com.example.heychatgptassist;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.graphics.Typeface;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

public class MainActivity extends Activity {
    private static final int REQ_MIC = 100;
    public static final String PREFS = "hey_chatgpt_prefs";
    public static final String KEY_WAKE_PHRASE = "wake_phrase";
    public static final String DEFAULT_WAKE_PHRASE = "Hey ChatGPT";

    private TextView status;
    private EditText phraseInput;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(48, 48, 48, 48);
        root.setGravity(Gravity.TOP);

        TextView title = new TextView(this);
        title.setText("Hey ChatGPT Assist");
        title.setTextSize(26);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(title, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView desc = new TextView(this);
        desc.setText("\nThis version launches ChatGPT's own assistant/voice activity directly — the same internal assistant screen used by Android assistant shortcuts.\n\n" +
                "FIRST TEST: keep ChatGPT selected as your default Digital assistant, then tap TEST CHATGPT ASSISTANT below. No voice listener is needed for this first test.");
        desc.setTextSize(16);
        root.addView(desc);

        Button test = new Button(this);
        test.setText("TEST CHATGPT ASSISTANT");
        test.setOnClickListener(v -> testAssistant());
        root.addView(test);

        Button overlay = new Button(this);
        overlay.setText("Allow appear on top (for hands-free mode)");
        overlay.setOnClickListener(v -> openOverlaySettings());
        root.addView(overlay);

        TextView label = new TextView(this);
        label.setText("\nCustom activation phrase:");
        label.setTextSize(16);
        label.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(label);

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

        status = new TextView(this);
        status.setText("\nStatus: stopped\n");
        status.setTextSize(17);
        root.addView(status);

        Button start = new Button(this);
        start.setText("Start voice listening");
        start.setOnClickListener(v -> {
            saveWakePhrase();
            requestAndStart();
        });
        root.addView(start);

        Button stop = new Button(this);
        stop.setText("Stop voice listening");
        stop.setOnClickListener(v -> {
            stopService(new Intent(this, WakeListenerService.class));
            status.setText("\nStatus: stopped\n");
        });
        root.addView(stop);

        TextView note = new TextView(this);
        note.setText("\nFor the voice wake test, Android may require ‘Appear on top’ so a background listener is allowed to bring up ChatGPT. " +
                "The listener releases its microphone before launching ChatGPT Voice.\n\n" +
                "If TEST CHATGPT ASSISTANT does not show ChatGPT, tell me exactly what appears or sounds before testing the wake phrase.");
        note.setTextSize(14);
        root.addView(note);

        setContentView(root);
    }

    private void testAssistant() {
        boolean ok = AssistantAccessibilityService.showAssistant(this);
        status.setText(ok ? "\nLaunch sent to ChatGPT assistant.\n"
                          : "\nCould not launch the ChatGPT assistant activity.\n");
    }

    private void openOverlaySettings() {
        try {
            Intent intent = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:" + getPackageName()));
            startActivity(intent);
        } catch (Throwable e) {
            startActivity(new Intent(Settings.ACTION_SETTINGS));
        }
    }

    private String getWakePhrase() {
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        return prefs.getString(KEY_WAKE_PHRASE, DEFAULT_WAKE_PHRASE);
    }

    private void saveWakePhrase() {
        String phrase = phraseInput.getText().toString().trim();
        if (phrase.isEmpty()) phrase = DEFAULT_WAKE_PHRASE;
        phraseInput.setText(phrase);
        getSharedPreferences(PREFS, MODE_PRIVATE)
                .edit().putString(KEY_WAKE_PHRASE, phrase).apply();
        Toast.makeText(this, "Activation phrase saved: " + phrase, Toast.LENGTH_SHORT).show();
    }

    private void requestAndStart() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQ_MIC);
            return;
        }
        if (Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_MIC);
            return;
        }
        Intent service = new Intent(this, WakeListenerService.class);
        startForegroundService(service);
        status.setText("\nStatus: listening for ‘" + getWakePhrase() + "’\n");
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_MIC) requestAndStart();
    }
}
