package com.example.heychatgptassist;

import android.app.*;
import android.content.*;
import android.os.*;
import android.speech.*;
import java.util.*;

public class WakeListenerService extends Service implements RecognitionListener {
    private static final String CHANNEL = "wake_listener";
    private static final int NOTIFICATION_ID = 46;
    private static final long RESTART_DELAY_MS = 700;
    private static final long PAUSE_AFTER_TRIGGER_MS = 45000;

    private SpeechRecognizer recognizer;
    private Intent recognizerIntent;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean stopping = false;
    private boolean pausedForAssistant = false;

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
        startForeground(NOTIFICATION_ID, notification("Starting listener…"));
        setupRecognizer();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        stopping = false;
        pausedForAssistant = false;
        updateNotification("Listening for “" + getWakePhrase() + "”");
        startListeningSoon(200);
        return START_STICKY;
    }

    private String getWakePhrase() {
        return getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .getString(MainActivity.KEY_WAKE_PHRASE, MainActivity.DEFAULT_WAKE_PHRASE)
                .trim();
    }

    private String normalize(String s) {
        if (s == null) return "";
        return s.toLowerCase(Locale.US)
                .replace("-", " ")
                .replace("_", " ")
                .replaceAll("[^a-z0-9 ]", " ")
                .replaceAll("\\s+", " ")
                .trim();
    }

    private void setupRecognizer() {
        if (recognizer != null) {
            recognizer.destroy();
            recognizer = null;
        }

        try {
            if (Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) {
                recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(this);
            } else {
                recognizer = SpeechRecognizer.createSpeechRecognizer(this);
            }
        } catch (Throwable t) {
            recognizer = SpeechRecognizer.createSpeechRecognizer(this);
        }

        recognizer.setRecognitionListener(this);

        recognizerIntent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5);
    }

    private void startListeningSoon(long delayMs) {
        handler.removeCallbacksAndMessages(null);
        handler.postDelayed(() -> {
            if (stopping || pausedForAssistant) return;
            try {
                recognizer.startListening(recognizerIntent);
                updateNotification("Listening for “" + getWakePhrase() + "”");
            } catch (Throwable t) {
                setupRecognizer();
                startListeningSoon(1500);
            }
        }, delayMs);
    }

    private boolean hasWakePhrase(ArrayList<String> results) {
        if (results == null) return false;

        String target = normalize(getWakePhrase());
        if (target.isEmpty()) return false;

        for (String s : results) {
            String heard = normalize(s);
            if (heard.equals(target) || heard.contains(target)) {
                return true;
            }
        }
        return false;
    }

    private void triggerAssistant() {
        if (pausedForAssistant) return;
        pausedForAssistant = true;
        updateNotification("Activation phrase heard — opening assistant");

        try { recognizer.cancel(); } catch (Throwable ignored) {}
        try { recognizer.destroy(); } catch (Throwable ignored) {}
        recognizer = null;

        handler.postDelayed(() -> {
            boolean ok = AssistantAccessibilityService.showAssistant();
            if (!ok) {
                updateNotification("Enable Accessibility service, then test again");
            }
        }, 450);

        handler.postDelayed(() -> {
            if (stopping) return;
            pausedForAssistant = false;
            setupRecognizer();
            startListeningSoon(500);
        }, PAUSE_AFTER_TRIGGER_MS);
    }

    @Override public void onPartialResults(Bundle partialResults) {
        ArrayList<String> list = partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        if (hasWakePhrase(list)) triggerAssistant();
    }

    @Override public void onResults(Bundle results) {
        ArrayList<String> list = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        if (hasWakePhrase(list)) {
            triggerAssistant();
        } else if (!pausedForAssistant) {
            startListeningSoon(RESTART_DELAY_MS);
        }
    }

    @Override public void onError(int error) {
        if (!stopping && !pausedForAssistant) {
            if (error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY) {
                setupRecognizer();
                startListeningSoon(1200);
            } else {
                startListeningSoon(RESTART_DELAY_MS);
            }
        }
    }

    @Override public void onReadyForSpeech(Bundle params) {}
    @Override public void onBeginningOfSpeech() {}
    @Override public void onRmsChanged(float rmsdB) {}
    @Override public void onBufferReceived(byte[] buffer) {}
    @Override public void onEndOfSpeech() {}
    @Override public void onEvent(int eventType, Bundle params) {}

    private void createChannel() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        NotificationChannel ch = new NotificationChannel(
                CHANNEL, "Custom assistant wake listener", NotificationManager.IMPORTANCE_LOW);
        ch.setDescription("Keeps the custom activation phrase listener active");
        nm.createNotificationChannel(ch);
    }

    private Notification notification(String text) {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(
                this, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);

        return new Notification.Builder(this, CHANNEL)
                .setContentTitle("Hey ChatGPT Assist")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setOngoing(true)
                .setContentIntent(pi)
                .build();
    }

    private void updateNotification(String text) {
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.notify(NOTIFICATION_ID, notification(text));
    }

    @Override
    public void onDestroy() {
        stopping = true;
        handler.removeCallbacksAndMessages(null);
        if (recognizer != null) {
            try { recognizer.cancel(); } catch (Throwable ignored) {}
            try { recognizer.destroy(); } catch (Throwable ignored) {}
        }
        super.onDestroy();
    }

    @Override
    public android.os.IBinder onBind(Intent intent) {
        return null;
    }
}
