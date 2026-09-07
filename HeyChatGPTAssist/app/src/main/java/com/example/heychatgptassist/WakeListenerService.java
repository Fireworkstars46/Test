package com.example.heychatgptassist;

import android.app.*;
import android.content.*;
import android.os.*;
import android.speech.*;
import java.util.*;

public class WakeListenerService extends Service implements RecognitionListener {
    private static final String CHANNEL = "wake_listener";
    private static final int NOTIFICATION_ID = 46;
    private static final long RESTART_DELAY_MS = 500;
    private static final long PAUSE_AFTER_TRIGGER_MS = 45000;

    public static final String KEY_LISTENER_STATUS = "listener_status";
    public static final String KEY_LAST_HEARD = "last_heard";

    private SpeechRecognizer recognizer;
    private Intent recognizerIntent;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable startRunnable = this::startListeningNow;
    private boolean stopping = false;
    private boolean pausedForAssistant = false;
    private boolean listening = false;

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
        startForeground(NOTIFICATION_ID, notification("Starting voice listener…"));
        setupRecognizer();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        stopping = false;
        pausedForAssistant = false;
        setStatus("Starting microphone…");
        startListeningSoon(250);
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
            try { recognizer.destroy(); } catch (Throwable ignored) {}
            recognizer = null;
        }

        // Use the phone's normal/default speech recognition provider. On Samsung this is
        // generally more reliable for a foreground service than forcing the on-device provider.
        recognizer = SpeechRecognizer.createSpeechRecognizer(this);
        recognizer.setRecognitionListener(this);

        recognizerIntent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1200L);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 700L);
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
            listening = true;
            recognizer.startListening(recognizerIntent);
            setStatus("Listening for ‘" + getWakePhrase() + "’");
        } catch (Throwable t) {
            listening = false;
            setStatus("Listener restart: " + t.getClass().getSimpleName());
            try { setupRecognizer(); } catch (Throwable ignored) {}
            startListeningSoon(1500);
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
        updateNotification("Heard: " + heard);
    }

    private void triggerAssistant() {
        if (pausedForAssistant) return;
        pausedForAssistant = true;
        listening = false;
        setStatus("Phrase matched — opening ChatGPT");

        handler.removeCallbacks(startRunnable);
        if (recognizer != null) {
            try { recognizer.cancel(); } catch (Throwable ignored) {}
            try { recognizer.destroy(); } catch (Throwable ignored) {}
            recognizer = null;
        }

        handler.postDelayed(() -> {
            boolean ok = AssistantAccessibilityService.showAssistant(this);
            if (!ok) setStatus("Phrase matched, but ChatGPT could not open");
        }, 500);

        handler.postDelayed(() -> {
            if (stopping) return;
            pausedForAssistant = false;
            try { setupRecognizer(); } catch (Throwable t) {
                setStatus("Could not restart listener: " + t.getClass().getSimpleName());
                return;
            }
            startListeningSoon(500);
        }, PAUSE_AFTER_TRIGGER_MS);
    }

    private String errorName(int error) {
        switch (error) {
            case SpeechRecognizer.ERROR_NETWORK_TIMEOUT: return "network timeout";
            case SpeechRecognizer.ERROR_NETWORK: return "network";
            case SpeechRecognizer.ERROR_AUDIO: return "audio";
            case SpeechRecognizer.ERROR_SERVER: return "server";
            case SpeechRecognizer.ERROR_CLIENT: return "client";
            case SpeechRecognizer.ERROR_SPEECH_TIMEOUT: return "speech timeout";
            case SpeechRecognizer.ERROR_NO_MATCH: return "no match";
            case SpeechRecognizer.ERROR_RECOGNIZER_BUSY: return "recognizer busy";
            case SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS: return "microphone permission";
            default:
                if (Build.VERSION.SDK_INT >= 31 && error == SpeechRecognizer.ERROR_TOO_MANY_REQUESTS)
                    return "too many requests";
                if (Build.VERSION.SDK_INT >= 31 && error == SpeechRecognizer.ERROR_SERVER_DISCONNECTED)
                    return "server disconnected";
                if (Build.VERSION.SDK_INT >= 31 && error == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)
                    return "language not supported";
                if (Build.VERSION.SDK_INT >= 31 && error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)
                    return "language unavailable";
                return "error " + error;
        }
    }

    private void setStatus(String text) {
        getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .edit().putString(KEY_LISTENER_STATUS, text).apply();
        updateNotification(text);
    }

    @Override public void onReadyForSpeech(Bundle params) {
        setStatus("Mic ready — say ‘" + getWakePhrase() + "’");
    }

    @Override public void onBeginningOfSpeech() {
        setStatus("Hearing speech…");
    }

    @Override public void onPartialResults(Bundle partialResults) {
        ArrayList<String> list = partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        rememberHeard(list);
        if (hasWakePhrase(list)) triggerAssistant();
    }

    @Override public void onResults(Bundle results) {
        listening = false;
        ArrayList<String> list = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        rememberHeard(list);
        if (hasWakePhrase(list)) {
            triggerAssistant();
        } else if (!pausedForAssistant && !stopping) {
            setStatus("No wake phrase — listening again…");
            startListeningSoon(RESTART_DELAY_MS);
        }
    }

    @Override public void onError(int error) {
        listening = false;
        if (stopping || pausedForAssistant) return;

        String name = errorName(error);
        setStatus("Speech: " + name + " — retrying");

        if (error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY ||
                error == SpeechRecognizer.ERROR_CLIENT ||
                (Build.VERSION.SDK_INT >= 31 && error == SpeechRecognizer.ERROR_SERVER_DISCONNECTED)) {
            try { setupRecognizer(); } catch (Throwable ignored) {}
            startListeningSoon(1200);
        } else if (Build.VERSION.SDK_INT >= 31 &&
                (error == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED ||
                 error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)) {
            try { setupRecognizer(); } catch (Throwable ignored) {}
            startListeningSoon(1500);
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
                .setStyle(new Notification.BigTextStyle().bigText(text))
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setOngoing(true)
                .setContentIntent(pi)
                .build();
    }

    private void updateNotification(String text) {
        getSystemService(NotificationManager.class).notify(NOTIFICATION_ID, notification(text));
    }

    @Override
    public void onDestroy() {
        stopping = true;
        listening = false;
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
