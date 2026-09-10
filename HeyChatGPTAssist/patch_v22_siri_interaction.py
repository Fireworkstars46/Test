from pathlib import Path
import re

# v2.2: Siri-like local popup interaction + stronger transient task isolation.
# The foreground wake service remains alive. Its microphone is paused only
# while the popup itself is actively listening for a follow-up question.

# ---------- Wake listener coordination ----------
p = Path('app/src/main/java/com/example/heychatgptassist/WakeListenerService.java')
s = p.read_text()

const_anchor = '''    public static final String ACTION_LOCAL_FINISHED =
            "com.example.heychatgptassist.LOCAL_FINISHED";'''
if const_anchor not in s:
    raise SystemExit('v2.2: local finished action missing')
s = s.replace(const_anchor, const_anchor + '''
    public static final String ACTION_LOCAL_MIC_STARTED =
            "com.example.heychatgptassist.LOCAL_MIC_STARTED";
    public static final String ACTION_LOCAL_MIC_STOPPED =
            "com.example.heychatgptassist.LOCAL_MIC_STOPPED";''', 1)

# Insert mic-state branches before LOCAL_FINISHED. MIC_STARTED owns the mic,
# MIC_STOPPED gives it immediately back to the background wake listener.
receive_anchor = '''            if (ACTION_LOCAL_FINISHED.equals(action)) {'''
if receive_anchor not in s:
    raise SystemExit('v2.2: receiver local branch missing')
s = s.replace(receive_anchor, '''            if (ACTION_LOCAL_MIC_STARTED.equals(action)) {
                pausedForAssistant = true;
                handler.removeCallbacks(startRunnable);
                handler.removeCallbacks(rearmRunnable);
                stopContinuousMic();
                if (recognizer != null) {
                    try { recognizer.cancel(); } catch (Throwable ignored) {}
                    try { recognizer.destroy(); } catch (Throwable ignored) {}
                    recognizer = null;
                }
                setStatus("Local popup listening — background wake mic paused");
            } else if (ACTION_LOCAL_MIC_STOPPED.equals(action)) {
                handler.removeCallbacks(assistantSessionTimeoutRunnable);
                if (!stopping) {
                    pausedForAssistant = false;
                    try { setupRecognizer(); } catch (Throwable ignored) { recognizer = null; }
                    setStatus("Background wake listener active while popup stays open");
                    startListeningSoon(100);
                }
            } else if (ACTION_LOCAL_FINISHED.equals(action)) {''', 1)

filter_anchor = '''        filter.addAction(ACTION_LOCAL_FINISHED);'''
if filter_anchor not in s:
    raise SystemExit('v2.2: receiver filter local action missing')
s = s.replace(filter_anchor, filter_anchor + '''
        filter.addAction(ACTION_LOCAL_MIC_STARTED);
        filter.addAction(ACTION_LOCAL_MIC_STOPPED);''', 1)

# Use a true document-style transient task. This is stronger than v2.1's
# affinity alone and prevents Android from resurrecting MainActivity behind it.
for cls in ('LocalModeActivity', 'SiriModeActivity'):
    marker = f'new Intent(this, {cls}.class);'
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit(f'v2.2: {cls} launch missing')
    add = s.find('open.addFlags(', pos)
    end = s.find(');', add)
    if add < 0 or end < 0:
        raise SystemExit(f'v2.2: {cls} launch flags missing')
    flags = ('Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NEW_DOCUMENT | '
             'Intent.FLAG_ACTIVITY_MULTIPLE_TASK | Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS | '
             'Intent.FLAG_ACTIVITY_NO_HISTORY')
    s = s[:add] + f'open.addFlags({flags})' + s[end+1:]
p.write_text(s)

# ---------- Stronger popup task isolation ----------
p = Path('app/src/main/AndroidManifest.xml')
s = p.read_text()
for name in ('LocalModeActivity', 'SiriModeActivity'):
    start = s.find(f'android:name=".{name}"')
    if start < 0:
        raise SystemExit(f'v2.2: manifest {name} missing')
    tag_start = s.rfind('<activity', 0, start)
    tag_end = s.find('/>', start)
    if tag_start < 0 or tag_end < 0:
        raise SystemExit(f'v2.2: malformed {name} manifest tag')
    tag = s[tag_start:tag_end+2]
    for attr in ('android:taskAffinity','android:documentLaunchMode','android:launchMode',
                 'android:noHistory','android:finishOnTaskLaunch','android:excludeFromRecents'):
        tag = re.sub(r'\s+' + re.escape(attr) + r'="[^"]*"', '', tag)
    tag = tag[:-2]
    tag += '''
            android:taskAffinity=""
            android:documentLaunchMode="always"
            android:launchMode="singleInstancePerTask"
            android:noHistory="true"
            android:finishOnTaskLaunch="true"
            android:excludeFromRecents="true" />'''
    s = s[:tag_start] + tag + s[tag_end+2:]
