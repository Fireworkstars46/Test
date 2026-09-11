from pathlib import Path

# v2.7: Debug mode writes a shareable text log into Downloads instead of
# drawing a live debug overlay over the user's screen.

# ---------------------------------------------------------------------------
# Add a small MediaStore logger. No storage permission is needed on modern
# Android; the file is created in Downloads/HeyChatGPTAssist.
# ---------------------------------------------------------------------------
logger = r'''package com.example.heychatgptassist;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Environment;
import android.os.ParcelFileDescriptor;
import android.provider.MediaStore;

import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

public final class DebugFileLogger {
    private static final String KEY_URI = "debug_log_uri";
    private static final String KEY_NAME = "debug_log_name";
    private static final String LAST_PREFIX = "debug_last_";

    private DebugFileLogger() {}

    private static SharedPreferences prefs(Context c) {
        return c.getSharedPreferences(MainActivity.PREFS, Context.MODE_PRIVATE);
    }

    public static synchronized String ensureSession(Context context) {
        String uri = prefs(context).getString(KEY_URI, "");
        String name = prefs(context).getString(KEY_NAME, "");
        if (!uri.isEmpty() && !name.isEmpty()) return name;
        return startNewSession(context);
    }

    public static synchronized String startNewSession(Context context) {
        Context app = context.getApplicationContext();
        String stamp = new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new Date());
        String name = "HeyChatGPTAssist-debug-" + stamp + ".txt";

        try {
            ContentValues values = new ContentValues();
            values.put(MediaStore.Downloads.DISPLAY_NAME, name);
            values.put(MediaStore.Downloads.MIME_TYPE, "text/plain");
            values.put(MediaStore.Downloads.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/HeyChatGPTAssist");
            Uri uri = app.getContentResolver().insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
            if (uri == null) throw new IllegalStateException("MediaStore returned no file");

            prefs(app).edit()
                    .putString(KEY_URI, uri.toString())
                    .putString(KEY_NAME, name)
                    .apply();

            writeLine(app, uri, "SESSION",
                    "Hey ChatGPT Assist v2.7 debug log started");
            return name;
        } catch (Throwable t) {
            prefs(app).edit()
                    .remove(KEY_URI)
                    .putString(KEY_NAME, "ERROR: " + t.getClass().getSimpleName())
                    .apply();
            return prefs(app).getString(KEY_NAME, "ERROR");
        }
    }

    public static String getCurrentFileName(Context context) {
        return prefs(context).getString(KEY_NAME, "");
    }

    public static synchronized void log(Context context, String tag, String message) {
        if (context == null || message == null) return;
        Context app = context.getApplicationContext();
        if (!prefs(app).getBoolean(MainActivity.KEY_DEBUG_MODE, false)) return;

        String uriText = prefs(app).getString(KEY_URI, "");
        if (uriText.isEmpty()) {
            ensureSession(app);
            uriText = prefs(app).getString(KEY_URI, "");
        }
        if (uriText.isEmpty()) return;

        try {
            writeLine(app, Uri.parse(uriText), tag, message);
        } catch (Throwable first) {
            // If Android invalidated the old MediaStore URI, automatically
            // start a fresh file and retry once.
            startNewSession(app);
            uriText = prefs(app).getString(KEY_URI, "");
            if (uriText.isEmpty()) return;
            try { writeLine(app, Uri.parse(uriText), tag, message); }
            catch (Throwable ignored) {}
        }
    }

    public static synchronized void logChanged(
            Context context, String key, String tag, String message) {
        if (context == null || message == null) return;
        Context app = context.getApplicationContext();
        if (!prefs(app).getBoolean(MainActivity.KEY_DEBUG_MODE, false)) return;

        String prefKey = LAST_PREFIX + key;
        String last = prefs(app).getString(prefKey, "");
        if (message.equals(last)) return;
        prefs(app).edit().putString(prefKey, message).apply();
        log(app, tag, message);
    }

    private static void writeLine(Context context, Uri uri, String tag, String message)
            throws Exception {
        ContentResolver resolver = context.getContentResolver();
        ParcelFileDescriptor pfd = resolver.openFileDescriptor(uri, "wa");
        if (pfd == null) throw new IllegalStateException("Could not open debug file");
        try (ParcelFileDescriptor closePfd = pfd;
             FileOutputStream out = new FileOutputStream(closePfd.getFileDescriptor())) {
            String time = new SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(new Date());
            String clean = message.replace("\r", "\\r").replace("\n", " | ");
            String line = "[" + time + "] [" + tag + "] " + clean + "\n";
            out.write(line.getBytes(StandardCharsets.UTF_8));
            out.flush();
        }
    }
}
'''
Path("app/src/main/java/com/example/heychatgptassist/DebugFileLogger.java").write_text(logger)

