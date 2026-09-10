from pathlib import Path

# v2.3: real follow-up loop for Local AI.
p = Path('app/src/main/java/com/example/heychatgptassist/LocalModeActivity.kt')
s = p.read_text()

s = s.replace(
    '''        statusText.text = "Listening… tap the orb to pause"
        questionText.text = "Say your question"
        answerText.text = ""''',
    '''        statusText.text = "Listening… tap the orb to pause"
        if (questionText.text.isNullOrBlank()) questionText.text = "Say your question"''',
    1)

old_engine = r'''        scope.launch {
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
        }'''
new_engine = r'''        scope.launch {
            try {
                val e = engine ?: AiChat.getInferenceEngine(applicationContext).also { engine = it }
                var state = e.state.value
                if (state !is InferenceEngine.State.Initialized &&
                    state !is InferenceEngine.State.ModelReady &&
                    state !is InferenceEngine.State.Error) {
                    state = withTimeout(30_000L) {
                        e.state.first {
                            it is InferenceEngine.State.Initialized ||
                            it is InferenceEngine.State.ModelReady ||
                            it is InferenceEngine.State.Error
                        }
                    }
                }
                if (state is InferenceEngine.State.Error) throw state.exception
                if (state is InferenceEngine.State.Initialized) {
                    e.loadModel(model.absolutePath)
                }
                e.setSystemPrompt("You are a concise phone voice assistant. Answer clearly and briefly unless the user asks for detail. If the question needs live/current data you do not have, say that clearly instead of inventing it.")
                statusText.text = "Thinking locally…"
                answerText.text = ""
                val built = StringBuilder()
                e.sendUserPrompt(question, 220).collect { token ->
                    built.append(token)
                    answerText.text = built.toString().trimStart()
                }
                val answer = built.toString().trim()
                if (answer.isEmpty()) showError("Local model returned no answer") else showAnswer(answer)
            } catch (_: UnsupportedArchitectureException) {
                showError("This model could not load. Tap the orb to retry after the corrected local model finishes updating.")
            } catch (t: Throwable) {
                showError("Local AI error: ${t.message ?: t.javaClass.simpleName}")
            }
        }'''
if old_engine not in s:
    raise SystemExit('v2.3: local engine block missing')
s = s.replace(old_engine, new_engine, 1)

old_listener = r'''        t.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onError(utteranceId: String?) { handler.postDelayed({ finishAndRemoveTask() }, 8_000L) }
            override fun onDone(utteranceId: String?) { handler.post { statusText.text = "Done"; handler.postDelayed({ finishAndRemoveTask() }, 5_000L) } }
        })'''
new_listener = r'''        t.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                handler.post { statusText.text = "Speaking — tap the orb to interrupt" }
            }
            override fun onError(utteranceId: String?) {
                handler.post {
                    statusText.text = "Tap the orb to listen again"
                    sendMicState(false)
                }
            }
            override fun onDone(utteranceId: String?) {
                handler.post {
                    statusText.text = "Listening for a follow-up…"
                    handler.postDelayed({ startQuestionListening() }, 250L)
                }
            }
        })'''
if old_listener not in s:
    raise SystemExit('v2.3: TTS progress listener missing')
s = s.replace(old_listener, new_listener, 1)

old_error = r'''    private fun showError(message: String) {
        statusText.text = "Couldn't complete request"
        answerText.text = message
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ finishAndRemoveTask() }, 12_000L)
    }'''
new_error = r'''    private fun showError(message: String) {
        isQuestionListening = false
        sendMicState(false)
        statusText.text = "Couldn't complete request — tap the orb to retry"
        answerText.text = message
    }'''
if old_error not in s:
    raise SystemExit('v2.3: showError block missing')
s = s.replace(old_error, new_error, 1)

s = s.replace(
    '''    override fun onBeginningOfSpeech() { statusText.text = "Listening…" }''',
    '''    override fun onBeginningOfSpeech() {
        statusText.text = "Listening…"
        questionText.text = ""
    }''',
    1)

p.write_text(s)

p = Path('app/src/main/java/com/example/heychatgptassist/MainActivity.java')
s = p.read_text().replace('Hey ChatGPT Assist v2.2', 'Hey ChatGPT Assist v2.3')
s = s.replace(
    'Tap the orb while listening to pause and keep the popup open; tap it again to listen for another question. The background wake listener resumes whenever the popup itself is not using the microphone.',
    'After each spoken Local AI answer, v2.3 automatically listens for your next follow-up. Tap the orb while it is listening to pause and keep the popup open; tap again to resume. The background wake listener stays active whenever the popup itself is not using the microphone.')
p.write_text(s)

p = Path('app/build.gradle')
s = p.read_text()
if 'versionCode 22' not in s or 'versionName "2.2"' not in s:
    raise SystemExit('v2.3: expected v2.2 version fields missing')
s = s.replace('versionCode 22', 'versionCode 23', 1)
s = s.replace('versionName "2.2"', 'versionName "2.3"', 1)
p.write_text(s)
