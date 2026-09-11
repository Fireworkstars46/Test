from pathlib import Path

# v3.3: make hidden Voice launch fail-closed and reliable.
#
# v3.2 proved the frozen cover itself works, but the debug log showed the
# broadcast bridge can disappear later in the same session. When that happened
# WakeListenerService intentionally fell back to a normal startActivity(), which
# exposed the full ChatGPT app again.
#
# v3.3 removes that visible fallback. WakeListenerService talks directly to the
# active AccessibilityService instance in the same app process. If the hidden
# launcher is not available, ChatGPT is NOT opened at all.
#
# It also:
# - returns to the prior app immediately when full Voice is detected (no queued delay)
# - never launches ChatGPT if the pre-launch screenshot cover cannot be created
# - restores the prior app/home before removing the cover on startup timeout

def replace_method(src: str, signature: str, replacement: str) -> str:
    start = src.find(signature)
    if start < 0:
        raise SystemExit(f"v3.3: method missing: {signature}")
    brace = src.find("{", start)
    if brace < 0:
        raise SystemExit(f"v3.3: opening brace missing: {signature}")
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
        raise SystemExit(f"v3.3: closing brace missing: {signature}")
    return src[:start] + replacement + src[end:]


# ---------------------------------------------------------------------------
# Wake listener: direct in-process bridge only. Never expose ChatGPT as fallback.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/WakeListenerService.java")
s = p.read_text()

new_trigger = r'''    private void triggerNormalAssistant() {
        beginAssistantPause();
        final int triggerDelayMs = getTriggerDelayMs();
        setStatus("Activation phrase heard — preparing hidden ChatGPT Voice");

        long now = System.currentTimeMillis();
        prefs().edit()
                .putLong(ChatGPTTextAccessibilityService.KEY_LAST_ASSIST_TRIGGER_MS, now)
                .putLong(ChatGPTTextAccessibilityService.KEY_FULL_VOICE_REQUEST_MS, now)
                .putLong(ChatGPTTextAccessibilityService.KEY_COVERED_LAUNCH_STARTED_MS, 0L)
                .putString(ChatGPTTextAccessibilityService.KEY_FULL_VOICE_STATUS,
                        "Preparing hidden ChatGPT Voice…")
                .apply();

        handler.removeCallbacks(assistantSessionTimeoutRunnable);
        handler.postDelayed(assistantSessionTimeoutRunnable, 60L * 60L * 1000L);

        Runnable requestCoveredLaunch = () -> {
            boolean accepted = false;
            try {
                accepted = ChatGPTTextAccessibilityService.requestCoveredVoiceLaunch();
            } catch (Throwable ignored) {}

            if (accepted) {
                setStatus("Freezing current screen before ChatGPT Voice opens");
                DebugFileLogger.log(this, "HIDE-LAUNCH",
                        "Direct Accessibility bridge accepted hidden Voice launch");
                return;
            }

            // Fail closed. The user's main requirement is that the ChatGPT app
            // must never visibly replace their game/app. If Accessibility is
            // unavailable, do not launch ChatGPT at all.
            prefs().edit()
                    .putLong(ChatGPTTextAccessibilityService.KEY_FULL_VOICE_REQUEST_MS, 0L)
                    .putString(ChatGPTTextAccessibilityService.KEY_FULL_VOICE_STATUS,
                            "Hidden launcher unavailable — ChatGPT was not opened")
                    .apply();
            setStatus("Hidden launcher unavailable — ChatGPT NOT opened");
            DebugFileLogger.log(this, "HIDE-LAUNCH",
                    "Direct Accessibility bridge unavailable; blocked visible ChatGPT fallback");
            handler.removeCallbacks(assistantSessionTimeoutRunnable);
            handler.postDelayed(this::rearmAfterTrigger, 700L);
        };

        if (triggerDelayMs <= 0) handler.post(requestCoveredLaunch);
        else handler.postDelayed(requestCoveredLaunch, triggerDelayMs);
    }'''
