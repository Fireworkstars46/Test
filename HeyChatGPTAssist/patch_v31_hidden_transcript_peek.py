from pathlib import Path

# v3.1: v3.0 confirmed that background AccessibilityEvent sources are detached
# from their sibling assistant text. Use a hidden "transcript peek":
# 1) wait for ChatGPT's background accessibility-event stream to go quiet,
# 2) freeze the current screen with an Accessibility screenshot overlay,
# 3) bring ChatGPT to the foreground behind that frozen image,
# 4) read the newest assistant message container while its real tree is attached,
# 5) restore the user's app/home and remove the frozen image.
#
# This keeps the user's visible screen essentially unchanged while giving the
# Accessibility service a real ChatGPT window long enough to recover response text.

p = Path("app/src/main/res/xml/accessibility_service_config.xml")
s = p.read_text()
if 'android:canTakeScreenshot=' not in s:
    s = s.replace(
        '    android:canRetrieveWindowContent="true"\n',
        '    android:canRetrieveWindowContent="true"\n'
        '    android:canTakeScreenshot="true"\n',
        1
    )
p.write_text(s)

p = Path("app/src/main/java/com/example/heychatgptassist/ChatGPTTextAccessibilityService.java")
s = p.read_text()

# Imports required by the frozen-screen peek.
imports = {
    'import android.graphics.Bitmap;\n': 'import android.graphics.Bitmap;\n',
    'import android.graphics.Rect;\n': 'import android.graphics.Rect;\n',
    'import android.hardware.HardwareBuffer;\n': 'import android.hardware.HardwareBuffer;\n',
    'import android.view.Display;\n': 'import android.view.Display;\n',
    'import android.widget.ImageView;\n': 'import android.widget.ImageView;\n',
}
anchor = 'import android.content.Intent;\n'
if anchor not in s:
    raise SystemExit("v3.1: import anchor missing")
for imp in imports:
    if imp not in s:
        s = s.replace(anchor, anchor + imp, 1)

# Add state.
field_anchor = '    private boolean dumpedResponseContainerThisSession = false;'
if field_anchor not in s:
    raise SystemExit("v3.1: v3.0 field anchor missing")
s = s.replace(field_anchor, field_anchor + r'''

    private long lastChatGptEventUptime = 0L;
    private long lastTranscriptPeekUptime = 0L;
    private boolean transcriptPeekInProgress = false;
    private String transcriptPeekReturnPackage = "";
    private String sessionReturnPackage = "";

    private WindowManager transcriptCoverWindowManager;
    private ImageView transcriptCoverView;

    private final Runnable transcriptPeekQuietRunnable = new Runnable() {
        @Override public void run() {
            if (!fullVoiceSessionActive || !returnedToPreviousApp
                    || transcriptPeekInProgress) return;

            long now = SystemClock.uptimeMillis();
            long quietFor = now - lastChatGptEventUptime;
            if (quietFor < 850L) {
                handler.postDelayed(this, 850L - quietFor);
                return;
            }
            if (now - lastTranscriptPeekUptime < 2500L) return;
            performTranscriptPeek("background ChatGPT events quiet");
        }
    };''', 1)

# Track each ChatGPT event and debounce a transcript peek after background
# activity settles.
old_chat_event = r'''            if (CHATGPT_PACKAGE.equals(pkg) && fullVoiceSessionActive) {
                captureEventText(event);
                captureEventSource(event);
            }'''
new_chat_event = r'''            if (CHATGPT_PACKAGE.equals(pkg) && fullVoiceSessionActive) {
                lastChatGptEventUptime = SystemClock.uptimeMillis();
                captureEventText(event);
                captureEventSource(event);

                if (returnedToPreviousApp && !transcriptPeekInProgress) {
                    handler.removeCallbacks(transcriptPeekQuietRunnable);
                    handler.postDelayed(transcriptPeekQuietRunnable, 850L);
                }
            }'''
if old_chat_event not in s:
    raise SystemExit("v3.1: v3.0 ChatGPT event block missing")
s = s.replace(old_chat_event, new_chat_event, 1)

