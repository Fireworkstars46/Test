from pathlib import Path
import re


def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)


service = r'''package com.example.heychatgptassist;

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
    public static final String KEY_LAST_WINDOW_DEBUG = "last_assistant_window_debug";
    public static final String KEY_TEMP_REQUEST_MS = "temp_voice_request_ms";
    public static final String KEY_TEMP_AUTOMATION_STATUS = "temp_voice_automation_status";

    private static final String CHATGPT_PACKAGE = "com.openai.chatgpt";
    private static final String OWN_PACKAGE = "com.example.heychatgptassist";
    private static final long ASSIST_SESSION_WINDOW_MS = 5L * 60L * 1000L;
    private static final long GONE_GRACE_MS = 900L;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Set<String> previousSnapshot = new LinkedHashSet<>();
    private long lastTriggerSeen = -1L;
    private long lastMarkerSeenUptime = 0L;
    private long lastDebugWriteUptime = 0L;
    private String lastDebug = "";
    private String lastDisplayed = "";
    private boolean assistantVisible = false;

    private WindowManager windowManager;
    private View overlayView;
    private TextView overlayText;

    private static class PopupSnapshot {
        final AccessibilityNodeInfo container;
        final String packageName;
        final Rect bounds;

        PopupSnapshot(AccessibilityNodeInfo container, String packageName, Rect bounds) {
            this.container = container;
            this.packageName = packageName;
            this.bounds = bounds;
        }
    }

    private final Runnable monitorRunnable = new Runnable() {
        @Override public void run() {
            updateAssistantSession();
            long next;
            if (assistantVisible) next = 300L;
            else if (isRecentAssistSession()) next = 900L;
            else next = 2500L;
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
        prefs().edit().putString(KEY_TEMP_AUTOMATION_STATUS,
                "v1.7: strict popup capture; wake listener pauses while assistant is open").apply();
        handler.removeCallbacks(monitorRunnable);
        handler.post(monitorRunnable);
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event == null) return;
        String pkg = stringValue(event.getPackageName());
        if (OWN_PACKAGE.equals(pkg)) return;
        updateAssistantSession();
    }

    private SharedPreferences prefs() {
        return getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE);
    }

    private boolean isResponseTextEnabled() {
        return prefs().getBoolean(MainActivity.KEY_RESPONSE_TEXT_ENABLED, true);
    }

    private boolean isRecentAssistSession() {
        long trigger = prefs().getLong(KEY_LAST_ASSIST_TRIGGER_MS, 0L);
        if (trigger <= 0L) return false;
        long age = System.currentTimeMillis() - trigger;
        return age >= 0L && age <= ASSIST_SESSION_WINDOW_MS;
    }

    private void updateAssistantSession() {
        long trigger = prefs().getLong(KEY_LAST_ASSIST_TRIGGER_MS, 0L);
        if (trigger != lastTriggerSeen) {
            lastTriggerSeen = trigger;
            previousSnapshot.clear();
            lastDisplayed = "";
            hideOverlay();
            assistantVisible = false;
            lastMarkerSeenUptime = 0L;
        }

        if (!isRecentAssistSession()) {
            if (assistantVisible) {
                assistantVisible = false;
                sendSessionBroadcast(WakeListenerService.ACTION_ASSIST_UI_GONE);
            }
            hideOverlay();
            return;
        }

        PopupSnapshot popup = findAssistantPopup();
        long now = SystemClock.uptimeMillis();
        if (popup != null) {
            lastMarkerSeenUptime = now;
            if (!assistantVisible) {
                assistantVisible = true;
                sendSessionBroadcast(WakeListenerService.ACTION_ASSIST_UI_VISIBLE);
            }
            if (isResponseTextEnabled()) processPopupText(popup);
            else hideOverlay();
        } else if (assistantVisible && now - lastMarkerSeenUptime > GONE_GRACE_MS) {
            assistantVisible = false;
            previousSnapshot.clear();
            lastDisplayed = "";
            hideOverlay();
            sendSessionBroadcast(WakeListenerService.ACTION_ASSIST_UI_GONE);
            writeDebug("Assistant popup closed; listener may re-arm now");
        }
    }

    private void sendSessionBroadcast(String action) {
        try {
            Intent intent = new Intent(action).setPackage(getPackageName());
            sendBroadcast(intent);
        } catch (Throwable ignored) {}
    }

    private PopupSnapshot findAssistantPopup() {
        List<AccessibilityWindowInfo> windows;
        try { windows = getWindows(); }
        catch (Throwable t) { return null; }
        if (windows == null) return null;

        for (AccessibilityWindowInfo window : windows) {
            if (window == null) continue;
            AccessibilityNodeInfo root;
            try { root = window.getRoot(); }
            catch (Throwable t) { continue; }
            if (root == null) continue;

            String pkg = stringValue(root.getPackageName());
            if (OWN_PACKAGE.equals(pkg)) continue;

            if (CHATGPT_PACKAGE.equals(pkg)) {
                Rect b = new Rect();
                root.getBoundsInScreen(b);
                return new PopupSnapshot(root, pkg, b);
            }

            if (!isPossibleHostPackage(pkg)) continue;
            AccessibilityNodeInfo marker = findMarkerNode(root);
            if (marker == null) continue;
            AccessibilityNodeInfo container = choosePopupContainer(marker);
            Rect b = new Rect();
            container.getBoundsInScreen(b);
            return new PopupSnapshot(container, pkg, b);
        }
        return null;
    }

    private boolean isPossibleHostPackage(String pkg) {
        if (pkg == null) return false;
        return "com.android.systemui".equals(pkg)
                || "android".equals(pkg)
                || "com.samsung.android.sidegesturepad".equals(pkg)
                || pkg.toLowerCase(Locale.US).contains("assistant");
    }

    private AccessibilityNodeInfo findMarkerNode(AccessibilityNodeInfo root) {
        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(root);
        int index = 0;
        int visited = 0;
        while (index < queue.size() && visited < 500) {
            AccessibilityNodeInfo node = queue.get(index++);
            visited++;
            if (node == null) continue;
            if (isAssistantMarker(node)) return node;
            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < 550; i++) {
                AccessibilityNodeInfo child = node.getChild(i);
                if (child != null) queue.add(child);
            }
        }
        return null;
    }

    private boolean isAssistantMarker(AccessibilityNodeInfo node) {
        String raw = (stringValue(node.getText()) + " "
                + stringValue(node.getContentDescription()) + " "
                + stringValue(node.getHintText())).toLowerCase(Locale.US);
        return raw.contains("chatgpt")
                || raw.contains("openai")
                || raw.contains("tap to interrupt")
                || raw.contains("voice conversation")
                || raw.contains("end voice mode");
    }

    private AccessibilityNodeInfo choosePopupContainer(AccessibilityNodeInfo marker) {
        AccessibilityNodeInfo best = marker;
        AccessibilityNodeInfo current = marker;
        Rect screen = windowManager == null
                ? new Rect(0, 0, 1080, 2400)
                : windowManager.getCurrentWindowMetrics().getBounds();
        long screenArea = Math.max(1L, (long) screen.width() * (long) screen.height());

        for (int i = 0; i < 7; i++) {
            AccessibilityNodeInfo parent = current.getParent();
            if (parent == null) break;
            Rect b = new Rect();
            parent.getBoundsInScreen(b);
            long area = Math.max(0L, (long) b.width() * (long) b.height());
            if (b.width() > 0 && b.height() > 0) {
                if (area > (long) (screenArea * 0.72)
                        || b.height() > (int) (screen.height() * 0.78)) {
                    break;
                }
                best = parent;
            }
            current = parent;
        }
        return best;
    }

    private void processPopupText(PopupSnapshot popup) {
        List<String> strings = new ArrayList<>();
        int[] visited = new int[] {0};
        collectStrings(popup.container, strings, visited);

        StringBuilder debug = new StringBuilder();
        debug.append("Popup host: ").append(popup.packageName);
        debug.append(" | bounds: ").append(popup.bounds.left).append(',').append(popup.bounds.top)
                .append('-').append(popup.bounds.right).append(',').append(popup.bounds.bottom);
        debug.append(" | popup text items: ").append(strings.size());
        if (!strings.isEmpty()) {
            debug.append(" | sample: ");
            int max = Math.min(4, strings.size());
            for (int i = 0; i < max; i++) {
                if (i > 0) debug.append(" / ");
                debug.append(truncate(strings.get(i), 90));
            }
        }
        writeDebug(debug.toString());

        String candidate = chooseCandidate(strings);
        previousSnapshot.clear();
        previousSnapshot.addAll(strings);

        if (!TextUtils.isEmpty(candidate) && !candidate.equals(lastDisplayed)) {
            lastDisplayed = candidate;
            prefs().edit().putString(KEY_LAST_CAPTURED_TEXT, candidate).apply();
            showOverlay(candidate);
        }
    }

    private void collectStrings(AccessibilityNodeInfo node, List<String> out, int[] visited) {
        if (node == null || visited[0] > 500) return;
        visited[0]++;
        if (node.isVisibleToUser()) {
            addCleanString(out, node.getText());
            addCleanString(out, node.getContentDescription());
            addCleanString(out, node.getHintText());
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
        if (s.length() > 2600) s = s.substring(0, 2600);
        return s;
    }

    private boolean isUiChrome(String text) {
        String s = text.toLowerCase(Locale.US).trim();
        if (s.isEmpty()) return true;
        String[] exact = new String[] {
                "chatgpt", "openai", "close", "cancel", "stop", "done", "back", "send",
                "listening", "thinking", "speaking", "voice", "mute", "unmute",
                "camera", "keyboard", "settings", "end", "end voice mode",
                "tap to interrupt", "tap to stop", "start voice mode", "temporary",
                "microphone", "more options", "drag handle", "recents", "home",
                "take photo", "open in app", "new chat", "start new chat"
        };
        for (String item : exact) if (s.equals(item)) return true;
        if (s.startsWith("wifi ") || s.startsWith("wi-fi ") || s.startsWith("mobile data ")) return true;
        if (s.contains(" bars") && (s.contains("wifi") || s.contains("signal"))) return true;
        if (s.matches("\\d{1,3}%")) return true;
        if (s.matches("\\d{1,2}:\\d{2}( [ap]m)?")) return true;
        if (s.startsWith("battery ") || s.startsWith("bluetooth ") || s.startsWith("alarm ")) return true;
        if (s.startsWith("google play services notification")) return true;
        if (s.startsWith("screen recorder notification")) return true;
        if (s.startsWith("double tap to")) return true;
        if (s.startsWith("button,")) return true;
        if (s.startsWith("image,")) return true;
        return false;
    }

    private String chooseCandidate(List<String> strings) {
        String best = "";
        int bestScore = Integer.MIN_VALUE;
        for (String s : strings) {
            if (TextUtils.isEmpty(s) || isUiChrome(s) || s.length() < 3) continue;
            int score = Math.min(s.length(), 700);
            if (!previousSnapshot.contains(s)) score += 900;
            if (!lastDisplayed.isEmpty()) {
                if (s.startsWith(lastDisplayed)) score += 500;
                else if (lastDisplayed.startsWith(s)) score += 200;
            }
            if (s.length() >= 15) score += 150;
            if (s.endsWith("?") && s.length() < 180) score -= 300;
            if (score > bestScore) {
                bestScore = score;
                best = s;
            }
        }
        return bestScore < 850 ? "" : best;
    }

    private void writeDebug(String text) {
        if (text == null) return;
        String value = text.length() > 1000 ? text.substring(0, 1000) : text;
        long now = SystemClock.uptimeMillis();
        if (value.equals(lastDebug) && now - lastDebugWriteUptime < 3000L) return;
        if (now - lastDebugWriteUptime < 700L) return;
        lastDebug = value;
        lastDebugWriteUptime = now;
        prefs().edit().putString(KEY_LAST_WINDOW_DEBUG, value).apply();
    }

    private String stringValue(CharSequence value) {
        return value == null ? "" : value.toString();
    }

    private String truncate(String value, int max) {
        if (value == null) return "";
        return value.length() <= max ? value : value.substring(0, max) + "…";
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
        panel.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);

        GradientDrawable background = new GradientDrawable();
        background.setColor(Color.argb(238, 28, 28, 30));
        background.setCornerRadius(dp(22));
        panel.setBackground(background);
        panel.setElevation(dp(10));

        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);

        TextView title = new TextView(this);
        title.setText("ChatGPT response");
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
        if (assistantVisible) sendSessionBroadcast(WakeListenerService.ACTION_ASSIST_UI_GONE);
        hideOverlay();
        super.onDestroy();
    }
}
'''

