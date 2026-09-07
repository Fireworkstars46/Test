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
        root.setPadding(48, 56, 48, 48);
        root.setGravity(Gravity.TOP);

        TextView title = new TextView(this);
        title.setText("Hey ChatGPT Assist");
        title.setTextSize(26);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(title, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView desc = new TextView(this);
        desc.setText("\nChoose any wake phrase you want. When the app hears it, " +
                "it releases the microphone and asks Android to launch your current default digital assistant.\n\n" +
                "Set ChatGPT as your default Digital assistant first.");
        desc.setTextSize(17);
        root.addView(desc);

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
        start.setText("Start listening");
        start.setOnClickListener(v -> {
            saveWakePhrase();
            requestAndStart();
        });
        root.addView(start);

        Button stop = new Button(this);
        stop.setText("Stop listening");
        stop.setOnClickListener(v -> {
            stopService(new Intent(this, WakeListenerService.class));
            status.setText("\nStatus: stopped\n");
        });
        root.addView(stop);

        Button test = new Button(this);
        test.setText("Test default assistant");
        test.setOnClickListener(v -> launchAssistant());
        root.addView(test);

        Button defaults = new Button(this);
        defaults.setText("Open default assistant settings");
        defaults.setOnClickListener(v -> {
            try {
                startActivity(new Intent(Settings.ACTION_VOICE_INPUT_SETTINGS));
            } catch (Exception e) {
                startActivity(new Intent(Settings.ACTION_SETTINGS));
            }
        });
        root.addView(defaults);

        TextView note = new TextView(this);
        note.setText("\nNotes:\n• Your custom phrase is saved on the phone.\n" +
                "• Android shows a microphone/privacy indicator while listening.\n" +
                "• Keep the persistent notification enabled.\n" +
                "• After triggering, listening pauses for 45 seconds so ChatGPT Voice can use the microphone.\n" +
                "• Active Discord/phone calls may prevent the wake listener or ChatGPT Voice from using the microphone.");
        note.setTextSize(15);
        root.addView(note);

        setContentView(root);
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
                .edit()
                .putString(KEY_WAKE_PHRASE, phrase)
                .apply();
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
        status.setText("\nStatus: listening for “" + getWakePhrase() + "”\n");
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_MIC) {
            requestAndStart();
        }
    }

    private void launchAssistant() {
        try {
            Intent assist = new Intent(Intent.ACTION_ASSIST);
            assist.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(assist);
        } catch (Exception e) {
            status.setText("\nCould not launch the default assistant: " + e.getClass().getSimpleName() + "\n");
        }
    }
}
