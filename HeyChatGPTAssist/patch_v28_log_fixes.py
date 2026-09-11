from pathlib import Path

# v2.8: fixes found from the v2.7 phone log:
# 1) Voice UI was briefly disappearing during normal state changes and we were
#    falsely treating that as "Voice ended".
# 2) Text mirroring was choosing old visible chat messages. Snapshot existing
#    ChatGPT text before Voice starts and only consider NEW text afterward.
# 3) Home/launcher was excluded from previous-app tracking, leaving a stale
#    package (for example Clock) as the restore target.
# 4) Add a one-time Voice accessibility-tree dump to the debug text file.

p = Path("app/src/main/java/com/example/heychatgptassist/ChatGPTTextAccessibilityService.java")
s = p.read_text()

# ---------------------------------------------------------------------------
# Fields / constants.
# ---------------------------------------------------------------------------
const_anchor = '    private static final long FULL_VOICE_MAX_MS = 60L * 60L * 1000L;'
if const_anchor not in s:
    raise SystemExit("v2.8: FULL_VOICE_MAX_MS missing")
s = s.replace(
    const_anchor,
    const_anchor + '\n    private static final long VOICE_UI_END_GRACE_MS = 10_000L;\n'
                   '    private static final String HOME_SENTINEL = "__HOME__";',
    1
)

field_anchor = '    private boolean lastDebugChatRoot = false;'
if field_anchor not in s:
    raise SystemExit("v2.8: v2.6 debug fields missing")
s = s.replace(
    field_anchor,
    field_anchor + r'''

    private final java.util.HashSet<String> voiceBaselineTexts = new java.util.HashSet<>();
    private boolean voiceBaselineCaptured = false;
    private boolean dumpedVoiceTreeThisSession = false;''',
    1
)

# ---------------------------------------------------------------------------
# Previous-app tracking: launcher means "return HOME", not a stale old app.
# ---------------------------------------------------------------------------
old_prev = r'''            if (!pkg.isEmpty()
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
            }'''
new_prev = r'''            if ("com.sec.android.app.launcher".equals(pkg)
                    || "com.google.android.apps.nexuslauncher".equals(pkg)) {
                prefs().edit().putString(KEY_PREVIOUS_APP_PACKAGE, HOME_SENTINEL).apply();
            } else if (!pkg.isEmpty()
                    && !CHATGPT_PACKAGE.equals(pkg)
                    && !getPackageName().equals(pkg)
                    && !"com.android.systemui".equals(pkg)
                    && !"android".equals(pkg)
                    && !"com.samsung.android.sidegesturepad".equals(pkg)) {
                prefs().edit().putString(KEY_PREVIOUS_APP_PACKAGE, pkg).apply();
            }

            if (CHATGPT_PACKAGE.equals(pkg) && fullVoiceSessionActive) {
                captureEventText(event);
            }'''
if old_prev not in s:
    raise SystemExit("v2.8: previous-app event block missing")
s = s.replace(old_prev, new_prev, 1)

# ---------------------------------------------------------------------------
# Full Voice activation: dump tree once for future diagnosis.
# ---------------------------------------------------------------------------
active_anchor = r'''            if (!fullVoiceSessionActive) {
                fullVoiceSessionActive = true;
                returnedToPreviousApp = false;
                fullVoiceStartedUptime = nowUp;
                prefs().edit().putString(KEY_FULL_VOICE_STATUS,
                        "Full ChatGPT Voice active").apply();
            }'''
active_repl = r'''            if (!fullVoiceSessionActive) {
                fullVoiceSessionActive = true;
                returnedToPreviousApp = false;
                fullVoiceStartedUptime = nowUp;
                prefs().edit().putString(KEY_FULL_VOICE_STATUS,
                        "Full ChatGPT Voice active").apply();
                if (!dumpedVoiceTreeThisSession && chatRoot != null) {
                    dumpedVoiceTreeThisSession = true;
                    debugDumpVoiceTree(chatRoot);
                }
            }'''
