from pathlib import Path
import re, runpy

# Start from the exact v1.8 generated source.
runpy.run_path('prepare_v18.py', run_name='__main__')

# ---------------- WakeListenerService: add free-local mode ----------------
p = Path('app/src/main/java/com/example/heychatgptassist/WakeListenerService.java')
s = p.read_text()

s = s.replace(
    '    public static final String ACTION_SIRI_FINISHED =\n            "com.example.heychatgptassist.SIRI_FINISHED";',
    '    public static final String ACTION_SIRI_FINISHED =\n            "com.example.heychatgptassist.SIRI_FINISHED";\n'
    '    public static final String ACTION_LOCAL_FINISHED =\n            "com.example.heychatgptassist.LOCAL_FINISHED";',
    1)

s = s.replace(
    '            if (ACTION_SIRI_FINISHED.equals(action)) {',
    '            if (ACTION_LOCAL_FINISHED.equals(action)) {\n'
    '                handler.removeCallbacks(assistantSessionTimeoutRunnable);\n'
    '                setStatus("Free local popup closed — re-arming listener");\n'
    '                rearmAfterTrigger();\n'
    '            } else if (ACTION_SIRI_FINISHED.equals(action)) {',
    1)

s = s.replace(
    '        filter.addAction(ACTION_SIRI_FINISHED);',
    '        filter.addAction(ACTION_SIRI_FINISHED);\n        filter.addAction(ACTION_LOCAL_FINISHED);',
    1)

anchor = '''    private boolean getSiriModeEnabled() {
        return prefs().getBoolean(MainActivity.KEY_SIRI_MODE_ENABLED, false);
    }'''
if anchor not in s:
    raise SystemExit('v1.9: Siri preference method anchor missing')
s = s.replace(anchor, anchor + '''

    private boolean getLocalModeEnabled() {
        return prefs().getBoolean(MainActivity.KEY_LOCAL_MODE_ENABLED, false);
    }''', 1)

old = '''    private void triggerAssistant(String heard) {
        if (pausedForAssistant || stopping) return;
        if (getSiriModeEnabled()) triggerSiriMode(extractQueryAfterWakePhrase(heard));
        else triggerNormalAssistant();
    }'''
new = '''    private void triggerAssistant(String heard) {
        if (pausedForAssistant || stopping) return;
        String query = extractQueryAfterWakePhrase(heard);
        if (getLocalModeEnabled()) triggerLocalMode(query);
        else if (getSiriModeEnabled()) triggerSiriMode(query);
        else triggerNormalAssistant();
    }'''
if old not in s:
    raise SystemExit('v1.9: triggerAssistant anchor missing')
s = s.replace(old, new, 1)

normal_anchor = '    private void triggerNormalAssistant() {'
if normal_anchor not in s:
    raise SystemExit('v1.9: triggerNormalAssistant anchor missing')
local_method = '''    private void triggerLocalMode(String query) {
        beginAssistantPause();
        handler.removeCallbacks(assistantSessionTimeoutRunnable);
        handler.postDelayed(assistantSessionTimeoutRunnable, 2L * 60L * 1000L);
        setStatus("Free local AI — opening Siri-style popup");
        try {
            Intent open = new Intent(this, LocalModeActivity.class);
            open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            if (query != null && !query.trim().isEmpty()) {
                open.putExtra(LocalModeActivity.EXTRA_QUERY, query.trim());
            }
            startActivity(open);
        } catch (Throwable t) {
            setStatus("Could not open free local popup — re-arming listener");
            rearmAfterTrigger();
        }
    }

'''
s = s.replace(normal_anchor, local_method + normal_anchor, 1)
p.write_text(s)

# ---------------- MainActivity: local model controls ----------------
p = Path('app/src/main/java/com/example/heychatgptassist/MainActivity.java')
s = p.read_text()
s = s.replace('Hey ChatGPT Assist v1.8', 'Hey ChatGPT Assist v1.9')
s = s.replace(
    '    public static final String KEY_OPENAI_API_KEY = "openai_api_key";',
    '    public static final String KEY_OPENAI_API_KEY = "openai_api_key";\n'
    '    public static final String KEY_LOCAL_MODE_ENABLED = "local_mode_enabled";',
    1)
