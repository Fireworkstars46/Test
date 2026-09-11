from pathlib import Path

# v3.4: self-healing hidden launch.
#
# v3.3 correctly stopped visible ChatGPT fallback, but the newest phone log shows
# the AccessibilityService bridge disappeared after the first attempt. From then
# on every wake phrase was blocked with:
#   "Direct Accessibility bridge unavailable; blocked visible ChatGPT fallback"
#
# v3.4 bootstraps the hidden launch without depending on a live Accessibility
# instance:
#   1. capture the current screen through the already-authorized Shizuku shell,
#   2. show that screenshot as a full-screen TYPE_APPLICATION_OVERLAY cover,
#   3. open ChatGPT behind the cover,
#   4. wait for Accessibility to reconnect OR use uiautomator+input through
#      Shizuku to press the Voice control and detect the full Voice UI,
#   5. restore the previous app/home while the cover is still visible,
#   6. remove the cover only after restoration.
#
# Thus a dead Accessibility bridge no longer means "do nothing", and ChatGPT is
# still never intentionally shown to the user.

def replace_method(src: str, signature: str, replacement: str) -> str:
    start = src.find(signature)
    if start < 0:
        raise SystemExit(f"v3.4: method missing: {signature}")
    brace = src.find("{", start)
    if brace < 0:
        raise SystemExit(f"v3.4: opening brace missing: {signature}")
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
        raise SystemExit(f"v3.4: closing brace missing: {signature}")
    return src[:start] + replacement + src[end:]


# ---------------------------------------------------------------------------
# Manifest: application overlay permission. v3.4 grants its app-op through
# Shizuku automatically; Settings remains a fallback if the ROM blocks appops.
# ---------------------------------------------------------------------------
p = Path("app/src/main/AndroidManifest.xml")
s = p.read_text()
perm = '    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />\n'
if "android.permission.SYSTEM_ALERT_WINDOW" not in s:
    anchor = '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />\n'
    if anchor not in s:
        raise SystemExit("v3.4: manifest permission anchor missing")
    s = s.replace(anchor, anchor + perm, 1)
p.write_text(s)


# ---------------------------------------------------------------------------
# ShizukuBridge: generic shell output + binary output for screencap.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/ShizukuBridge.java")
s = p.read_text()

imports_anchor = "import java.lang.reflect.Method;\n"
extra_imports = """import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
"""
if "import java.io.ByteArrayOutputStream;" not in s:
    if imports_anchor not in s:
        raise SystemExit("v3.4: ShizukuBridge import anchor missing")
    s = s.replace(imports_anchor, imports_anchor + extra_imports, 1)

class_anchor = "    public static final class Result {"
if class_anchor not in s:
    raise SystemExit("v3.4: ShizukuBridge Result anchor missing")

