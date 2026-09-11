from pathlib import Path

# v3.0: Recover the committed assistant response from the AccessibilityEvent
# message container. v2.9 proved the event source itself is often just a
# feedback/control node ("Good response", "Bad response") or null. The actual
# answer can be a sibling, so climb to the nearest ancestor containing the
# assistant feedback controls, then inspect TEXT children of that container.

def replace_method(src: str, signature: str, replacement: str) -> str:
    start = src.find(signature)
    if start < 0:
        raise SystemExit(f"v3.0: method missing: {signature}")
    brace = src.find("{", start)
    if brace < 0:
        raise SystemExit(f"v3.0: opening brace missing: {signature}")
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
        raise SystemExit(f"v3.0: closing brace missing: {signature}")
    return src[:start] + replacement + src[end:]

p = Path("app/src/main/java/com/example/heychatgptassist/ChatGPTTextAccessibilityService.java")
s = p.read_text()

field_anchor = '    private long lastEventSourceScanUptime = 0L;'
if field_anchor not in s:
    raise SystemExit("v3.0: v2.9 fields missing")
s = s.replace(field_anchor, field_anchor + '\n    private boolean dumpedResponseContainerThisSession = false;', 1)

new_capture = r'''    private void captureEventSource(AccessibilityEvent event) {
        if (event == null || !fullVoiceSessionActive) return;

        long now = SystemClock.uptimeMillis();
        if (now - lastEventSourceScanUptime < 120L) return;
        lastEventSourceScanUptime = now;

        AccessibilityNodeInfo source = null;
        try { source = event.getSource(); } catch (Throwable ignored) {}
        if (source == null) {
            DebugFileLogger.logChanged(this, "event_source_null_" + event.getEventType(),
                    "EVENT-SOURCE",
                    "ChatGPT event type=" + event.getEventType() + " source=(null)");
            return;
        }

        if (!dumpedBackgroundEventTreeThisSession) {
            dumpedBackgroundEventTreeThisSession = true;
            debugDumpEventSourceTree(source, event.getEventType());
        }

        AccessibilityNodeInfo responseContainer = findAssistantResponseContainer(source);
        if (responseContainer == null) {
            // Do not show text from arbitrary ChatGPT event nodes. v2.9 proved
            // that doing so can display toolbar labels or old chat content.
            return;
        }

        if (!dumpedResponseContainerThisSession) {
            dumpedResponseContainerThisSession = true;
            debugDumpResponseContainer(responseContainer);
        }

        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(responseContainer);
        int index = 0;
        int visited = 0;
        String best = "";
        int bestScore = 0;

        while (index < queue.size() && visited < 450) {
            AccessibilityNodeInfo node = queue.get(index++);
            visited++;
            if (node == null) continue;

            String text = "";
            String cls = "";
            try {
                if (node.getText() != null) text = normalizeDebugText(node.getText().toString());
                if (node.getClassName() != null) cls = node.getClassName().toString();
            } catch (Throwable ignored) {}

            if (!text.isEmpty()
                    && !voiceBaselineTexts.contains(text)
                    && !isResponseControlLabel(text)) {
                int score = responseTextScore(text, cls);
                if (score > 0) {
                    String dbg = text.length() > 260 ? text.substring(0, 260) + "…" : text;
                    DebugFileLogger.logChanged(this,
                            "response_candidate_" + text.hashCode(),
                            "RESPONSE-TEXT",
                            "score=" + score + " cls=" + cls + " text=" + dbg);
                }
                if (score > bestScore) {
                    bestScore = score;
                    best = text;
                }
            }

            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < 500; i++) {
                AccessibilityNodeInfo child = null;
                try { child = node.getChild(i); } catch (Throwable ignored) {}
                if (child != null) queue.add(child);
            }
        }

        if (bestScore >= 55 && !best.isEmpty()) {
            DebugFileLogger.logChanged(this, "response_selected",
                    "TEXT-SELECTED",
                    "ASSISTANT RESPONSE score=" + bestScore + " text=" + best);
            updateCaption(best);
            voiceBaselineTexts.add(best);
        }
    }'''
s = replace_method(s, "    private void captureEventSource(AccessibilityEvent event)", new_capture)