# Freeze the original return target when the Voice session first becomes active.
active_anchor = r'''                fullVoiceSessionActive = true;
                returnedToPreviousApp = false;
                fullVoiceStartedUptime = nowUp;'''
if active_anchor not in s:
    raise SystemExit("v3.1: full Voice activation anchor missing")
s = s.replace(active_anchor, r'''                fullVoiceSessionActive = true;
                returnedToPreviousApp = false;
                fullVoiceStartedUptime = nowUp;
                sessionReturnPackage = prefs().getString(KEY_PREVIOUS_APP_PACKAGE, "");''', 1)

# Prefer the frozen return target for the initial return as well.
return_line = '        String pkg = prefs().getString(KEY_PREVIOUS_APP_PACKAGE, "");'
if return_line not in s:
    raise SystemExit("v3.1: return package line missing")
s = s.replace(return_line,
              '        String pkg = sessionReturnPackage == null || sessionReturnPackage.isEmpty()'
              ' ? prefs().getString(KEY_PREVIOUS_APP_PACKAGE, "") : sessionReturnPackage;', 1)

# Add peek helpers before captureEventText.
anchor = '    private void captureEventText(AccessibilityEvent event) {'
if anchor not in s:
    raise SystemExit("v3.1: captureEventText anchor missing")