helpers = r'''    private static Object newShellProcess(String command) throws Exception {
        Method newProcess = Shizuku.class.getDeclaredMethod(
                "newProcess", String[].class, String[].class, String.class);
        newProcess.setAccessible(true);
        String[] cmd = new String[]{"sh", "-c", command};
        return newProcess.invoke(null, new Object[]{cmd, null, null});
    }

    public static CommandResult runCommand(String command) {
        if (!isRunning()) return new CommandResult(false, "Shizuku is not running", -1);
        if (!hasPermission()) return new CommandResult(false, "Shizuku permission is not granted", -1);

        Object process = null;
        try {
            process = newShellProcess(command);
            Method getInputStream = process.getClass().getMethod("getInputStream");
            InputStream in = (InputStream) getInputStream.invoke(process);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) >= 0) {
                if (n > 0) out.write(buf, 0, n);
            }

            Method waitFor = process.getClass().getMethod("waitFor");
            int exitCode = ((Number) waitFor.invoke(process)).intValue();
            try {
                Method destroy = process.getClass().getMethod("destroy");
                destroy.invoke(process);
            } catch (Throwable ignored) {}

            String stdout = new String(out.toByteArray(), StandardCharsets.UTF_8);
            return new CommandResult(exitCode == 0, stdout, exitCode);
        } catch (Throwable t) {
            try {
                if (process != null) {
                    Method destroy = process.getClass().getMethod("destroy");
                    destroy.invoke(process);
                }
            } catch (Throwable ignored) {}
            Throwable cause = t.getCause() != null ? t.getCause() : t;
            String msg = cause.getMessage();
            if (msg == null || msg.trim().isEmpty()) msg = cause.getClass().getSimpleName();
            return new CommandResult(false, msg, -1);
        }
    }

    public static BinaryResult runBinaryCommand(String command) {
        if (!isRunning()) return new BinaryResult(false, new byte[0], "Shizuku is not running");
        if (!hasPermission()) return new BinaryResult(false, new byte[0], "Shizuku permission is not granted");

        Object process = null;
        try {
            process = newShellProcess(command);
            Method getInputStream = process.getClass().getMethod("getInputStream");
            InputStream in = (InputStream) getInputStream.invoke(process);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[32768];
            int n;
            while ((n = in.read(buf)) >= 0) {
                if (n > 0) out.write(buf, 0, n);
            }

            Method waitFor = process.getClass().getMethod("waitFor");
            int exitCode = ((Number) waitFor.invoke(process)).intValue();
            try {
                Method destroy = process.getClass().getMethod("destroy");
                destroy.invoke(process);
            } catch (Throwable ignored) {}

            byte[] data = out.toByteArray();
            return new BinaryResult(exitCode == 0 && data.length > 0, data,
                    exitCode == 0 ? "" : "exit=" + exitCode);
        } catch (Throwable t) {
            try {
                if (process != null) {
                    Method destroy = process.getClass().getMethod("destroy");
                    destroy.invoke(process);
                }
            } catch (Throwable ignored) {}
            Throwable cause = t.getCause() != null ? t.getCause() : t;
            String msg = cause.getMessage();
            if (msg == null || msg.trim().isEmpty()) msg = cause.getClass().getSimpleName();
            return new BinaryResult(false, new byte[0], msg);
        }
    }

    public static final class CommandResult {
        public final boolean success;
        public final String output;
        public final int exitCode;

        public CommandResult(boolean success, String output, int exitCode) {
            this.success = success;
            this.output = output == null ? "" : output;
            this.exitCode = exitCode;
        }
    }

    public static final class BinaryResult {
        public final boolean success;
        public final byte[] data;
        public final String message;

        public BinaryResult(boolean success, byte[] data, String message) {
            this.success = success;
            this.data = data == null ? new byte[0] : data;
            this.message = message == null ? "" : message;
        }
    }

'''
s = s.replace(class_anchor, helpers + class_anchor, 1)
p.write_text(s)


# ---------------------------------------------------------------------------
# Accessibility bridge exposes readiness for the bootstrap worker.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/ChatGPTTextAccessibilityService.java")
s = p.read_text()
bridge_anchor = "    public static boolean requestCoveredVoiceLaunch() {"
if bridge_anchor not in s:
    raise SystemExit("v3.4: v3.3 direct bridge missing")
readiness = r'''    public static boolean isDirectBridgeReady() {
        return activeInstance != null;
    }

'''
s = s.replace(bridge_anchor, readiness + bridge_anchor, 1)
p.write_text(s)


# ---------------------------------------------------------------------------
# WakeListenerService: fallback bootstrap overlay when direct bridge is absent.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/WakeListenerService.java")
s = p.read_text()

# android.app.* and android.content.* are already wildcard imports.
imports_anchor = "import android.speech.*;\n"
extra = """import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.provider.Settings;
import android.view.Gravity;
import android.view.WindowManager;
import android.widget.ImageView;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
"""
if "import android.graphics.Bitmap;" not in s:
    if imports_anchor not in s:
        raise SystemExit("v3.4: WakeListenerService import anchor missing")
    s = s.replace(imports_anchor, imports_anchor + extra, 1)

field_anchor = "    private boolean tempReceiverRegistered = false;"
if field_anchor not in s:
    raise SystemExit("v3.4: WakeListenerService field anchor missing")
s = s.replace(field_anchor, field_anchor + r'''

    private WindowManager bootstrapCoverWindowManager;
    private ImageView bootstrapCoverView;
    private volatile boolean bootstrapHiddenLaunchInProgress = false;
    private volatile String bootstrapReturnPackage = "";
''', 1)

