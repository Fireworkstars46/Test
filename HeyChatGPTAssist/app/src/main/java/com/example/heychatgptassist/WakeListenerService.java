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
    private static final long BUSY_RESTART_DELAY_MS = 650;
    private static final long TRIGGER_DELAY_MS = 100;
    private static final long PAUSE_AFTER_TRIGGER_MS = 45000;

    public static final String KEY_LISTENER_STATUS = "listener_status";
    public static final String KEY_LAST_HEARD = "last_heard";

    private SpeechRecognizer recognizer;
    private Intent recognizerIntent;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable startRunnable = this::startListeningNow;
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
        setStatus("Listening for ‘" + getWakePhrase() + "’");
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
        handler.removeCallbacks(startRunnable);
        handler.postDelayed(startRunnable, delayMs);
    }

    private void startListeningNow() {
        if (stopping || pausedForAssistant) return;
        try {
            if (recognizer == null) setupRecognizer();
            recognizer.startListening(recognizerIntent);
            setStatus("Listening for ‘" + getWakePhrase() + "’");
        } catch (Throwable t) {
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
        if (pausedForAssistant) return;
        pausedForAssistant = true;
        final int keyCode = getAssistKeyCode();
        setStatus("Activation phrase heard — opening assistant");

        handler.removeCallbacks(startRunnable);
        if (recognizer != null) {
            try { recognizer.cancel(); } catch (Throwable ignored) {}
            try { recognizer.destroy(); } catch (Throwable ignored) {}
            recognizer = null;
        }

        new Thread(() -> {
            try { Thread.sleep(TRIGGER_DELAY_MS); } catch (InterruptedException ignored) {}
            ShizukuBridge.Result result = ShizukuBridge.sendKeyEvent(keyCode);
            handler.post(() -> {
                if (result.success) {
                    setStatus("Assistant opened — listener paused");
                } else {
                    setStatus("Wake phrase matched, but " + result.message);
                }
            });
        }, "shizuku-wake-trigger").start();

        handler.postDelayed(() -> {
            if (stopping) return;
            pausedForAssistant = false;
            try { setupRecognizer(); } catch (Throwable t) {
                setStatus("Listener could not restart");
                return;
            }
            startListeningSoon(150);
        }, PAUSE_AFTER_TRIGGER_MS);
    }

    private void setStatus(String text) {
        getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .edit().putString(KEY_LISTENER_STATUS, text).apply();
    }

    @Override public void onReadyForSpeech(Bundle params) {
        setStatus("Listening for ‘" + getWakePhrase() + "’");
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

        if (error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY ||
                error == SpeechRecognizer.ERROR_CLIENT ||
                (Build.VERSION.SDK_INT >= 31 && error == SpeechRecognizer.ERROR_SERVER_DISCONNECTED)) {
            try { setupRecognizer(); } catch (Throwable ignored) {}
            startListeningSoon(BUSY_RESTART_DELAY_MS);
        } else if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
            setStatus("Microphone permission required");
        } else {
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
        ch.setDescription("Quiet background microphone listener");
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
                .setContentText("Listening for ‘" + getWakePhrase() + "’")
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
        handler.removeCallbacksAndMessages(null);
        if (recognizer != null) {
            try { recognizer.cancel(); } catch (Throwable ignored) {}
            try { recognizer.destroy(); } catch (Throwable ignored) {}
        }
        getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .edit().putString(KEY_LISTENER_STATUS, "Stopped").apply();
        super.onDestroy();
    }

    @Override public android.os.IBinder onBind(Intent intent) { return null; }
}
