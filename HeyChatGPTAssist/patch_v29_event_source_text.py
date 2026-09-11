from pathlib import Path

# v2.9: The v2.8 log proved full ChatGPT Voice stays active in the background,
# but once ChatGPT is backgrounded there is no ChatGPT accessibility window/root.
# However, Android can still deliver AccessibilityEvents from ChatGPT. Inspect
# each event's SOURCE node/subtree and try to recover the live transcript there.

p = Path("app/src/main/java/com/example/heychatgptassist/ChatGPTTextAccessibilityService.java")
s = p.read_text()

# Fields for source-tree diagnostics/rate limiting.
field_anchor = '    private boolean dumpedVoiceTreeThisSession = false;'
if field_anchor not in s:
    raise SystemExit("v2.9: v2.8 field anchor missing")
s = s.replace(field_anchor, field_anchor + r'''
    private boolean dumpedBackgroundEventTreeThisSession = false;
    private long lastEventSourceScanUptime = 0L;''', 1)

# Replace the ChatGPT event handling so we inspect event.getSource(), even when
# ChatGPT has no active accessibility window.
old = r'''            if (CHATGPT_PACKAGE.equals(pkg) && fullVoiceSessionActive) {
                captureEventText(event);
            }'''
new = r'''            if (CHATGPT_PACKAGE.equals(pkg) && fullVoiceSessionActive) {
                captureEventText(event);
                captureEventSource(event);
            }'''
if old not in s:
    raise SystemExit("v2.9: ChatGPT event handling anchor missing")
s = s.replace(old, new, 1)

# Add stronger rejection for app chrome seen in the v2.8 log.
reject_anchor = r'''                "settings", "background conversations", "separate mode",
                "what's on your mind", "message chatgpt"
        };'''
if reject_anchor not in s:
    raise SystemExit("v2.9: caption reject list anchor missing")
s = s.replace(reject_anchor, r'''                "settings", "background conversations", "separate mode",
                "what's on your mind", "message chatgpt",
                "projects", "scheduled", "finances", "new chat",
                "voice settings", "menu", "turn microphone off",
                "turn microphone on", "end", "dictation", "attachment",
                "toggle focus mode"
        };''', 1)

# Insert event-source helpers before captureEventText.
anchor = '    private void captureEventText(AccessibilityEvent event) {'
if anchor not in s:
    raise SystemExit("v2.9: captureEventText anchor missing")

