from pathlib import Path

# v2.6: add an opt-in live debug overlay so we can see exactly which stage
# normal/full-Voice mode reaches on the phone. The overlay is only visible when
# Debug mode is enabled and is intentionally not touchable.

# ---------------------------------------------------------------------------
# MainActivity: debug toggle + live stored debug state.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/MainActivity.java")
s = p.read_text()

const_anchor = '    public static final String KEY_LOCAL_MODE_ENABLED = "local_mode_enabled";'
if const_anchor not in s:
    raise SystemExit("v2.6: local-mode constant anchor missing")
s = s.replace(
    const_anchor,
    const_anchor + '\n    public static final String KEY_DEBUG_MODE = "debug_mode_enabled";',
    1
)

field_anchor = '    private TextView localModelStatus;'
if field_anchor not in s:
    raise SystemExit("v2.6: localModelStatus field anchor missing")
s = s.replace(
    field_anchor,
    field_anchor + '\n    private CheckBox debugModeToggle;\n    private TextView debugStatus;',
    1
)

ui_anchor = '''        addHeading(root, "Timing settings", 20);'''
if ui_anchor not in s:
    raise SystemExit("v2.6: timing UI anchor missing")

debug_ui = r'''        addHeading(root, "Debug mode", 20);
        addNote(root, "Turn this on while testing. A small live overlay will show the wake/ChatGPT Voice stages, visible packages, Voice UI detection, previous app, and the latest Accessibility event/text candidate. Send a screenshot or recording of that overlay if something fails.");
        debugModeToggle = new CheckBox(this);
        debugModeToggle.setText("Show live debug overlay");
        debugModeToggle.setChecked(prefs().getBoolean(KEY_DEBUG_MODE, false));
        debugModeToggle.setOnCheckedChangeListener((buttonView, checked) -> {
            prefs().edit().putBoolean(KEY_DEBUG_MODE, checked).apply();
            updateDebugStatus();
            Toast.makeText(this, checked ? "Debug overlay ON" : "Debug overlay OFF", Toast.LENGTH_SHORT).show();
        });
        root.addView(debugModeToggle);

        debugStatus = new TextView(this);
        debugStatus.setTextSize(13);
        debugStatus.setPadding(0, dp(4), 0, dp(8));
        root.addView(debugStatus);

'''
s = s.replace(ui_anchor, debug_ui + ui_anchor, 1)

method_anchor = '''    private void updateLocalModelStatus() {'''
if method_anchor not in s:
    raise SystemExit("v2.6: updateLocalModelStatus anchor missing")

debug_method = r'''    private void updateDebugStatus() {
        if (debugStatus == null) return;
        boolean enabled = prefs().getBoolean(KEY_DEBUG_MODE, false);
        String state = prefs().getString(ChatGPTTextAccessibilityService.KEY_DEBUG_STATE, "No debug state yet");
        String event = prefs().getString(ChatGPTTextAccessibilityService.KEY_DEBUG_EVENT, "No Accessibility event yet");
        debugStatus.setText("Debug overlay: " + (enabled ? "ON" : "OFF") +
                "\nState: " + state +
                "\nEvent: " + event);
    }

'''
s = s.replace(method_anchor, debug_method + method_anchor, 1)

# Refresh it alongside the existing diagnostics updater.
refresh_anchor = '''            updateCompanionStatus();
            updateTemporaryVoiceStatus();'''
if refresh_anchor not in s:
    # v1.9 inserts updateLocalModelStatus between these calls.
    refresh_anchor = '''            updateCompanionStatus();
            updateLocalModelStatus();
            updateTemporaryVoiceStatus();'''
if refresh_anchor not in s:
    raise SystemExit("v2.6: diagnostics refresh anchor missing")
if "updateDebugStatus();" not in refresh_anchor:
    if "updateLocalModelStatus();" in refresh_anchor:
        replacement = refresh_anchor.replace(
            "            updateTemporaryVoiceStatus();",
            "            updateTemporaryVoiceStatus();\n            updateDebugStatus();"
        )
    else:
        replacement = refresh_anchor.replace(
            "            updateTemporaryVoiceStatus();",
            "            updateTemporaryVoiceStatus();\n            updateDebugStatus();"
        )
    s = s.replace(refresh_anchor, replacement, 1)

# Initial UI refresh at the end of onCreate.
init_anchor = '''        updateCompanionStatus();
        updateLocalModelStatus();
        updateTemporaryVoiceStatus();'''
if init_anchor in s:
    s = s.replace(init_anchor, init_anchor + '\n        updateDebugStatus();', 1)
