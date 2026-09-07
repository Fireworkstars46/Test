package com.example.heychatgptassist;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.AccessibilityServiceInfo;
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

    private static final String CHATGPT_PACKAGE = "com.openai.chatgpt";
    private static final long ASSIST_SESSION_WINDOW_MS = 10 * 60 * 1000L;
    private static final long WINDOW_GONE_GRACE_MS = 450L;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Set<String> previousSnapshot = new LinkedHashSet<>();
    private long lastTriggerSeen = -1L;
    private long lastChatGptWindowSeenUptime = 0L;
    private String lastDisplayed = "";

    private WindowManager windowManager;
    private View overlayView;
    private TextView overlayText;

    private final Runnable windowMonitor = new Runnable() {
        @Override public void run() {
            if (overlayView != null) {
                if (hasChatGptWindow()) {
                    lastChatGptWindowSeenUptime = SystemClock.uptimeMillis();
                } else if (SystemClock.uptimeMillis() - lastChatGptWindowSeenUptime > WINDOW_GONE_GRACE_MS) {
                    hideOverlay();
                    previousSnapshot.clear();
                    lastDisplayed = "";
                }
            }
            handler.postDelayed(this, 250L);
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
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event == null || !isFeatureEnabled()) {
            hideOverlay();
            return;
        }

        CharSequence pkg = event.getPackageName();
        if (pkg == null || !CHATGPT_PACKAGE.contentEquals(pkg)) return;
        if (!isRecentAssistSession()) return;

        AccessibilityNodeInfo root = findChatGptRoot();
        if (root == null) return;

        lastChatGptWindowSeenUptime = SystemClock.uptimeMillis();

        List<String> rootStrings = new ArrayList<>();
        int[] visited = new int[] {0};
        collectStrings(root, rootStrings, visited);

        long trigger = getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .getLong(KEY_LAST_ASSIST_TRIGGER_MS, 0L);
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
            getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                    .edit().putString(KEY_LAST_CAPTURED_TEXT, candidate).apply();
            showOverlay(candidate);
        }
    }

    @Override
    public void onInterrupt() {
        hideOverlay();
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        hideOverlay();
        super.onDestroy();
    }

    private boolean isFeatureEnabled() {
        return getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .getBoolean(MainActivity.KEY_RESPONSE_TEXT_ENABLED, true);
    }

    private boolean isRecentAssistSession() {
        long trigger = getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE)
                .getLong(KEY_LAST_ASSIST_TRIGGER_MS, 0L);
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
        String s = raw.replace('\u00a0', ' ')
                .replaceAll("\\s+", " ")
                .trim();
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
                "tap to interrupt", "tap to stop", "start voice mode"
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

        if (bestScore < 400) return "";
        return best;
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
}
