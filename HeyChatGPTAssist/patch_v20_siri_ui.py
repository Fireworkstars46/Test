from pathlib import Path
p = Path('app/src/main/java/com/example/heychatgptassist/SiriModeActivity.java')
s = p.read_text()

# Rebuild the method wholesale because v1.9 inserted the bubble inside panel.
start = s.find('    private void buildUi() {')
end = s.find('    private void startBubbleAnimation() {', start)
if start < 0 or end < 0:
    raise SystemExit('v2.0: Siri buildUi boundaries missing')
new_build_ui = r'''    private void buildUi() {
        FrameLayout outer = new FrameLayout(this);
        outer.setPadding(dp(12), dp(20), dp(12), dp(24));

        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(18), dp(12), dp(16), dp(16));
        GradientDrawable panelBg = new GradientDrawable();
        panelBg.setColor(Color.argb(246, 28, 28, 30));
        panelBg.setCornerRadius(dp(24));
        panel.setBackground(panelBg);
        panel.setElevation(dp(12));

        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = new TextView(this);
        title.setText("AI assistant");
        title.setTextColor(Color.WHITE);
        title.setTextSize(16);
        title.setTypeface(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD);
        header.addView(title, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        TextView close = new TextView(this);
        close.setText("×");
        close.setTextColor(Color.LTGRAY);
        close.setTextSize(28);
        close.setGravity(Gravity.CENTER);
        close.setPadding(dp(12), 0, dp(2), 0);
        close.setOnClickListener(v -> finish());
        header.addView(close);
        panel.addView(header);

        statusText = new TextView(this);
        statusText.setTextColor(Color.LTGRAY);
        statusText.setTextSize(13);
        statusText.setPadding(0, dp(2), 0, dp(4));
        panel.addView(statusText);

        questionText = new TextView(this);
        questionText.setTextColor(Color.rgb(205, 205, 210));
        questionText.setTextSize(14);
        questionText.setMaxLines(2);
        questionText.setEllipsize(android.text.TextUtils.TruncateAt.END);
        panel.addView(questionText);

        answerText = new TextView(this);
        answerText.setTextColor(Color.WHITE);
        answerText.setTextSize(18);
        answerText.setLineSpacing(0f, 1.08f);
        answerText.setMaxLines(8);
        answerText.setEllipsize(android.text.TextUtils.TruncateAt.END);
        answerText.setPadding(0, dp(6), 0, 0);
        panel.addView(answerText);

        FrameLayout.LayoutParams panelLp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM);
        panelLp.bottomMargin = dp(122);
        outer.addView(panel, panelLp);

        voiceBubble = new View(this);
        GradientDrawable bubbleBg = new GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                new int[] {
                        Color.rgb(104, 74, 255),
                        Color.rgb(55, 177, 255),
                        Color.rgb(255, 80, 174),
                        Color.rgb(88, 58, 214)
                });
        bubbleBg.setShape(GradientDrawable.OVAL);
        voiceBubble.setBackground(bubbleBg);
        voiceBubble.setElevation(dp(18));
        FrameLayout.LayoutParams bubbleLp = new FrameLayout.LayoutParams(
                dp(78), dp(78), Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        bubbleLp.bottomMargin = dp(18);
        outer.addView(voiceBubble, bubbleLp);

        setContentView(outer);
        startBubbleAnimation();
    }

'''
s = s[:start] + new_build_ui + s[end:]

# Add a slow rotation to the existing pulse animation.
old_anim = r'''        ObjectAnimator alpha = ObjectAnimator.ofFloat(voiceBubble, View.ALPHA, 0.55f, 1.0f);
        sx.setRepeatCount(ValueAnimator.INFINITE); sx.setRepeatMode(ValueAnimator.REVERSE);
        sy.setRepeatCount(ValueAnimator.INFINITE); sy.setRepeatMode(ValueAnimator.REVERSE);
        alpha.setRepeatCount(ValueAnimator.INFINITE); alpha.setRepeatMode(ValueAnimator.REVERSE);
        sx.setDuration(850L); sy.setDuration(850L); alpha.setDuration(850L);
        bubbleAnimator = new AnimatorSet();
        bubbleAnimator.playTogether(sx, sy, alpha);'''
new_anim = r'''        ObjectAnimator alpha = ObjectAnimator.ofFloat(voiceBubble, View.ALPHA, 0.78f, 1.0f);
        ObjectAnimator rotation = ObjectAnimator.ofFloat(voiceBubble, View.ROTATION, 0f, 360f);
        sx.setRepeatCount(ValueAnimator.INFINITE); sx.setRepeatMode(ValueAnimator.REVERSE);
        sy.setRepeatCount(ValueAnimator.INFINITE); sy.setRepeatMode(ValueAnimator.REVERSE);
        alpha.setRepeatCount(ValueAnimator.INFINITE); alpha.setRepeatMode(ValueAnimator.REVERSE);
        rotation.setRepeatCount(ValueAnimator.INFINITE); rotation.setRepeatMode(ValueAnimator.RESTART);
        sx.setDuration(800L); sy.setDuration(800L); alpha.setDuration(800L); rotation.setDuration(4200L);
        bubbleAnimator = new AnimatorSet();
        bubbleAnimator.playTogether(sx, sy, alpha, rotation);'''
if old_anim not in s:
    raise SystemExit('v2.0: Siri animation anchor missing')
s = s.replace(old_anim, new_anim, 1)

# Full-screen transparent popup so bottom anchoring is relative to the display.
s = s.replace('window.setGravity(Gravity.TOP | Gravity.CENTER_HORIZONTAL);', 'window.setGravity(Gravity.FILL);')
s = s.replace('window.setLayout(WindowManager.LayoutParams.MATCH_PARENT,\n                WindowManager.LayoutParams.WRAP_CONTENT);',
              'window.setLayout(WindowManager.LayoutParams.MATCH_PARENT,\n                WindowManager.LayoutParams.MATCH_PARENT);')
s = s.replace('getWindow().setGravity(Gravity.TOP | Gravity.CENTER_HORIZONTAL);', 'getWindow().setGravity(Gravity.FILL);')
s = s.replace('getWindow().setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.WRAP_CONTENT);',
              'getWindow().setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT);')
p.write_text(s)