s = replace_method(s, "    private void triggerNormalAssistant()", new_trigger)
p.write_text(s)


# ---------------------------------------------------------------------------
# Accessibility service: stable direct bridge + fail-closed cover handling.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/ChatGPTTextAccessibilityService.java")
s = p.read_text()

field_anchor = '    private boolean initialLaunchCoverActive = false;'
if field_anchor not in s:
    raise SystemExit("v3.3: v3.2 initial cover field missing")
s = s.replace(field_anchor, r'''    private static volatile ChatGPTTextAccessibilityService activeInstance;

    private boolean initialLaunchCoverActive = false;''', 1)

# Publish active Accessibility instance as soon as Android connects it.
service_anchor = '''    protected void onServiceConnected() {
        super.onServiceConnected();'''
if service_anchor not in s:
    raise SystemExit("v3.3: onServiceConnected anchor missing")
s = s.replace(service_anchor, service_anchor + r'''
        activeInstance = this;
        DebugFileLogger.log(this, "HIDE-LAUNCH",
                "Accessibility direct bridge READY");''', 1)

# Direct same-process entrypoint used by WakeListenerService.
helper_anchor = '    private void prepareCoveredInitialVoiceLaunch() {'
if helper_anchor not in s:
    raise SystemExit("v3.3: prepareCoveredInitialVoiceLaunch missing")

direct_bridge = r'''    public static boolean requestCoveredVoiceLaunch() {
        ChatGPTTextAccessibilityService svc = activeInstance;
        if (svc == null) return false;
        try {
            svc.handler.post(() -> {
                try {
                    svc.prepareCoveredInitialVoiceLaunch();
                } catch (Throwable t) {
                    DebugFileLogger.log(svc, "HIDE-LAUNCH",
                            "Direct hidden-launch request failed: "
                                    + t.getClass().getSimpleName());
                    svc.abortInitialHiddenLaunch(
                            "Hidden launch failed before ChatGPT opened");
                }
            });
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

'''
s = s.replace(helper_anchor, direct_bridge + helper_anchor, 1)

# Do not launch ChatGPT unless a real full-screen frozen cover exists.
old_launch_head = r'''    private void launchChatGptBehindInitialCover(Bitmap frozen) {
        if (frozen != null) {
            showTranscriptCover(frozen);
            DebugFileLogger.log(this, "HIDE-LAUNCH",
                    "Frozen-screen cover is visible");
        } else {
            DebugFileLogger.log(this, "HIDE-LAUNCH",
                    "No screenshot cover available; launch may be briefly visible");
        }

        prefs().edit()'''
new_launch_head = r'''    private void launchChatGptBehindInitialCover(Bitmap frozen) {
        if (frozen == null) {
            DebugFileLogger.log(this, "HIDE-LAUNCH",
                    "No screenshot cover available; BLOCKED ChatGPT launch");
            abortInitialHiddenLaunch(
                    "Could not freeze screen — ChatGPT was not opened");
            return;
        }

        showTranscriptCover(frozen);
        showSiriOrb();
        DebugFileLogger.log(this, "HIDE-LAUNCH",
                "Frozen-screen cover is visible");

        prefs().edit()'''
if old_launch_head not in s:
    raise SystemExit("v3.3: initial launch head missing")
s = s.replace(old_launch_head, new_launch_head, 1)

# Replace timeout: restore underneath the cover first, then remove it.
old_timeout = r'''        // Never leave a frozen screen stuck indefinitely.
        handler.postDelayed(() -> {
            if (initialLaunchCoverActive && !fullVoiceSessionActive) {
                DebugFileLogger.log(ChatGPTTextAccessibilityService.this,
                        "HIDE-LAUNCH",
                        "Safety removing initial cover because Voice did not become active");
                initialLaunchCoverActive = false;
                hideTranscriptCover();
            }
        }, 12_000L);'''