Path('app/src/main/java/com/example/heychatgptassist/ChatGPTTextAccessibilityService.java').write_text(service)

xml = r'''<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:description="@string/accessibility_description"
    android:accessibilityEventTypes="typeWindowStateChanged|typeWindowContentChanged|typeViewTextChanged|typeWindowsChanged|typeViewFocused"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:notificationTimeout="50"
    android:canRetrieveWindowContent="true"
    android:accessibilityFlags="flagDefault|flagIncludeNotImportantViews|flagReportViewIds|flagRetrieveInteractiveWindows" />
'''
Path('app/src/main/res/xml/accessibility_service_config.xml').write_text(xml)

# Wake listener: preserve the long-session v1.2 speech setup, but keep the listener
# paused while the actual assistant popup is visible. This prevents the wake
# recognizer from repeatedly taking/releasing the mic while ChatGPT is using it.
p = Path('app/src/main/java/com/example/heychatgptassist/WakeListenerService.java')
s = p.read_text()

anchor = '    private Intent recognizerIntent;\n    private final Handler handler = new Handler(Looper.getMainLooper());'
replacement = ('    private Intent recognizerIntent;\n'
               '    private boolean stopping = false;\n'
               '    private boolean pausedForAssistant = false;\n'
               '    private boolean assistantUiVisible = false;\n'
               '    private final Handler handler = new Handler(Looper.getMainLooper());')
