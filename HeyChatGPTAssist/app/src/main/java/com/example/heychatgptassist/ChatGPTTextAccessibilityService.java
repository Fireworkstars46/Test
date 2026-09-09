package com.example.heychatgptassist;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * v1.8: this service no longer attempts to scrape/show ChatGPT response text.
 * It is used only to tell the wake listener when the real Android ChatGPT
 * assistant popup is present so our microphone stays paused until it closes.
 */
public class ChatGPTTextAccessibilityService extends AccessibilityService {
    public static final String KEY_LAST_ASSIST_TRIGGER_MS = "last_assist_trigger_ms";
    public static final String KEY_LAST_CAPTURED_TEXT = "last_captured_response_text";
    public static final String KEY_LAST_WINDOW_DEBUG = "last_assistant_window_debug";
    public static final String KEY_TEMP_REQUEST_MS = "temp_voice_request_ms";
    public static final String KEY_TEMP_AUTOMATION_STATUS = "temp_voice_automation_status";

    private static final String CHATGPT_PACKAGE = "com.openai.chatgpt";
    private static final long SESSION_WINDOW_MS = 2L * 60L * 1000L;
    private static final long CLOSED_GRACE_MS = 650L;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean popupOpen = false;
    private long lastPopupSeenUptime = 0L;

    private final Runnable monitor = new Runnable() {
        @Override public void run() {
            checkPopupState();
            handler.postDelayed(this, popupOpen ? 220L : 1000L);
        }
    };

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        AccessibilityServiceInfo info = getServiceInfo();
        if (info != null) {
            info.flags |= AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
            info.flags |= AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS;
            info.flags |= AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS;
            setServiceInfo(info);
        }
        handler.removeCallbacks(monitor);
        handler.post(monitor);
        getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE).edit()
                .putString(KEY_TEMP_AUTOMATION_STATUS,
                        "v1.8: legacy response scraping disabled; popup detection only")
                .remove(KEY_LAST_CAPTURED_TEXT)
                .apply();
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        checkPopupState();
    }

    private SharedPreferences prefs() {
        return getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE);
    }

    private boolean isRecentAssistSession() {
        long trigger = prefs().getLong(KEY_LAST_ASSIST_TRIGGER_MS, 0L);
        if (trigger <= 0L) return false;
        long age = System.currentTimeMillis() - trigger;
        return age >= 0L && age <= SESSION_WINDOW_MS;
    }

    private void checkPopupState() {
        if (!isRecentAssistSession()) {
            if (popupOpen) markClosed();
            return;
        }

        boolean found = false;
        StringBuilder packages = new StringBuilder();
        List<AccessibilityWindowInfo> windows = getWindows();
        if (windows != null) {
            for (AccessibilityWindowInfo window : windows) {
                if (window == null) continue;
                AccessibilityNodeInfo root = null;
                try { root = window.getRoot(); } catch (Throwable ignored) {}
                if (root == null) continue;

                String pkg = root.getPackageName() == null ? "" : root.getPackageName().toString();
                if (!pkg.isEmpty()) {
                    if (packages.length() > 0) packages.append(", ");
                    packages.append(pkg);
                }

                if (CHATGPT_PACKAGE.equals(pkg) || subtreeLooksLikeChatGptAssistant(root)) {
                    found = true;
                    break;
                }
            }
        }

        prefs().edit().putString(KEY_LAST_WINDOW_DEBUG,
                "v1.8 popup detector | windows: " +
                        (packages.length() == 0 ? "(none)" : packages.toString()) +
                        " | popup: " + (found ? "OPEN" : "not seen")).apply();

        long now = SystemClock.uptimeMillis();
        if (found) {
            lastPopupSeenUptime = now;
            if (!popupOpen) {
                popupOpen = true;
                sendState(WakeListenerService.ACTION_ASSISTANT_POPUP_OPENED);
            }
        } else if (popupOpen && now - lastPopupSeenUptime > CLOSED_GRACE_MS) {
            markClosed();
        }
    }

    private boolean subtreeLooksLikeChatGptAssistant(AccessibilityNodeInfo root) {
        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(root);
        int index = 0;
        int visited = 0;
        while (index < queue.size() && visited < 350) {
            AccessibilityNodeInfo node = queue.get(index++);
            visited++;
            if (node == null) continue;

            String text = ((node.getText() == null ? "" : node.getText().toString()) + " " +
                    (node.getContentDescription() == null ? "" : node.getContentDescription().toString()) + " " +
                    (node.getHintText() == null ? "" : node.getHintText().toString()))
                    .toLowerCase(Locale.US);
            if (text.contains("chatgpt") || text.contains("tap to interrupt") ||
                    text.contains("end voice mode") || text.contains("voice conversation") ||
                    text.contains("openai")) {
                return true;
            }

            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < 400; i++) {
                AccessibilityNodeInfo child = node.getChild(i);
                if (child != null) queue.add(child);
            }
        }
        return false;
    }

    private void markClosed() {
        popupOpen = false;
        lastPopupSeenUptime = 0L;
        sendState(WakeListenerService.ACTION_ASSISTANT_POPUP_CLOSED);
    }

    private void sendState(String action) {
        try {
            sendBroadcast(new Intent(action).setPackage(getPackageName()));
        } catch (Throwable ignored) {}
    }

    @Override public void onInterrupt() {}

    @Override
    public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (popupOpen) markClosed();
        super.onDestroy();
    }
}