if active_anchor not in s:
    raise SystemExit("v2.8: full voice activation block missing")
s = s.replace(active_anchor, active_repl, 1)

# ---------------------------------------------------------------------------
# Voice-close logic: 1.4s was far too aggressive. The real Voice UI toggles
# between detectable and non-detectable layouts while it is still active.
# ---------------------------------------------------------------------------
old_close = r'''            if (chatRoot != null && nowUp - lastVoiceUiSeenUptime > 1400L) {
                prefs().edit().putString(KEY_FULL_VOICE_STATUS,
                        "ChatGPT Voice ended").apply();
                markClosed();
            } else if (fullVoiceStartedUptime > 0L
                    && nowUp - fullVoiceStartedUptime > FULL_VOICE_MAX_MS) {'''
new_close = r'''            if (chatRoot != null && nowUp - lastVoiceUiSeenUptime > VOICE_UI_END_GRACE_MS) {
                prefs().edit().putString(KEY_FULL_VOICE_STATUS,
                        "ChatGPT Voice ended after stable non-Voice UI").apply();
                DebugFileLogger.log(this, "VOICE",
                        "No Voice UI for " + VOICE_UI_END_GRACE_MS + " ms while ChatGPT is foreground; ending helper session");
                markClosed();
            } else if (fullVoiceStartedUptime > 0L
                    && nowUp - fullVoiceStartedUptime > FULL_VOICE_MAX_MS) {'''
if old_close not in s:
    raise SystemExit("v2.8: old 1400ms close block missing")
s = s.replace(old_close, new_close, 1)

# ---------------------------------------------------------------------------
# Previous app restore: understand HOME sentinel.
# ---------------------------------------------------------------------------
old_return = r'''        if (pkg == null || pkg.isEmpty() || CHATGPT_PACKAGE.equals(pkg)
                || getPackageName().equals(pkg)) {
            // We do not know the previous task. HOME is safer than BACK because
            // BACK can end the Voice screen instead of merely backgrounding it.
            try { performGlobalAction(GLOBAL_ACTION_HOME); } catch (Throwable ignored) {}
            return;
        }'''
new_return = r'''        if (pkg == null || pkg.isEmpty() || HOME_SENTINEL.equals(pkg)
                || CHATGPT_PACKAGE.equals(pkg) || getPackageName().equals(pkg)) {
            try { performGlobalAction(GLOBAL_ACTION_HOME); } catch (Throwable ignored) {}
            DebugFileLogger.log(this, "VOICE", "Returned to HOME");
            return;
        }'''
if old_return not in s:
    raise SystemExit("v2.8: return-home block missing")
s = s.replace(old_return, new_return, 1)

# ---------------------------------------------------------------------------
# Baseline-aware event text.
# ---------------------------------------------------------------------------
start = s.find("    private void captureEventText(AccessibilityEvent event) {")
if start < 0:
    raise SystemExit("v2.8: captureEventText missing")
brace = s.find("{", start)
depth = 0
end = None
for i in range(brace, len(s)):
    if s[i] == "{": depth += 1
    elif s[i] == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
new_event = r'''    private void captureEventText(AccessibilityEvent event) {
        if (event == null || !fullVoiceSessionActive) return;
        try {
            List<CharSequence> parts = event.getText();
            if (parts == null) return;
            String best = "";
            for (CharSequence cs : parts) {
                if (cs == null) continue;
                String x = normalizeDebugText(cs.toString());
                if (x.isEmpty() || voiceBaselineTexts.contains(x)) continue;
                if (captionScore(x, "") > captionScore(best, "")) best = x;
            }
            if (!best.isEmpty()) {
                DebugFileLogger.logChanged(this, "new_event_text", "NEW-TEXT",
                        "Accessibility event: " + best);
                updateCaption(best);
            }
        } catch (Throwable ignored) {}
    }'''
s = s[:start] + new_event + s[end:]