new_timeout = r'''        // Never expose ChatGPT if Voice fails to initialize. Restore the
        // original app/home UNDER the frozen cover, then remove the cover.
        handler.postDelayed(() -> {
            if (initialLaunchCoverActive && !fullVoiceSessionActive) {
                DebugFileLogger.log(ChatGPTTextAccessibilityService.this,
                        "HIDE-LAUNCH",
                        "Voice startup timeout; restoring prior app before cover removal");
                String target = sessionReturnPackage;
                restoreAfterTranscriptPeek(target);
                handler.postDelayed(() -> {
                    if (!fullVoiceSessionActive) {
                        abortInitialHiddenLaunch(
                                "Voice startup timed out — ChatGPT hidden and closed from view");
                    }
                }, 450L);
            }
        }, 12_000L);'''
if old_timeout not in s:
    raise SystemExit("v3.3: old initial cover timeout missing")
s = s.replace(old_timeout, new_timeout, 1)

# Add common abort helper before finishInitialLaunchCover().
finish_anchor = '    private void finishInitialLaunchCover() {'
if finish_anchor not in s:
    raise SystemExit("v3.3: finishInitialLaunchCover missing")

abort_helper = r'''    private void abortInitialHiddenLaunch(String reason) {
        initialLaunchCoverActive = false;
        hideTranscriptCover();
        hideSiriOrb();
        prefs().edit()
                .putLong(KEY_FULL_VOICE_REQUEST_MS, 0L)
                .putLong(KEY_COVERED_LAUNCH_STARTED_MS, 0L)
                .putString(KEY_FULL_VOICE_STATUS, reason)
                .apply();
        DebugFileLogger.log(this, "HIDE-LAUNCH", reason);
        try { sendState(WakeListenerService.ACTION_ASSISTANT_POPUP_CLOSED); }
        catch (Throwable ignored) {}
    }

'''
s = s.replace(finish_anchor, abort_helper + finish_anchor, 1)

# Once Voice UI is truly detected, restore NOW rather than enqueueing a delayed
# callback that can sit behind a flood of Accessibility/debug events.
if 'handler.postDelayed(this::returnToPreviousApp, 350L);' not in s:
    raise SystemExit("v3.3: v3.2 delayed return call missing")
s = s.replace(
    'handler.postDelayed(this::returnToPreviousApp, 350L);',
    'returnToPreviousApp();',
    1
)

# Clear static bridge only if this exact service instance is being destroyed.
destroy_sig = "    public void onDestroy()"
start = s.find(destroy_sig)
if start < 0:
    raise SystemExit("v3.3: onDestroy missing")
brace = s.find("{", start)
insert_at = brace + 1
s = s[:insert_at] + r'''
        if (activeInstance == this) activeInstance = null;''' + s[insert_at:]

p.write_text(s)


# ---------------------------------------------------------------------------
# Version/UI.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/MainActivity.java")
s = p.read_text()
s = s.replace("Hey ChatGPT Assist v3.2", "Hey ChatGPT Assist v3.3")
s = s.replace(
    "v3.2 also hides the initial ChatGPT launch. The helper freezes the app/game currently on screen BEFORE ChatGPT is foregrounded, starts full Voice behind that frozen image, restores your app/home as soon as Voice is detected, then removes the cover. Later transcript peeks use the same hidden-screen method.",
    "v3.3 makes hidden launch fail-closed. It uses a direct Accessibility bridge instead of the intermittent broadcast path, never visibly launches ChatGPT as a fallback, immediately restores your app/home when Voice is detected, and restores your app before removing the frozen cover if Voice startup fails."
)
p.write_text(s)

p = Path("app/build.gradle")
s = p.read_text()
if 'versionCode 32' not in s or 'versionName "3.2"' not in s:
    raise SystemExit("v3.3: expected v3.2 version fields missing")
s = s.replace("versionCode 32", "versionCode 33", 1)
s = s.replace('versionName "3.2"', 'versionName "3.3"', 1)
p.write_text(s)