s = s.replace(
    '    private EditText apiKeyInput;',
    '    private EditText apiKeyInput;\n    private CheckBox localModeToggle;\n    private TextView localModelStatus;',
    1)

# Make API and local toggles mutually exclusive.
old_listener = '''        siriModeToggle.setOnCheckedChangeListener((buttonView, checked) -> {
            prefs().edit().putBoolean(KEY_SIRI_MODE_ENABLED, checked).apply();
            updateCompanionStatus();
        });'''
new_listener = '''        siriModeToggle.setOnCheckedChangeListener((buttonView, checked) -> {
            if (checked) {
                prefs().edit().putBoolean(KEY_LOCAL_MODE_ENABLED, false).apply();
                if (localModeToggle != null) localModeToggle.setChecked(false);
            }
            prefs().edit().putBoolean(KEY_SIRI_MODE_ENABLED, checked).apply();
            updateCompanionStatus();
            updateLocalModelStatus();
        });'''
if old_listener not in s:
    raise SystemExit('v1.9: Siri toggle listener anchor missing')
s = s.replace(old_listener, new_listener, 1)

status_anchor = '''        companionStatus = new TextView(this);
        companionStatus.setTextSize(14);
        root.addView(companionStatus);

'''
if status_anchor not in s:
    raise SystemExit('v1.9: companion status UI anchor missing')
local_ui = '''        companionStatus = new TextView(this);
        companionStatus.setTextSize(14);
        root.addView(companionStatus);

        addHeading(root, "Free local AI", 20);
        addNote(root, "No API credits or subscription needed. The first setup downloads a ~429 MB Qwen2.5 0.5B model once, then answers are generated on your S22 itself. The model is only loaded after you activate the popup and is unloaded when the popup closes, so it does not sit in memory while you play games. Local answers are not ChatGPT and cannot know live information such as current weather unless it was in the model's training data.");
        localModeToggle = new CheckBox(this);
        localModeToggle.setText("Use FREE local Siri text mode for wake phrase");
        localModeToggle.setChecked(prefs().getBoolean(KEY_LOCAL_MODE_ENABLED, false));
        localModeToggle.setOnCheckedChangeListener((buttonView, checked) -> {
            if (checked) {
                prefs().edit().putBoolean(KEY_SIRI_MODE_ENABLED, false).apply();
                if (siriModeToggle != null) siriModeToggle.setChecked(false);
            }
            prefs().edit().putBoolean(KEY_LOCAL_MODE_ENABLED, checked).apply();
            updateLocalModelStatus();
            updateCompanionStatus();
        });
        root.addView(localModeToggle);

        localModelStatus = new TextView(this);
        localModelStatus.setTextSize(14);
        localModelStatus.setPadding(0, dp(4), 0, dp(4));
        root.addView(localModelStatus);

        addButton(root, "DOWNLOAD FREE LOCAL MODEL (~429 MB)", v -> {
            localModelStatus.setText("Local model: starting download…");
            v.setEnabled(false);
            LocalModelManager.download(this, new LocalModelManager.Callback() {
                @Override public void onProgress(int percent) {
                    runOnUiThread(() -> localModelStatus.setText("Local model: downloading… " + percent + "%"));
                }
                @Override public void onComplete(java.io.File file) {
                    runOnUiThread(() -> {
                        v.setEnabled(true);
                        updateLocalModelStatus();
                        Toast.makeText(MainActivity.this, "Free local model ready", Toast.LENGTH_SHORT).show();
                    });
                }
                @Override public void onError(String message) {
                    runOnUiThread(() -> {
                        v.setEnabled(true);
                        localModelStatus.setText("Local model download failed: " + message);
                    });
                }
            });
        });
        addButton(root, "DELETE LOCAL MODEL", v -> {
            boolean deleted = LocalModelManager.deleteModel(this);
            Toast.makeText(this, deleted ? "Local model deleted" : "No local model to delete", Toast.LENGTH_SHORT).show();
            updateLocalModelStatus();
        });
        addNote(root, "The small animated voice bubble only exists while the local/API assistant popup is open. It disappears completely when you close the popup; nothing is left floating over games or other apps.");

'''
s = s.replace(status_anchor, local_ui, 1)