if anchor in s:
    s = s.replace(anchor, replacement, 1)
duplicate = ('\n    private boolean stopping = false;\n'
             '    private boolean pausedForAssistant = false;\n'
             '    private boolean forceSystemRecognizer = false;')
if duplicate in s:
    s = s.replace(duplicate, '\n    private boolean forceSystemRecognizer = false;', 1)

finish_anchor = ('    public static final String ACTION_TEMP_VOICE_FINISHED =\n'
                 '            "com.example.heychatgptassist.TEMP_VOICE_FINISHED";')
actions = finish_anchor + ('\n    public static final String ACTION_ASSIST_UI_VISIBLE =\n'
                           '            "com.example.heychatgptassist.ASSIST_UI_VISIBLE";\n'
                           '    public static final String ACTION_ASSIST_UI_GONE =\n'
                           '            "com.example.heychatgptassist.ASSIST_UI_GONE";')
s = replace_once(s, finish_anchor, actions, 'wake action constants')

runnables = '''    private final Runnable assistantOpenDetectTimeoutRunnable = () -> {
        if (!stopping && pausedForAssistant && !assistantUiVisible) {
            setStatus("Assistant popup was not detected — re-arming listener");
            rearmAfterTrigger();
        }
    };
    private final Runnable assistantMaxPauseRunnable = () -> {
        if (!stopping && pausedForAssistant) {
            setStatus("Assistant pause safety timeout — re-arming listener");
            rearmAfterTrigger();
        }
    };

'''
force_anchor = '    private boolean forceSystemRecognizer = false;'
if 'assistantOpenDetectTimeoutRunnable' not in s:
    s = replace_once(s, force_anchor, runnables + force_anchor, 'wake runnable insertion')