p.write_text(s)

# ---------- Local popup: Siri-like tap-to-listen / tap-to-pause ----------
p = Path('app/src/main/java/com/example/heychatgptassist/LocalModeActivity.kt')
s = p.read_text()

# Extra state.
field_anchor = '''    private var pendingSpeak = ""'''
if field_anchor not in s:
    raise SystemExit('v2.2: Local pendingSpeak field missing')
s = s.replace(field_anchor, field_anchor + '''
    private var isQuestionListening = false
    private var manualListeningStop = false
    private var lastQuestion = ""''', 1)

# Bubble is now interactive.
bubble_anchor = '''            bubble.elevation = dp(18).toFloat()
            outer.addView(bubble, FrameLayout.LayoutParams(dp(78), dp(78), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {'''
if bubble_anchor not in s:
    raise SystemExit('v2.2: Local bubble anchor missing')
s = s.replace(bubble_anchor, '''            bubble.elevation = dp(18).toFloat()
            bubble.isClickable = true
            bubble.isFocusable = true
            bubble.contentDescription = "Tap to start or stop listening"
            bubble.setOnClickListener { toggleBubbleListening() }
            outer.addView(bubble, FrameLayout.LayoutParams(dp(78), dp(78), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {''', 1)

# Replace startQuestionListening() with a toggle-aware version.
start = s.find('    private fun startQuestionListening() {')
end = s.find('    private fun submitQuestion(', start)
if start < 0 or end < 0:
    raise SystemExit('v2.2: Local listening method boundaries missing')
new_listen = r'''    private fun sendMicState(started: Boolean) {
        val action = if (started)
            WakeListenerService.ACTION_LOCAL_MIC_STARTED
        else
            WakeListenerService.ACTION_LOCAL_MIC_STOPPED
        sendBroadcast(Intent(action).setPackage(packageName))
    }

    private fun toggleBubbleListening() {
        if (isQuestionListening) {
            stopListeningKeepPopup()
        } else {
            try { tts?.stop() } catch (_: Throwable) {}
            startQuestionListening()
        }
    }

    private fun stopListeningKeepPopup() {
        manualListeningStop = true
        isQuestionListening = false
        recognizer?.let {
            try { it.cancel() } catch (_: Throwable) {}
            try { it.destroy() } catch (_: Throwable) {}
        }
        recognizer = null
        statusText.text = "Paused — tap the orb to listen"
        sendMicState(false)
    }

    private fun startQuestionListening() {
        manualListeningStop = false
        isQuestionListening = true
        statusText.text = "Listening… tap the orb to pause"
        questionText.text = "Say your question"
        answerText.text = ""
        sendMicState(true)
        try {
            recognizer?.let {
                try { it.cancel() } catch (_: Throwable) {}
                try { it.destroy() } catch (_: Throwable) {}
            }
            recognizer = if (android.os.Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
            } else {
                SpeechRecognizer.createSpeechRecognizer(this)
            }.also { it.setRecognitionListener(this) }
            recognizer?.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            })
        } catch (_: Throwable) {
            isQuestionListening = false
            sendMicState(false)
            showError("Could not start voice input")
        }
    }

'''
s = s[:start] + new_listen + s[end:]

# submitQuestion: immediately return the mic to the background wake listener,
# then self-heal old/missing local model instead of showing the migration message.
submit_anchor = '''    private fun submitQuestion(question: String) {
        if (question.isBlank()) { showError("I didn't catch a question"); return }'''
if submit_anchor not in s:
    raise SystemExit('v2.2: submitQuestion anchor missing')
s = s.replace(submit_anchor, '''    private fun submitQuestion(question: String) {
        if (question.isBlank()) { showError("I didn't catch a question"); return }
        lastQuestion = question
        isQuestionListening = false
        sendMicState(false)''', 1)

old_model = r'''        val model = LocalModelManager.getModelFile(this)
        if (!LocalModelManager.isModelReady(this)) {
            val legacy = LocalModelManager.hasLegacyV19Model(this)
            showError(if (legacy)
                "The old v1.9 model is still installed. Download the corrected ~353 MB local model once from the helper, then Local AI will work."
            else
                "Free local model isn't downloaded yet — open the helper and tap DOWNLOAD FREE LOCAL MODEL")
            return
        }
        statusText.text = "Loading local AI…"'''