# Add helper status method before updateCompanionStatus.
method_anchor = '    private void updateCompanionStatus() {'
if method_anchor not in s:
    raise SystemExit('v1.9: updateCompanionStatus anchor missing')
local_status_method = '''    private void updateLocalModelStatus() {
        if (localModelStatus == null) return;
        boolean installed = LocalModelManager.isModelReady(this);
        boolean enabled = prefs().getBoolean(KEY_LOCAL_MODE_ENABLED, false);
        localModelStatus.setText("Free local mode: " + (enabled ? "ON" : "OFF") +
                " | Model: " + (installed ? "ready" : "not downloaded"));
    }

'''
s = s.replace(method_anchor, local_status_method + method_anchor, 1)

# Include local state in companion status.
s = s.replace(
    '        boolean siri = prefs().getBoolean(KEY_SIRI_MODE_ENABLED, false);',
    '        boolean siri = prefs().getBoolean(KEY_SIRI_MODE_ENABLED, false);\n'
    '        boolean local = prefs().getBoolean(KEY_LOCAL_MODE_ENABLED, false);',
    1)
s = s.replace(
    '        companionStatus.setText("Siri text mode: " + (siri ? "ON" : "OFF") +',
    '        companionStatus.setText("Mode: " + (local ? "FREE LOCAL" : (siri ? "OPENAI API" : "NORMAL CHATGPT")) +\n'
    '                " | Siri API: " + (siri ? "ON" : "OFF") +',
    1)

# onResume status refresh.
s = s.replace(
    '        updateCompanionStatus();\n        updateTemporaryVoiceStatus();',
    '        updateCompanionStatus();\n        updateLocalModelStatus();\n        updateTemporaryVoiceStatus();',
    1)
p.write_text(s)

# ---------------- SiriModeActivity: restore an animated voice bubble ----------------
p = Path('app/src/main/java/com/example/heychatgptassist/SiriModeActivity.java')
s = p.read_text()
if 'import android.animation.ObjectAnimator;' not in s:
    s = s.replace('package com.example.heychatgptassist;\n\n',
                  'package com.example.heychatgptassist;\n\nimport android.animation.AnimatorSet;\nimport android.animation.ObjectAnimator;\nimport android.animation.ValueAnimator;\n', 1)
if 'import android.view.View;' not in s:
    s = s.replace('import android.view.Gravity;\n', 'import android.view.Gravity;\nimport android.view.View;\n', 1)
s = s.replace(
    '    private TextView answerText;',
    '    private TextView answerText;\n    private View voiceBubble;\n    private AnimatorSet bubbleAnimator;',
    1)

bubble_anchor = '        panel.addView(header);\n\n        statusText = new TextView(this);'
if bubble_anchor not in s:
    raise SystemExit('v1.9: Siri bubble UI anchor missing')
bubble_code = '''        panel.addView(header);

        voiceBubble = new View(this);
        GradientDrawable bubbleBg = new GradientDrawable();
        bubbleBg.setShape(GradientDrawable.OVAL);
        bubbleBg.setColor(Color.rgb(215, 215, 220));
        voiceBubble.setBackground(bubbleBg);
        LinearLayout.LayoutParams bubbleLp = new LinearLayout.LayoutParams(dp(42), dp(42));
        bubbleLp.gravity = Gravity.CENTER_HORIZONTAL;
        bubbleLp.setMargins(0, dp(3), 0, dp(6));
        panel.addView(voiceBubble, bubbleLp);
        startBubbleAnimation();

        statusText = new TextView(this);'''
s = s.replace(bubble_anchor, bubble_code, 1)

