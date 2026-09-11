from pathlib import Path

# v2.5: normal mode now starts a full ChatGPT Voice conversation rather than
# Android's one-shot assistant surface.  ChatGPT remains the intelligence and
# voice engine.  When ChatGPT Voice is active we return to the app that was in
# front before the wake phrase and keep only our Siri orb over it.
#
# Also add best-effort response-text mirroring.  GPT-Live renders text in the
# ChatGPT UI while it speaks; when Android exposes that text through
# Accessibility events/windows, mirror the newest assistant-looking text into
# a small card above the orb.  This does not use the API or a local AI model.

def replace_method(src: str, signature: str, replacement: str) -> str:
    start = src.find(signature)
    if start < 0:
        raise SystemExit(f"v2.5: method missing: {signature}")
    brace = src.find("{", start)
    if brace < 0:
        raise SystemExit(f"v2.5: opening brace missing: {signature}")
    depth = 0
    end = None
    for i in range(brace, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end is None:
        raise SystemExit(f"v2.5: closing brace missing: {signature}")
    return src[:start] + replacement + src[end:]


# ---------------------------------------------------------------------------
# WakeListenerService: launch the full ChatGPT app/Voice instead of KEYCODE_ASSIST.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/WakeListenerService.java")
s = p.read_text()

new_trigger = r'''    private void triggerNormalAssistant() {
        beginAssistantPause();
        final int keyCode = getAssistKeyCode();
        final int triggerDelayMs = getTriggerDelayMs();
        setStatus("Activation phrase heard — opening full ChatGPT Voice");

        long now = System.currentTimeMillis();
        prefs().edit()
                .putLong(ChatGPTTextAccessibilityService.KEY_LAST_ASSIST_TRIGGER_MS, now)
                .putLong(ChatGPTTextAccessibilityService.KEY_FULL_VOICE_REQUEST_MS, now)
                .putString(ChatGPTTextAccessibilityService.KEY_FULL_VOICE_STATUS,
                        "Opening ChatGPT…")
                .apply();

        handler.removeCallbacks(assistantSessionTimeoutRunnable);
        // ChatGPT background Voice sessions can last up to an hour. This is a
        // safety re-arm only; normally Accessibility re-arms as soon as Voice
        // is actually ended in ChatGPT.
        handler.postDelayed(assistantSessionTimeoutRunnable, 60L * 60L * 1000L);

        Runnable launch = () -> {
            boolean opened = false;
            try {
                Intent open = getPackageManager().getLaunchIntentForPackage("com.openai.chatgpt");
                if (open != null) {
                    open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                            | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                            | Intent.FLAG_ACTIVITY_SINGLE_TOP);
                    startActivity(open);
                    opened = true;
                    setStatus("ChatGPT opened — starting full Voice");
                }
            } catch (Throwable ignored) {}

            if (!opened) {
                // Last-resort compatibility fallback: preserve the old
                // assistant-key behavior if ChatGPT cannot be launched.
                new Thread(() -> {
                    ShizukuBridge.Result result = ShizukuBridge.sendKeyEvent(keyCode);
                    handler.post(() -> {
                        if (!result.success) {
                            setStatus("Could not open ChatGPT Voice — re-arming");
                            rearmAfterTrigger();
                        } else {
                            setStatus("Full app launch failed — opened normal assistant fallback");
                        }
                    });
                }, "shizuku-voice-fallback").start();
            }
        };

        if (triggerDelayMs <= 0) handler.post(launch);
        else handler.postDelayed(launch, triggerDelayMs);
    }'''
s = replace_method(s, "    private void triggerNormalAssistant()", new_trigger)
p.write_text(s)


# ---------------------------------------------------------------------------
# Accessibility service: full Voice automation + persistent orb + best-effort text.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/ChatGPTTextAccessibilityService.java")
s = p.read_text()

if "import android.widget.TextView;" not in s:
    s = s.replace("import android.view.WindowManager;\n",
                  "import android.view.WindowManager;\nimport android.view.ViewGroup;\nimport android.widget.TextView;\nimport android.text.TextUtils;\n", 1)

const_anchor = '''    private static final long CLOSED_GRACE_MS = 650L;'''
if const_anchor not in s:
    raise SystemExit("v2.5: constants anchor missing")
s = s.replace(const_anchor, const_anchor + r'''
    public static final String KEY_FULL_VOICE_REQUEST_MS = "full_voice_request_ms";
    public static final String KEY_FULL_VOICE_STATUS = "full_voice_status";
    public static final String KEY_PREVIOUS_APP_PACKAGE = "previous_app_package";
    private static final long FULL_VOICE_START_WINDOW_MS = 20_000L;
    private static final long FULL_VOICE_MAX_MS = 60L * 60L * 1000L;''', 1)

field_anchor = '''    private AnimatorSet siriOrbAnimator;'''
if field_anchor not in s:
    raise SystemExit("v2.5: v2.4 orb fields missing")
s = s.replace(field_anchor, field_anchor + r'''

    private boolean fullVoiceSessionActive = false;
    private boolean returnedToPreviousApp = false;
    private long fullVoiceStartedUptime = 0L;
    private long lastVoiceUiSeenUptime = 0L;
    private long lastVoiceClickUptime = 0L;
    private long lastChatGptForegroundUptime = 0L;

    private WindowManager captionWindowManager;
    private TextView captionView;
    private String lastCaption = "";''', 1)

new_event = r'''    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event != null) {
            String pkg = event.getPackageName() == null ? "" : event.getPackageName().toString();

            // Remember the app the user was actually using before ChatGPT is
            // brought forward, so we can put it back in front after Voice starts.
            if (!pkg.isEmpty()
                    && !CHATGPT_PACKAGE.equals(pkg)
                    && !getPackageName().equals(pkg)
                    && !"com.android.systemui".equals(pkg)
                    && !"com.sec.android.app.launcher".equals(pkg)
                    && !"com.google.android.apps.nexuslauncher".equals(pkg)
                    && !"android".equals(pkg)) {
                prefs().edit().putString(KEY_PREVIOUS_APP_PACKAGE, pkg).apply();
            }

            if (CHATGPT_PACKAGE.equals(pkg)) {
                captureEventText(event);
            }
        }
        checkPopupState();
    }'''
s = replace_method(s, "    public void onAccessibilityEvent(AccessibilityEvent event)", new_event)

new_check = r'''    private void checkPopupState() {
        long nowWall = System.currentTimeMillis();
        long nowUp = SystemClock.uptimeMillis();
        long voiceRequest = prefs().getLong(KEY_FULL_VOICE_REQUEST_MS, 0L);
        long requestAge = voiceRequest <= 0L ? Long.MAX_VALUE : nowWall - voiceRequest;
        boolean startingFullVoice = requestAge >= 0L && requestAge <= FULL_VOICE_START_WINDOW_MS;

        AccessibilityNodeInfo chatRoot = null;
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

                if (CHATGPT_PACKAGE.equals(pkg)) {
                    chatRoot = root;
                    lastChatGptForegroundUptime = nowUp;
                    captureBestText(root);
                    break;
                }
            }
        }

        boolean voiceUi = chatRoot != null && subtreeLooksLikeFullVoice(chatRoot);

        if (chatRoot != null && startingFullVoice && !voiceUi) {
            // "Start with Voice" in ChatGPT settings is the cleanest path.
            // If it is off (or the app resumed an existing chat), tap ChatGPT's
            // Voice control as a fallback.
            if (nowUp - lastVoiceClickUptime > 1100L) {
                lastVoiceClickUptime = nowUp;
                if (tryClickVoiceControl(chatRoot)) {
                    prefs().edit().putString(KEY_FULL_VOICE_STATUS,
                            "Tapped ChatGPT Voice control…").apply();
                }
            }
        }

        if (voiceUi) {
            lastPopupSeenUptime = nowUp;
            lastVoiceUiSeenUptime = nowUp;
            if (!fullVoiceSessionActive) {
                fullVoiceSessionActive = true;
                returnedToPreviousApp = false;
                fullVoiceStartedUptime = nowUp;
                prefs().edit().putString(KEY_FULL_VOICE_STATUS,
                        "Full ChatGPT Voice active").apply();
            }

            showSiriOrb();
            if (!popupOpen) {
                popupOpen = true;
                sendState(WakeListenerService.ACTION_ASSISTANT_POPUP_OPENED);
            }

            // Let ChatGPT finish entering Voice, then restore the app/game that
            // was visible before the wake phrase. Background conversations must
            // be enabled in ChatGPT for the call to keep running there.
            if (!returnedToPreviousApp) {
                returnedToPreviousApp = true;
                handler.postDelayed(this::returnToPreviousApp, 1200L);
            }
        } else if (fullVoiceSessionActive) {
            // Once Voice is running in the background ChatGPT has no interactive
            // window, so absence of a ChatGPT window does NOT mean Voice ended.
            showSiriOrb();

            // If the user brings ChatGPT back and the Voice controls disappear,
            // they ended Voice. Re-arm promptly.
            if (chatRoot != null && nowUp - lastVoiceUiSeenUptime > 1400L) {
                prefs().edit().putString(KEY_FULL_VOICE_STATUS,
                        "ChatGPT Voice ended").apply();
                markClosed();
            } else if (fullVoiceStartedUptime > 0L
                    && nowUp - fullVoiceStartedUptime > FULL_VOICE_MAX_MS) {
                prefs().edit().putString(KEY_FULL_VOICE_STATUS,
                        "Voice safety timeout reached").apply();
                markClosed();
            }
        } else if (startingFullVoice) {
            // Still waiting for ChatGPT to enter Voice. Keep the wake listener
            // paused and allow the fallback click loop above to work.
            if (chatRoot != null) {
                lastPopupSeenUptime = nowUp;
                if (!popupOpen) {
                    popupOpen = true;
                    sendState(WakeListenerService.ACTION_ASSISTANT_POPUP_OPENED);
                }
            }
        } else if (isRecentAssistSession()) {
            // Compatibility with the old one-shot assistant fallback.
            boolean found = chatRoot != null;
            if (!found && windows != null) {
                for (AccessibilityWindowInfo window : windows) {
                    if (window == null) continue;
                    AccessibilityNodeInfo root = null;
                    try { root = window.getRoot(); } catch (Throwable ignored) {}
                    if (root != null && subtreeLooksLikeChatGptAssistant(root)) {
                        found = true;
                        break;
                    }
                }
            }
            if (found) {
                lastPopupSeenUptime = nowUp;
                showSiriOrb();
                if (!popupOpen) {
                    popupOpen = true;
                    sendState(WakeListenerService.ACTION_ASSISTANT_POPUP_OPENED);
                }
            } else if (popupOpen && nowUp - lastPopupSeenUptime > CLOSED_GRACE_MS) {
                markClosed();
            }
        } else if (popupOpen) {
            markClosed();
        } else {
            hideSiriOrb();
            hideCaption();
        }

        prefs().edit().putString(KEY_LAST_WINDOW_DEBUG,
                "v2.5 full Voice | windows: " +
                        (packages.length() == 0 ? "(none)" : packages.toString()) +
                        " | voice: " + (fullVoiceSessionActive ? "ACTIVE" : "not active") +
                        " | voice UI: " + (voiceUi ? "seen" : "not seen") +
                        " | caption: " + (lastCaption.isEmpty() ? "(none)" : "captured"))
                .apply();
    }'''
s = replace_method(s, "    private void checkPopupState()", new_check)

helper_anchor = '''    private boolean subtreeLooksLikeChatGptAssistant(AccessibilityNodeInfo root) {'''
if helper_anchor not in s:
    raise SystemExit("v2.5: assistant subtree method missing")

helpers = r'''    private boolean subtreeLooksLikeFullVoice(AccessibilityNodeInfo root) {
        if (root == null) return false;
        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(root);
        int index = 0;
        int visited = 0;
        boolean sawMicControl = false;
        boolean sawExitControl = false;
        boolean sawVoicePhrase = false;

        while (index < queue.size() && visited < 500) {
            AccessibilityNodeInfo node = queue.get(index++);
            visited++;
            if (node == null) continue;

            String t = nodeText(node).toLowerCase(Locale.US);
            if (t.contains("end voice") || t.contains("exit voice")
                    || t.contains("leave voice") || t.contains("stop voice")) {
                sawExitControl = true;
            }
            if (t.contains("mute") || t.contains("unmute")
                    || t.contains("microphone")) {
                sawMicControl = true;
            }
            if (t.contains("voice conversation") || t.contains("voice mode")
                    || t.contains("tap to interrupt") || t.contains("listening")) {
                sawVoicePhrase = true;
            }

            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < 550; i++) {
                AccessibilityNodeInfo child = node.getChild(i);
                if (child != null) queue.add(child);
            }
        }
        return sawExitControl || (sawMicControl && sawVoicePhrase);
    }

    private boolean tryClickVoiceControl(AccessibilityNodeInfo root) {
        if (root == null) return false;
        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(root);
        int index = 0;
        int visited = 0;

        while (index < queue.size() && visited < 500) {
            AccessibilityNodeInfo node = queue.get(index++);
            visited++;
            if (node == null) continue;

            String t = nodeText(node).toLowerCase(Locale.US).trim();
            boolean candidate = t.equals("voice")
                    || t.equals("voice mode")
                    || t.contains("start voice")
                    || t.contains("start a voice")
                    || t.contains("open voice");
            boolean reject = t.contains("settings") || t.contains("language")
                    || t.contains("background") || t.contains("separate mode");

            if (candidate && !reject && clickNodeOrParent(node)) return true;

            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < 550; i++) {
                AccessibilityNodeInfo child = node.getChild(i);
                if (child != null) queue.add(child);
            }
        }
        return false;
    }

    private boolean clickNodeOrParent(AccessibilityNodeInfo node) {
        AccessibilityNodeInfo cur = node;
        for (int i = 0; i < 5 && cur != null; i++) {
            try {
                if (cur.isClickable()
                        && cur.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                    return true;
                }
            } catch (Throwable ignored) {}
            try { cur = cur.getParent(); } catch (Throwable ignored) { cur = null; }
        }
        return false;
    }

    private String nodeText(AccessibilityNodeInfo node) {
        if (node == null) return "";
        StringBuilder b = new StringBuilder();
        try {
            if (node.getText() != null) b.append(node.getText()).append(' ');
            if (node.getContentDescription() != null) b.append(node.getContentDescription()).append(' ');
            if (node.getHintText() != null) b.append(node.getHintText()).append(' ');
        } catch (Throwable ignored) {}
        return b.toString().trim();
    }

    private void returnToPreviousApp() {
        if (!fullVoiceSessionActive) return;
        String pkg = prefs().getString(KEY_PREVIOUS_APP_PACKAGE, "");
        if (pkg == null || pkg.isEmpty() || CHATGPT_PACKAGE.equals(pkg)
                || getPackageName().equals(pkg)) {
            // We do not know the previous task. HOME is safer than BACK because
            // BACK can end the Voice screen instead of merely backgrounding it.
            try { performGlobalAction(GLOBAL_ACTION_HOME); } catch (Throwable ignored) {}
            return;
        }

        try {
            Intent open = getPackageManager().getLaunchIntentForPackage(pkg);
            if (open == null) throw new IllegalStateException("No launch intent");
            open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                    | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                    | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            startActivity(open);
            prefs().edit().putString(KEY_FULL_VOICE_STATUS,
                    "Voice running over " + pkg).apply();
        } catch (Throwable t) {
            try { performGlobalAction(GLOBAL_ACTION_HOME); } catch (Throwable ignored) {}
        }
    }

    private void captureEventText(AccessibilityEvent event) {
        if (event == null) return;
        try {
            List<CharSequence> parts = event.getText();
            if (parts == null) return;
            String best = "";
            for (CharSequence cs : parts) {
                if (cs == null) continue;
                String x = cs.toString().trim();
                if (captionScore(x, "") > captionScore(best, "")) best = x;
            }
            if (!best.isEmpty()) updateCaption(best);
        } catch (Throwable ignored) {}
    }

    private void captureBestText(AccessibilityNodeInfo root) {
        if (root == null) return;
        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(root);
        int index = 0;
        int visited = 0;
        String best = "";
        int bestScore = 0;

        while (index < queue.size() && visited < 650) {
            AccessibilityNodeInfo node = queue.get(index++);
            visited++;
            if (node == null) continue;

            String text = "";
            String id = "";
            try {
                if (node.getText() != null) text = node.getText().toString().trim();
                if (node.getViewIdResourceName() != null) id = node.getViewIdResourceName();
                AccessibilityNodeInfo parent = node.getParent();
                if (parent != null) {
                    String ptxt = parent.getContentDescription() == null ? ""
                            : parent.getContentDescription().toString();
                    String pid = parent.getViewIdResourceName() == null ? ""
                            : parent.getViewIdResourceName();
                    id = id + " " + pid + " " + ptxt;
                }
            } catch (Throwable ignored) {}

            int score = captionScore(text, id);
            if (score > bestScore) {
                bestScore = score;
                best = text;
            }

            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < 700; i++) {
                AccessibilityNodeInfo child = node.getChild(i);
                if (child != null) queue.add(child);
            }
        }

        if (bestScore >= 25 && !best.isEmpty()) updateCaption(best);
    }

    private int captionScore(String raw, String context) {
        if (raw == null) return 0;
        String text = raw.trim().replaceAll("\\s+", " ");
        if (text.length() < 8) return 0;
        if (text.length() > 1400) text = text.substring(0, 1400);

        String lower = text.toLowerCase(Locale.US);
        String ctx = context == null ? "" : context.toLowerCase(Locale.US);

        String[] reject = new String[] {
                "start voice", "voice mode", "voice conversation", "end voice",
                "exit voice", "mute", "unmute", "microphone", "tap to interrupt",
                "new chat", "search chats", "attach", "camera", "photo library",
                "settings", "background conversations", "separate mode",
                "what's on your mind", "message chatgpt"
        };
        for (String x : reject) if (lower.equals(x) || lower.startsWith(x + " ")) return 0;

        int score = Math.min(text.length(), 260);
        if (text.length() >= 24) score += 20;
        if (ctx.contains("assistant") || ctx.contains("response")) score += 220;
        if (ctx.contains("message")) score += 35;
        if (ctx.contains("user")) score -= 180;
        if (lower.startsWith("you:") || lower.startsWith("you said")) score -= 180;
        return Math.max(0, score);
    }

    private void updateCaption(String raw) {
        if (raw == null) return;
        String text = raw.trim().replaceAll("\\s+", " ");
        if (text.length() < 8 || text.equals(lastCaption)) return;
        if (text.length() > 900) text = text.substring(0, 900) + "…";

        lastCaption = text;
        prefs().edit().putString(KEY_LAST_CAPTURED_TEXT, text).apply();
        showCaption(text);
    }

    private void showCaption(String text) {
        if (text == null || text.trim().isEmpty()) return;
        try {
            if (captionView == null) {
                WindowManager wm = (WindowManager) getSystemService(WINDOW_SERVICE);
                if (wm == null) return;

                TextView tv = new TextView(this);
                tv.setTextColor(Color.WHITE);
                tv.setTextSize(17f);
                tv.setMaxLines(6);
                tv.setEllipsize(TextUtils.TruncateAt.END);
                tv.setPadding(dp(16), dp(12), dp(16), dp(12));
                tv.setGravity(Gravity.CENTER_VERTICAL);

                GradientDrawable bg = new GradientDrawable();
                bg.setColor(Color.argb(238, 28, 28, 30));
                bg.setCornerRadius(dp(20));
                tv.setBackground(bg);
                tv.setElevation(dp(12));

                WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                        WindowManager.LayoutParams.MATCH_PARENT,
                        WindowManager.LayoutParams.WRAP_CONTENT,
                        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                                | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                                | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                        PixelFormat.TRANSLUCENT);
                lp.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
                lp.x = 0;
                lp.y = dp(112);
                lp.horizontalMargin = 0.045f;
                lp.setTitle("Hey ChatGPT Assist response");

                wm.addView(tv, lp);
                captionWindowManager = wm;
                captionView = tv;
            }
            captionView.setText(text);
            captionView.setVisibility(View.VISIBLE);
        } catch (Throwable ignored) {}
    }

    private void hideCaption() {
        TextView tv = captionView;
        captionView = null;
        WindowManager wm = captionWindowManager;
        captionWindowManager = null;
        if (tv != null && wm != null) {
            try { wm.removeViewImmediate(tv); } catch (Throwable ignored) {}
        }
    }

'''
s = s.replace(helper_anchor, helpers + helper_anchor, 1)

# Reset full-Voice state and caption when a session actually ends.
new_mark = r'''    private void markClosed() {
        popupOpen = false;
        fullVoiceSessionActive = false;
        returnedToPreviousApp = false;
        fullVoiceStartedUptime = 0L;
        lastVoiceUiSeenUptime = 0L;
        lastPopupSeenUptime = 0L;
        prefs().edit().putLong(KEY_FULL_VOICE_REQUEST_MS, 0L).apply();
        hideSiriOrb();
        hideCaption();
        sendState(WakeListenerService.ACTION_ASSISTANT_POPUP_CLOSED);
    }'''
s = replace_method(s, "    private void markClosed()", new_mark)

# v2.4's hide orb is still used independently. Do not let it leave stale text
# around when no session is active.
old_hide_end = '''        if (orb != null && wm != null) {
            try { wm.removeViewImmediate(orb); } catch (Throwable ignored) {}
        }
    }'''
if old_hide_end not in s:
    raise SystemExit("v2.5: hide orb tail missing")
s = s.replace(old_hide_end, '''        if (orb != null && wm != null) {
            try { wm.removeViewImmediate(orb); } catch (Throwable ignored) {}
        }
        if (!fullVoiceSessionActive && !popupOpen) hideCaption();
    }''', 1)

p.write_text(s)


# ---------------------------------------------------------------------------
# Main UI/version wording.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/MainActivity.java")
s = p.read_text()
s = s.replace("Hey ChatGPT Assist v2.4", "Hey ChatGPT Assist v2.5")
s = s.replace(
    "Normal mode now means REAL ChatGPT + Siri-style orb. ChatGPT itself handles listening, intelligence, follow-ups, and voice. The helper adds only the animated orb; there is no custom answer text box.",
    "Normal mode now starts a FULL ChatGPT Voice conversation, returns you to the app/game you were using, and keeps the Siri-style orb on top while ChatGPT continues in the background. In ChatGPT Settings → Voice, turn ON Start with Voice and Background conversations. v2.5 also tries to mirror GPT-Live response text into a small card whenever Android exposes that text through Accessibility."
)
s = s.replace(
    "For NORMAL mode: keep ‘Hey ChatGPT Assist response text’ enabled in Accessibility. v2.4 uses it only to detect the real ChatGPT assistant popup and place the animated Siri-style orb over it. No ChatGPT response text is read, copied, or displayed by the helper.",
    "For NORMAL mode: keep ‘Hey ChatGPT Assist response text’ enabled in Accessibility. v2.5 uses it to start/detect full ChatGPT Voice, restore your previous app, show the Siri orb, and make a best-effort attempt to mirror ChatGPT's spoken response text. No OpenAI API key or local model is used."
)
p.write_text(s)

p = Path("app/build.gradle")
s = p.read_text()
if 'versionCode 24' not in s or 'versionName "2.4"' not in s:
    raise SystemExit("v2.5: expected v2.4 version fields missing")
s = s.replace("versionCode 24", "versionCode 25", 1)
s = s.replace('versionName "2.4"', 'versionName "2.5"', 1)
p.write_text(s)