helpers = r'''    private void performTranscriptPeek(String reason) {
        if (!fullVoiceSessionActive || transcriptPeekInProgress) return;

        long now = SystemClock.uptimeMillis();
        if (now - lastTranscriptPeekUptime < 2500L) return;
        lastTranscriptPeekUptime = now;
        transcriptPeekInProgress = true;

        transcriptPeekReturnPackage = currentForegroundPackage();
        if (transcriptPeekReturnPackage == null || transcriptPeekReturnPackage.isEmpty()
                || CHATGPT_PACKAGE.equals(transcriptPeekReturnPackage)
                || getPackageName().equals(transcriptPeekReturnPackage)) {
            transcriptPeekReturnPackage = sessionReturnPackage;
        }

        DebugFileLogger.log(this, "PEEK",
                "Starting hidden transcript peek: " + reason
                        + " return=" + transcriptPeekReturnPackage);

        try {
            takeScreenshot(Display.DEFAULT_DISPLAY, getMainExecutor(),
                    new TakeScreenshotCallback() {
                        @Override
                        public void onSuccess(ScreenshotResult screenshotResult) {
                            Bitmap copy = null;
                            HardwareBuffer buffer = null;
                            try {
                                buffer = screenshotResult.getHardwareBuffer();
                                Bitmap hardware = Bitmap.wrapHardwareBuffer(
                                        buffer, screenshotResult.getColorSpace());
                                if (hardware != null) {
                                    copy = hardware.copy(Bitmap.Config.ARGB_8888, false);
                                }
                            } catch (Throwable t) {
                                DebugFileLogger.log(ChatGPTTextAccessibilityService.this,
                                        "PEEK", "Screenshot conversion failed: "
                                                + t.getClass().getSimpleName());
                            } finally {
                                if (buffer != null) {
                                    try { buffer.close(); } catch (Throwable ignored) {}
                                }
                            }

                            if (copy != null) showTranscriptCover(copy);
                            launchChatGptForTranscriptPeek();
                        }

                        @Override
                        public void onFailure(int errorCode) {
                            DebugFileLogger.log(ChatGPTTextAccessibilityService.this,
                                    "PEEK", "Screenshot failed code=" + errorCode
                                            + "; continuing with a very brief visible peek");
                            launchChatGptForTranscriptPeek();
                        }
                    });
        } catch (Throwable t) {
            DebugFileLogger.log(this, "PEEK",
                    "takeScreenshot unavailable: " + t.getClass().getSimpleName());
            launchChatGptForTranscriptPeek();
        }
    }

    private void showTranscriptCover(Bitmap bitmap) {
        try {
            hideTranscriptCover();
            WindowManager wm = (WindowManager) getSystemService(WINDOW_SERVICE);
            if (wm == null || bitmap == null) return;

            ImageView image = new ImageView(this);
            image.setImageBitmap(bitmap);
            image.setScaleType(ImageView.ScaleType.FIT_XY);

            WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                            | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                            | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                            | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.OPAQUE);
            lp.gravity = Gravity.TOP | Gravity.START;
            lp.x = 0;
            lp.y = 0;
            lp.setTitle("Hey ChatGPT Assist frozen transcript peek");

            wm.addView(image, lp);
            transcriptCoverWindowManager = wm;
            transcriptCoverView = image;
        } catch (Throwable t) {
            DebugFileLogger.log(this, "PEEK",
                    "Could not show frozen-screen cover: " + t.getClass().getSimpleName());
        }
    }

    private void hideTranscriptCover() {
        ImageView view = transcriptCoverView;
        transcriptCoverView = null;
        WindowManager wm = transcriptCoverWindowManager;
        transcriptCoverWindowManager = null;
        if (view != null && wm != null) {
            try {
                if (view.getDrawable() != null) view.setImageDrawable(null);
                wm.removeViewImmediate(view);
            } catch (Throwable ignored) {}
        }
    }

    private void launchChatGptForTranscriptPeek() {
        if (!fullVoiceSessionActive) {
            finishTranscriptPeek(false, "Voice session ended before peek");
            return;
        }

        try {
            Intent open = getPackageManager().getLaunchIntentForPackage(CHATGPT_PACKAGE);
            if (open == null) throw new IllegalStateException("No ChatGPT launch intent");
            open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                    | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                    | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            startActivity(open);
            DebugFileLogger.log(this, "PEEK",
                    "ChatGPT brought forward behind frozen-screen cover");
        } catch (Throwable t) {
            finishTranscriptPeek(false,
                    "Could not foreground ChatGPT: " + t.getClass().getSimpleName());
            return;
        }

        handler.postDelayed(() -> scrapeTranscriptDuringPeek(1), 450L);
    }

    private void scrapeTranscriptDuringPeek(int attempt) {
        if (!transcriptPeekInProgress || !fullVoiceSessionActive) {
            finishTranscriptPeek(false, "Peek cancelled");
            return;
        }

        AccessibilityNodeInfo root = findChatGptRoot();
        if (root == null) {
            if (attempt < 3) {
                handler.postDelayed(() -> scrapeTranscriptDuringPeek(attempt + 1), 300L);
            } else {
                finishTranscriptPeek(false, "ChatGPT root unavailable during peek");
            }
            return;
        }

        String answer = extractNewestAssistantResponse(root);
        if (answer != null && !answer.isEmpty()) {
            DebugFileLogger.log(this, "PEEK-TEXT",
                    "Captured assistant response: " + answer);
            updateCaption(answer);
            voiceBaselineTexts.add(answer);
            finishTranscriptPeek(true, "Captured response text");
            return;
        }

        if (attempt < 3) {
            handler.postDelayed(() -> scrapeTranscriptDuringPeek(attempt + 1), 350L);
        } else {
            finishTranscriptPeek(false,
                    "No new assistant response text found in foreground ChatGPT tree");
        }
    }

    private AccessibilityNodeInfo findChatGptRoot() {
        List<AccessibilityWindowInfo> windows = getWindows();
        if (windows == null) return null;

        for (AccessibilityWindowInfo window : windows) {
            if (window == null) continue;
            AccessibilityNodeInfo root = null;
            try { root = window.getRoot(); } catch (Throwable ignored) {}
            if (root == null) continue;

            String pkg = root.getPackageName() == null
                    ? "" : root.getPackageName().toString();
            if (CHATGPT_PACKAGE.equals(pkg)) return root;
        }
        return null;
    }

    private String extractNewestAssistantResponse(AccessibilityNodeInfo root) {
        if (root == null) return "";

        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(root);
        int index = 0;
        int visited = 0;

        String bestText = "";
        int bestY = Integer.MIN_VALUE;
        int bestScore = 0;

        while (index < queue.size() && visited < 1200) {
            AccessibilityNodeInfo node = queue.get(index++);
            visited++;
            if (node == null) continue;

            String text = "";
            String desc = "";
            try {
                if (node.getText() != null) text = normalizeDebugText(node.getText().toString());
                if (node.getContentDescription() != null) {
                    desc = normalizeDebugText(node.getContentDescription().toString());
                }
            } catch (Throwable ignored) {}

            String lowText = text.toLowerCase(Locale.US);
            String lowDesc = desc.toLowerCase(Locale.US);
            boolean feedback = lowText.equals("good response")
                    || lowText.equals("bad response")
                    || lowDesc.equals("good response")
                    || lowDesc.equals("bad response");

            if (feedback) {
                AccessibilityNodeInfo container = findAssistantResponseContainer(node);
                if (container != null) {
                    String candidate = bestTextInsideResponseContainer(container);
                    if (!candidate.isEmpty()) {
                        Rect bounds = new Rect();
                        try { node.getBoundsInScreen(bounds); } catch (Throwable ignored) {}
                        int y = bounds.bottom;
                        int score = responseTextScore(candidate, "android.widget.TextView");
                        if (y > bestY || (y == bestY && score > bestScore)) {
                            bestY = y;
                            bestScore = score;
                            bestText = candidate;
                        }
                    }
                }
            }

            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < 1300; i++) {
                AccessibilityNodeInfo child = null;
                try { child = node.getChild(i); } catch (Throwable ignored) {}
                if (child != null) queue.add(child);
            }
        }

        if (!bestText.isEmpty()) {
            DebugFileLogger.logChanged(this, "peek_selected",
                    "TEXT-SELECTED",
                    "HIDDEN PEEK score=" + bestScore + " y=" + bestY
                            + " text=" + bestText);
        }
        return bestText;
    }

    private String bestTextInsideResponseContainer(AccessibilityNodeInfo container) {
        if (container == null) return "";

        ArrayList<AccessibilityNodeInfo> queue = new ArrayList<>();
        queue.add(container);
        int index = 0;
        int visited = 0;
        String best = "";
        int bestScore = 0;

        while (index < queue.size() && visited < 500) {
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
                if (score > bestScore) {
                    bestScore = score;
                    best = text;
                }
            }

            int count = node.getChildCount();
            for (int i = 0; i < count && queue.size() < 550; i++) {
                AccessibilityNodeInfo child = null;
                try { child = node.getChild(i); } catch (Throwable ignored) {}
                if (child != null) queue.add(child);
            }
        }

        return bestScore >= 55 ? best : "";
    }

    private String currentForegroundPackage() {
        List<AccessibilityWindowInfo> windows = getWindows();
        if (windows == null) return "";

        for (AccessibilityWindowInfo window : windows) {
            if (window == null) continue;
            boolean active = false;
            boolean focused = false;
            try {
                active = window.isActive();
                focused = window.isFocused();
            } catch (Throwable ignored) {}
            if (!active && !focused) continue;

            AccessibilityNodeInfo root = null;
            try { root = window.getRoot(); } catch (Throwable ignored) {}
            if (root == null) continue;

            String pkg = root.getPackageName() == null
                    ? "" : root.getPackageName().toString();
            if (pkg.isEmpty()
                    || "com.android.systemui".equals(pkg)
                    || getPackageName().equals(pkg)) continue;

            if ("com.sec.android.app.launcher".equals(pkg)
                    || "com.google.android.apps.nexuslauncher".equals(pkg)) {
                return HOME_SENTINEL;
            }
            return pkg;
        }
        return "";
    }

    private void finishTranscriptPeek(boolean success, String message) {
        DebugFileLogger.log(this, "PEEK",
                (success ? "SUCCESS: " : "DONE: ") + message);

        String target = transcriptPeekReturnPackage;
        if (target == null || target.isEmpty()
                || CHATGPT_PACKAGE.equals(target)
                || getPackageName().equals(target)) {
            target = sessionReturnPackage;
        }

        restoreAfterTranscriptPeek(target);
        final String finalTarget = target;
        handler.postDelayed(() -> {
            hideTranscriptCover();
            transcriptPeekInProgress = false;
            DebugFileLogger.log(ChatGPTTextAccessibilityService.this,
                    "PEEK", "Frozen-screen cover removed; restored=" + finalTarget);
        }, 350L);
    }

    private void restoreAfterTranscriptPeek(String pkg) {
        if (pkg == null || pkg.isEmpty() || HOME_SENTINEL.equals(pkg)
                || CHATGPT_PACKAGE.equals(pkg) || getPackageName().equals(pkg)) {
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
        } catch (Throwable t) {
            try { performGlobalAction(GLOBAL_ACTION_HOME); } catch (Throwable ignored) {}
        }
    }

'''
s = s.replace(anchor, helpers + anchor, 1)

