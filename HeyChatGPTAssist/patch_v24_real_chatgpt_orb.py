from pathlib import Path

# v2.4: normal mode keeps the REAL ChatGPT Android assistant and adds only
# a Siri-style animated orb. No custom response text is scraped or displayed.
# The orb is an Accessibility overlay, so it needs no Draw-over-other-apps
# permission beyond the popup-detector Accessibility service already used by
# normal mode.

p = Path('app/src/main/java/com/example/heychatgptassist/ChatGPTTextAccessibilityService.java')
s = p.read_text()

imports_anchor = '''import android.accessibilityservice.AccessibilityServiceInfo;
import android.content.Intent;'''
if imports_anchor not in s:
    raise SystemExit('v2.4: accessibility imports anchor missing')
s = s.replace(imports_anchor, '''import android.accessibilityservice.AccessibilityServiceInfo;
import android.animation.AnimatorSet;
import android.animation.ObjectAnimator;
import android.animation.ValueAnimator;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;''', 1)

field_anchor = '''    private boolean popupOpen = false;
    private long lastPopupSeenUptime = 0L;'''
if field_anchor not in s:
    raise SystemExit('v2.4: popup fields anchor missing')
s = s.replace(field_anchor, field_anchor + '''

    // Decorative Siri-style orb shown only while the real ChatGPT assistant
    // popup is active. It is deliberately NOT_TOUCHABLE so ChatGPT retains
    // all touch/input control underneath it.
    private WindowManager orbWindowManager;
    private View siriOrb;
    private AnimatorSet siriOrbAnimator;''', 1)

recent_anchor = '''        if (!isRecentAssistSession()) {
            if (popupOpen) markClosed();
            return;
        }'''
if recent_anchor not in s:
    raise SystemExit('v2.4: recent-session block missing')
s = s.replace(recent_anchor, '''        if (!isRecentAssistSession()) {
            if (popupOpen) markClosed();
            else hideSiriOrb();
            return;
        }''', 1)

found_anchor = '''        if (found) {
            lastPopupSeenUptime = now;
            if (!popupOpen) {
                popupOpen = true;
                sendState(WakeListenerService.ACTION_ASSISTANT_POPUP_OPENED);
            }
        } else if (popupOpen && now - lastPopupSeenUptime > CLOSED_GRACE_MS) {'''
if found_anchor not in s:
    raise SystemExit('v2.4: found-popup block missing')
s = s.replace(found_anchor, '''        if (found) {
            lastPopupSeenUptime = now;
            showSiriOrb();
            if (!popupOpen) {
                popupOpen = true;
                sendState(WakeListenerService.ACTION_ASSISTANT_POPUP_OPENED);
            }
        } else if (popupOpen && now - lastPopupSeenUptime > CLOSED_GRACE_MS) {''', 1)

mark_anchor = '''    private void markClosed() {
        popupOpen = false;
        lastPopupSeenUptime = 0L;
        sendState(WakeListenerService.ACTION_ASSISTANT_POPUP_CLOSED);
    }'''
if mark_anchor not in s:
    raise SystemExit('v2.4: markClosed block missing')
