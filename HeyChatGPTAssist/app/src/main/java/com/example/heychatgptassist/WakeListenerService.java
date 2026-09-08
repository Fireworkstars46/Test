package com.example.heychatgptassist;

import android.app.*;
import android.content.*;
import android.os.*;
import android.speech.*;
import java.util.*;

public class WakeListenerService extends Service implements RecognitionListener {
    private static final String CHANNEL = "wake_listener_quiet_v06";
    private static final int NOTIFICATION_ID = 46;
    private static final String KEY_SMOOTH_MIGRATED = "smooth_listener_migrated_v12";

    public static final String KEY_LISTENER_STATUS = "listener_status";
    public static final String KEY_LAST_HEARD = "last_heard";
    public static final String ACTION_TEMP_VOICE_STARTED =
            "com.example.heychatgptassist.TEMP_VOICE_STARTED";
    public static final String ACTION_TEMP_VOICE_FINISHED =
            "com.example.heychatgptassist.TEMP_VOICE_FINISHED";

    private SpeechRecognizer recognizer;
    private Intent recognizerIntent;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable startRunnable = this::startListeningNow;
    private final Runnable rearmRunnable = this::rearmAfterTrigger;
    private final Runnable tempSetupTimeoutRunnable = () -> {
        if (!stopping && pausedForAssistant) {
            setStatus("Temporary Voice setup timed out — re-arming listener");
            rearmAfterTrigger();
        }
    };
    private final Runnable tempMaxSessionRunnable = () -> {
        if (!stopping && pausedForAssistant) {
            setStatus("Temporary Voice safety timeout — re-arming listener");
            rearmAfterTrigger();
        }
    };

    private boolean stopping = false;
    private boolean pausedForAssistant = false;
    private boolean forceSystemRecognizer = false;
    private boolean usingOnDeviceRecognizer = false;
    private boolean tempReceiverRegistered = false;

    private String lastStatusWritten = "";
    private String lastHeardWritten = "";
    private long lastHeardWriteUptime = 0L;