# If v3.0 sees an attached feedback subtree while ChatGPT is still foreground,
# keep its direct path. If the subtree is detached, the quiet-event peek handles it.
null_container = r'''        AccessibilityNodeInfo responseContainer = findAssistantResponseContainer(source);
        if (responseContainer == null) {
            // Do not show text from arbitrary ChatGPT event nodes. v2.9 proved
            // that doing so can display toolbar labels or old chat content.
            return;
        }'''
if null_container not in s:
    raise SystemExit("v3.1: v3.0 response-container block missing")
s = s.replace(null_container, r'''        AccessibilityNodeInfo responseContainer = findAssistantResponseContainer(source);
        if (responseContainer == null) {
            ResponseSignals detachedSignals = inspectResponseSignals(source, 160);
            if (detachedSignals.feedback) {
                DebugFileLogger.logChanged(this, "detached_feedback",
                        "PEEK",
                        "Feedback control arrived without attached assistant text; hidden peek will recover it");
                handler.removeCallbacks(transcriptPeekQuietRunnable);
                handler.postDelayed(transcriptPeekQuietRunnable, 450L);
            }
            return;
        }''', 1)

# Clean up new state at real session end/service destruction.
reset_anchor = r'''        dumpedResponseContainerThisSession = false;
        lastEventSourceScanUptime = 0L;
        lastCaption = "";'''