# ---------------------------------------------------------------------------
# MainActivity: make Debug mode file-based and show the generated file name.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/MainActivity.java")
s = p.read_text()

s = s.replace("Hey ChatGPT Assist v2.6", "Hey ChatGPT Assist v2.7")
s = s.replace(
    "Turn this on while testing. A small live overlay will show the wake/ChatGPT Voice stages, visible packages, Voice UI detection, previous app, and the latest Accessibility event/text candidate. Send a screenshot or recording of that overlay if something fails.",
    "Turn this on while testing. v2.7 records the wake/ChatGPT Voice stages, visible packages, Voice detection, previous app, Accessibility events, and response-text candidates into a normal .txt file in Downloads/HeyChatGPTAssist. No debug overlay is drawn on screen."
)
s = s.replace(
    'debugModeToggle.setText("Show live debug overlay");',
    'debugModeToggle.setText("Record debug log to text file");'
)

old_listener = '''        debugModeToggle.setOnCheckedChangeListener((buttonView, checked) -> {
            prefs().edit().putBoolean(KEY_DEBUG_MODE, checked).apply();
            updateDebugStatus();
            Toast.makeText(this, checked ? "Debug overlay ON" : "Debug overlay OFF", Toast.LENGTH_SHORT).show();
        });'''
new_listener = '''        debugModeToggle.setOnCheckedChangeListener((buttonView, checked) -> {
            prefs().edit().putBoolean(KEY_DEBUG_MODE, checked).apply();
            if (checked) {
                String name = DebugFileLogger.startNewSession(this);
                Toast.makeText(this, "Debug file: " + name, Toast.LENGTH_LONG).show();
            } else {
                Toast.makeText(this, "Debug recording OFF", Toast.LENGTH_SHORT).show();
            }
            updateDebugStatus();
        });'''
if old_listener not in s:
    raise SystemExit("v2.7: debug toggle listener anchor missing")
s = s.replace(old_listener, new_listener, 1)

status_block = '''        debugStatus = new TextView(this);
        debugStatus.setTextSize(13);
        debugStatus.setPadding(0, dp(4), 0, dp(8));
        root.addView(debugStatus);
'''
if status_block not in s:
    raise SystemExit("v2.7: debug status block missing")
s = s.replace(status_block, status_block + '''
        addButton(root, "START NEW DEBUG TEXT FILE", v -> {
            prefs().edit().putBoolean(KEY_DEBUG_MODE, true).apply();
            if (debugModeToggle != null) debugModeToggle.setChecked(true);
            String name = DebugFileLogger.startNewSession(this);
            updateDebugStatus();
            Toast.makeText(this, "New debug file: " + name, Toast.LENGTH_LONG).show();
        });
''', 1)

old_status = r'''        debugStatus.setText("Debug overlay: " + (enabled ? "ON" : "OFF") +
                "\nState: " + state +
                "\nEvent: " + event);'''
new_status = r'''        String file = DebugFileLogger.getCurrentFileName(this);
        debugStatus.setText("Debug text file: " + (enabled ? "RECORDING" : "OFF") +
                "\nFile: " + (file.isEmpty() ? "(none yet)" : file) +
                "\nLocation: Downloads/HeyChatGPTAssist" +
                "\nState: " + state +
                "\nEvent: " + event);'''
if old_status not in s:
    raise SystemExit("v2.7: debug status method anchor missing")
s = s.replace(old_status, new_status, 1)

# Ensure an active Debug toggle always has a real file when listening starts.
request_anchor = '''    private void requestAndStart() {'''
if request_anchor not in s:
    raise SystemExit("v2.7: requestAndStart missing")
s = s.replace(request_anchor, request_anchor + '''
        if (prefs().getBoolean(KEY_DEBUG_MODE, false)) {
            DebugFileLogger.ensureSession(this);
            DebugFileLogger.log(this, "MAIN", "START ALWAYS LISTENING pressed");
        }
''', 1)

s = s.replace(
    "v2.6 adds an optional live debug overlay so failed Voice/text detection can be diagnosed from a screenshot or recording.",
    "v2.7 can record a detailed debug text file in Downloads/HeyChatGPTAssist so failed Voice/text detection can be diagnosed without covering the screen."
)
p.write_text(s)

# ---------------------------------------------------------------------------
# Wake listener: record meaningful status changes and heard phrases.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/WakeListenerService.java")
s = p.read_text()

