package com.example.heychatgptassist;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.text.InputType;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Locale;

public class SiriModeActivity extends Activity implements RecognitionListener, TextToSpeech.OnInitListener {
    public static final String EXTRA_QUERY = "query";

    private final Handler handler = new Handler(Looper.getMainLooper());
    private SpeechRecognizer recognizer;
    private TextToSpeech tts;
    private TextView statusText;
    private TextView questionText;
    private TextView answerText;
    private boolean finishedBroadcastSent = false;
    private boolean ttsReady = false;
    private String pendingSpeak = "";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        Window window = getWindow();
        window.setBackgroundDrawableResource(android.R.color.transparent);
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL |
                WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH);
        window.setGravity(Gravity.TOP | Gravity.CENTER_HORIZONTAL);

        buildUi();
        window.setLayout(WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.WRAP_CONTENT);

        tts = new TextToSpeech(this, this);

        String query = getIntent() == null ? "" : getIntent().getStringExtra(EXTRA_QUERY);
        if (query != null) query = query.trim();
        if (!TextUtils.isEmpty(query)) {
            submitQuestion(query);
        } else {
            startQuestionListening();
        }
    }

    private void buildUi() {
        FrameLayout outer = new FrameLayout(this);
        outer.setPadding(dp(12), dp(54), dp(12), dp(8));

        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(18), dp(12), dp(14), dp(14));

        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Color.argb(245, 28, 28, 30));
        bg.setCornerRadius(dp(24));
        panel.setBackground(bg);
        panel.setElevation(dp(12));

        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);

        TextView title = new TextView(this);
        title.setText("ChatGPT");
        title.setTextColor(Color.WHITE);
        title.setTextSize(16);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        header.addView(title, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView close = new TextView(this);
        close.setText("×");
        close.setTextColor(Color.LTGRAY);
        close.setTextSize(28);
        close.setGravity(Gravity.CENTER);
        close.setPadding(dp(12), 0, dp(2), 0);
        close.setOnClickListener(v -> finish());
        header.addView(close);
        panel.addView(header);

        statusText = new TextView(this);
        statusText.setTextColor(Color.LTGRAY);
        statusText.setTextSize(13);
        statusText.setPadding(0, dp(2), 0, dp(4));
        panel.addView(statusText);

        questionText = new TextView(this);
        questionText.setTextColor(Color.rgb(205, 205, 210));
        questionText.setTextSize(14);
        questionText.setMaxLines(3);
        questionText.setEllipsize(TextUtils.TruncateAt.END);
        panel.addView(questionText);

        answerText = new TextView(this);
        answerText.setTextColor(Color.WHITE);
        answerText.setTextSize(18);
        answerText.setLineSpacing(0f, 1.08f);
        answerText.setMaxLines(10);
        answerText.setEllipsize(TextUtils.TruncateAt.END);
        answerText.setPadding(0, dp(6), 0, 0);
        panel.addView(answerText);

        outer.addView(panel, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        setContentView(outer);
    }

    private SharedPreferences prefs() {
        return getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE);
    }

    private void startQuestionListening() {
        statusText.setText("Listening…");
        questionText.setText("Say your question");
        answerText.setText("");
        try {
            recognizer = SpeechRecognizer.createSpeechRecognizer(this);
            recognizer.setRecognitionListener(this);
            Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
            intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
            intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
            intent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3);
            recognizer.startListening(intent);
        } catch (Throwable t) {
            showError("Could not start voice input");
        }
    }

    private void submitQuestion(String question) {
        if (TextUtils.isEmpty(question)) {
            showError("I didn't catch a question");
            return;
        }
        if (recognizer != null) {
            try { recognizer.cancel(); } catch (Throwable ignored) {}
            try { recognizer.destroy(); } catch (Throwable ignored) {}
            recognizer = null;
        }

        questionText.setText("You: " + question);
        answerText.setText("");
        statusText.setText("Thinking…");

        final String apiKey = prefs().getString(MainActivity.KEY_OPENAI_API_KEY, "").trim();
        if (apiKey.isEmpty()) {
            showError("OpenAI API key missing — open the helper and save one first");
            return;
        }

        new Thread(() -> callOpenAi(apiKey, question), "siri-api-request").start();
    }

    private void callOpenAi(String apiKey, String question) {
        HttpURLConnection connection = null;
        try {
            URL url = new URL("https://api.openai.com/v1/responses");
            connection = (HttpURLConnection) url.openConnection();
            connection.setRequestMethod("POST");
            connection.setConnectTimeout(20000);
            connection.setReadTimeout(60000);
            connection.setDoOutput(true);
            connection.setRequestProperty("Authorization", "Bearer " + apiKey);
            connection.setRequestProperty("Content-Type", "application/json");

            JSONObject body = new JSONObject();
            body.put("model", "gpt-5.6-luna");
            body.put("input", "You are a concise phone voice assistant. Answer clearly and briefly unless the user asks for detail. User: " + question);
            body.put("max_output_tokens", 500);

            byte[] payload = body.toString().getBytes(StandardCharsets.UTF_8);
            try (OutputStream os = connection.getOutputStream()) {
                os.write(payload);
            }

            int code = connection.getResponseCode();
            InputStream stream = code >= 200 && code < 300
                    ? connection.getInputStream() : connection.getErrorStream();
            String raw = readAll(stream);

            if (code < 200 || code >= 300) {
                String message = "API error " + code;
                try {
                    JSONObject err = new JSONObject(raw).optJSONObject("error");
                    if (err != null && !TextUtils.isEmpty(err.optString("message"))) {
                        message = err.optString("message");
                    }
                } catch (Throwable ignored) {}
                final String finalMessage = message;
                handler.post(() -> showError(finalMessage));
                return;
            }

            String answer = extractText(raw);
            if (TextUtils.isEmpty(answer)) answer = "No text response was returned.";
            final String finalAnswer = answer.trim();
            handler.post(() -> showAnswer(finalAnswer));
        } catch (Throwable t) {
            handler.post(() -> showError("API request failed: " + t.getClass().getSimpleName()));
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    private String readAll(InputStream stream) throws Exception {
        if (stream == null) return "";
        StringBuilder sb = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(stream, StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) sb.append(line);
        }
        return sb.toString();
    }

    private String extractText(String raw) {
        try {
            JSONObject root = new JSONObject(raw);
            String direct = root.optString("output_text", "").trim();
            if (!direct.isEmpty()) return direct;

            JSONArray output = root.optJSONArray("output");
            if (output == null) return "";
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < output.length(); i++) {
                JSONObject item = output.optJSONObject(i);
                if (item == null) continue;
                JSONArray content = item.optJSONArray("content");
                if (content == null) continue;
                for (int j = 0; j < content.length(); j++) {
                    JSONObject part = content.optJSONObject(j);
                    if (part == null) continue;
                    String type = part.optString("type", "");
                    if ("output_text".equals(type) || "text".equals(type)) {
                        String text = part.optString("text", "");
                        if (!TextUtils.isEmpty(text)) {
                            if (sb.length() > 0) sb.append('\n');
                            sb.append(text);
                        }
                    }
                }
            }
            return sb.toString();
        } catch (Throwable ignored) {
            return "";
        }
    }

    private void showAnswer(String answer) {
        statusText.setText("Speaking");
        answerText.setText(answer);
        speakOrQueue(answer);
    }

    private void showError(String message) {
        statusText.setText("Couldn’t complete request");
        answerText.setText(message);
        handler.removeCallbacksAndMessages(null);
        handler.postDelayed(this::finish, 12000L);
    }

    private void speakOrQueue(String answer) {
        if (TextUtils.isEmpty(answer)) return;
        if (!ttsReady || tts == null) {
            pendingSpeak = answer;
            return;
        }
        Bundle params = new Bundle();
        tts.speak(answer, TextToSpeech.QUEUE_FLUSH, params, "siri-answer");
    }

    @Override
    public void onInit(int status) {
        if (status != TextToSpeech.SUCCESS || tts == null) return;
        ttsReady = true;
        tts.setLanguage(Locale.getDefault());
        tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
            @Override public void onStart(String utteranceId) {}
            @Override public void onError(String utteranceId) {
                handler.postDelayed(SiriModeActivity.this::finish, 8000L);
            }
            @Override public void onDone(String utteranceId) {
                handler.post(() -> {
                    statusText.setText("Done");
                    handler.postDelayed(SiriModeActivity.this::finish, 5000L);
                });
            }
        });
        if (!pendingSpeak.isEmpty()) {
            String text = pendingSpeak;
            pendingSpeak = "";
            speakOrQueue(text);
        }
    }

    private String firstResult(Bundle results) {
        if (results == null) return "";
        ArrayList<String> list = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        if (list == null || list.isEmpty() || list.get(0) == null) return "";
        return list.get(0).trim();
    }

    @Override public void onReadyForSpeech(Bundle params) { statusText.setText("Listening…"); }
    @Override public void onBeginningOfSpeech() { statusText.setText("Listening…"); }
    @Override public void onRmsChanged(float rmsdB) {}
    @Override public void onBufferReceived(byte[] buffer) {}
    @Override public void onEndOfSpeech() { statusText.setText("Processing question…"); }
    @Override public void onError(int error) { showError("I didn't catch that — close and try again"); }
    @Override public void onResults(Bundle results) { submitQuestion(firstResult(results)); }
    @Override public void onPartialResults(Bundle partialResults) {
        String partial = firstResult(partialResults);
        if (!partial.isEmpty()) questionText.setText("You: " + partial);
    }
    @Override public void onEvent(int eventType, Bundle params) {}

    private void sendFinishedBroadcast() {
        if (finishedBroadcastSent) return;
        finishedBroadcastSent = true;
        sendBroadcast(new Intent(WakeListenerService.ACTION_SIRI_FINISHED)
                .setPackage(getPackageName()));
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (recognizer != null) {
            try { recognizer.cancel(); } catch (Throwable ignored) {}
            try { recognizer.destroy(); } catch (Throwable ignored) {}
            recognizer = null;
        }
        if (tts != null) {
            try { tts.stop(); } catch (Throwable ignored) {}
            try { tts.shutdown(); } catch (Throwable ignored) {}
            tts = null;
        }
        sendFinishedBroadcast();
        super.onDestroy();
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