else:
    init_anchor = '''        updateCompanionStatus();
        updateTemporaryVoiceStatus();'''
    if init_anchor not in s:
        raise SystemExit("v2.6: initial status refresh anchor missing")
    s = s.replace(init_anchor, init_anchor + '\n        updateDebugStatus();', 1)

s = s.replace("Hey ChatGPT Assist v2.5", "Hey ChatGPT Assist v2.6")
s = s.replace(
    "Normal mode now starts a FULL ChatGPT Voice conversation, returns you to the app/game you were using, and keeps the Siri-style orb on top while ChatGPT continues in the background. In ChatGPT Settings → Voice, turn ON Start with Voice and Background conversations. v2.5 also tries to mirror GPT-Live response text into a small card whenever Android exposes that text through Accessibility.",
    "Normal mode starts a FULL ChatGPT Voice conversation, returns you to the app/game you were using, and keeps the Siri-style orb on top while ChatGPT continues in the background. In ChatGPT Settings → Voice, turn ON Start with Voice and Background conversations. v2.6 adds an optional live debug overlay so failed Voice/text detection can be diagnosed from a screenshot or recording."
)
p.write_text(s)


# ---------------------------------------------------------------------------
# Accessibility service: live debug overlay + event trace.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/ChatGPTTextAccessibilityService.java")
s = p.read_text()

const_anchor = '    public static final String KEY_PREVIOUS_APP_PACKAGE = "previous_app_package";'
if const_anchor not in s:
    raise SystemExit("v2.6: v2.5 constants missing")
s = s.replace(
    const_anchor,
    const_anchor + '\n    public static final String KEY_DEBUG_STATE = "debug_state";\n'
                   '    public static final String KEY_DEBUG_EVENT = "debug_event";',
    1
)

field_anchor = '    private String lastCaption = "";'
if field_anchor not in s:
    raise SystemExit("v2.6: caption field missing")
s = s.replace(
    field_anchor,
    field_anchor + r'''

    private WindowManager debugWindowManager;
    private TextView debugOverlayView;
    private String lastDebugEvent = "(none)";
    private String lastDebugCandidate = "(none)";
    private String lastDebugPackages = "(none)";
    private boolean lastDebugStartingVoice = false;
    private boolean lastDebugVoiceUi = false;
    private boolean lastDebugChatRoot = false;''',
    1
)

# Add event summary near the start of onAccessibilityEvent.
event_anchor = '''        if (event != null) {
            String pkg = event.getPackageName() == null ? "" : event.getPackageName().toString();'''
if event_anchor not in s:
    raise SystemExit("v2.6: accessibility event anchor missing")
s = s.replace(event_anchor, event_anchor + r'''
            try {
                StringBuilder ev = new StringBuilder();
                ev.append(pkg.isEmpty() ? "(no pkg)" : pkg);
                ev.append(" type=").append(event.getEventType());
                List<CharSequence> eventText = event.getText();
                if (eventText != null && !eventText.isEmpty()) {
                    String first = eventText.get(0) == null ? "" : eventText.get(0).toString().trim();
                    if (first.length() > 120) first = first.substring(0, 120) + "…";
                    if (!first.isEmpty()) ev.append(" text=").append(first);
                }
                lastDebugEvent = ev.toString();
                prefs().edit().putString(KEY_DEBUG_EVENT, lastDebugEvent).apply();
            } catch (Throwable ignored) {}''', 1)

# Record the best text candidate, including weak candidates that are not shown
# in the normal caption card. This is important for finding ChatGPT UI changes.
candidate_anchor = '''            int score = captionScore(text, id);
            if (score > bestScore) {'''
if candidate_anchor not in s:
    raise SystemExit("v2.6: caption score anchor missing")
s = s.replace(candidate_anchor, r'''            int score = captionScore(text, id);
            if (score > 0 && !text.isEmpty()) {
                String dbg = text.replaceAll("\\s+", " ").trim();
                if (dbg.length() > 160) dbg = dbg.substring(0, 160) + "…";
                lastDebugCandidate = "score=" + score + " " + dbg;
            }
            if (score > bestScore) {''', 1)

# Insert debug-overlay methods before the one-shot-assistant subtree method.
method_anchor = '''    private boolean subtreeLooksLikeChatGptAssistant(AccessibilityNodeInfo root) {'''
if method_anchor not in s:
    raise SystemExit("v2.6: helper insertion anchor missing")