# Replace triggerNormalAssistant from v3.3.
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

            // v3.4 self-healing path: don't give up just because the Accessibility
            // service instance was reclaimed. Bootstrap the same hidden launch
            // using Shizuku screencap + an app overlay.
            setStatus("Accessibility bridge asleep — self-healing hidden launch");
            DebugFileLogger.log(this, "BOOTSTRAP",
                    "Direct Accessibility bridge unavailable; starting Shizuku hidden bootstrap");
            startShizukuHiddenBootstrap();
        };

        if (triggerDelayMs <= 0) handler.post(requestCoveredLaunch);
        else handler.postDelayed(requestCoveredLaunch, triggerDelayMs);
    }'''
s = replace_method(s, "    private void triggerNormalAssistant()", new_trigger)

# Add bootstrap helpers immediately before triggerTemporaryVoice.
anchor = "    private void triggerTemporaryVoice() {"
if anchor not in s:
    raise SystemExit("v3.4: triggerTemporaryVoice anchor missing")

helpers = r'''    private void startShizukuHiddenBootstrap() {
        if (bootstrapHiddenLaunchInProgress) return;
        bootstrapHiddenLaunchInProgress = true;

        bootstrapReturnPackage = prefs().getString(
                ChatGPTTextAccessibilityService.KEY_PREVIOUS_APP_PACKAGE, "__HOME__");
        if (bootstrapReturnPackage == null || bootstrapReturnPackage.trim().isEmpty()
                || "com.openai.chatgpt".equals(bootstrapReturnPackage)
                || getPackageName().equals(bootstrapReturnPackage)) {
            bootstrapReturnPackage = "__HOME__";
        }

        new Thread(() -> {
            try {
                if (!ShizukuBridge.isRunning() || !ShizukuBridge.hasPermission()) {
                    failBootstrap("Shizuku unavailable — ChatGPT was not opened");
                    return;
                }

                // Shell can grant the SYSTEM_ALERT_WINDOW app-op after the user
                // already granted this app Shizuku access.
                ShizukuBridge.CommandResult appOp = ShizukuBridge.runCommand(
                        "appops set " + getPackageName()
                                + " SYSTEM_ALERT_WINDOW allow 2>/dev/null || true");
                DebugFileLogger.log(this, "BOOTSTRAP",
                        "Overlay app-op command exit=" + appOp.exitCode);

                ShizukuBridge.BinaryResult shot =
                        ShizukuBridge.runBinaryCommand("screencap -p");
                if (!shot.success || shot.data.length < 4096) {
                    failBootstrap("Could not capture frozen screen — ChatGPT was not opened");
                    return;
                }

                Bitmap bitmap = BitmapFactory.decodeByteArray(
                        shot.data, 0, shot.data.length);
                if (bitmap == null) {
                    failBootstrap("Frozen screen decode failed — ChatGPT was not opened");
                    return;
                }

                CountDownLatch shown = new CountDownLatch(1);
                handler.post(() -> {
                    boolean ok = showBootstrapCover(bitmap);
                    if (ok) {
                        DebugFileLogger.log(WakeListenerService.this, "BOOTSTRAP",
                                "Shizuku frozen-screen cover visible");
                    }
                    shown.countDown();
                });
                shown.await(1800L, TimeUnit.MILLISECONDS);

                if (bootstrapCoverView == null) {
                    failBootstrap("Overlay cover unavailable — ChatGPT was not opened");
                    return;
                }

                // Only after the cover is definitely on-screen may ChatGPT come forward.
                handler.post(() -> {
                    try {
                        Intent open = getPackageManager().getLaunchIntentForPackage(
                                "com.openai.chatgpt");
                        if (open == null) throw new IllegalStateException("no launch intent");
                        open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                                | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                                | Intent.FLAG_ACTIVITY_SINGLE_TOP);
                        startActivity(open);
                        DebugFileLogger.log(WakeListenerService.this, "BOOTSTRAP",
                                "ChatGPT launched behind Shizuku overlay cover");
                    } catch (Throwable t) {
                        failBootstrap("Could not launch ChatGPT behind cover");
                    }
                });

                long deadline = SystemClock.uptimeMillis() + 15000L;
                boolean voiceActive = false;
                boolean clickedVoice = false;

                while (SystemClock.uptimeMillis() < deadline
                        && bootstrapHiddenLaunchInProgress) {
                    try { Thread.sleep(450L); } catch (InterruptedException ignored) {}

                    String status = prefs().getString(
                            ChatGPTTextAccessibilityService.KEY_FULL_VOICE_STATUS, "");
                    if (status != null && status.contains("Full ChatGPT Voice active")) {
                        voiceActive = true;
                        DebugFileLogger.log(this, "BOOTSTRAP",
                                "Accessibility reconnected and detected full Voice");
                        break;
                    }

                    // If Accessibility hasn't reconnected, use Android's shell UI
                    // hierarchy to find the same ChatGPT controls.
                    String xml = dumpCurrentUiXml();
                    if (xml.isEmpty()) continue;

                    if (looksLikeFullVoiceXml(xml)) {
                        voiceActive = true;
                        prefs().edit().putString(
                                ChatGPTTextAccessibilityService.KEY_FULL_VOICE_STATUS,
                                "Full ChatGPT Voice active (Shizuku bootstrap)").apply();
                        DebugFileLogger.log(this, "BOOTSTRAP",
                                "Shizuku UI dump detected full Voice");
                        break;
                    }

                    if (!clickedVoice) {
                        int[] pt = findBoundsCenter(xml,
                                "Start a voice conversation", "Voice mode", "Voice");
                        if (pt != null) {
                            ShizukuBridge.runCommand(
                                    "input tap " + pt[0] + " " + pt[1]);
                            clickedVoice = true;
                            DebugFileLogger.log(this, "BOOTSTRAP",
                                    "Shizuku tapped ChatGPT Voice control at "
                                            + pt[0] + "," + pt[1]);
                        }
                    }
                }

                if (!voiceActive) {
                    failBootstrap("Full Voice did not start — restored previous screen");
                    return;
                }

                // Restore the user's app/home while the frozen image still covers
                // the display, then uncover it.
                restoreBootstrapTarget();
                try { Thread.sleep(550L); } catch (InterruptedException ignored) {}
                handler.post(() -> {
                    hideBootstrapCover();
                    bootstrapHiddenLaunchInProgress = false;
                    setStatus("Full ChatGPT Voice active in background");
                    DebugFileLogger.log(WakeListenerService.this, "BOOTSTRAP",
                            "Frozen cover removed after previous screen restored");
                });
            } catch (Throwable t) {
                failBootstrap("Hidden bootstrap failed: "
                        + t.getClass().getSimpleName());
            }
        }, "shizuku-hidden-voice-bootstrap").start();
    }

    private boolean showBootstrapCover(Bitmap bitmap) {
        hideBootstrapCover();
        if (bitmap == null) return false;
        try {
            bootstrapCoverWindowManager =
                    (WindowManager) getSystemService(WINDOW_SERVICE);
            ImageView image = new ImageView(this);
            image.setScaleType(ImageView.ScaleType.FIT_XY);
            image.setBackgroundColor(Color.BLACK);
            image.setImageBitmap(bitmap);

            WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.MATCH_PARENT,
                    Build.VERSION.SDK_INT >= 26
                            ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                            : WindowManager.LayoutParams.TYPE_PHONE,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                            | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                            | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.OPAQUE);
            lp.gravity = Gravity.TOP | Gravity.START;
            lp.x = 0;
            lp.y = 0;
            bootstrapCoverWindowManager.addView(image, lp);
            bootstrapCoverView = image;
            return true;
        } catch (Throwable t) {
            DebugFileLogger.log(this, "BOOTSTRAP",
                    "Overlay add failed: " + t.getClass().getSimpleName()
                            + " canDraw=" + Settings.canDrawOverlays(this));
            bootstrapCoverView = null;
            return false;
        }
    }

    private void hideBootstrapCover() {
        ImageView view = bootstrapCoverView;
        WindowManager wm = bootstrapCoverWindowManager;
        bootstrapCoverView = null;
        bootstrapCoverWindowManager = null;
        if (view != null && wm != null) {
            try { wm.removeViewImmediate(view); } catch (Throwable ignored) {}
        }
    }

    private String dumpCurrentUiXml() {
        String path = "/sdcard/heychatgptassist_ui.xml";
        ShizukuBridge.CommandResult r = ShizukuBridge.runCommand(
                "uiautomator dump " + path
                        + " >/dev/null 2>&1; cat " + path
                        + " 2>/dev/null; rm -f " + path);
        return r.output == null ? "" : r.output;
    }

    private boolean looksLikeFullVoiceXml(String xml) {
        if (xml == null || xml.isEmpty()) return false;
        String low = xml.toLowerCase(Locale.US);
        boolean end = low.contains("content-desc=\"end\"")
                || low.contains("text=\"end\"");
        boolean mic = low.contains("turn microphone off")
                || low.contains("turn microphone on")
                || low.contains("mute")
                || low.contains("unmute");
        boolean voice = low.contains("voice settings")
                || low.contains("voice conversation")
                || low.contains("focus mode");
        return end && (mic || voice);
    }

    private int[] findBoundsCenter(String xml, String... labels) {
        if (xml == null || xml.isEmpty() || labels == null) return null;
        String low = xml.toLowerCase(Locale.US);
        for (String label : labels) {
            if (label == null || label.isEmpty()) continue;
            String needle = label.toLowerCase(Locale.US);
            int at = low.indexOf("content-desc=\"" + needle + "\"");
            if (at < 0) at = low.indexOf("text=\"" + needle + "\"");
            if (at < 0) continue;

            int nodeStart = low.lastIndexOf("<node", at);
            int nodeEnd = low.indexOf(">", at);
            if (nodeStart < 0 || nodeEnd < 0) continue;
            String node = xml.substring(nodeStart, nodeEnd + 1);
            Matcher m = Pattern.compile(
                    "bounds=\"\\\\[(\\\\d+),(\\\\d+)\\\\]\\\\[(\\\\d+),(\\\\d+)\\\\]\"")
                    .matcher(node);
            if (m.find()) {
                int x1 = Integer.parseInt(m.group(1));
                int y1 = Integer.parseInt(m.group(2));
                int x2 = Integer.parseInt(m.group(3));
                int y2 = Integer.parseInt(m.group(4));
                return new int[]{(x1 + x2) / 2, (y1 + y2) / 2};
            }
        }
        return null;
    }

    private void restoreBootstrapTarget() {
        String pkg = bootstrapReturnPackage;
        if (pkg == null || pkg.isEmpty() || "__HOME__".equals(pkg)
                || "com.openai.chatgpt".equals(pkg)
                || getPackageName().equals(pkg)) {
            ShizukuBridge.runCommand("input keyevent 3");
            DebugFileLogger.log(this, "BOOTSTRAP", "Restored HOME under cover");
            return;
        }

        CountDownLatch done = new CountDownLatch(1);
        handler.post(() -> {
            try {
                Intent open = getPackageManager().getLaunchIntentForPackage(pkg);
                if (open == null) throw new IllegalStateException("no launch intent");
                open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                        | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                        | Intent.FLAG_ACTIVITY_SINGLE_TOP);
                startActivity(open);
                DebugFileLogger.log(WakeListenerService.this, "BOOTSTRAP",
                        "Restored previous app under cover: " + pkg);
            } catch (Throwable t) {
                ShizukuBridge.runCommand("input keyevent 3");
                DebugFileLogger.log(WakeListenerService.this, "BOOTSTRAP",
                        "Previous app restore failed; restored HOME under cover");
            } finally {
                done.countDown();
            }
        });
        try { done.await(1200L, TimeUnit.MILLISECONDS); }
        catch (InterruptedException ignored) {}
    }

    private void failBootstrap(String reason) {
        DebugFileLogger.log(this, "BOOTSTRAP", reason);
        restoreBootstrapTarget();
        handler.postDelayed(() -> {
            hideBootstrapCover();
            bootstrapHiddenLaunchInProgress = false;
            prefs().edit()
                    .putLong(ChatGPTTextAccessibilityService.KEY_FULL_VOICE_REQUEST_MS, 0L)
                    .putString(ChatGPTTextAccessibilityService.KEY_FULL_VOICE_STATUS,
                            reason)
                    .apply();
            setStatus(reason);
            handler.removeCallbacks(assistantSessionTimeoutRunnable);
            rearmAfterTrigger();
        }, 450L);
    }