helpers = r'''    private void captureEventSource(AccessibilityEvent event) {
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

        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(source);
        int index = 0;
        int visited = 0;
        String best = "";
        String bestContext = "";
        int bestScore = 0;

        while (index < queue.size() && visited < 350) {
            AccessibilityNodeInfo node = queue.get(index++);
            visited++;
            if (node == null) continue;

            String text = "";
            String desc = "";
            String hint = "";
            String id = "";
            try {
                if (node.getText() != null) text = normalizeDebugText(node.getText().toString());
                if (node.getContentDescription() != null) desc = normalizeDebugText(node.getContentDescription().toString());
                if (node.getHintText() != null) hint = normalizeDebugText(node.getHintText().toString());
                if (node.getViewIdResourceName() != null) id = node.getViewIdResourceName();
            } catch (Throwable ignored) {}

            String[] candidates = new String[] { text, desc, hint };
            for (String candidate : candidates) {
                if (candidate == null || candidate.isEmpty()) continue;
                if (voiceBaselineTexts.contains(candidate)) continue;

                String ctx = id + " " + desc + " " + hint;
                int score = captionScore(candidate, ctx);

                // Event-source text is much more interesting while ChatGPT has
                // no visible window. Reward sentence-like text and penalize
                // short control labels.
                if (candidate.length() >= 18) score += 25;
                if (candidate.length() >= 45) score += 35;
                if (candidate.contains(" ") && candidate.matches(".*[.!?].*")) score += 20;

                if (score > 0) {
                    String dbg = candidate.length() > 220
                            ? candidate.substring(0, 220) + "…" : candidate;
                    DebugFileLogger.logChanged(this,
                            "event_src_text_" + candidate.hashCode(),
                            "EVENT-TEXT",
                            "score=" + score + " id=" + id + " text=" + dbg);
                }

                if (score > bestScore) {
                    bestScore = score;
                    best = candidate;
                    bestContext = ctx;
                }
            }

            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < 400; i++) {
                AccessibilityNodeInfo child = null;
                try { child = node.getChild(i); } catch (Throwable ignored) {}
                if (child != null) queue.add(child);
            }
        }

        // Be conservative: only display reasonably strong event-source text.
        if (bestScore >= 75 && !best.isEmpty()) {
            DebugFileLogger.logChanged(this, "event_src_selected",
                    "TEXT-SELECTED",
                    "EVENT SOURCE score=" + bestScore + " ctx=" + bestContext + " text=" + best);
            updateCaption(best);
            voiceBaselineTexts.add(best);
        }
    }

    private void debugDumpEventSourceTree(AccessibilityNodeInfo root, int eventType) {
        if (!isDebugMode() || root == null) return;
        try {
            DebugFileLogger.log(this, "EVENT-TREE",
                    "---- background ChatGPT event source tree start; eventType=" + eventType + " ----");
            ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
            queue.add(root);
            int index = 0;
            int visited = 0;

            while (index < queue.size() && visited < 160) {
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
                    if (line.length() > 600) line = line.substring(0, 600) + "…";
                    DebugFileLogger.log(this, "EVENT-TREE", line);
                }

                int count = node.getChildCount();
                for (int i = 0; i < count && queue.size() < 190; i++) {
                    AccessibilityNodeInfo child = null;
                    try { child = node.getChild(i); } catch (Throwable ignored) {}
                    if (child != null) queue.add(child);
                }
            }
            DebugFileLogger.log(this, "EVENT-TREE",
                    "---- background ChatGPT event source tree end ----");
        } catch (Throwable t) {
            DebugFileLogger.log(this, "EVENT-TREE",
                    "Event-source tree dump failed: " + t.getClass().getSimpleName());
        }
    }

'''
s = s.replace(anchor, helpers + anchor, 1)

# Reset new diagnostics with the session.
reset_anchor = r'''        dumpedVoiceTreeThisSession = false;
        lastCaption = "";'''
if reset_anchor not in s:
    raise SystemExit("v2.9: v2.8 reset anchor missing")
s = s.replace(reset_anchor, r'''        dumpedVoiceTreeThisSession = false;
        dumpedBackgroundEventTreeThisSession = false;
        lastEventSourceScanUptime = 0L;
        lastCaption = "";''', 1)

p.write_text(s)

# UI/version text.
p = Path("app/src/main/java/com/example/heychatgptassist/MainActivity.java")
s = p.read_text()
s = s.replace("Hey ChatGPT Assist v2.8", "Hey ChatGPT Assist v2.9")
s = s.replace(
    "v2.8 records the wake/ChatGPT Voice stages into a .txt file in Downloads/HeyChatGPTAssist. It also logs a one-time accessibility-tree snapshot of the real Voice UI. v2.8 ignores old chat text and only tries to show NEW text that appears after Voice starts.",
    "v2.9 keeps the v2.8 Voice fixes and also inspects the AccessibilityEvent source tree that ChatGPT sends while Voice is running in the background. This is our best chance to recover the live spoken-answer text while your game/home screen stays visible."
)
p.write_text(s)

p = Path("app/build.gradle")
s = p.read_text()
if 'versionCode 28' not in s or 'versionName "2.8"' not in s:
    raise SystemExit("v2.9: expected v2.8 version fields missing")
s = s.replace("versionCode 28", "versionCode 29", 1)
s = s.replace('versionName "2.8"', 'versionName "2.9"', 1)
p.write_text(s)