method_insert = '''    private void startBubbleAnimation() {
        if (voiceBubble == null) return;
        ObjectAnimator sx = ObjectAnimator.ofFloat(voiceBubble, View.SCALE_X, 0.82f, 1.08f);
        ObjectAnimator sy = ObjectAnimator.ofFloat(voiceBubble, View.SCALE_Y, 0.82f, 1.08f);
        ObjectAnimator alpha = ObjectAnimator.ofFloat(voiceBubble, View.ALPHA, 0.55f, 1.0f);
        sx.setRepeatCount(ValueAnimator.INFINITE); sx.setRepeatMode(ValueAnimator.REVERSE);
        sy.setRepeatCount(ValueAnimator.INFINITE); sy.setRepeatMode(ValueAnimator.REVERSE);
        alpha.setRepeatCount(ValueAnimator.INFINITE); alpha.setRepeatMode(ValueAnimator.REVERSE);
        sx.setDuration(850L); sy.setDuration(850L); alpha.setDuration(850L);
        bubbleAnimator = new AnimatorSet();
        bubbleAnimator.playTogether(sx, sy, alpha);
        bubbleAnimator.start();
    }

'''
destroy_anchor = '    @Override\n    protected void onDestroy() {'
if destroy_anchor not in s:
    raise SystemExit('v1.9: Siri onDestroy anchor missing')
s = s.replace(destroy_anchor, method_insert + destroy_anchor, 1)
s = s.replace(
    '        handler.removeCallbacksAndMessages(null);',
    '        handler.removeCallbacksAndMessages(null);\n        if (bubbleAnimator != null) bubbleAnimator.cancel();',
    1)
p.write_text(s)

# ---------------- Local model manager ----------------
Path('app/src/main/java/com/example/heychatgptassist/LocalModelManager.java').write_text(r'''package com.example.heychatgptassist;

import android.content.Context;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.Locale;

public final class LocalModelManager {
    private LocalModelManager() {}

    public static final String MODEL_NAME = "qwen2.5-0.5b-instruct-q4_0.gguf";
    public static final long MIN_READY_BYTES = 400L * 1024L * 1024L;
    private static final String MODEL_URL = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_0.gguf?download=true";
    private static final String EXPECTED_SHA256 = "7671c0c304e6ce5a7fc577bcb12aba01e2c155cc2efd29b2213c95b18edaf6ed";

    public interface Callback {
        void onProgress(int percent);
        void onComplete(File file);
        void onError(String message);
    }

    public static File getModelFile(Context context) {
        File dir = new File(context.getFilesDir(), "local_models");
        return new File(dir, MODEL_NAME);
    }

    public static boolean isModelReady(Context context) {
        File f = getModelFile(context);
        return f.isFile() && f.length() >= MIN_READY_BYTES;
    }

    public static boolean deleteModel(Context context) {
        File f = getModelFile(context);
        File part = new File(f.getParentFile(), MODEL_NAME + ".part");
        boolean existed = f.exists() || part.exists();
        if (f.exists()) f.delete();
        if (part.exists()) part.delete();
        return existed;
    }

    public static void download(Context context, Callback callback) {
        final Context app = context.getApplicationContext();
        new Thread(() -> {
            HttpURLConnection c = null;
            FileOutputStream out = null;
            try {
                File target = getModelFile(app);
                File dir = target.getParentFile();
                if (!dir.exists() && !dir.mkdirs()) throw new Exception("could not create model folder");
                if (dir.getUsableSpace() < 520L * 1024L * 1024L) {
                    throw new Exception("need about 520 MB free storage");
                }
                File part = new File(dir, MODEL_NAME + ".part");
                if (part.exists()) part.delete();

                URL url = new URL(MODEL_URL);
                c = (HttpURLConnection) url.openConnection();
                c.setConnectTimeout(20000);
                c.setReadTimeout(30000);
                c.setInstanceFollowRedirects(true);
                c.setRequestProperty("User-Agent", "HeyChatGPTAssist/1.9");
                c.connect();
                int code = c.getResponseCode();
                if (code < 200 || code >= 300) throw new Exception("HTTP " + code);
                long total = c.getContentLengthLong();

                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                BufferedInputStream in = new BufferedInputStream(c.getInputStream(), 64 * 1024);
                out = new FileOutputStream(part);
                byte[] buffer = new byte[64 * 1024];
                long done = 0L;
                int lastPercent = -1;
                int n;
                while ((n = in.read(buffer)) >= 0) {
                    if (n == 0) continue;
                    out.write(buffer, 0, n);
                    digest.update(buffer, 0, n);
                    done += n;
                    if (total > 0L) {
                        int p = (int) Math.min(100L, done * 100L / total);
                        if (p != lastPercent) {
                            lastPercent = p;
                            callback.onProgress(p);
                        }
                    }
                }
                in.close();
                out.flush();
                out.close(); out = null;

                StringBuilder hex = new StringBuilder();
                for (byte b : digest.digest()) hex.append(String.format(Locale.US, "%02x", b & 0xff));
                if (!EXPECTED_SHA256.equalsIgnoreCase(hex.toString())) {
                    part.delete();
                    throw new Exception("download checksum did not match");
                }
                if (target.exists()) target.delete();
                if (!part.renameTo(target)) throw new Exception("could not finish model file");
                callback.onProgress(100);
                callback.onComplete(target);
            } catch (Throwable t) {
                callback.onError(t.getMessage() == null ? t.getClass().getSimpleName() : t.getMessage());
            } finally {
                try { if (out != null) out.close(); } catch (Throwable ignored) {}
                if (c != null) c.disconnect();
            }
        }, "local-model-download").start();
    }
}
''')

