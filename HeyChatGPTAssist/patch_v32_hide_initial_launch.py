from pathlib import Path

# v3.2: hide the *initial* ChatGPT app launch too.
# v3.1 only hid later transcript peeks. The phone log showed full Voice was
# detected at 00:48:47 but the previous app was not restored until 00:48:54,
# so ChatGPT itself was visibly on screen for several seconds.
#
# v3.2 asks the Accessibility service to freeze the current screen BEFORE
# foregrounding ChatGPT. ChatGPT can initialize Voice behind that frozen image,
# then we restore the original app/home and remove the cover.

def replace_method(src: str, signature: str, replacement: str) -> str:
    start = src.find(signature)
    if start < 0:
        raise SystemExit(f"v3.2: method missing: {signature}")
    brace = src.find("{", start)
    if brace < 0:
        raise SystemExit(f"v3.2: opening brace missing: {signature}")
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
        raise SystemExit(f"v3.2: closing brace missing: {signature}")
    return src[:start] + replacement + src[end:]


# ---------------------------------------------------------------------------
# Wake listener: request a covered launch first. If Accessibility is disabled
# or cannot respond, fall back to the old direct launch after 1.8 seconds.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/WakeListenerService.java")
s = p.read_text()

new_trigger = r'''    private void triggerNormalAssistant() {
        beginAssistantPause();
        final int keyCode = getAssistKeyCode();
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

        Runnable fallbackLaunch = () -> {
            long coveredStarted = prefs().getLong(
                    ChatGPTTextAccessibilityService.KEY_COVERED_LAUNCH_STARTED_MS, 0L);
            long age = coveredStarted <= 0L
                    ? Long.MAX_VALUE : System.currentTimeMillis() - coveredStarted;
            if (age >= 0L && age < 10_000L) {
                // Accessibility already launched ChatGPT behind the cover.
                return;
            }

            boolean opened = false;
            try {
                Intent open = getPackageManager().getLaunchIntentForPackage("com.openai.chatgpt");
                if (open != null) {
                    open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                            | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                            | Intent.FLAG_ACTIVITY_SINGLE_TOP);
                    startActivity(open);
                    opened = true;
                    setStatus("ChatGPT opened — hidden-cover fallback was unavailable");
                    DebugFileLogger.log(this, "HIDE-LAUNCH",
                            "Accessibility cover did not respond; used direct ChatGPT launch fallback");
                }
            } catch (Throwable ignored) {}

            if (!opened) {
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

        Runnable requestCoveredLaunch = () -> {
            try {
                Intent prep = new Intent(
                        ChatGPTTextAccessibilityService.ACTION_PREPARE_COVERED_VOICE_LAUNCH);
                prep.setPackage(getPackageName());
                sendBroadcast(prep);
                setStatus("Freezing current screen before ChatGPT Voice opens");
                DebugFileLogger.log(this, "HIDE-LAUNCH",
                        "Requested Accessibility frozen-screen cover before ChatGPT launch");
            } catch (Throwable ignored) {}
            handler.postDelayed(fallbackLaunch, 1800L);
        };

        if (triggerDelayMs <= 0) handler.post(requestCoveredLaunch);
        else handler.postDelayed(requestCoveredLaunch, triggerDelayMs);
    }'''
s = replace_method(s, "    private void triggerNormalAssistant()", new_trigger)
p.write_text(s)


# ---------------------------------------------------------------------------
# Accessibility service: receive covered-launch request, freeze the currently
# visible app, launch ChatGPT behind it, and remove the cover only after we have
# restored the original app/home.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/ChatGPTTextAccessibilityService.java")
s = p.read_text()

for imp in [
    "import android.content.BroadcastReceiver;\n",
    "import android.content.Context;\n",
    "import android.content.IntentFilter;\n",
]:
    if imp not in s:
        s = s.replace("import android.content.Intent;\n",
                      "import android.content.Intent;\n" + imp, 1)

const_anchor = '    public static final String KEY_PREVIOUS_APP_PACKAGE = "previous_app_package";'
if const_anchor not in s:
    raise SystemExit("v3.2: previous-app constant missing")
s = s.replace(const_anchor, const_anchor + r'''
    public static final String ACTION_PREPARE_COVERED_VOICE_LAUNCH =
            "com.example.heychatgptassist.PREPARE_COVERED_VOICE_LAUNCH";
    public static final String KEY_COVERED_LAUNCH_STARTED_MS =
            "covered_voice_launch_started_ms";''', 1)

field_anchor = '    private ImageView transcriptCoverView;'
if field_anchor not in s:
    raise SystemExit("v3.2: v3.1 cover field missing")