debug_methods = r'''    private boolean isDebugMode() {
        return prefs().getBoolean(MainActivity.KEY_DEBUG_MODE, false);
    }

    private void updateDebugOverlay(String state) {
        if (state == null) state = "";
        prefs().edit().putString(KEY_DEBUG_STATE, state).apply();

        if (!isDebugMode()) {
            hideDebugOverlay();
            return;
        }

        try {
            if (debugOverlayView == null) {
                WindowManager wm = (WindowManager) getSystemService(WINDOW_SERVICE);
                if (wm == null) return;

                TextView tv = new TextView(this);
                tv.setTextColor(Color.WHITE);
                tv.setTextSize(11f);
                tv.setMaxLines(14);
                tv.setPadding(dp(10), dp(8), dp(10), dp(8));

                GradientDrawable bg = new GradientDrawable();
                bg.setColor(Color.argb(220, 18, 18, 20));
                bg.setCornerRadius(dp(12));
                tv.setBackground(bg);
                tv.setElevation(dp(10));

                WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                        dp(330),
                        WindowManager.LayoutParams.WRAP_CONTENT,
                        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                                | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                                | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                        PixelFormat.TRANSLUCENT);
                lp.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
                lp.y = dp(48);
                lp.setTitle("Hey ChatGPT Assist debug");

                wm.addView(tv, lp);
                debugWindowManager = wm;
                debugOverlayView = tv;
            }

            String voiceStatus = prefs().getString(KEY_FULL_VOICE_STATUS, "(none)");
            String previous = prefs().getString(KEY_PREVIOUS_APP_PACKAGE, "(none)");
            String listener = prefs().getString(WakeListenerService.KEY_LISTENER_STATUS, "(none)");
            String heard = prefs().getString(WakeListenerService.KEY_LAST_HEARD, "(none)");

            String text = "DEBUG v2.6\n"
                    + state
                    + "\nlistener=" + listener
                    + "\nlast heard=" + heard
                    + "\nvoice status=" + voiceStatus
                    + "\nprevious app=" + previous
                    + "\nwindows=" + lastDebugPackages
                    + "\nevent=" + lastDebugEvent
                    + "\ncandidate=" + lastDebugCandidate;

            debugOverlayView.setText(text);
            debugOverlayView.setVisibility(View.VISIBLE);
        } catch (Throwable ignored) {}
    }

    private void hideDebugOverlay() {
        TextView tv = debugOverlayView;
        debugOverlayView = null;
        WindowManager wm = debugWindowManager;
        debugWindowManager = null;
        if (tv != null && wm != null) {
            try { wm.removeViewImmediate(tv); } catch (Throwable ignored) {}
        }
    }

'''
s = s.replace(method_anchor, debug_methods + method_anchor, 1)

# Feed the current v2.5 state machine into the overlay.
state_anchor = '''        prefs().edit().putString(KEY_LAST_WINDOW_DEBUG,
                "v2.5 full Voice | windows: " +'''
if state_anchor not in s:
    raise SystemExit("v2.6: v2.5 debug-state write missing")

# Insert state capture immediately before the existing KEY_LAST_WINDOW_DEBUG write.
state_prep = r'''        lastDebugPackages = packages.length() == 0 ? "(none)" : packages.toString();
        lastDebugStartingVoice = startingFullVoice;
        lastDebugVoiceUi = voiceUi;
        lastDebugChatRoot = chatRoot != null;

        String liveState = "request=" + (startingFullVoice ? "STARTING" : "idle")
                + " | chatRoot=" + (chatRoot != null ? "YES" : "no")
                + " | voiceUI=" + (voiceUi ? "YES" : "no")
                + " | session=" + (fullVoiceSessionActive ? "ACTIVE" : "no")
                + " | popup=" + (popupOpen ? "OPEN" : "no")
                + " | returned=" + (returnedToPreviousApp ? "YES" : "no")
                + " | caption=" + (lastCaption.isEmpty() ? "none" : "captured");
        updateDebugOverlay(liveState);

'''
s = s.replace(state_anchor, state_prep + state_anchor, 1)

# If debug is toggled off while nothing else changes, the periodic monitor still
# reaches checkPopupState and removes it. Also clean it up with the service.
destroy_anchor = '''    public void onDestroy() {
        handler.removeCallbacksAndMessages(null);'''
if destroy_anchor not in s:
    raise SystemExit("v2.6: onDestroy anchor missing")
s = s.replace(destroy_anchor, destroy_anchor + '\n        hideDebugOverlay();', 1)

p.write_text(s)


# ---------------------------------------------------------------------------
# Version.
# ---------------------------------------------------------------------------
p = Path("app/build.gradle")
s = p.read_text()
if 'versionCode 25' not in s or 'versionName "2.5"' not in s:
    raise SystemExit("v2.6: expected v2.5 version fields missing")
s = s.replace("versionCode 25", "versionCode 26", 1)
s = s.replace('versionName "2.5"', 'versionName "2.6"', 1)
p.write_text(s)