# ---------------- Local Siri-style popup ----------------
Path('app/src/main/java/com/example/heychatgptassist/LocalModeActivity.kt').write_text(r'''package com.example.heychatgptassist

import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.arm.aichat.AiChat
import com.arm.aichat.InferenceEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.util.Locale

class LocalModeActivity : Activity(), RecognitionListener, TextToSpeech.OnInitListener {
    companion object { const val EXTRA_QUERY = "query" }

    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var recognizer: SpeechRecognizer? = null
    private var tts: TextToSpeech? = null
    private var engine: InferenceEngine? = null
    private lateinit var statusText: TextView
    private lateinit var questionText: TextView
    private lateinit var answerText: TextView
    private var voiceBubble: View? = null
    private var bubbleAnimator: AnimatorSet? = null
    private var finishedBroadcastSent = false
    private var ttsReady = false
    private var pendingSpeak = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setBackgroundDrawableResource(android.R.color.transparent)
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH)
        window.setGravity(Gravity.TOP or Gravity.CENTER_HORIZONTAL)
        buildUi()
        window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.WRAP_CONTENT)
        tts = TextToSpeech(this, this)
        val query = intent?.getStringExtra(EXTRA_QUERY)?.trim().orEmpty()
        if (query.isNotEmpty()) submitQuestion(query) else startQuestionListening()
    }

    private fun buildUi() {
        val outer = FrameLayout(this).apply { setPadding(dp(12), dp(54), dp(12), dp(8)) }
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(12), dp(14), dp(14))
            background = GradientDrawable().apply {
                setColor(Color.argb(245, 28, 28, 30)); cornerRadius = dp(24).toFloat()
            }
            elevation = dp(12).toFloat()
        }
        val header = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val title = TextView(this).apply {
            text = "Local AI"; setTextColor(Color.WHITE); textSize = 16f; setTypeface(Typeface.DEFAULT, Typeface.BOLD)
        }
        header.addView(title, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val close = TextView(this).apply {
            text = "×"; setTextColor(Color.LTGRAY); textSize = 28f; gravity = Gravity.CENTER
            setPadding(dp(12), 0, dp(2), 0); setOnClickListener { finish() }
        }
        header.addView(close); panel.addView(header)

        voiceBubble = View(this).also { bubble ->
            bubble.background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.rgb(215, 215, 220)) }
            panel.addView(bubble, LinearLayout.LayoutParams(dp(42), dp(42)).apply {
                gravity = Gravity.CENTER_HORIZONTAL; setMargins(0, dp(3), 0, dp(6))
            })
        }
        startBubbleAnimation()

        statusText = TextView(this).apply { setTextColor(Color.LTGRAY); textSize = 13f; setPadding(0, dp(2), 0, dp(4)) }
        panel.addView(statusText)
        questionText = TextView(this).apply {
            setTextColor(Color.rgb(205,205,210)); textSize = 14f; maxLines = 3; ellipsize = TextUtils.TruncateAt.END
        }
        panel.addView(questionText)
        answerText = TextView(this).apply {
            setTextColor(Color.WHITE); textSize = 18f; setLineSpacing(0f, 1.08f); maxLines = 10
            ellipsize = TextUtils.TruncateAt.END; setPadding(0, dp(6), 0, 0)
        }
        panel.addView(answerText)
        outer.addView(panel, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        setContentView(outer)
    }

    private fun startBubbleAnimation() {
        val b = voiceBubble ?: return
        val sx = ObjectAnimator.ofFloat(b, View.SCALE_X, .82f, 1.08f)
        val sy = ObjectAnimator.ofFloat(b, View.SCALE_Y, .82f, 1.08f)
        val a = ObjectAnimator.ofFloat(b, View.ALPHA, .55f, 1f)
        listOf(sx, sy, a).forEach { it.duration = 850L; it.repeatCount = ValueAnimator.INFINITE; it.repeatMode = ValueAnimator.REVERSE }
        bubbleAnimator = AnimatorSet().apply { playTogether(sx, sy, a); start() }
    }

    private fun startQuestionListening() {
        statusText.text = "Listening…"
        questionText.text = "Say your question"
        answerText.text = ""
        try {
            recognizer = SpeechRecognizer.createSpeechRecognizer(this).also { it.setRecognitionListener(this) }
            recognizer?.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            })
        } catch (_: Throwable) { showError("Could not start voice input") }
    }

    private fun submitQuestion(question: String) {
        if (question.isBlank()) { showError("I didn't catch a question"); return }
        recognizer?.let { try { it.cancel() } catch (_: Throwable) {}; try { it.destroy() } catch (_: Throwable) {} }
        recognizer = null
        questionText.text = "You: $question"
        answerText.text = ""
        val model = LocalModelManager.getModelFile(this)
        if (!LocalModelManager.isModelReady(this)) {
            showError("Free local model isn't downloaded yet — open the helper and tap DOWNLOAD FREE LOCAL MODEL")
            return
        }
        statusText.text = "Loading local AI…"
        scope.launch {
            try {
                val e = AiChat.getInferenceEngine(applicationContext)
                engine = e
                val ready = withTimeout(30_000L) {
                    e.state.first { it is InferenceEngine.State.Initialized || it is InferenceEngine.State.Error }
                }
                if (ready is InferenceEngine.State.Error) throw ready.exception
                e.loadModel(model.absolutePath)
                e.setSystemPrompt("You are a concise phone voice assistant. Answer clearly and briefly unless the user asks for detail. If the question needs live/current data you do not have, say that clearly instead of inventing it.")
                statusText.text = "Thinking locally…"
                val built = StringBuilder()
                e.sendUserPrompt(question, 220).collect { token ->
                    built.append(token)
                    answerText.text = built.toString().trimStart()
                }
                val answer = built.toString().trim()
                if (answer.isEmpty()) showError("Local model returned no answer") else showAnswer(answer)
            } catch (t: Throwable) {
                showError("Local AI error: ${t.message ?: t.javaClass.simpleName}")
            }
        }
    }

    private fun showAnswer(answer: String) {
        statusText.text = "Speaking"
        answerText.text = answer
        speakOrQueue(answer)
    }

    private fun showError(message: String) {
        statusText.text = "Couldn't complete request"
        answerText.text = message
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ finish() }, 12_000L)
    }

    private fun speakOrQueue(answer: String) {
        if (answer.isBlank()) return
        val t = tts
        if (!ttsReady || t == null) { pendingSpeak = answer; return }
        t.speak(answer, TextToSpeech.QUEUE_FLUSH, Bundle(), "local-answer")
    }

    override fun onInit(status: Int) {
        val t = tts ?: return
        if (status != TextToSpeech.SUCCESS) return
        ttsReady = true
        t.language = Locale.getDefault()
        t.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onError(utteranceId: String?) { handler.postDelayed({ finish() }, 8_000L) }
            override fun onDone(utteranceId: String?) { handler.post { statusText.text = "Done"; handler.postDelayed({ finish() }, 5_000L) } }
        })
        if (pendingSpeak.isNotEmpty()) { val x = pendingSpeak; pendingSpeak = ""; speakOrQueue(x) }
    }

    private fun firstResult(results: Bundle?): String {
        val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
        return list?.firstOrNull()?.trim().orEmpty()
    }

    override fun onReadyForSpeech(params: Bundle?) { statusText.text = "Listening…" }
    override fun onBeginningOfSpeech() { statusText.text = "Listening…" }
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() { statusText.text = "Processing question…" }
    override fun onError(error: Int) { showError("I didn't catch that — close and try again") }
    override fun onResults(results: Bundle?) { submitQuestion(firstResult(results)) }
    override fun onPartialResults(partialResults: Bundle?) { firstResult(partialResults).takeIf { it.isNotEmpty() }?.let { questionText.text = "You: $it" } }
    override fun onEvent(eventType: Int, params: Bundle?) {}

    private fun sendFinishedBroadcast() {
        if (finishedBroadcastSent) return
        finishedBroadcastSent = true
        sendBroadcast(Intent(WakeListenerService.ACTION_LOCAL_FINISHED).setPackage(packageName))
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        bubbleAnimator?.cancel()
        recognizer?.let { try { it.cancel() } catch (_: Throwable) {}; try { it.destroy() } catch (_: Throwable) {} }
        recognizer = null
        tts?.let { try { it.stop() } catch (_: Throwable) {}; try { it.shutdown() } catch (_: Throwable) {} }
        tts = null
        try {
            engine?.let { e ->
                val st = e.state.value
                if (st is InferenceEngine.State.ModelReady || st is InferenceEngine.State.Error) e.cleanUp()
            }
        } catch (_: Throwable) {}
        scope.cancel()
        sendFinishedBroadcast()
        super.onDestroy()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
}
''')