status_anchor = '''        lastStatusWritten = text;
        prefs().edit().putString(KEY_LISTENER_STATUS, text).apply();'''
if status_anchor not in s:
    raise SystemExit("v2.7: Wake setStatus anchor missing")
s = s.replace(status_anchor, status_anchor + '''
        DebugFileLogger.log(this, "WAKE", text);''', 1)

heard_anchor = '''        lastHeardWritten = heard;
        prefs().edit().putString(KEY_LAST_HEARD, heard).apply();'''
if heard_anchor not in s:
    raise SystemExit("v2.7: Wake rememberHeard anchor missing")
s = s.replace(heard_anchor, heard_anchor + '''
        DebugFileLogger.logChanged(this, "heard", "HEARD", heard);''', 1)

p.write_text(s)

# ---------------------------------------------------------------------------
# Accessibility: write the same diagnostics that v2.6 displayed, but don't
# display a debug overlay.
# ---------------------------------------------------------------------------
p = Path("app/src/main/java/com/example/heychatgptassist/ChatGPTTextAccessibilityService.java")
s = p.read_text()

# Event trace.
event_write = '''                lastDebugEvent = ev.toString();
                prefs().edit().putString(KEY_DEBUG_EVENT, lastDebugEvent).apply();'''
if event_write not in s:
    raise SystemExit("v2.7: debug event write missing")
s = s.replace(event_write, event_write + '''
                DebugFileLogger.logChanged(this, "access_event", "ACCESS", lastDebugEvent);''', 1)

# Text candidates.
candidate_write = '''                lastDebugCandidate = "score=" + score + " " + dbg;'''
if candidate_write not in s:
    raise SystemExit("v2.7: debug candidate write missing")
s = s.replace(candidate_write, candidate_write + '''
                DebugFileLogger.logChanged(this, "text_candidate", "TEXT", lastDebugCandidate);''', 1)

# Replace updateDebugOverlay with file-only logging while retaining the method
# name so the v2.6 state machine needs no larger rewrite.
start = s.find("    private void updateDebugOverlay(String state) {")
if start < 0:
    raise SystemExit("v2.7: updateDebugOverlay method missing")
brace = s.find("{", start)
depth = 0
end = None
for i in range(brace, len(s)):
    if s[i] == "{":
        depth += 1
    elif s[i] == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end is None:
    raise SystemExit("v2.7: updateDebugOverlay method end missing")
replacement = r'''    private void updateDebugOverlay(String state) {
        if (state == null) state = "";
        prefs().edit().putString(KEY_DEBUG_STATE, state).apply();
        hideDebugOverlay();

        if (!isDebugMode()) return;

        String voiceStatus = prefs().getString(KEY_FULL_VOICE_STATUS, "(none)");
        String previous = prefs().getString(KEY_PREVIOUS_APP_PACKAGE, "(none)");
        String listener = prefs().getString(WakeListenerService.KEY_LISTENER_STATUS, "(none)");
        String heard = prefs().getString(WakeListenerService.KEY_LAST_HEARD, "(none)");

        String text = state
                + " | listener=" + listener
                + " | heard=" + heard
                + " | voiceStatus=" + voiceStatus
                + " | previous=" + previous
                + " | windows=" + lastDebugPackages
                + " | event=" + lastDebugEvent
                + " | candidate=" + lastDebugCandidate;
        DebugFileLogger.logChanged(this, "access_state", "STATE", text);
    }'''
s = s[:start] + replacement + s[end:]

# Record previous-app restore attempts explicitly.
return_anchor = '''    private void returnToPreviousApp() {
        if (!fullVoiceSessionActive) return;'''
if return_anchor not in s:
    raise SystemExit("v2.7: returnToPreviousApp anchor missing")
s = s.replace(return_anchor, return_anchor + '''
        DebugFileLogger.log(this, "VOICE", "Returning to previous app");''', 1)

# Record session closure.
close_anchor = '''    private void markClosed() {
        popupOpen = false;'''
if close_anchor not in s:
    raise SystemExit("v2.7: markClosed anchor missing")
s = s.replace(close_anchor, close_anchor + '''
        DebugFileLogger.log(this, "VOICE", "Session marked closed");''', 1)

p.write_text(s)

# ---------------------------------------------------------------------------
# Version.
# ---------------------------------------------------------------------------
p = Path("app/build.gradle")
s = p.read_text()
if 'versionCode 26' not in s or 'versionName "2.6"' not in s:
    raise SystemExit("v2.7: expected v2.6 version fields missing")
s = s.replace("versionCode 26", "versionCode 27", 1)
s = s.replace('versionName "2.6"', 'versionName "2.7"', 1)
p.write_text(s)