old_receiver_tail = '''            } else if (ACTION_TEMP_VOICE_FINISHED.equals(action)) {
                handler.removeCallbacks(tempSetupTimeoutRunnable);
                handler.removeCallbacks(tempMaxSessionRunnable);
                setStatus("Temporary Voice ended — re-arming listener");
                rearmAfterTrigger();
            }'''
new_receiver_tail = '''            } else if (ACTION_TEMP_VOICE_FINISHED.equals(action)) {
                handler.removeCallbacks(tempSetupTimeoutRunnable);
                handler.removeCallbacks(tempMaxSessionRunnable);
                setStatus("Temporary Voice ended — re-arming listener");
                rearmAfterTrigger();
            } else if (ACTION_ASSIST_UI_VISIBLE.equals(action)) {
                if (pausedForAssistant) {
                    assistantUiVisible = true;
                    handler.removeCallbacks(assistantOpenDetectTimeoutRunnable);
                    setStatus("Assistant active — wake listener paused");
                }
            } else if (ACTION_ASSIST_UI_GONE.equals(action)) {
                if (pausedForAssistant) {
                    assistantUiVisible = false;
                    handler.removeCallbacks(assistantOpenDetectTimeoutRunnable);
                    handler.removeCallbacks(assistantMaxPauseRunnable);
                    setStatus("Assistant closed — re-arming listener");
                    int delay = getRearmDelayMs();
                    if (delay <= 0) handler.post(rearmRunnable);
                    else handler.postDelayed(rearmRunnable, delay);
                }
            }'''