anchor = '    private void debugDumpEventSourceTree(AccessibilityNodeInfo root, int eventType) {'
if anchor not in s:
    raise SystemExit("v3.0: debugDumpEventSourceTree anchor missing")

helpers = r'''    private AccessibilityNodeInfo findAssistantResponseContainer(AccessibilityNodeInfo source) {
        AccessibilityNodeInfo cur = source;
        AccessibilityNodeInfo fallback = null;

        for (int depth = 0; depth < 9 && cur != null; depth++) {
            ResponseSignals signals = inspectResponseSignals(cur, 380);
            if (signals.feedback && signals.hasSubstantiveText) {
                DebugFileLogger.logChanged(this, "response_container_depth",
                        "RESPONSE-CONTAINER",
                        "Found assistant message container at parent depth=" + depth
                                + " nodes=" + signals.nodes
                                + " textNodes=" + signals.textNodes);
                return cur;
            }
            if (fallback == null && signals.feedback) fallback = cur;

            AccessibilityNodeInfo parent = null;
            try { parent = cur.getParent(); } catch (Throwable ignored) {}
            cur = parent;
        }

        return fallback != null && inspectResponseSignals(fallback, 420).hasSubstantiveText
                ? fallback : null;
    }

    private static final class ResponseSignals {
        boolean feedback;
        boolean hasSubstantiveText;
        int nodes;
        int textNodes;
    }

    private ResponseSignals inspectResponseSignals(AccessibilityNodeInfo root, int maxNodes) {
        ResponseSignals out = new ResponseSignals();
        if (root == null) return out;

        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(root);
        int index = 0;

        while (index < queue.size() && out.nodes < maxNodes) {
            AccessibilityNodeInfo node = queue.get(index++);
            out.nodes++;
            if (node == null) continue;

            String text = "";
            String desc = "";
            try {
                if (node.getText() != null) text = normalizeDebugText(node.getText().toString());
                if (node.getContentDescription() != null) desc =
                        normalizeDebugText(node.getContentDescription().toString());
            } catch (Throwable ignored) {}

            String lowText = text.toLowerCase(Locale.US);
            String lowDesc = desc.toLowerCase(Locale.US);

            if (lowDesc.equals("good response") || lowDesc.equals("bad response")
                    || lowText.equals("good response") || lowText.equals("bad response")) {
                out.feedback = true;
            }

            if (!text.isEmpty()) {
                out.textNodes++;
                if (!voiceBaselineTexts.contains(text)
                        && !isResponseControlLabel(text)
                        && responseTextScore(text, "") >= 55) {
                    out.hasSubstantiveText = true;
                }
            }

            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < maxNodes + 20; i++) {
                AccessibilityNodeInfo child = null;
                try { child = node.getChild(i); } catch (Throwable ignored) {}
                if (child != null) queue.add(child);
            }
        }
        return out;
    }

    private boolean isResponseControlLabel(String raw) {
        if (raw == null) return true;
        String x = normalizeDebugText(raw).toLowerCase(Locale.US);
        if (x.isEmpty()) return true;

        String[] labels = new String[] {
                "good response", "bad response", "copy", "read aloud", "share",
                "more actions", "sources", "reply to chatgpt", "navigate up",
                "edit menu", "start a voice conversation", "dictation",
                "attachment", "new chat", "voice settings", "menu",
                "turn microphone off", "turn microphone on", "end",
                "branch · hey siri discord calls", "hey siri discord calls"
        };
        for (String label : labels) {
            if (x.equals(label)) return true;
        }
        if (x.startsWith("branch ·")) return true;
        if (x.startsWith("download heychatgptassist")) return true;
        if (x.endsWith(".txt") && x.contains("heychatgptassist-debug")) return true;
        return false;
    }

    private int responseTextScore(String raw, String cls) {
        if (raw == null) return 0;
        String text = normalizeDebugText(raw);
        if (text.length() < 8 || isResponseControlLabel(text)) return 0;

        int score = Math.min(text.length(), 260);
        if (text.length() >= 20) score += 30;
        if (text.length() >= 45) score += 35;
        if (text.length() >= 90) score += 30;
        if (text.contains(" ") && text.matches(".*[.!?].*")) score += 25;
        if (cls != null && cls.contains("TextView")) score += 15;

        String low = text.toLowerCase(Locale.US);
        if (low.startsWith("you:") || low.startsWith("you said")) score -= 180;
        if (low.equals("chatgpt")) score -= 180;
        return Math.max(0, score);
    }

    private void debugDumpResponseContainer(AccessibilityNodeInfo root) {
        if (!isDebugMode() || root == null) return;
        try {
            DebugFileLogger.log(this, "RESPONSE-TREE",
                    "---- assistant response container start ----");
            ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
            queue.add(root);
            int index = 0;
            int visited = 0;

            while (index < queue.size() && visited < 220) {
                AccessibilityNodeInfo node = queue.get(index++);
                visited++;
                if (node == null) continue;

                String text = "";
                String desc = "";
                String cls = "";
                try {
                    if (node.getText() != null) text = normalizeDebugText(node.getText().toString());
                    if (node.getContentDescription() != null) desc =
                            normalizeDebugText(node.getContentDescription().toString());
                    if (node.getClassName() != null) cls = node.getClassName().toString();
                } catch (Throwable ignored) {}

                if (!text.isEmpty() || !desc.isEmpty()) {
                    String line = "#" + visited + " cls=" + cls
                            + " text=" + text + " desc=" + desc;
                    if (line.length() > 700) line = line.substring(0, 700) + "…";
                    DebugFileLogger.log(this, "RESPONSE-TREE", line);
                }

                int count = node.getChildCount();
                for (int i = 0; i < count && queue.size() < 260; i++) {
                    AccessibilityNodeInfo child = null;
                    try { child = node.getChild(i); } catch (Throwable ignored) {}
                    if (child != null) queue.add(child);
                }
            }
            DebugFileLogger.log(this, "RESPONSE-TREE",
                    "---- assistant response container end ----");
        } catch (Throwable t) {
            DebugFileLogger.log(this, "RESPONSE-TREE",
                    "Response container dump failed: " + t.getClass().getSimpleName());
        }
    }

'''
s = s.replace(anchor, helpers + anchor, 1)