if old_model not in s:
    # Accept v2.0 wording too, in case v2.1 wording patch did not match.
    old_model = r'''        val model = LocalModelManager.getModelFile(this)
        if (!LocalModelManager.isModelReady(this)) {
            val legacy = LocalModelManager.hasLegacyV19Model(this)
            showError(if (legacy)
                "v1.9's local model was incompatible. Open the helper and download the corrected ~353 MB v2.0 model."
            else
                "Free local model isn't downloaded yet — open the helper and tap DOWNLOAD FREE LOCAL MODEL")
            return
        }
        statusText.text = "Loading local AI…"'''
if old_model not in s:
    raise SystemExit('v2.2: Local model readiness block missing')
new_model = r'''        var model = LocalModelManager.getModelFile(this)
        if (!LocalModelManager.isModelReady(this)) {
            statusText.text = if (LocalModelManager.hasLegacyV19Model(this))
                "Updating old local model… 0%"
            else
                "Downloading local model… 0%"
            answerText.text = "One-time local model setup. You can leave this popup open."
            LocalModelManager.download(this, object : LocalModelManager.Callback {
                override fun onProgress(percent: Int) {
                    runOnUiThread {
                        statusText.text = "Downloading local model… $percent%"
                    }
                }
                override fun onComplete(file: java.io.File) {
                    runOnUiThread {
                        statusText.text = "Local model ready"
                        answerText.text = ""
                        submitQuestion(lastQuestion)
                    }
                }
                override fun onError(message: String) {
                    runOnUiThread {
                        showError("Local model download failed: $message")
                    }
                }
            })
            return
        }
        model = LocalModelManager.getModelFile(this)
        statusText.text = "Loading local AI…"'''
s = s.replace(old_model, new_model, 1)

# Recognition callbacks: tapping the orb to pause should not turn into an error;
# successful speech also returns the mic before inference starts.
s = s.replace(
    '    override fun onError(error: Int) { showError("I didn\'t catch that — close and try again") }',
    '''    override fun onError(error: Int) {
        if (manualListeningStop) {
            manualListeningStop = false
            return
        }
        isQuestionListening = false
        sendMicState(false)
        statusText.text = "Didn't catch that — tap the orb to try again"
    }''', 1)
s = s.replace(
    '    override fun onResults(results: Bundle?) { submitQuestion(firstResult(results)) }',
    '''    override fun onResults(results: Bundle?) {
        isQuestionListening = false
        sendMicState(false)
        submitQuestion(firstResult(results))
    }''', 1)

# When launched with a complete "Hey phone, question" utterance, the popup does
# not need the mic at all, so hand it straight back to the background service.
create_anchor = '''        val query = intent?.getStringExtra(EXTRA_QUERY)?.trim().orEmpty()
        if (query.isNotEmpty()) submitQuestion(query) else startQuestionListening()'''
if create_anchor not in s:
    raise SystemExit('v2.2: Local onCreate query anchor missing')
s = s.replace(create_anchor, '''        val query = intent?.getStringExtra(EXTRA_QUERY)?.trim().orEmpty()
        if (query.isNotEmpty()) {
            sendMicState(false)
            submitQuestion(query)
        } else {
            startQuestionListening()
        }''', 1)

# Make close/finish paths release mic state before removal.
destroy_anchor = '''    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)'''
if destroy_anchor not in s:
    raise SystemExit('v2.2: Local onDestroy anchor missing')
s = s.replace(destroy_anchor, '''    override fun onDestroy() {
        isQuestionListening = false
        sendMicState(false)
        handler.removeCallbacksAndMessages(null)''', 1)

p.write_text(s)

# ---------- Version / wording ----------
p = Path('app/src/main/java/com/example/heychatgptassist/MainActivity.java')
s = p.read_text()
s = s.replace('Hey ChatGPT Assist v2.1', 'Hey ChatGPT Assist v2.2')
s = s.replace(
    'The response card now sits above a separate Siri-style orb at the bottom of the screen. The orb only exists while the local/API assistant popup is open and disappears completely when you close it.',
    'The response card sits above a separate Siri-style orb at the bottom. Tap the orb while listening to pause and keep the popup open; tap it again to listen for another question. The background wake listener resumes whenever the popup itself is not using the microphone.')
p.write_text(s)

p = Path('app/build.gradle')
s = p.read_text()
if 'versionCode 21' not in s or 'versionName "2.1"' not in s:
    raise SystemExit('v2.2: expected v2.1 version fields missing')
s = s.replace('versionCode 21', 'versionCode 22', 1)
s = s.replace('versionName "2.1"', 'versionName "2.2"', 1)
p.write_text(s)
