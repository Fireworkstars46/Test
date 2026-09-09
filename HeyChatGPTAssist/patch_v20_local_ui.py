from pathlib import Path
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
import com.arm.aichat.UnsupportedArchitectureException
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
        window.setGravity(Gravity.FILL)
        buildUi()
        window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
        tts = TextToSpeech(this, this)
        val query = intent?.getStringExtra(EXTRA_QUERY)?.trim().orEmpty()
        if (query.isNotEmpty()) submitQuestion(query) else startQuestionListening()
    }

    private fun buildUi() {
        val outer = FrameLayout(this).apply { setPadding(dp(12), dp(20), dp(12), dp(24)) }

        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(12), dp(16), dp(16))
            background = GradientDrawable().apply {
                setColor(Color.argb(246, 28, 28, 30)); cornerRadius = dp(24).toFloat()
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
        header.addView(close)
        panel.addView(header)

        statusText = TextView(this).apply { setTextColor(Color.LTGRAY); textSize = 13f; setPadding(0, dp(2), 0, dp(4)) }
        panel.addView(statusText)
        questionText = TextView(this).apply {
            setTextColor(Color.rgb(205,205,210)); textSize = 14f; maxLines = 2; ellipsize = TextUtils.TruncateAt.END
        }
        panel.addView(questionText)
        answerText = TextView(this).apply {
            setTextColor(Color.WHITE); textSize = 18f; setLineSpacing(0f, 1.08f); maxLines = 8
            ellipsize = TextUtils.TruncateAt.END; setPadding(0, dp(6), 0, 0)
        }
        panel.addView(answerText)

        outer.addView(panel, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM
        ).apply { bottomMargin = dp(122) })

        voiceBubble = View(this).also { bubble ->
            bubble.background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(
                    Color.rgb(104, 74, 255),
                    Color.rgb(55, 177, 255),
                    Color.rgb(255, 80, 174),
                    Color.rgb(88, 58, 214)
                )
            ).apply { shape = GradientDrawable.OVAL }
            bubble.elevation = dp(18).toFloat()
            outer.addView(bubble, FrameLayout.LayoutParams(dp(78), dp(78), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
                bottomMargin = dp(18)
            })
        }
        setContentView(outer)
        startBubbleAnimation()
    }

    private fun startBubbleAnimation() {
        val b = voiceBubble ?: return
        val sx = ObjectAnimator.ofFloat(b, View.SCALE_X, .90f, 1.08f)
        val sy = ObjectAnimator.ofFloat(b, View.SCALE_Y, .90f, 1.08f)
        val a = ObjectAnimator.ofFloat(b, View.ALPHA, .78f, 1f)
        val r = ObjectAnimator.ofFloat(b, View.ROTATION, 0f, 360f)
        listOf(sx, sy, a).forEach {
            it.duration = 800L; it.repeatCount = ValueAnimator.INFINITE; it.repeatMode = ValueAnimator.REVERSE
        }
        r.duration = 4200L; r.repeatCount = ValueAnimator.INFINITE; r.repeatMode = ValueAnimator.RESTART
        bubbleAnimator = AnimatorSet().apply { playTogether(sx, sy, a, r); start() }
    }

    private fun startQuestionListening() {
        statusText.text = "Listening…"
        questionText.text = "Say your question"
        answerText.text = ""
        try {
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
            val legacy = LocalModelManager.hasLegacyV19Model(this)
            showError(if (legacy)
                "v1.9's local model was incompatible. Open the helper and download the corrected ~353 MB v2.0 model."
            else
                "Free local model isn't downloaded yet — open the helper and tap DOWNLOAD FREE LOCAL MODEL")
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
            } catch (_: UnsupportedArchitectureException) {
                showError("This model could not load. Delete the local model in the helper, then download the corrected v2.0 model again.")
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