if reset_anchor not in s:
    raise SystemExit("v3.1: v3.0 reset anchor missing")
s = s.replace(reset_anchor, r'''        dumpedResponseContainerThisSession = false;
        lastEventSourceScanUptime = 0L;
        lastChatGptEventUptime = 0L;
        handler.removeCallbacks(transcriptPeekQuietRunnable);
        transcriptPeekInProgress = false;
        sessionReturnPackage = "";
        transcriptPeekReturnPackage = "";
        hideTranscriptCover();
        lastCaption = "";''', 1)

destroy_anchor = '''        hideDebugOverlay();'''
if destroy_anchor not in s:
    raise SystemExit("v3.1: onDestroy debug cleanup anchor missing")
s = s.replace(destroy_anchor, destroy_anchor + '''
        handler.removeCallbacks(transcriptPeekQuietRunnable);
        hideTranscriptCover();''', 1)

p.write_text(s)

# UI/version.
p = Path("app/src/main/java/com/example/heychatgptassist/MainActivity.java")
s = p.read_text()
s = s.replace("Hey ChatGPT Assist v3.0", "Hey ChatGPT Assist v3.1")
s = s.replace(
    "v3.0 uses the v2.9 debug result differently: when ChatGPT exposes the assistant feedback controls, it climbs to that assistant message container and reads NEW text siblings from the same response. This avoids showing toolbar labels like Good response/Bad response or unrelated old chat text.",
    "v3.1 adds a hidden transcript peek. When full Voice is running in the background, the helper briefly freezes your visible screen, brings ChatGPT forward behind that frozen image, reads the newest assistant response from its real Accessibility tree, restores your app/home, then removes the frozen image. This is designed to recover the actual ChatGPT response text without showing ChatGPT on screen."
)
p.write_text(s)

p = Path("app/build.gradle")
s = p.read_text()
if 'versionCode 30' not in s or 'versionName "3.0"' not in s:
    raise SystemExit("v3.1: expected v3.0 version fields missing")
s = s.replace("versionCode 30", "versionCode 31", 1)
s = s.replace('versionName "3.0"', 'versionName "3.1"', 1)
p.write_text(s)