s = replace_once(s, old_receiver_tail, new_receiver_tail, 'wake receiver tail')

s = replace_once(s,
                 '        filter.addAction(ACTION_TEMP_VOICE_FINISHED);',
                 '        filter.addAction(ACTION_TEMP_VOICE_FINISHED);\n        filter.addAction(ACTION_ASSIST_UI_VISIBLE);\n        filter.addAction(ACTION_ASSIST_UI_GONE);',
                 'wake receiver filter')

s = replace_once(s,
                 '        handler.removeCallbacks(tempMaxSessionRunnable);\n        migrateSmoothDefaults();',
                 '        handler.removeCallbacks(tempMaxSessionRunnable);\n        handler.removeCallbacks(assistantOpenDetectTimeoutRunnable);\n        handler.removeCallbacks(assistantMaxPauseRunnable);\n        assistantUiVisible = false;\n        migrateSmoothDefaults();',
                 'wake start reset')

pref_anchor = '    private int getIntPref(String key, int defaultValue, int maxValue) {'
companion_method = '''    private boolean isCompanionAccessibilityEnabled() {
        try {
            String enabled = android.provider.Settings.Secure.getString(
                    getContentResolver(), android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
            if (enabled == null || enabled.isEmpty()) return false;
            ComponentName wanted = new ComponentName(this, ChatGPTTextAccessibilityService.class);
            for (String item : enabled.split(":")) {
                ComponentName found = ComponentName.unflattenFromString(item);
                if (wanted.equals(found)) return true;
            }
        } catch (Throwable ignored) {}
        return false;
    }

'''
s = replace_once(s, pref_anchor, companion_method + pref_anchor, 'companion accessibility method')

# Internal retry floors prevent 0 ms settings from hammering SpeechRecognizer.
s = s.replace('''    private int getRestartDelayMs() {
        return getIntPref(MainActivity.KEY_RESTART_DELAY_MS,
                MainActivity.DEFAULT_RESTART_DELAY_MS, MainActivity.MAX_RESTART_DELAY_MS);
    }''', '''    private int getRestartDelayMs() {
        return Math.max(100, getIntPref(MainActivity.KEY_RESTART_DELAY_MS,
                MainActivity.DEFAULT_RESTART_DELAY_MS, MainActivity.MAX_RESTART_DELAY_MS));
    }''')
s = s.replace('''    private int getBusyRetryDelayMs() {
        return getIntPref(MainActivity.KEY_BUSY_RETRY_DELAY_MS,
                MainActivity.DEFAULT_BUSY_RETRY_DELAY_MS, MainActivity.MAX_BUSY_RETRY_DELAY_MS);
    }''', '''    private int getBusyRetryDelayMs() {
        return Math.max(100, getIntPref(MainActivity.KEY_BUSY_RETRY_DELAY_MS,
                MainActivity.DEFAULT_BUSY_RETRY_DELAY_MS, MainActivity.MAX_BUSY_RETRY_DELAY_MS));
    }''')
s = s.replace('''    private int getRateLimitRetryDelayMs() {
        return getIntPref(MainActivity.KEY_RATE_LIMIT_RETRY_DELAY_MS,
                MainActivity.DEFAULT_RATE_LIMIT_RETRY_DELAY_MS, MainActivity.MAX_RATE_LIMIT_RETRY_DELAY_MS);
    }''', '''    private int getRateLimitRetryDelayMs() {
        return Math.max(250, getIntPref(MainActivity.KEY_RATE_LIMIT_RETRY_DELAY_MS,
                MainActivity.DEFAULT_RATE_LIMIT_RETRY_DELAY_MS, MainActivity.MAX_RATE_LIMIT_RETRY_DELAY_MS));
    }''')