# ---------------------------------------------------------------------------
# Baseline-aware tree scanning. Before Voice becomes active, collect all text
# already on screen. After it becomes active, only NEW strings are candidates.
# ---------------------------------------------------------------------------
start = s.find("    private void captureBestText(AccessibilityNodeInfo root) {")
if start < 0:
    raise SystemExit("v2.8: captureBestText missing")
brace = s.find("{", start)
depth = 0
end = None
for i in range(brace, len(s)):
    if s[i] == "{": depth += 1
    elif s[i] == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break

new_capture = r'''    private void captureBestText(AccessibilityNodeInfo root) {
        if (root == null) return;

        if (!fullVoiceSessionActive) {
            snapshotVoiceBaseline(root);
            return;
        }

        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(root);
        int index = 0;
        int visited = 0;
        String best = "";
        String bestContext = "";
        int bestScore = 0;

        while (index < queue.size() && visited < 700) {
            AccessibilityNodeInfo node = queue.get(index++);
            visited++;
            if (node == null) continue;

            String text = "";
            String id = "";
            try {
                if (node.getText() != null) text = normalizeDebugText(node.getText().toString());
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

            if (!text.isEmpty() && !voiceBaselineTexts.contains(text)) {
                int score = captionScore(text, id);
                if (score > 0) {
                    String dbg = text;
                    if (dbg.length() > 180) dbg = dbg.substring(0, 180) + "…";
                    DebugFileLogger.logChanged(this, "new_tree_text_" + text.hashCode(),
                            "NEW-TEXT", "score=" + score + " ctx=" + id + " text=" + dbg);
                }
                if (score > bestScore) {
                    bestScore = score;
                    best = text;
                    bestContext = id;
                }
            }

            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < 750; i++) {
                AccessibilityNodeInfo child = node.getChild(i);
                if (child != null) queue.add(child);
            }
        }

        if (bestScore >= 25 && !best.isEmpty()) {
            DebugFileLogger.logChanged(this, "best_new_text", "TEXT-SELECTED",
                    "score=" + bestScore + " ctx=" + bestContext + " text=" + best);
            updateCaption(best);
            // Treat this exact string as seen, while allowing a longer streaming
            // version of the same answer to be picked up later.
            voiceBaselineTexts.add(best);
        }
    }

    private void snapshotVoiceBaseline(AccessibilityNodeInfo root) {
        if (root == null) return;
        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(root);
        int index = 0;
        int visited = 0;
        int before = voiceBaselineTexts.size();

        while (index < queue.size() && visited < 900) {
            AccessibilityNodeInfo node = queue.get(index++);
            visited++;
            if (node == null) continue;
            try {
                if (node.getText() != null) {
                    String text = normalizeDebugText(node.getText().toString());
                    if (!text.isEmpty()) voiceBaselineTexts.add(text);
                }
            } catch (Throwable ignored) {}

            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < 950; i++) {
                AccessibilityNodeInfo child = node.getChild(i);
                if (child != null) queue.add(child);
            }
        }

        if (!voiceBaselineCaptured) {
            voiceBaselineCaptured = true;
            DebugFileLogger.log(this, "TEXT",
                    "Captured pre-Voice baseline: " + voiceBaselineTexts.size() + " unique visible strings");
        } else if (voiceBaselineTexts.size() > before) {
            DebugFileLogger.logChanged(this, "baseline_count", "TEXT",
                    "Pre-Voice baseline expanded to " + voiceBaselineTexts.size() + " strings");
        }
    }

    private String normalizeDebugText(String raw) {
        if (raw == null) return "";
        return raw.trim().replaceAll("\\s+", " ");
    }

    private void debugDumpVoiceTree(AccessibilityNodeInfo root) {
        if (!isDebugMode() || root == null) return;
        try {
            DebugFileLogger.log(this, "TREE", "---- ChatGPT Voice accessibility tree start ----");
            ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
            queue.add(root);
            int index = 0;
            int visited = 0;
            while (index < queue.size() && visited < 180) {
                AccessibilityNodeInfo node = queue.get(index++);
                visited++;
                if (node == null) continue;

                String text = "";
                String desc = "";
                String hint = "";
                String id = "";
                String cls = "";
                try {
                    if (node.getText() != null) text = normalizeDebugText(node.getText().toString());
                    if (node.getContentDescription() != null) desc = normalizeDebugText(node.getContentDescription().toString());
                    if (node.getHintText() != null) hint = normalizeDebugText(node.getHintText().toString());
                    if (node.getViewIdResourceName() != null) id = node.getViewIdResourceName();
                    if (node.getClassName() != null) cls = node.getClassName().toString();
                } catch (Throwable ignored) {}

                if (!text.isEmpty() || !desc.isEmpty() || !hint.isEmpty() || !id.isEmpty()) {
                    String line = "#" + visited
                            + " cls=" + cls
                            + " id=" + id
                            + " text=" + text
                            + " desc=" + desc
                            + " hint=" + hint
                            + " click=" + node.isClickable();
                    if (line.length() > 500) line = line.substring(0, 500) + "…";
                    DebugFileLogger.log(this, "TREE", line);
                }

                int count = node.getChildCount();
                for (int i = 0; i < count && queue.size() < 220; i++) {
                    AccessibilityNodeInfo child = node.getChild(i);
                    if (child != null) queue.add(child);
                }
            }
            DebugFileLogger.log(this, "TREE", "---- ChatGPT Voice accessibility tree end ----");
        } catch (Throwable t) {
            DebugFileLogger.log(this, "TREE", "Tree dump failed: " + t.getClass().getSimpleName());
        }
    }'''