s = s.replace(field_anchor, field_anchor + r'''
    private boolean initialLaunchCoverActive = false;
    private boolean coveredLaunchReceiverRegistered = false;

    private final BroadcastReceiver coveredLaunchReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (intent == null) return;
            if (ACTION_PREPARE_COVERED_VOICE_LAUNCH.equals(intent.getAction())) {
                prepareCoveredInitialVoiceLaunch();
            }
        }
    };''', 1)

# Register our private broadcast receiver when Accessibility starts.
service_anchor = '''    protected void onServiceConnected() {
        super.onServiceConnected();'''
if service_anchor not in s:
    raise SystemExit("v3.2: onServiceConnected anchor missing")
s = s.replace(service_anchor, service_anchor + r'''
        if (!coveredLaunchReceiverRegistered) {
            IntentFilter hiddenFilter =
                    new IntentFilter(ACTION_PREPARE_COVERED_VOICE_LAUNCH);
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(coveredLaunchReceiver, hiddenFilter,
                        Context.RECEIVER_NOT_EXPORTED);
            } else {
                registerReceiver(coveredLaunchReceiver, hiddenFilter);
            }
            coveredLaunchReceiverRegistered = true;
        }''', 1)

# Don't start a transcript peek while the initial launch is still deliberately
# hidden behind the frozen screen.
s = s.replace(
    'if (returnedToPreviousApp && !transcriptPeekInProgress) {',
    'if (returnedToPreviousApp && !transcriptPeekInProgress && !initialLaunchCoverActive) {',
    1
)

# Return much sooner once full Voice controls are detected. The old 1200ms
# callback was observed being delayed several seconds by UI/accessibility work.
s = s.replace(
    'handler.postDelayed(this::returnToPreviousApp, 1200L);',
    'handler.postDelayed(this::returnToPreviousApp, 350L);',
    1
)

# Covered initial-launch helpers.
helper_anchor = '    private void performTranscriptPeek(String reason) {'
if helper_anchor not in s:
    raise SystemExit("v3.2: v3.1 peek helper anchor missing")

helpers = r'''    private void prepareCoveredInitialVoiceLaunch() {
        if (initialLaunchCoverActive) return;
        initialLaunchCoverActive = true;

        sessionReturnPackage = currentForegroundPackage();
        if (sessionReturnPackage == null || sessionReturnPackage.isEmpty()
                || CHATGPT_PACKAGE.equals(sessionReturnPackage)
                || getPackageName().equals(sessionReturnPackage)) {
            sessionReturnPackage = prefs().getString(KEY_PREVIOUS_APP_PACKAGE, "");
        }

        DebugFileLogger.log(this, "HIDE-LAUNCH",
                "Preparing frozen cover; return=" + sessionReturnPackage);

        if (Build.VERSION.SDK_INT < 30) {
            launchChatGptBehindInitialCover(null);
            return;
        }

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
                                        "HIDE-LAUNCH",
                                        "Initial screenshot conversion failed: "
                                                + t.getClass().getSimpleName());
                            } finally {
                                if (buffer != null) {
                                    try { buffer.close(); } catch (Throwable ignored) {}
                                }
                            }
                            launchChatGptBehindInitialCover(copy);
                        }

                        @Override
                        public void onFailure(int errorCode) {
                            DebugFileLogger.log(ChatGPTTextAccessibilityService.this,
                                    "HIDE-LAUNCH",
                                    "Initial screenshot failed code=" + errorCode);
                            launchChatGptBehindInitialCover(null);
                        }
                    });
        } catch (Throwable t) {
            DebugFileLogger.log(this, "HIDE-LAUNCH",
                    "Initial takeScreenshot failed: " + t.getClass().getSimpleName());
            launchChatGptBehindInitialCover(null);
        }
    }

    private void launchChatGptBehindInitialCover(Bitmap frozen) {
        if (frozen != null) {
            showTranscriptCover(frozen);
            DebugFileLogger.log(this, "HIDE-LAUNCH",
                    "Frozen-screen cover is visible");
        } else {
            DebugFileLogger.log(this, "HIDE-LAUNCH",
                    "No screenshot cover available; launch may be briefly visible");
        }

        prefs().edit()
                .putLong(KEY_COVERED_LAUNCH_STARTED_MS, System.currentTimeMillis())
                .putString(KEY_FULL_VOICE_STATUS,
                        frozen != null
                                ? "Opening ChatGPT Voice behind frozen screen…"
                                : "Opening ChatGPT Voice…")
                .apply();

        try {
            Intent open = getPackageManager().getLaunchIntentForPackage(CHATGPT_PACKAGE);
            if (open == null) throw new IllegalStateException("No ChatGPT launch intent");
            open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                    | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                    | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            startActivity(open);
            DebugFileLogger.log(this, "HIDE-LAUNCH",
                    "ChatGPT launched behind initial frozen-screen cover");
        } catch (Throwable t) {
            DebugFileLogger.log(this, "HIDE-LAUNCH",
                    "ChatGPT launch failed: " + t.getClass().getSimpleName());
            initialLaunchCoverActive = false;
            hideTranscriptCover();
        }

        // Never leave a frozen screen stuck indefinitely.
        handler.postDelayed(() -> {
            if (initialLaunchCoverActive && !fullVoiceSessionActive) {
                DebugFileLogger.log(ChatGPTTextAccessibilityService.this,
                        "HIDE-LAUNCH",
                        "Safety removing initial cover because Voice did not become active");
                initialLaunchCoverActive = false;
                hideTranscriptCover();
            }
        }, 12_000L);
    }

    private void finishInitialLaunchCover() {
        if (!initialLaunchCoverActive) return;
        handler.postDelayed(() -> {
            initialLaunchCoverActive = false;
            hideTranscriptCover();
            DebugFileLogger.log(ChatGPTTextAccessibilityService.this,
                    "HIDE-LAUNCH",
                    "Initial frozen-screen cover removed after previous app/home restored");
        }, 450L);
    }

'''
s = s.replace(helper_anchor, helpers + helper_anchor, 1)