# ---------------- Manifest ----------------
p = Path('app/src/main/AndroidManifest.xml')
s = p.read_text()
activity_anchor = '''        <activity
            android:name=".SiriModeActivity"'''
if activity_anchor not in s:
    raise SystemExit('v1.9: SiriModeActivity manifest anchor missing')
s = s.replace(activity_anchor, '''        <activity
            android:name=".LocalModeActivity"
            android:exported="false"
            android:excludeFromRecents="true"
            android:theme="@style/SiriPopupTheme" />

        <activity
            android:name=".SiriModeActivity"''', 1)
p.write_text(s)

# ---------------- Gradle: Kotlin + local llama.android module ----------------
p = Path('build.gradle')
s = p.read_text()
if "com.android.library" not in s:
    s = s.replace("id 'com.android.application' version '8.7.3' apply false",
                  "id 'com.android.application' version '8.7.3' apply false\n    id 'com.android.library' version '8.7.3' apply false\n    id 'org.jetbrains.kotlin.android' version '2.1.21' apply false", 1)
p.write_text(s)

p = Path('settings.gradle')
s = p.read_text()
if 'include(":aichat")' not in s:
    s += '\ninclude(":aichat")\nproject(":aichat").projectDir = file("llama.cpp/examples/llama.android/lib")\n'
p.write_text(s)

p = Path('app/build.gradle')
s = p.read_text()
s = s.replace("id 'com.android.application'\n", "id 'com.android.application'\n    id 'org.jetbrains.kotlin.android'\n", 1)
s = s.replace('versionCode 18', 'versionCode 19', 1)
s = s.replace('versionName "1.8"', 'versionName "1.9"', 1)
if 'compileOptions {' not in s:
    s = s.replace('\n}\n\ndependencies {', '''
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = '17' }
}

dependencies {''', 1)
if "implementation project(':aichat')" not in s:
    s = s.replace('dependencies {', '''dependencies {
    implementation project(':aichat')
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2"''', 1)
p.write_text(s)