s = s[:start] + new_capture + s[end:]

# ---------------------------------------------------------------------------
# Reset text-session state when Voice truly ends.
# ---------------------------------------------------------------------------
close_anchor = r'''        lastPopupSeenUptime = 0L;
        prefs().edit().putLong(KEY_FULL_VOICE_REQUEST_MS, 0L).apply();'''
if close_anchor not in s:
    raise SystemExit("v2.8: markClosed reset anchor missing")
s = s.replace(close_anchor, r'''        lastPopupSeenUptime = 0L;
        voiceBaselineTexts.clear();
        voiceBaselineCaptured = false;
        dumpedVoiceTreeThisSession = false;
        lastCaption = "";
        prefs().edit().putLong(KEY_FULL_VOICE_REQUEST_MS, 0L).apply();''', 1)

p.write_text(s)

# ---------------------------------------------------------------------------
# Main UI/version text.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/MainActivity.java")
s = p.read_text()
s = s.replace("Hey ChatGPT Assist v2.7", "Hey ChatGPT Assist v2.8")
s = s.replace(
    "v2.7 records the wake/ChatGPT Voice stages, visible packages, Voice detection, previous app, Accessibility events, and response-text candidates into a normal .txt file in Downloads/HeyChatGPTAssist. No debug overlay is drawn on screen.",
    "v2.8 records the wake/ChatGPT Voice stages into a .txt file in Downloads/HeyChatGPTAssist. It also logs a one-time accessibility-tree snapshot of the real Voice UI. v2.8 ignores old chat text and only tries to show NEW text that appears after Voice starts."
)
s = s.replace(
    "v2.7 can record a detailed debug text file in Downloads/HeyChatGPTAssist so failed Voice/text detection can be diagnosed without covering the screen.",
    "v2.8 can record a detailed debug text file in Downloads/HeyChatGPTAssist. Voice detection now has a longer grace period so normal ChatGPT UI transitions do not end the helper session."
)
p.write_text(s)

p = Path("app/build.gradle")
s = p.read_text()
if 'versionCode 27' not in s or 'versionName "2.7"' not in s:
    raise SystemExit("v2.8: expected v2.7 version fields missing")
s = s.replace("versionCode 27", "versionCode 28", 1)
s = s.replace('versionName "2.7"', 'versionName "2.8"', 1)
p.write_text(s)
