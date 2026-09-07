package com.example.heychatgptassist;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
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
        desc.setText("\nThis version uses Android Accessibility's system ‘Show Assistant’ action so it behaves more like your assistant button.\n\n" +
                "1. Keep ChatGPT selected as your default Digital assistant.\n" +
                "2. Enable Hey ChatGPT Assist under Accessibility.\n" +
                "3. Test the assistant button below before starting voice listening.");
        desc.setTextSize(16);
        root.addView(desc);

        Button accessibility = new Button(this);
        accessibility.setText("Open Accessibility settings");
        accessibility.setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        root.addView(accessibility);

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

        Button test = new Button(this);
        test.setText("TEST SYSTEM ASSISTANT");
        test.setOnClickListener(v -> testAssistant());
        root.addView(test);

        Button start = new Button(this);
        start.setText("Start voice listening");
        start.setOnClickListener(v -> {
            saveWakePhrase();
            if (!AssistantAccessibilityService.isConnected()) {
                status.setText("\nAccessibility service is not enabled yet. Tap Open Accessibility settings first.\n");
                return;
            }
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
        note.setText("\nPrivacy: the Accessibility service does not read screen content or type anything. It is used only for Android's global Show Assistant command. " +
                "The microphone listener is separate and can be stopped at any time.\n\n" +
                "After a wake phrase is detected, this app releases the mic before showing ChatGPT so ChatGPT Voice can take it.");
        note.setTextSize(14);
        root.addView(note);

        setContentView(root);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (status != null && AssistantAccessibilityService.isConnected()) {
            status.setText("\nAccessibility assistant trigger: ready\n");
        }
    }

    private void testAssistant() {
        if (!AssistantAccessibilityService.isConnected()) {
            status.setText("\nEnable Hey ChatGPT Assist in Accessibility first, then return and test again.\n");
            return;
        }
        boolean ok = AssistantAccessibilityService.showAssistant();
        status.setText(ok ? "\nAssistant action sent. ChatGPT should appear.\n"
                          : "\nAndroid did not accept the Show Assistant action.\n");
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
