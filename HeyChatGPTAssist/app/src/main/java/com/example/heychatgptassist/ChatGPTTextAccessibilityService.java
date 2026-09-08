package com.example.heychatgptassist;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

public class ChatGPTTextAccessibilityService extends AccessibilityService {
    public static final String KEY_LAST_ASSIST_TRIGGER_MS = "last_assist_trigger_ms";
    public static final String KEY_LAST_CAPTURED_TEXT = "last_captured_response_text";
    public static final String KEY_TEMP_REQUEST_MS = "temp_voice_request_ms";
    public static final String KEY_TEMP_AUTOMATION_STATUS = "temp_voice_automation_status";

    private static final String CHATGPT_PACKAGE = "com.openai.chatgpt";
    private static final long ASSIST_SESSION_WINDOW_MS = 10L * 60L * 1000L;
    private static final long TEMP_SETUP_WINDOW_MS = 18_000L;
    private static final long WINDOW_GONE_GRACE_MS = 650L;

    private static final int TEMP_IDLE = 0;
    private static final int TEMP_PREPARE_NEW_CHAT = 1;
    private static final int TEMP_FIND_TEMPORARY = 2;
    private static final int TEMP_CONFIRM_TEMPORARY = 3;
    private static final int TEMP_START_VOICE = 4;
    private static final int TEMP_VOICE_ACTIVE = 5;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Set<String> previousSnapshot = new LinkedHashSet<>();
    private long lastTriggerSeen = -1L;
    private long lastChatGptWindowSeenUptime = 0L;
    private String lastDisplayed = "";

    private long tempRequestSeen = -1L;
    private long tempRequestWallTime = 0L;
    private int tempStage = TEMP_IDLE;
    private long tempStageStartedUptime = 0L;
    private long lastVoiceUiSeenUptime = 0L;
    private boolean newChatAttempted = false;
    private boolean temporaryClicked = false;
    private boolean voiceClicked = false;

    private WindowManager windowManager;
    private View overlayView;
    private TextView overlayText;

    private final Runnable windowMonitor = new Runnable() {
        @Override public void run() {
            processTemporaryAutomation();

            if (overlayView != null) {
                if (hasChatGptWindow()) {
                    lastChatGptWindowSeenUptime = SystemClock.uptimeMillis();
                } else if (SystemClock.uptimeMillis() - lastChatGptWindowSeenUptime > WINDOW_GONE_GRACE_MS) {
                    hideOverlay();
                    previousSnapshot.clear();
                    lastDisplayed = "";
                }
            }

            long next = (tempStage != TEMP_IDLE || overlayView != null) ? 250L : 1500L;
            handler.postDelayed(this, next);
        }
    };

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        windowManager = (WindowManager) getSystemService(WINDOW_SERVICE);

        AccessibilityServiceInfo info = getServiceInfo();
        if (info != null) {
            info.flags |= AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
            info.flags |= AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS;
            info.flags |= AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS;
            setServiceInfo(info);
        }