begin_old = '''    private void beginAssistantPause() {
        pausedForAssistant = true;
        handler.removeCallbacks(startRunnable);
        handler.removeCallbacks(rearmRunnable);'''
begin_new = '''    private void beginAssistantPause() {
        pausedForAssistant = true;
        assistantUiVisible = false;
        handler.removeCallbacks(startRunnable);
        handler.removeCallbacks(rearmRunnable);
        handler.removeCallbacks(assistantOpenDetectTimeoutRunnable);
        handler.removeCallbacks(assistantMaxPauseRunnable);'''
s = replace_once(s, begin_old, begin_new, 'begin assistant pause')

trigger_pattern = re.compile(
    r'    private void triggerAssistant\(\) \{\n'
    r'        if \(pausedForAssistant \|\| stopping\) return;\n'
    r'        if \(getTemporaryVoiceEnabled\(\)\) triggerTemporaryVoice\(\);\n'
    r'        else triggerNormalAssistant\(\);\n'
    r'    \}')
trigger_replacement = ('    private void triggerAssistant() {\n'
                       '        if (pausedForAssistant || stopping) return;\n'
                       '        triggerNormalAssistant();\n'
                       '    }')
s, count = trigger_pattern.subn(trigger_replacement, s, count=1)
if count != 1:
    raise SystemExit('triggerAssistant block not found')

s = s.replace('? "Assistant opened — re-arming listener"', '? "Assistant opened"', 1)
s = s.replace(': "Wake phrase matched, but " + result.message + " — re-arming"',
              ': "Wake phrase matched, but " + result.message', 1)

old_rearm_schedule = '''        if (rearmDelayMs <= 0) handler.post(rearmRunnable);
        else handler.postDelayed(rearmRunnable, rearmDelayMs);'''
new_rearm_schedule = '''        if (isCompanionAccessibilityEnabled()) {
            // Accessibility tells us exactly when the assistant popup closes.
            // Do not immediately take the microphone back from ChatGPT.
            handler.postDelayed(assistantOpenDetectTimeoutRunnable, 3000L);
            handler.postDelayed(assistantMaxPauseRunnable, 10L * 60L * 1000L);
        } else {
            // Without the companion, use a small floor to avoid instant mic thrashing.
            int safeDelay = Math.max(rearmDelayMs, 500);
            handler.postDelayed(rearmRunnable, safeDelay);
        }'''
s = replace_once(s, old_rearm_schedule, new_rearm_schedule, 'normal assistant rearm schedule')

rearm_old = '''    private void rearmAfterTrigger() {
        if (stopping) return;
        handler.removeCallbacks(tempSetupTimeoutRunnable);
        handler.removeCallbacks(tempMaxSessionRunnable);
        pausedForAssistant = false;'''
rearm_new = '''    private void rearmAfterTrigger() {
        if (stopping) return;
        handler.removeCallbacks(tempSetupTimeoutRunnable);
        handler.removeCallbacks(tempMaxSessionRunnable);
        handler.removeCallbacks(assistantOpenDetectTimeoutRunnable);
        handler.removeCallbacks(assistantMaxPauseRunnable);
        assistantUiVisible = false;
        pausedForAssistant = false;'''
s = replace_once(s, rearm_old, rearm_new, 'rearm reset')

p.write_text(s)

# Main UI for v1.7.
p = Path('app/src/main/java/com/example/heychatgptassist/MainActivity.java')
s = p.read_text()
s = replace_once(s, 'Hey ChatGPT Assist v1.3', 'Hey ChatGPT Assist v1.7', 'main title')
s = s.replace(
    'Always-listening assistant with smoother microphone handling, optional response text, and an experimental Temporary Voice mode that keeps finished Voice chats out of normal history.',
    'Always-listening assistant with smoother microphone handling and strict Siri-style response-text capture. The wake listener now stays paused while the real ChatGPT assistant popup is open.')
