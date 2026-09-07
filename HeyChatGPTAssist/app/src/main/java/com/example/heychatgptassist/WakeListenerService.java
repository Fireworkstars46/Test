package com.example.heychatgptassist;

import android.app.*;
import android.content.*;
import android.os.*;
import android.speech.*;
import java.util.*;

public class WakeListenerService extends Service implements RecognitionListener {
    private static final String CHANNEL = "wake_listener_quiet_v06";
    private static final int NOTIFICATION_ID = 46;
    private static final long RESTART_DELAY_MS = 100;
    private static final long BUSY_RESTART_DELAY_MS = 500;

    public static final String KEY_LISTENER_STATUS = "listener_status";
    public static final String KEY_LAST_HEARD = "last_heard";

    private SpeechRecognizer recognizer;
    private Intent recognizerIntent;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable startRunnable = this::startListeningNow;
    private final Runnable rearmRunnable = this::rearmAfterTrigger;
    private boolean stopping = false;
    private boolean pausedForAssistant = false;

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
        startForeground(NOTIFICATION_ID, notification());
        setupRecognizer();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        stopping = false;
        pausedForAssistant = false;
        handler.removeCallbacks(rearmRunnable);
        handler.removeCallbacks(startRunnable);
        try { setupRecognizer(); } catch (Throwable ignored) {}
        setStatus("Always listening for ‘" + getWakePhrase() + "’");
        startListeningSoon(100);
        return START_STICKY;
    }

    private String getWakePhrase() {
        return getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .getString(MainActivity.KEY_WAKE_PHRASE, MainActivity.DEFAULT_WAKE_PHRASE)
                .trim();
    }

    private int getAssistKeyCode() {
        return getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .getInt(MainActivity.KEY_ASSIST_KEYCODE, MainActivity.DEFAULT_ASSIST_KEYCODE);
    }

    private int getTriggerDelayMs() {
        int value = getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .getInt(MainActivity.KEY_TRIGGER_DELAY_MS, MainActivity.DEFAULT_TRIGGER_DELAY_MS);
        return Math.max(0, Math.min(MainActivity.MAX_TRIGGER_DELAY_MS, value));
    }

    private int getRearmDelayMs() {
        int value = getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .getInt(MainActivity.KEY_REARM_DELAY_MS, MainActivity.DEFAULT_REARM_DELAY_MS);
        return Math.max(0, Math.min(MainActivity.MAX_REARM_DELAY_MS, value));
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
            try { recognizer.cancel(); } catch (Throwable ignored) {}
            try { recognizer.destroy(); } catch (Throwable ignored) {}
            recognizer = null;
        }

        recognizer = SpeechRecognizer.createSpeechRecognizer(this);
        recognizer.setRecognitionListener(this);

        recognizerIntent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 3500L);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1800L);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 500L);
    }

    private void startListeningSoon(long delayMs) {
        if (stopping || pausedForAssistant) return;
        handler.removeCallbacks(startRunnable);
        if (delayMs <= 0) handler.post(startRunnable);
        else handler.postDelayed(startRunnable, delayMs);
    }

    private void startListeningNow() {
        if (stopping || pausedForAssistant) return;
        try {
            if (recognizer == null) setupRecognizer();
            recognizer.startListening(recognizerIntent);
            setStatus("Always listening for ‘" + getWakePhrase() + "’");
        } catch (Throwable t) {
            // Never give up: rebuild the recognizer and keep retrying.
            try { setupRecognizer(); } catch (Throwable ignored) {}
            startListeningSoon(BUSY_RESTART_DELAY_MS);
        }
    }

    private boolean hasWakePhrase(ArrayList<String> results) {
        if (results == null) return false;
        String target = normalize(getWakePhrase());
        if (target.isEmpty()) return false;
        for (String s : results) {
            String heard = normalize(s);
            if (heard.equals(target) || heard.contains(target)) return true;
        }
        return false;
    }

    private String firstResult(ArrayList<String> results) {
        if (results == null || results.isEmpty() || results.get(0) == null) return "";
        return results.get(0).trim();
    }

    private void rememberHeard(ArrayList<String> results) {
        String heard = firstResult(results);
        if (heard.isEmpty()) return;
        getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .edit().putString(KEY_LAST_HEARD, heard).apply();
    }

    private void triggerAssistant() {
        if (pausedForAssistant || stopping) return;
        pausedForAssistant = true;

        final int keyCode = getAssistKeyCode();
        final int triggerDelayMs = getTriggerDelayMs();
        final int rearmDelayMs = getRearmDelayMs();

        setStatus("Activation phrase heard — opening assistant");

        handler.removeCallbacks(startRunnable);
        handler.removeCallbacks(rearmRunnable);

        if (recognizer != null) {
            try { recognizer.cancel(); } catch (Throwable ignored) {}
            try { recognizer.destroy(); } catch (Throwable ignored) {}
            recognizer = null;
        }

        new Thread(() -> {
            if (triggerDelayMs > 0) {
                try { Thread.sleep(triggerDelayMs); } catch (InterruptedException ignored) {}
            }

            ShizukuBridge.Result result = ShizukuBridge.sendKeyEvent(keyCode);
            handler.post(() -> {
                if (result.success) {
                    setStatus("Assistant opened — re-arming listener");
                } else {
                    setStatus("Wake phrase matched, but " + result.message + " — re-arming");
                }
            });
        }, "shizuku-wake-trigger").start();

        // v0.7 waited 45 seconds here. v0.8 always re-arms after the user's
        // short delay, then continuously retries if the recognizer/mic is busy.
        if (rearmDelayMs <= 0) handler.post(rearmRunnable);
        else handler.postDelayed(rearmRunnable, rearmDelayMs);
    }

    private void rearmAfterTrigger() {
        if (stopping) return;
        pausedForAssistant = false;
        try {
            setupRecognizer();
        } catch (Throwable ignored) {
            recognizer = null;
        }
        setStatus("Always listening — re-armed");
        startListeningSoon(0);
    }

    private void setStatus(String text) {
        getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .edit().putString(KEY_LISTENER_STATUS, text).apply();
    }

    @Override public void onReadyForSpeech(Bundle params) {
        setStatus("Always listening for ‘" + getWakePhrase() + "’");
    }

    @Override public void onBeginningOfSpeech() {}

    @Override public void onPartialResults(Bundle partialResults) {
        ArrayList<String> list = partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        rememberHeard(list);
        if (hasWakePhrase(list)) triggerAssistant();
    }

    @Override public void onResults(Bundle results) {
        ArrayList<String> list = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        rememberHeard(list);
        if (hasWakePhrase(list)) {
            triggerAssistant();
        } else if (!pausedForAssistant && !stopping) {
            startListeningSoon(RESTART_DELAY_MS);
        }
    }

    @Override public void onError(int error) {
        if (stopping || pausedForAssistant) return;

        if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
            setStatus("Microphone permission required");
            return;
        }

        if (error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY ||
                error == SpeechRecognizer.ERROR_CLIENT ||
                (Build.VERSION.SDK_INT >= 31 && error == SpeechRecognizer.ERROR_SERVER_DISCONNECTED)) {
            try { setupRecognizer(); } catch (Throwable ignored) { recognizer = null; }
            startListeningSoon(BUSY_RESTART_DELAY_MS);
        } else if (Build.VERSION.SDK_INT >= 31 && error == SpeechRecognizer.ERROR_TOO_MANY_REQUESTS) {
            // Back off a little, then continue automatically.
            startListeningSoon(1000);
        } else {
            // Speech timeout and no-match are normal for an always-on loop.
            startListeningSoon(RESTART_DELAY_MS);
        }
    }

    @Override public void onRmsChanged(float rmsdB) {}
    @Override public void onBufferReceived(byte[] buffer) {}
    @Override public void onEndOfSpeech() {}
    @Override public void onEvent(int eventType, Bundle params) {}

    private void createChannel() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        NotificationChannel ch = new NotificationChannel(
                CHANNEL, "Hands-free assistant listener", NotificationManager.IMPORTANCE_MIN);
        ch.setDescription("Quiet always-on background microphone listener");
        ch.setShowBadge(false);
        ch.setSound(null, null);
        ch.enableVibration(false);
        ch.setLockscreenVisibility(Notification.VISIBILITY_SECRET);
        nm.createNotificationChannel(ch);
    }

    private Notification notification() {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(
                this, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);

        return new Notification.Builder(this, CHANNEL)
                .setContentTitle("Hey ChatGPT Assist")
                .setContentText("Always listening for ‘" + getWakePhrase() + "’")
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setPriority(Notification.PRIORITY_MIN)
                .setContentIntent(pi)
                .build();
    }

    @Override
    public void onDestroy() {
        stopping = true;
        pausedForAssistant = false;
        handler.removeCallbacksAndMessages(null);
        if (recognizer != null) {
            try { recognizer.cancel(); } catch (Throwable ignored) {}
            try { recognizer.destroy(); } catch (Throwable ignored) {}
            recognizer = null;
        }
        getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .edit().putString(KEY_LISTENER_STATUS, "Stopped").apply();
        super.onDestroy();
    }

    @Override public android.os.IBinder onBind(Intent intent) { return null; }
}