# Visible-tree scanning is useful before Voice starts for the baseline, but once
# Voice is active it can accidentally grab unrelated chat/history text. From
# v3.0 onward, response display comes only from the assistant message container.
old_capture_start = '''    private void captureBestText(AccessibilityNodeInfo root) {
        if (root == null) return;

        if (!fullVoiceSessionActive) {'''
new_capture_start = '''    private void captureBestText(AccessibilityNodeInfo root) {
        if (root == null) return;

        if (fullVoiceSessionActive) return;

        if (!fullVoiceSessionActive) {'''
if old_capture_start not in s:
    raise SystemExit("v3.0: captureBestText start missing")
s = s.replace(old_capture_start, new_capture_start, 1)

reset_anchor = '''        dumpedBackgroundEventTreeThisSession = false;
        lastEventSourceScanUptime = 0L;
        lastCaption = "";'''
if reset_anchor not in s:
    raise SystemExit("v3.0: v2.9 reset anchor missing")
s = s.replace(reset_anchor, '''        dumpedBackgroundEventTreeThisSession = false;
        dumpedResponseContainerThisSession = false;
        lastEventSourceScanUptime = 0L;
        lastCaption = "";''', 1)

p.write_text(s)

p = Path("app/src/main/java/com/example/heychatgptassist/MainActivity.java")
s = p.read_text()
s = s.replace("Hey ChatGPT Assist v2.9", "Hey ChatGPT Assist v3.0")
s = s.replace(
    "v2.9 keeps the v2.8 Voice fixes and also inspects the AccessibilityEvent source tree that ChatGPT sends while Voice is running in the background. This is our best chance to recover the live spoken-answer text while your game/home screen stays visible.",
    "v3.0 uses the v2.9 debug result differently: when ChatGPT exposes the assistant feedback controls, it climbs to that assistant message container and reads NEW text siblings from the same response. This avoids showing toolbar labels like Good response/Bad response or unrelated old chat text."
)
p.write_text(s)

p = Path("app/build.gradle")
s = p.read_text()
if 'versionCode 29' not in s or 'versionName "2.9"' not in s:
    raise SystemExit("v3.0: expected v2.9 version fields missing")
s = s.replace("versionCode 29", "versionCode 30", 1)
s = s.replace('versionName "2.9"', 'versionName "3.0"', 1)
p.write_text(s)