s = s.replace(
    'When ChatGPT exposes its live response text through Android Accessibility, the companion can mirror it into a small panel. The Accessibility service is restricted to the ChatGPT app.',
    'v1.7 only reads the accessibility subtree anchored to the actual ChatGPT assistant popup. It no longer scans the rest of System UI, so Wi-Fi, weather, notifications, Home, and other unrelated text are ignored. If ChatGPT does not expose spoken response text in that popup, nothing is shown instead of guessing.')
s = s.replace(
    'When enabled, saying the wake phrase opens ChatGPT, starts a fresh Temporary chat, and then starts Voice. It uses the same Accessibility companion. Voice is not started unless the helper reaches the Temporary control first. This mode opens the ChatGPT app rather than the small Android assistant popup because ChatGPT does not expose a supported Temporary-mode flag for that popup.',
    'Automatic Temporary Chat remains disabled so the wake phrase always keeps the small assistant popup. Temporary Chat still needs to be started manually in the normal ChatGPT app.')
s = s.replace('        temporaryVoiceToggle.setText("Always use Temporary Chat for wake-phrase Voice");',
              '        temporaryVoiceToggle.setText("Automatic Temporary Chat unavailable with assistant popup");')
s = s.replace('        temporaryVoiceToggle.setChecked(prefs().getBoolean(KEY_TEMPORARY_VOICE_ENABLED, false));',
              '        temporaryVoiceToggle.setChecked(false);\n        temporaryVoiceToggle.setEnabled(false);')
listener_pattern = re.compile(
    r'\n        temporaryVoiceToggle\.setOnCheckedChangeListener\(\(buttonView, checked\) -> \{\n'
    r'            prefs\(\)\.edit\(\)\.putBoolean\(KEY_TEMPORARY_VOICE_ENABLED, checked\)\.apply\(\);\n'
    r'            updateTemporaryVoiceStatus\(\);\n'
    r'        \}\);')
s = listener_pattern.sub('', s, count=1)

init_anchor = '        Shizuku.addRequestPermissionResultListener(shizukuPermissionListener);\n'
if init_anchor in s:
    s = s.replace(init_anchor, init_anchor +
                  '        prefs().edit().putBoolean(KEY_TEMPORARY_VOICE_ENABLED, false).apply();\n', 1)

s = s.replace(
    'One-time setup: turn on ‘Hey ChatGPT Assist response text’ in Accessibility. That same service handles both response-text mirroring and Temporary Voice automation.',
    'One-time setup: turn on ‘Hey ChatGPT Assist response text’ in Accessibility. It now also tells the wake listener when the real assistant popup opens/closes, preventing repeated microphone activate/deactivate cycles while ChatGPT is talking.')
s = s.replace(
    'Normal mode keeps the side-button-style Android assistant behavior. Temporary Voice is separate and only takes over the wake action while its toggle is enabled.',
    'Wake-phrase activation always keeps the side-button-style Android assistant popup. While that popup is active, the wake listener releases the microphone and resumes immediately after the popup closes.')

s = s.replace(
    '"Normal assistant mode only. 0 = immediate. Temporary Voice pauses the wake listener while Voice is active."',
    '"With Accessibility enabled, this delay is applied after the assistant popup closes. 0 = immediate after close."')
s = s.replace(
    '"Delay after a normal timeout or no-match before listening starts again."',
    '"Delay after a normal timeout or no-match. v1.7 uses an internal 100 ms minimum to prevent rapid recognizer cycling."')
s = s.replace(
    '"Retry delay when Android temporarily says the microphone or recognizer is busy."',
    '"Retry delay when Android says the microphone or recognizer is busy. v1.7 uses an internal 100 ms minimum."')

marker = '        companionStatus.setText(text);'
diagnostic = ('        String debug = prefs().getString(ChatGPTTextAccessibilityService.KEY_LAST_WINDOW_DEBUG, "");\n'
              '        if (!debug.isEmpty()) text += "\\nAssistant capture debug: " + debug;\n'
              '        companionStatus.setText(text);')
s = replace_once(s, marker, diagnostic, 'companion diagnostic insertion')
p.write_text(s)

p = Path('app/build.gradle')
s = p.read_text()
s = replace_once(s, 'versionCode 13', 'versionCode 17', 'version code')
s = replace_once(s, 'versionName "1.3"', 'versionName "1.7"', 'version name')
p.write_text(s)