orb_methods = r'''    private void showSiriOrb() {
        if (siriOrb != null) return;
        try {
            WindowManager wm = (WindowManager) getSystemService(WINDOW_SERVICE);
            if (wm == null) return;

            View orb = new View(this);
            GradientDrawable bg = new GradientDrawable(
                    GradientDrawable.Orientation.TL_BR,
                    new int[] {
                            Color.rgb(104, 74, 255),
                            Color.rgb(55, 177, 255),
                            Color.rgb(255, 80, 174),
                            Color.rgb(88, 58, 214)
                    });
            bg.setShape(GradientDrawable.OVAL);
            orb.setBackground(bg);
            orb.setElevation(dp(18));

            WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                    dp(78),
                    dp(78),
                    WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                            | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                            | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                            | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.TRANSLUCENT);
            lp.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
            lp.y = dp(18);
            lp.setTitle("Hey ChatGPT Assist Siri orb");

            wm.addView(orb, lp);
            orbWindowManager = wm;
            siriOrb = orb;
            startSiriOrbAnimation();
        } catch (Throwable ignored) {
            hideSiriOrb();
        }
    }

    private void startSiriOrbAnimation() {
        View orb = siriOrb;
        if (orb == null) return;
        try {
            ObjectAnimator sx = ObjectAnimator.ofFloat(orb, View.SCALE_X, 0.90f, 1.08f);
            ObjectAnimator sy = ObjectAnimator.ofFloat(orb, View.SCALE_Y, 0.90f, 1.08f);
            ObjectAnimator alpha = ObjectAnimator.ofFloat(orb, View.ALPHA, 0.78f, 1.0f);
            ObjectAnimator rotation = ObjectAnimator.ofFloat(orb, View.ROTATION, 0f, 360f);
            ObjectAnimator lift = ObjectAnimator.ofFloat(orb, View.TRANSLATION_Y, 0f, -dp(3), 0f);

            ObjectAnimator[] pulses = new ObjectAnimator[] { sx, sy, alpha };
            for (ObjectAnimator a : pulses) {
                a.setDuration(800L);
                a.setRepeatCount(ValueAnimator.INFINITE);
                a.setRepeatMode(ValueAnimator.REVERSE);
            }
            rotation.setDuration(4200L);
            rotation.setRepeatCount(ValueAnimator.INFINITE);
            rotation.setRepeatMode(ValueAnimator.RESTART);
            lift.setDuration(1500L);
            lift.setRepeatCount(ValueAnimator.INFINITE);
            lift.setRepeatMode(ValueAnimator.RESTART);

            siriOrbAnimator = new AnimatorSet();
            siriOrbAnimator.playTogether(sx, sy, alpha, rotation, lift);
            siriOrbAnimator.start();
        } catch (Throwable ignored) {}
    }

    private void hideSiriOrb() {
        AnimatorSet animator = siriOrbAnimator;
        siriOrbAnimator = null;
        if (animator != null) {
            try { animator.cancel(); } catch (Throwable ignored) {}
        }

        View orb = siriOrb;
        siriOrb = null;
        WindowManager wm = orbWindowManager;
        orbWindowManager = null;
        if (orb != null && wm != null) {
            try { wm.removeViewImmediate(orb); } catch (Throwable ignored) {}
        }
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

'''
s = s.replace(mark_anchor, '''    private void markClosed() {
        popupOpen = false;
        lastPopupSeenUptime = 0L;
        hideSiriOrb();
        sendState(WakeListenerService.ACTION_ASSISTANT_POPUP_CLOSED);
    }

''' + orb_methods, 1)

destroy_anchor = '''    public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (popupOpen) markClosed();
        super.onDestroy();
    }'''
if destroy_anchor not in s:
    raise SystemExit('v2.4: onDestroy block missing')
s = s.replace(destroy_anchor, '''    public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (popupOpen) markClosed();
        else hideSiriOrb();
        super.onDestroy();
    }''', 1)

p.write_text(s)

# Make the helper UI clearly describe normal mode: real ChatGPT + orb, no
# custom response text. Local/API modes remain available as optional fallbacks.
p = Path('app/src/main/java/com/example/heychatgptassist/MainActivity.java')
s = p.read_text().replace('Hey ChatGPT Assist v2.3', 'Hey ChatGPT Assist v2.4')
s = s.replace(
    'For NORMAL mode only: keep ‘Hey ChatGPT Assist response text’ enabled in Accessibility. v1.8 no longer reads or displays response text from Accessibility; it only detects when the real ChatGPT assistant popup closes so the wake microphone can resume cleanly. Siri text mode does not need Accessibility for its answer text.',
    'For NORMAL mode: keep ‘Hey ChatGPT Assist response text’ enabled in Accessibility. v2.4 uses it only to detect the real ChatGPT assistant popup and place the animated Siri-style orb over it. No ChatGPT response text is read, copied, or displayed by the helper.'
)
s = s.replace(
    'Normal mode keeps the original Side-button-style ChatGPT assistant popup. Siri text mode uses our own popup with API answer text and Android speech. No legacy accessibility text overlay is shown.',
    'Normal mode now means REAL ChatGPT + Siri-style orb. ChatGPT itself handles listening, intelligence, follow-ups, and voice. The helper adds only the animated orb; there is no custom answer text box.'
)
p.write_text(s)

p = Path('app/build.gradle')
s = p.read_text()
if 'versionCode 23' not in s or 'versionName "2.3"' not in s:
    raise SystemExit('v2.4: expected v2.3 version fields missing')
s = s.replace('versionCode 23', 'versionCode 24', 1)
s = s.replace('versionName "2.3"', 'versionName "2.4"', 1)
p.write_text(s)