        handler.removeCallbacks(windowMonitor);
        handler.post(windowMonitor);
        setTempStatus("Temporary Voice companion ready");
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event == null) return;

        CharSequence pkg = event.getPackageName();
        if (pkg != null && CHATGPT_PACKAGE.contentEquals(pkg)) {
            processTemporaryAutomation();
        }

        if (!isResponseTextEnabled() || tempStage != TEMP_IDLE) {
            if (!isResponseTextEnabled()) hideOverlay();
            return;
        }

        if (pkg == null || !CHATGPT_PACKAGE.contentEquals(pkg)) return;
        if (!isRecentAssistSession()) return;

        AccessibilityNodeInfo root = findChatGptRoot();
        if (root == null) return;
        lastChatGptWindowSeenUptime = SystemClock.uptimeMillis();

        List<String> rootStrings = new ArrayList<>();
        int[] visited = new int[] {0};
        collectStrings(root, rootStrings, visited);

        long trigger = prefs().getLong(KEY_LAST_ASSIST_TRIGGER_MS, 0L);
        if (trigger != lastTriggerSeen) {
            lastTriggerSeen = trigger;
            previousSnapshot.clear();
            previousSnapshot.addAll(rootStrings);
            lastDisplayed = "";
            return;
        }

        List<String> eventStrings = new ArrayList<>();
        if (event.getText() != null) {
            for (CharSequence cs : event.getText()) addCleanString(eventStrings, cs);
        }
        addCleanString(eventStrings, event.getContentDescription());

        String candidate = chooseCandidate(rootStrings, eventStrings);
        previousSnapshot.clear();
        previousSnapshot.addAll(rootStrings);

        if (!TextUtils.isEmpty(candidate) && !candidate.equals(lastDisplayed)) {
            lastDisplayed = candidate;
            prefs().edit().putString(KEY_LAST_CAPTURED_TEXT, candidate).apply();
            showOverlay(candidate);
        }
    }

    private SharedPreferences prefs() {
        return getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE);
    }

    private boolean isResponseTextEnabled() {
        return prefs().getBoolean(MainActivity.KEY_RESPONSE_TEXT_ENABLED, true);
    }

    private boolean isTemporaryVoiceEnabled() {
        return prefs().getBoolean(MainActivity.KEY_TEMPORARY_VOICE_ENABLED, false);
    }

    private void processTemporaryAutomation() {
        long request = prefs().getLong(KEY_TEMP_REQUEST_MS, 0L);
        long nowWall = System.currentTimeMillis();
        long nowUp = SystemClock.uptimeMillis();

        if (request > 0L && request != tempRequestSeen &&
                nowWall >= request && nowWall - request <= TEMP_SETUP_WINDOW_MS) {
            tempRequestSeen = request;
            tempRequestWallTime = request;
            tempStage = TEMP_PREPARE_NEW_CHAT;
            tempStageStartedUptime = nowUp;
            newChatAttempted = false;
            temporaryClicked = false;
            voiceClicked = false;
            lastVoiceUiSeenUptime = 0L;
            hideOverlay();
            setTempStatus("Temporary Voice: opening a fresh ChatGPT chat…");
        }

        if (tempStage == TEMP_IDLE) return;
        if (!isTemporaryVoiceEnabled()) {
            failTemporary("Temporary Voice was turned off");
            return;
        }

        if (tempStage != TEMP_VOICE_ACTIVE &&
                nowWall - tempRequestWallTime > TEMP_SETUP_WINDOW_MS) {
            failTemporary("Temporary Voice setup timed out before Voice started");
            return;
        }

        AccessibilityNodeInfo root = findChatGptRoot();
        if (root == null) {
            if (tempStage == TEMP_VOICE_ACTIVE &&
                    nowUp - lastChatGptWindowSeenUptime > WINDOW_GONE_GRACE_MS) {
                finishTemporary("Temporary Voice ended — chat remains temporary");
            }
            return;
        }

        lastChatGptWindowSeenUptime = nowUp;

        if (tempStage == TEMP_PREPARE_NEW_CHAT) {
            AccessibilityNodeInfo activeVoiceEnd = findActionNode(root,
                    "end voice mode", "exit voice mode", "close voice", "end voice");
            if (activeVoiceEnd != null) {
                if (clickNode(activeVoiceEnd)) {
                    setTempStatus("Temporary Voice: closing auto-started normal Voice first…");
                    tempStageStartedUptime = nowUp;
                }
                return;
            }

            AccessibilityNodeInfo temporary = findTemporaryControl(root);
            if (temporary != null && !newChatAttempted) {
                tempStage = TEMP_FIND_TEMPORARY;
                tempStageStartedUptime = nowUp;
                return;
            }

            if (!newChatAttempted) {
                AccessibilityNodeInfo newChat = findActionNode(root,
                        "new chat", "start new chat", "new conversation");
                if (newChat != null && clickNode(newChat)) {
                    newChatAttempted = true;
                    tempStageStartedUptime = nowUp;
                    setTempStatus("Temporary Voice: fresh chat opened…");
                    return;
                }
                if (nowUp - tempStageStartedUptime > 1800L) {
                    newChatAttempted = true;
                    tempStageStartedUptime = nowUp;
                }
            }

            if (newChatAttempted && nowUp - tempStageStartedUptime > 350L) {
                tempStage = TEMP_FIND_TEMPORARY;
                tempStageStartedUptime = nowUp;
            }
            return;
        }

        if (tempStage == TEMP_FIND_TEMPORARY) {
            AccessibilityNodeInfo temporary = findTemporaryControl(root);
            if (temporary != null) {
                if (looksSelected(temporary)) {
                    temporaryClicked = true;
                    tempStage = TEMP_CONFIRM_TEMPORARY;
                    tempStageStartedUptime = nowUp;
                    setTempStatus("Temporary Voice: Temporary mode already selected…");
                } else if (clickNode(temporary)) {
                    temporaryClicked = true;
                    tempStage = TEMP_CONFIRM_TEMPORARY;
                    tempStageStartedUptime = nowUp;
                    setTempStatus("Temporary Voice: enabling Temporary Chat…");
                }
                return;
            }

            if (nowUp - tempStageStartedUptime > 5000L) {
                failTemporary("Could not find ChatGPT's Temporary button — Voice was not started");
            }
            return;
        }

        if (tempStage == TEMP_CONFIRM_TEMPORARY) {
            AccessibilityNodeInfo nonPersonalized = findActionNode(root,
                    "non personalized", "non-personalized", "without personalization",
                    "do not personalize", "don't personalize");
            if (nonPersonalized != null && clickNode(nonPersonalized)) {
                setTempStatus("Temporary Voice: using non-personalized Temporary Chat…");
                tempStageStartedUptime = nowUp;
                return;
            }

            AccessibilityNodeInfo continueButton = findActionNode(root,
                    "start temporary chat", "use temporary chat", "continue");
            if (continueButton != null && clickNode(continueButton)) {
                setTempStatus("Temporary Voice: confirming Temporary Chat…");
                tempStageStartedUptime = nowUp;
                return;
            }

            if (temporaryClicked && nowUp - tempStageStartedUptime > 900L) {
                tempStage = TEMP_START_VOICE;
                tempStageStartedUptime = nowUp;
                setTempStatus("Temporary Voice: Temporary mode set — starting Voice…");
            }
            return;
        }

        if (tempStage == TEMP_START_VOICE) {
            if (isVoiceUi(root)) {
                markVoiceStarted();
                return;
            }

            if (!voiceClicked) {
                AccessibilityNodeInfo voice = findActionNode(root,
                        "start voice mode", "start voice", "voice mode", "voice");
                if (voice != null && clickNode(voice)) {
                    voiceClicked = true;
                    tempStageStartedUptime = nowUp;
                    setTempStatus("Temporary Voice: Voice button pressed…");
                    return;
                }
            }

            if (voiceClicked && isVoiceUi(root)) {
                markVoiceStarted();
                return;
            }

            if (nowUp - tempStageStartedUptime > 6000L) {
                failTemporary("Temporary Chat was prepared, but the Voice control was not found");
            }
            return;
        }

        if (tempStage == TEMP_VOICE_ACTIVE) {
            if (isVoiceUi(root)) {
                lastVoiceUiSeenUptime = nowUp;
            } else if (nowUp - lastVoiceUiSeenUptime > 1800L) {
                finishTemporary("Temporary Voice ended — chat remains temporary");
            }
        }
    }

    private void markVoiceStarted() {
        tempStage = TEMP_VOICE_ACTIVE;
        lastVoiceUiSeenUptime = SystemClock.uptimeMillis();
        setTempStatus("Temporary Voice active — this chat should stay out of normal history");
        Intent started = new Intent(WakeListenerService.ACTION_TEMP_VOICE_STARTED)
                .setPackage(getPackageName());
        sendBroadcast(started);
    }

    private void failTemporary(String message) {
        setTempStatus(message);
        clearTemporaryRequest();
        Intent finished = new Intent(WakeListenerService.ACTION_TEMP_VOICE_FINISHED)
                .setPackage(getPackageName());
        sendBroadcast(finished);
    }

    private void finishTemporary(String message) {
        setTempStatus(message);
        clearTemporaryRequest();
        Intent finished = new Intent(WakeListenerService.ACTION_TEMP_VOICE_FINISHED)
                .setPackage(getPackageName());
        sendBroadcast(finished);
    }

    private void clearTemporaryRequest() {
        tempStage = TEMP_IDLE;
        newChatAttempted = false;
        temporaryClicked = false;
        voiceClicked = false;
        prefs().edit().putLong(KEY_TEMP_REQUEST_MS, 0L).apply();
    }

    private void setTempStatus(String text) {
        String old = prefs().getString(KEY_TEMP_AUTOMATION_STATUS, "");
        if (!text.equals(old)) prefs().edit().putString(KEY_TEMP_AUTOMATION_STATUS, text).apply();
    }

    private AccessibilityNodeInfo findTemporaryControl(AccessibilityNodeInfo root) {
        return findActionNode(root, "temporary chat", "temporary");
    }

    private boolean looksSelected(AccessibilityNodeInfo node) {
        if (node == null) return false;
        AccessibilityNodeInfo current = node;
        for (int i = 0; i < 5 && current != null; i++) {
            if (current.isSelected() || current.isChecked()) return true;
            String label = nodeLabel(current);
            if (label.contains("selected") || label.contains("on") || label.contains("active")) return true;
            current = current.getParent();
        }
        return false;
    }

    private AccessibilityNodeInfo findActionNode(AccessibilityNodeInfo root, String... labels) {
        if (root == null) return null;
        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(root);
        int index = 0;
        int visited = 0;
        AccessibilityNodeInfo fallback = null;

        while (index < queue.size() && visited < 650) {
            AccessibilityNodeInfo node = queue.get(index++);
            visited++;
            if (node == null) continue;

            String label = nodeLabel(node);
            if (!label.isEmpty() && label.length() <= 120 && matchesAny(label, labels)) {
                if (node.isClickable()) return node;
                AccessibilityNodeInfo clickable = firstClickableParent(node);
                if (clickable != null) return clickable;
                if (fallback == null) fallback = node;
            }

            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < 700; i++) {
                AccessibilityNodeInfo child = node.getChild(i);
                if (child != null) queue.add(child);
            }
        }
        return fallback;
    }

    private boolean matchesAny(String label, String... labels) {
        for (String wanted : labels) {
            String w = normalizeLabel(wanted);
            if (label.equals(w) || label.contains(w)) return true;
        }
        return false;
    }

    private String nodeLabel(AccessibilityNodeInfo node) {
        if (node == null) return "";
        StringBuilder sb = new StringBuilder();
        if (node.getText() != null) sb.append(node.getText()).append(' ');
        if (node.getContentDescription() != null) sb.append(node.getContentDescription()).append(' ');
        if (node.getHintText() != null) sb.append(node.getHintText());
        return normalizeLabel(sb.toString());
    }

    private String normalizeLabel(String value) {
        if (value == null) return "";
        return value.toLowerCase(Locale.US)
                .replace('-', ' ')
                .replace('_', ' ')
                .replaceAll("\\s+", " ")
                .trim();
    }

    private AccessibilityNodeInfo firstClickableParent(AccessibilityNodeInfo node) {
        AccessibilityNodeInfo current = node;
        for (int i = 0; i < 6 && current != null; i++) {
            if (current.isClickable()) return current;
            current = current.getParent();
        }
        return null;
    }

    private boolean clickNode(AccessibilityNodeInfo node) {
        if (node == null) return false;
        AccessibilityNodeInfo target = node.isClickable() ? node : firstClickableParent(node);
        if (target == null) target = node;
        try { return target.performAction(AccessibilityNodeInfo.ACTION_CLICK); }
        catch (Throwable ignored) { return false; }
    }

    private boolean isVoiceUi(AccessibilityNodeInfo root) {
        return findActionNode(root,
                "end voice mode", "exit voice mode", "tap to interrupt", "mute microphone",
                "unmute microphone", "voice conversation", "stop voice") != null;
    }

    private boolean isRecentAssistSession() {
        long trigger = prefs().getLong(KEY_LAST_ASSIST_TRIGGER_MS, 0L);
        if (trigger <= 0L) return false;
        long age = System.currentTimeMillis() - trigger;
        return age >= 0L && age <= ASSIST_SESSION_WINDOW_MS;
    }

    private AccessibilityNodeInfo findChatGptRoot() {
        AccessibilityNodeInfo active = getRootInActiveWindow();
        if (isChatGptNode(active)) return active;
        List<AccessibilityWindowInfo> windows = getWindows();
        if (windows != null) {
            for (AccessibilityWindowInfo window : windows) {
                if (window == null) continue;
                AccessibilityNodeInfo root = window.getRoot();
                if (isChatGptNode(root)) return root;
            }
        }
        return null;
    }

    private boolean hasChatGptWindow() {
        List<AccessibilityWindowInfo> windows = getWindows();
        if (windows == null) return false;
        for (AccessibilityWindowInfo window : windows) {
            if (window == null) continue;
            AccessibilityNodeInfo root = window.getRoot();
            if (isChatGptNode(root)) return true;
        }
        return false;
    }

    private boolean isChatGptNode(AccessibilityNodeInfo node) {
        if (node == null) return false;
        CharSequence pkg = node.getPackageName();
        return pkg != null && CHATGPT_PACKAGE.contentEquals(pkg);
    }

    private void collectStrings(AccessibilityNodeInfo node, List<String> out, int[] visited) {
        if (node == null || visited[0] > 500) return;
        visited[0]++;
        if (node.isVisibleToUser()) {
            addCleanString(out, node.getText());
            addCleanString(out, node.getContentDescription());
        }
        int count = node.getChildCount();
        for (int i = 0; i < count && visited[0] <= 500; i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child != null) collectStrings(child, out, visited);
        }
    }

    private void addCleanString(List<String> out, CharSequence value) {
        if (value == null) return;
        String s = clean(value.toString());
        if (s.isEmpty() || isUiChrome(s)) return;
        if (!out.contains(s)) out.add(s);
    }

    private String clean(String raw) {
        if (raw == null) return "";
        String s = raw.replace('\u00a0', ' ').replaceAll("\\s+", " ").trim();
        if (s.length() > 2200) s = s.substring(0, 2200);
        return s;
    }

    private boolean isUiChrome(String text) {
        String s = text.toLowerCase(Locale.US).trim();
        if (s.isEmpty()) return true;
        String[] exact = new String[] {
                "chatgpt", "close", "cancel", "stop", "done", "back", "send",
                "listening", "thinking", "speaking", "voice", "mute", "unmute",
                "camera", "keyboard", "settings", "end", "end voice mode",
                "tap to interrupt", "tap to stop", "start voice mode", "temporary"
        };
        for (String item : exact) if (s.equals(item)) return true;
        if (s.startsWith("double tap to")) return true;
        if (s.startsWith("button,")) return true;
        if (s.startsWith("image,")) return true;
        if (s.matches("\\d{1,2}:\\d{2}")) return true;
        return false;
    }

    private String chooseCandidate(List<String> rootStrings, List<String> eventStrings) {
        String best = "";
        int bestScore = Integer.MIN_VALUE;
        LinkedHashSet<String> all = new LinkedHashSet<>();
        all.addAll(eventStrings);
        all.addAll(rootStrings);

        for (String s : all) {
            if (TextUtils.isEmpty(s) || isUiChrome(s)) continue;
            int score = Math.min(s.length(), 300);
            if (eventStrings.contains(s)) score += 900;
            if (!previousSnapshot.contains(s)) score += 500;
            if (!lastDisplayed.isEmpty()) {
                if (s.startsWith(lastDisplayed)) score += 450;
                else if (lastDisplayed.startsWith(s)) score += 250;
            }
            if (s.length() <= 2) score -= 100;
            if (s.length() >= 5) score += 50;
            if (score > bestScore) {
                bestScore = score;
                best = s;
            }
        }
        return bestScore < 400 ? "" : best;
    }

    private void showOverlay(String text) {
        if (windowManager == null) return;
        if (overlayView == null) createOverlay();
        if (overlayText != null) overlayText.setText(text);
    }

    private void createOverlay() {
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(18), dp(12), dp(14), dp(14));

        GradientDrawable background = new GradientDrawable();
        background.setColor(Color.argb(238, 28, 28, 30));
        background.setCornerRadius(dp(22));
        panel.setBackground(background);
        panel.setElevation(dp(10));

        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);

        TextView title = new TextView(this);
        title.setText("ChatGPT");
        title.setTextColor(Color.WHITE);
        title.setTextSize(14);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        header.addView(title, new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f));

        TextView close = new TextView(this);
        close.setText("×");
        close.setTextColor(Color.LTGRAY);
        close.setTextSize(26);
        close.setGravity(Gravity.CENTER);
        close.setPadding(dp(10), 0, dp(4), 0);
        close.setOnClickListener(v -> hideOverlay());
        header.addView(close, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
        panel.addView(header);

        overlayText = new TextView(this);
        overlayText.setTextColor(Color.WHITE);
        overlayText.setTextSize(18);
        overlayText.setLineSpacing(0f, 1.08f);
        overlayText.setMaxLines(9);
        overlayText.setEllipsize(TextUtils.TruncateAt.END);
        overlayText.setPadding(0, dp(4), 0, 0);
        panel.addView(overlayText, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        Rect bounds = windowManager.getCurrentWindowMetrics().getBounds();
        int width = Math.max(dp(220), bounds.width() - dp(24));
        WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                width,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE |
                        WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL |
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT);
        params.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
        params.y = dp(54);

        try {
            windowManager.addView(panel, params);
            overlayView = panel;
        } catch (Throwable ignored) {
            overlayView = null;
            overlayText = null;
        }
    }

    private void hideOverlay() {
        if (windowManager != null && overlayView != null) {
            try { windowManager.removeView(overlayView); } catch (Throwable ignored) {}
        }
        overlayView = null;
        overlayText = null;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    @Override public void onInterrupt() {
        hideOverlay();
    }

    @Override public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        hideOverlay();
        super.onDestroy();
    }
}
