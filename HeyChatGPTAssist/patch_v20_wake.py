from pathlib import Path
p = Path('app/src/main/java/com/example/heychatgptassist/WakeListenerService.java')
s = p.read_text()

if 'import android.media.*;' not in s:
    s = s.replace('import android.content.*;\n', 'import android.content.*;\nimport android.media.*;\n', 1)
if 'import java.io.*;' not in s:
    s = s.replace('import android.speech.*;\n', 'import android.speech.*;\nimport java.io.*;\n', 1)

field_anchor = '    private boolean tempReceiverRegistered = false;\n'
if field_anchor not in s:
    raise SystemExit('v2.0: WakeListener field anchor missing')
continuous_fields = r'''

    // Android 13+ continuous microphone path. AudioRecord owns the mic for the
    // whole idle-listening session (Discord-call style), while SpeechRecognizer
    // reads the same PCM stream from a pipe. The mic only stops when an
    // assistant session needs it or the foreground listener is stopped.
    private static final int CONTINUOUS_SAMPLE_RATE = 16000;
    private final Object audioPipeLock = new Object();
    private AudioRecord continuousAudioRecord;
    private Thread continuousAudioThread;
    private volatile boolean continuousMicRunning = false;
    private ParcelFileDescriptor speechPipeRead;
    private ParcelFileDescriptor speechPipeWrite;
    private FileOutputStream speechPipeOutput;
    private boolean usingContinuousPipeSession = false;
    private boolean continuousPipeModeFailed = false;
'''
s = s.replace(field_anchor, field_anchor + continuous_fields, 1)

method_anchor = '    private void startListeningSoon(long delayMs) {'
if method_anchor not in s:
    raise SystemExit('v2.0: startListeningSoon anchor missing')
continuous_methods = r'''    private boolean ensureContinuousMic() {
        if (Build.VERSION.SDK_INT < 33 || continuousPipeModeFailed) return false;
        if (continuousMicRunning && continuousAudioRecord != null) return true;

        int minBuffer = AudioRecord.getMinBufferSize(
                CONTINUOUS_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT);
        if (minBuffer <= 0) minBuffer = CONTINUOUS_SAMPLE_RATE * 2;

        try {
            AudioFormat format = new AudioFormat.Builder()
                    .setSampleRate(CONTINUOUS_SAMPLE_RATE)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .build();
            AudioRecord record = new AudioRecord.Builder()
                    .setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(Math.max(minBuffer * 4, CONTINUOUS_SAMPLE_RATE * 2))
                    .build();
            if (record.getState() != AudioRecord.STATE_INITIALIZED) {
                try { record.release(); } catch (Throwable ignored) {}
                throw new IllegalStateException("AudioRecord did not initialize");
            }

            record.startRecording();
            if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
                try { record.release(); } catch (Throwable ignored) {}
                throw new IllegalStateException("AudioRecord did not start");
            }

            continuousAudioRecord = record;
            continuousMicRunning = true;
            continuousAudioThread = new Thread(this::pumpContinuousAudio, "continuous-wake-mic");
            continuousAudioThread.start();
            return true;
        } catch (Throwable t) {
            continuousPipeModeFailed = true;
            stopContinuousMic();
            return false;
        }
    }

    private void pumpContinuousAudio() {
        final byte[] buffer = new byte[3200]; // 100 ms of 16 kHz mono PCM16
        while (continuousMicRunning) {
            AudioRecord record = continuousAudioRecord;
            if (record == null) break;
            int count;
            try {
                count = record.read(buffer, 0, buffer.length, AudioRecord.READ_BLOCKING);
            } catch (Throwable t) {
                break;
            }
            if (count <= 0) continue;

            FileOutputStream out;
            synchronized (audioPipeLock) {
                out = speechPipeOutput;
            }
            if (out != null) {
                try {
                    out.write(buffer, 0, count);
                } catch (Throwable ignored) {
                    synchronized (audioPipeLock) {
                        if (speechPipeOutput == out) closeSpeechPipeLocked();
                    }
                }
            }
        }
    }

    private void closeSpeechPipeLocked() {
        usingContinuousPipeSession = false;
        try { if (speechPipeOutput != null) speechPipeOutput.close(); } catch (Throwable ignored) {}
        try { if (speechPipeWrite != null) speechPipeWrite.close(); } catch (Throwable ignored) {}
        try { if (speechPipeRead != null) speechPipeRead.close(); } catch (Throwable ignored) {}
        speechPipeOutput = null;
        speechPipeWrite = null;
        speechPipeRead = null;
    }

    private void closeSpeechPipe() {
        synchronized (audioPipeLock) {
            closeSpeechPipeLocked();
        }
    }

    private void stopContinuousMic() {
        continuousMicRunning = false;
        closeSpeechPipe();
        AudioRecord record = continuousAudioRecord;
        continuousAudioRecord = null;
        if (record != null) {
            try { record.stop(); } catch (Throwable ignored) {}
            try { record.release(); } catch (Throwable ignored) {}
        }
        Thread t = continuousAudioThread;
        continuousAudioThread = null;
        if (t != null && t != Thread.currentThread()) {
            try { t.interrupt(); } catch (Throwable ignored) {}
        }
    }

    private Intent buildSessionRecognizerIntent() throws IOException {
        Intent session = new Intent(recognizerIntent);
        if (Build.VERSION.SDK_INT >= 33 && ensureContinuousMic()) {
            closeSpeechPipe();
            ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
            speechPipeRead = pipe[0];
            speechPipeWrite = pipe[1];
            speechPipeOutput = new FileOutputStream(speechPipeWrite.getFileDescriptor());
            session.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, speechPipeRead);
            session.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1);
            session.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT);
            session.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, CONTINUOUS_SAMPLE_RATE);
            session.putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE);
            session.putStringArrayListExtra(
                    RecognizerIntent.EXTRA_BIASING_STRINGS,
                    new ArrayList<>(Collections.singletonList(getWakePhrase())));
            usingContinuousPipeSession = true;
        }
        return session;
    }

'''
s = s.replace(method_anchor, continuous_methods + method_anchor, 1)