'''
s = s.replace(anchor, helpers + anchor, 1)

# Clean bootstrap overlay on service destruction.
destroy_sig = "    public void onDestroy()"
start = s.find(destroy_sig)
if start < 0:
    raise SystemExit("v3.4: WakeListenerService onDestroy missing")
brace = s.find("{", start)
insert_at = brace + 1
s = s[:insert_at] + r'''
        bootstrapHiddenLaunchInProgress = false;
        hideBootstrapCover();''' + s[insert_at:]

p.write_text(s)


# ---------------------------------------------------------------------------
# Version/UI.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/MainActivity.java")
s = p.read_text()
s = s.replace("Hey ChatGPT Assist v3.3", "Hey ChatGPT Assist v3.4")
s = s.replace(
    "v3.3 makes hidden launch fail-closed. It uses a direct Accessibility bridge instead of the intermittent broadcast path, never visibly launches ChatGPT as a fallback, immediately restores your app/home when Voice is detected, and restores your app before removing the frozen cover if Voice startup fails.",
    "v3.4 self-heals when Android drops the Accessibility bridge. It uses Shizuku to capture the current screen, keeps that frozen image above ChatGPT, starts/detects Voice behind it, restores your previous app/home, and only then removes the cover. A dead Accessibility bridge no longer makes the wake phrase do nothing."
)
p.write_text(s)

p = Path("app/build.gradle")
s = p.read_text()
if 'versionCode 33' not in s or 'versionName "3.3"' not in s:
    raise SystemExit("v3.4: expected v3.3 version fields missing")
s = s.replace("versionCode 33", "versionCode 34", 1)
s = s.replace('versionName "3.3"', 'versionName "3.4"', 1)
p.write_text(s)