# Replace return method so every return path schedules cover removal.
new_return = r'''    private void returnToPreviousApp() {
        if (!fullVoiceSessionActive) {
            finishInitialLaunchCover();
            return;
        }

        String pkg = sessionReturnPackage == null || sessionReturnPackage.isEmpty()
                ? prefs().getString(KEY_PREVIOUS_APP_PACKAGE, "")
                : sessionReturnPackage;

        DebugFileLogger.log(this, "VOICE", "Returning to previous app");
        if (pkg == null || pkg.isEmpty() || HOME_SENTINEL.equals(pkg)
                || CHATGPT_PACKAGE.equals(pkg) || getPackageName().equals(pkg)) {
            try { performGlobalAction(GLOBAL_ACTION_HOME); } catch (Throwable ignored) {}
            DebugFileLogger.log(this, "VOICE", "Returned to HOME");
            finishInitialLaunchCover();
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
            DebugFileLogger.log(this, "VOICE", "Restored previous app: " + pkg);
        } catch (Throwable t) {
            try { performGlobalAction(GLOBAL_ACTION_HOME); } catch (Throwable ignored) {}
            DebugFileLogger.log(this, "VOICE",
                    "Previous app restore failed; returned HOME");
        }
        finishInitialLaunchCover();
    }'''
s = replace_method(s, "    private void returnToPreviousApp()", new_return)

# Unregister receiver / remove cover at service teardown.
destroy_sig = "    public void onDestroy()"
start = s.find(destroy_sig)
if start < 0:
    raise SystemExit("v3.2: onDestroy missing")
brace = s.find("{", start)
insert_at = brace + 1
destroy_prefix = r'''
        if (coveredLaunchReceiverRegistered) {
            try { unregisterReceiver(coveredLaunchReceiver); } catch (Throwable ignored) {}
            coveredLaunchReceiverRegistered = false;
        }
        initialLaunchCoverActive = false;
        hideTranscriptCover();'''
s = s[:insert_at] + destroy_prefix + s[insert_at:]

p.write_text(s)


# ---------------------------------------------------------------------------
# Version/UI.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/MainActivity.java")
s = p.read_text()
s = s.replace("Hey ChatGPT Assist v3.1", "Hey ChatGPT Assist v3.2")
s = s.replace(
    "v3.1 adds a hidden transcript peek. When full Voice is running in the background, the helper briefly freezes your visible screen, brings ChatGPT forward behind that frozen image, reads the newest assistant response from its real Accessibility tree, restores your app/home, then removes the frozen image. This is designed to recover the actual ChatGPT response text without showing ChatGPT on screen.",
    "v3.2 also hides the initial ChatGPT launch. The helper freezes the app/game currently on screen BEFORE ChatGPT is foregrounded, starts full Voice behind that frozen image, restores your app/home as soon as Voice is detected, then removes the cover. Later transcript peeks use the same hidden-screen method."
)
p.write_text(s)

p = Path("app/build.gradle")
s = p.read_text()
if 'versionCode 31' not in s or 'versionName "3.1"' not in s:
    raise SystemExit("v3.2: expected v3.1 version fields missing")
s = s.replace("versionCode 31", "versionCode 32", 1)
s = s.replace('versionName "3.1"', 'versionName "3.2"', 1)
p.write_text(s)