old_start = r'''    private void startListeningNow() {
        if (stopping || pausedForAssistant) return;
        try {
            if (recognizer == null) setupRecognizer();
            recognizer.startListening(recognizerIntent);
            setStatus("Always listening for ‘" + getWakePhrase() + "’");
        } catch (Throwable t) {
            try { setupRecognizer(); } catch (Throwable ignored) { recognizer = null; }
            startListeningSoon(getBusyRetryDelayMs());
        }
    }'''
new_start = r'''    private void startListeningNow() {
        if (stopping || pausedForAssistant) return;
        try {
            if (recognizer == null) setupRecognizer();
            Intent sessionIntent = buildSessionRecognizerIntent();
            recognizer.startListening(sessionIntent);
            setStatus(continuousMicRunning
                    ? "Always listening continuously for ‘" + getWakePhrase() + "’"
                    : "Always listening for ‘" + getWakePhrase() + "’");
        } catch (Throwable t) {
            closeSpeechPipe();
            // If the recognition service rejects injected audio, permanently
            // fall back to the old direct-microphone path for this service run.
            if (continuousMicRunning) {
                continuousPipeModeFailed = true;
                stopContinuousMic();
            }
            try { setupRecognizer(); } catch (Throwable ignored) { recognizer = null; }
            startListeningSoon(getBusyRetryDelayMs());
        }
    }'''
if old_start not in s:
    raise SystemExit('v2.0: startListeningNow block missing')
s = s.replace(old_start, new_start, 1)

# Local/API modes wait for a full segment/result so "Hey phone, how are you?"
# can be passed through as one utterance. Normal ChatGPT mode still triggers as
# soon as the partial result contains the wake phrase for maximum speed.
old_partial = r'''    @Override public void onPartialResults(Bundle partialResults) {
        if (getSiriModeEnabled()) {
            if (partialResults != null) {
                ArrayList<String> list = partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
                rememberHeard(list);
            }
        } else {
            handleRecognitionBundle(partialResults, false);
        }
    }'''
new_partial = r'''    @Override public void onPartialResults(Bundle partialResults) {
        if (getSiriModeEnabled() || getLocalModeEnabled()) {
            if (partialResults != null) {
                ArrayList<String> list = partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
                rememberHeard(list);
            }
        } else {
            handleRecognitionBundle(partialResults, false);
        }
    }'''
if old_partial not in s:
    raise SystemExit('v2.0: partial-result block missing')
s = s.replace(old_partial, new_partial, 1)

# Release the continuous wake mic whenever the assistant needs microphone access.
begin_anchor = r'''    private void beginAssistantPause() {
        pausedForAssistant = true;
        handler.removeCallbacks(startRunnable);
        handler.removeCallbacks(rearmRunnable);'''
if begin_anchor not in s:
    raise SystemExit('v2.0: beginAssistantPause anchor missing')
s = s.replace(begin_anchor, begin_anchor + '\n        stopContinuousMic();', 1)

# Close/recreate only the speech pipe on recognition completion/errors; the
# AudioRecord mic itself stays open unless an assistant session starts.
s = s.replace(
    '    @Override public void onResults(Bundle results) {\n        handleRecognitionBundle(results, true);\n    }',
    '    @Override public void onResults(Bundle results) {\n        closeSpeechPipe();\n        handleRecognitionBundle(results, true);\n    }',
    1)
s = s.replace(
    '    @Override public void onEndOfSegmentedSession() {\n        if (!pausedForAssistant && !stopping) startListeningSoon(getRestartDelayMs());\n    }',
    '    @Override public void onEndOfSegmentedSession() {\n        closeSpeechPipe();\n        if (!pausedForAssistant && !stopping) startListeningSoon(getRestartDelayMs());\n    }',
    1)

error_anchor = '    @Override public void onError(int error) {\n        if (stopping || pausedForAssistant) return;'
if error_anchor not in s:
    raise SystemExit('v2.0: onError anchor missing')
s = s.replace(error_anchor, error_anchor + r'''
        boolean pipeSession = usingContinuousPipeSession;
        closeSpeechPipe();
        if (pipeSession && (error == SpeechRecognizer.ERROR_AUDIO || error == SpeechRecognizer.ERROR_CLIENT)) {
            continuousPipeModeFailed = true;
            stopContinuousMic();
            try { setupRecognizer(); } catch (Throwable ignored) { recognizer = null; }
            startListeningSoon(getBusyRetryDelayMs());
            return;
        }''', 1)

# Ensure service shutdown releases the one long-lived mic capture.
destroy_anchor = '        handler.removeCallbacksAndMessages(null);\n        if (recognizer != null) {'
if destroy_anchor not in s:
    raise SystemExit('v2.0: onDestroy cleanup anchor missing')
s = s.replace(destroy_anchor, '        handler.removeCallbacksAndMessages(null);\n        stopContinuousMic();\n        if (recognizer != null) {', 1)

# Version-specific wording in status.
s = s.replace('setStatus("Always listening — re-armed");',
              'setStatus("Always listening — continuous mic re-armed");', 1)
p.write_text(s)