    private final BroadcastReceiver tempVoiceReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (intent == null) return;
            String action = intent.getAction();
            if (ACTION_TEMP_VOICE_STARTED.equals(action)) {
                handler.removeCallbacks(tempSetupTimeoutRunnable);
                handler.removeCallbacks(tempMaxSessionRunnable);
                setStatus("Temporary Voice active — wake listener paused");
                handler.postDelayed(tempMaxSessionRunnable, 60L * 60L * 1000L);
            } else if (ACTION_TEMP_VOICE_FINISHED.equals(action)) {
                handler.removeCallbacks(tempSetupTimeoutRunnable);
                handler.removeCallbacks(tempMaxSessionRunnable);
                setStatus("Temporary Voice ended — re-arming listener");
                rearmAfterTrigger();
            }
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
        startForeground(NOTIFICATION_ID, notification());
        registerTempVoiceReceiver();
        migrateSmoothDefaults();
        setupRecognizer();
    }

    private void registerTempVoiceReceiver() {
        if (tempReceiverRegistered) return;
        IntentFilter filter = new IntentFilter();
        filter.addAction(ACTION_TEMP_VOICE_STARTED);
        filter.addAction(ACTION_TEMP_VOICE_FINISHED);
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(tempVoiceReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(tempVoiceReceiver, filter);
        }
        tempReceiverRegistered = true;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        stopping = false;
        pausedForAssistant = false;
        handler.removeCallbacks(rearmRunnable);
        handler.removeCallbacks(startRunnable);
        handler.removeCallbacks(tempSetupTimeoutRunnable);
        handler.removeCallbacks(tempMaxSessionRunnable);
        migrateSmoothDefaults();
        try { setupRecognizer(); } catch (Throwable ignored) {}
        setStatus("Always listening for ‘" + getWakePhrase() + "’");
        startListeningSoon(getInitialListenDelayMs());
        return START_STICKY;
    }

    private void migrateSmoothDefaults() {
        SharedPreferences prefs = getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE);
        if (prefs.getBoolean(KEY_SMOOTH_MIGRATED, false)) return;
        SharedPreferences.Editor editor = prefs.edit();
        int complete = prefs.getInt(MainActivity.KEY_COMPLETE_SILENCE_MS, 3500);
        int possible = prefs.getInt(MainActivity.KEY_POSSIBLY_COMPLETE_SILENCE_MS, 1800);
        if (complete == 3500) editor.putInt(MainActivity.KEY_COMPLETE_SILENCE_MS, 60000);
        if (possible == 1800) editor.putInt(MainActivity.KEY_POSSIBLY_COMPLETE_SILENCE_MS, 30000);
        editor.putBoolean(KEY_SMOOTH_MIGRATED, true).apply();
    }

    private int getIntPref(String key, int defaultValue, int maxValue) {
        int value = getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .getInt(key, defaultValue);
        return Math.max(0, Math.min(maxValue, value));
    }

    private SharedPreferences prefs() {
        return getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE);
    }

    private String getWakePhrase() {
        return prefs().getString(MainActivity.KEY_WAKE_PHRASE, MainActivity.DEFAULT_WAKE_PHRASE).trim();
    }

    private int getAssistKeyCode() {
        return prefs().getInt(MainActivity.KEY_ASSIST_KEYCODE, MainActivity.DEFAULT_ASSIST_KEYCODE);
    }

    private boolean getTemporaryVoiceEnabled() {
        return prefs().getBoolean(MainActivity.KEY_TEMPORARY_VOICE_ENABLED, false);
    }

    private int getTriggerDelayMs() {
        return getIntPref(MainActivity.KEY_TRIGGER_DELAY_MS,
                MainActivity.DEFAULT_TRIGGER_DELAY_MS, MainActivity.MAX_TRIGGER_DELAY_MS);
    }

    private int getRearmDelayMs() {
        return getIntPref(MainActivity.KEY_REARM_DELAY_MS,
                MainActivity.DEFAULT_REARM_DELAY_MS, MainActivity.MAX_REARM_DELAY_MS);
    }

    private int getInitialListenDelayMs() {
        return getIntPref(MainActivity.KEY_INITIAL_LISTEN_DELAY_MS,
                MainActivity.DEFAULT_INITIAL_LISTEN_DELAY_MS, MainActivity.MAX_INITIAL_LISTEN_DELAY_MS);
    }

    private int getRestartDelayMs() {
        return getIntPref(MainActivity.KEY_RESTART_DELAY_MS,
                MainActivity.DEFAULT_RESTART_DELAY_MS, MainActivity.MAX_RESTART_DELAY_MS);
    }

    private int getBusyRetryDelayMs() {
        return getIntPref(MainActivity.KEY_BUSY_RETRY_DELAY_MS,
                MainActivity.DEFAULT_BUSY_RETRY_DELAY_MS, MainActivity.MAX_BUSY_RETRY_DELAY_MS);
    }

    private int getRateLimitRetryDelayMs() {
        return getIntPref(MainActivity.KEY_RATE_LIMIT_RETRY_DELAY_MS,
                MainActivity.DEFAULT_RATE_LIMIT_RETRY_DELAY_MS, MainActivity.MAX_RATE_LIMIT_RETRY_DELAY_MS);
    }

    private int getCompleteSilenceMs() {
        return getIntPref(MainActivity.KEY_COMPLETE_SILENCE_MS,
                MainActivity.DEFAULT_COMPLETE_SILENCE_MS, MainActivity.MAX_COMPLETE_SILENCE_MS);
    }

    private int getPossiblyCompleteSilenceMs() {
        return getIntPref(MainActivity.KEY_POSSIBLY_COMPLETE_SILENCE_MS,
                MainActivity.DEFAULT_POSSIBLY_COMPLETE_SILENCE_MS, MainActivity.MAX_POSSIBLY_COMPLETE_SILENCE_MS);
    }

    private int getMinSpeechMs() {
        return getIntPref(MainActivity.KEY_MIN_SPEECH_MS,
                MainActivity.DEFAULT_MIN_SPEECH_MS, MainActivity.MAX_MIN_SPEECH_MS);
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

    private SpeechRecognizer createBestRecognizer() {
        usingOnDeviceRecognizer = false;
        if (!forceSystemRecognizer && Build.VERSION.SDK_INT >= 31) {
            try {
                if (SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) {
                    SpeechRecognizer local = SpeechRecognizer.createOnDeviceSpeechRecognizer(this);
                    usingOnDeviceRecognizer = true;
                    return local;
                }
            } catch (Throwable ignored) {
                usingOnDeviceRecognizer = false;
            }
        }
        return SpeechRecognizer.createSpeechRecognizer(this);
    }

    private void setupRecognizer() {
        if (recognizer != null) {
            try { recognizer.cancel(); } catch (Throwable ignored) {}
            try { recognizer.destroy(); } catch (Throwable ignored) {}
            recognizer = null;
        }
        recognizer = createBestRecognizer();
        recognizer.setRecognitionListener(this);
        recognizerIntent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true);
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                (long) getCompleteSilenceMs());
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                (long) getPossiblyCompleteSilenceMs());
        recognizerIntent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS,
                (long) getMinSpeechMs());
        if (Build.VERSION.SDK_INT >= 33) {
            recognizerIntent.putExtra(
                    RecognizerIntent.EXTRA_SEGMENTED_SESSION,
                    RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS);
        }
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
            try { setupRecognizer(); } catch (Throwable ignored) { recognizer = null; }
            startListeningSoon(getBusyRetryDelayMs());
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
        if (heard.isEmpty() || heard.equals(lastHeardWritten)) return;
        long now = SystemClock.uptimeMillis();
        if (now - lastHeardWriteUptime < 750L) return;
        lastHeardWriteUptime = now;
        lastHeardWritten = heard;
        prefs().edit().putString(KEY_LAST_HEARD, heard).apply();
    }

    private void handleRecognitionBundle(Bundle bundle, boolean restartWhenNoMatch) {
        if (bundle == null) return;
        ArrayList<String> list = bundle.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        rememberHeard(list);
        if (hasWakePhrase(list)) {
            triggerAssistant();
        } else if (restartWhenNoMatch && !pausedForAssistant && !stopping) {
            startListeningSoon(getRestartDelayMs());
        }
    }

    private void beginAssistantPause() {
        pausedForAssistant = true;
        handler.removeCallbacks(startRunnable);
        handler.removeCallbacks(rearmRunnable);
        if (recognizer != null) {
            try { recognizer.cancel(); } catch (Throwable ignored) {}
            try { recognizer.destroy(); } catch (Throwable ignored) {}
            recognizer = null;
        }
    }

    private void triggerAssistant() {
        if (pausedForAssistant || stopping) return;
        if (getTemporaryVoiceEnabled()) triggerTemporaryVoice();
        else triggerNormalAssistant();
    }

    private void triggerNormalAssistant() {
        beginAssistantPause();
        final int keyCode = getAssistKeyCode();
        final int triggerDelayMs = getTriggerDelayMs();
        final int rearmDelayMs = getRearmDelayMs();
        setStatus("Activation phrase heard — opening assistant");
        prefs().edit()
                .putLong(ChatGPTTextAccessibilityService.KEY_LAST_ASSIST_TRIGGER_MS,
                        System.currentTimeMillis())
                .apply();
        new Thread(() -> {
            if (triggerDelayMs > 0) {
                try { Thread.sleep(triggerDelayMs); } catch (InterruptedException ignored) {}
            }
            ShizukuBridge.Result result = ShizukuBridge.sendKeyEvent(keyCode);
            handler.post(() -> setStatus(result.success
                    ? "Assistant opened — re-arming listener"
                    : "Wake phrase matched, but " + result.message + " — re-arming"));
        }, "shizuku-wake-trigger").start();
        if (rearmDelayMs <= 0) handler.post(rearmRunnable);
        else handler.postDelayed(rearmRunnable, rearmDelayMs);
    }

    private void triggerTemporaryVoice() {
        beginAssistantPause();
        final int triggerDelayMs = getTriggerDelayMs();
        final long requestTime = System.currentTimeMillis();
        setStatus("Activation phrase heard — preparing Temporary Voice");
        prefs().edit()
                .putLong(ChatGPTTextAccessibilityService.KEY_TEMP_REQUEST_MS, requestTime)
                .putString(ChatGPTTextAccessibilityService.KEY_TEMP_AUTOMATION_STATUS,
                        "Opening ChatGPT for Temporary Voice…")
                .apply();
        handler.removeCallbacks(tempSetupTimeoutRunnable);
        handler.postDelayed(tempSetupTimeoutRunnable, 20000L);
        Runnable launch = () -> {
            try {
                Intent open = getPackageManager().getLaunchIntentForPackage("com.openai.chatgpt");
                if (open == null) throw new IllegalStateException("ChatGPT launch intent unavailable");
                open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
                startActivity(open);
                setStatus("Temporary Voice: ChatGPT opened — waiting for Temporary mode");
            } catch (Throwable t) {
                prefs().edit().putString(ChatGPTTextAccessibilityService.KEY_TEMP_AUTOMATION_STATUS,
                        "Could not open ChatGPT for Temporary Voice").apply();
                setStatus("Could not open ChatGPT — re-arming listener");
                rearmAfterTrigger();
            }
        };
        if (triggerDelayMs <= 0) handler.post(launch);
        else handler.postDelayed(launch, triggerDelayMs);
    }

    private void rearmAfterTrigger() {
        if (stopping) return;
        handler.removeCallbacks(tempSetupTimeoutRunnable);
        handler.removeCallbacks(tempMaxSessionRunnable);
        pausedForAssistant = false;
        try { setupRecognizer(); }
        catch (Throwable ignored) { recognizer = null; }
        setStatus("Always listening — re-armed");
        startListeningSoon(0);
    }

    private void setStatus(String text) {
        if (text == null || text.equals(lastStatusWritten)) return;
        lastStatusWritten = text;
        prefs().edit().putString(KEY_LISTENER_STATUS, text).apply();
    }

    @Override public void onReadyForSpeech(Bundle params) {
        setStatus("Always listening for ‘" + getWakePhrase() + "’");
    }
    @Override public void onBeginningOfSpeech() {}
    @Override public void onPartialResults(Bundle partialResults) {
        handleRecognitionBundle(partialResults, false);
    }
    @Override public void onResults(Bundle results) {
        handleRecognitionBundle(results, true);
    }
    @Override public void onSegmentResults(Bundle segmentResults) {
        handleRecognitionBundle(segmentResults, false);
    }
    @Override public void onEndOfSegmentedSession() {
        if (!pausedForAssistant && !stopping) startListeningSoon(getRestartDelayMs());
    }

    @Override public void onError(int error) {
        if (stopping || pausedForAssistant) return;
        if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
            setStatus("Microphone permission required");
            return;
        }
        if (usingOnDeviceRecognizer && Build.VERSION.SDK_INT >= 31 &&
                (error == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED ||
                        error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)) {
            forceSystemRecognizer = true;
            try { setupRecognizer(); } catch (Throwable ignored) { recognizer = null; }
            startListeningSoon(getBusyRetryDelayMs());
            return;
        }
        if (error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY) {
            if (recognizer != null) {
                try { recognizer.cancel(); } catch (Throwable ignored) {}
            }
            startListeningSoon(getBusyRetryDelayMs());
            return;
        }
        if (error == SpeechRecognizer.ERROR_CLIENT ||
                (Build.VERSION.SDK_INT >= 31 && error == SpeechRecognizer.ERROR_SERVER_DISCONNECTED)) {
            try { setupRecognizer(); } catch (Throwable ignored) { recognizer = null; }
            startListeningSoon(getBusyRetryDelayMs());
            return;
        }
        if (Build.VERSION.SDK_INT >= 31 && error == SpeechRecognizer.ERROR_TOO_MANY_REQUESTS) {
            startListeningSoon(getRateLimitRetryDelayMs());
            return;
        }
        startListeningSoon(getRestartDelayMs());
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
        if (tempReceiverRegistered) {
            try { unregisterReceiver(tempVoiceReceiver); } catch (Throwable ignored) {}
            tempReceiverRegistered = false;
        }
        prefs().edit().putString(KEY_LISTENER_STATUS, "Stopped").apply();
        super.onDestroy();
    }

    @Override public android.os.IBinder onBind(Intent intent) { return null; }
}
