package com.fireworkstars46.icloudnotes;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.DownloadManager;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;

public class MainActivity extends Activity {
    private static final String START_URL = "https://www.icloud.com/notes/";
    private static final int FILE_CHOOSER_REQUEST = 401;

    private static final String PREFS_NAME = "icloud_notes_preferences";
    private static final String OLD_KEY_SCROLL_SPEED = "fast_scroll_multiplier";
    private static final String KEY_SCROLL_TENTHS = "fast_scroll_multiplier_tenths";

    private static final int DEFAULT_SCROLL_TENTHS = 55; // 5.5x
    private static final int MIN_SCROLL_TENTHS = 1;     // 0.1x
    private static final int MAX_SCROLL_TENTHS = 1000;  // 100.0x

    private FastWebView webView;
    private ValueCallback<Uri[]> fileCallback;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        getWindow().setStatusBarColor(Color.WHITE);
        getWindow().setNavigationBarColor(Color.WHITE);
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        );

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.WHITE);
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            int top = insets.getSystemWindowInsetTop();
            int bottom = insets.getSystemWindowInsetBottom();

            if (v.getPaddingTop() != top || v.getPaddingBottom() != bottom) {
                v.setPadding(0, top, 0, bottom);
            }
            return insets;
        });

        LinearLayout appColumn = new LinearLayout(this);
        appColumn.setOrientation(LinearLayout.VERTICAL);
        appColumn.setBackgroundColor(Color.WHITE);

        LinearLayout settingsStrip = new LinearLayout(this);
        settingsStrip.setOrientation(LinearLayout.HORIZONTAL);
        settingsStrip.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
        settingsStrip.setPadding(dp(4), 0, dp(7), 0);
        settingsStrip.setBackgroundColor(Color.rgb(250, 250, 250));

        TextView settingsButton = new TextView(this);
        settingsButton.setText("⚙");
        settingsButton.setTextSize(19f);
        settingsButton.setTextColor(Color.rgb(75, 75, 75));
        settingsButton.setGravity(Gravity.CENTER);
        settingsButton.setContentDescription("Scroll settings");
        settingsButton.setBackground(makeRoundedBackground(
                Color.rgb(245, 245, 245),
                Color.rgb(205, 205, 205),
                14
        ));
        settingsButton.setOnClickListener(v -> showScrollSettings());

        LinearLayout.LayoutParams settingsButtonParams =
                new LinearLayout.LayoutParams(dp(38), dp(26));
        settingsStrip.addView(settingsButton, settingsButtonParams);

        View divider = new View(this);
        divider.setBackgroundColor(Color.rgb(225, 225, 225));

        webView = new FastWebView(this);
        webView.setBackgroundColor(Color.WHITE);
        webView.setLayerType(View.LAYER_TYPE_HARDWARE, null);
        webView.setVerticalScrollBarEnabled(false);
        webView.setHorizontalScrollBarEnabled(false);
        webView.setOverScrollMode(View.OVER_SCROLL_NEVER);
        webView.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false);

        appColumn.addView(
                settingsStrip,
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        dp(30)
                )
        );
        appColumn.addView(
                divider,
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        dp(1)
                )
        );
        appColumn.addView(
                webView,
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        0,
                        1f
                )
        );

        root.addView(
                appColumn,
                new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                )
        );

        setContentView(root);
        root.requestApplyInsets();

        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setAllowContentAccess(true);
        s.setAllowFileAccess(false);
        s.setLoadsImagesAutomatically(true);
        s.setMediaPlaybackRequiresUserGesture(false);

        s.setTextZoom(100);
        s.setSupportZoom(false);
        s.setBuiltInZoomControls(false);
        s.setDisplayZoomControls(false);
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(false);

        s.setCacheMode(WebSettings.LOAD_DEFAULT);
        s.setOffscreenPreRaster(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);

        String ua = s.getUserAgentString();
        if (ua != null) {
            s.setUserAgentString(ua.replace("; wv", ""));
        }

        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        cookies.setAcceptThirdPartyCookies(webView, true);

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase();

                if (scheme.equals("http") || scheme.equals("https")) {
                    return false;
                }

                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, uri));
                } catch (ActivityNotFoundException e) {
                    Toast.makeText(MainActivity.this, "No app can open this link.", Toast.LENGTH_SHORT).show();
                }
                return true;
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);

                view.evaluateJavascript(
                        "(function(){"
                                + "var id='s22-notes-scroll-tweaks';"
                                + "if(!document.getElementById(id)){"
                                + "var st=document.createElement('style');"
                                + "st.id=id;"
                                + "st.textContent='html,body,*{scroll-behavior:auto!important;}';"
                                + "document.documentElement.appendChild(st);"
                                + "}"
                                + "})();",
                        null
                );
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (fileCallback != null) {
                    fileCallback.onReceiveValue(null);
                }
                fileCallback = callback;

                try {
                    startActivityForResult(params.createIntent(), FILE_CHOOSER_REQUEST);
                    return true;
                } catch (ActivityNotFoundException e) {
                    fileCallback = null;
                    Toast.makeText(MainActivity.this, "No file picker is available.", Toast.LENGTH_SHORT).show();
                    return false;
                }
            }
        });

        webView.setDownloadListener(new DownloadListener() {
            @Override
            public void onDownloadStart(String url, String userAgent, String contentDisposition,
                                        String mimeType, long contentLength) {
                try {
                    DownloadManager.Request request = new DownloadManager.Request(Uri.parse(url));
                    request.setMimeType(mimeType);
                    request.addRequestHeader("Cookie", CookieManager.getInstance().getCookie(url));
                    request.addRequestHeader("User-Agent", userAgent);
                    request.setNotificationVisibility(
                            DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                    );
                    request.setDestinationInExternalPublicDir(
                            Environment.DIRECTORY_DOWNLOADS,
                            android.webkit.URLUtil.guessFileName(url, contentDisposition, mimeType)
                    );
                    ((DownloadManager) getSystemService(Context.DOWNLOAD_SERVICE)).enqueue(request);
                    Toast.makeText(MainActivity.this, "Downloading…", Toast.LENGTH_SHORT).show();
                } catch (Exception e) {
                    try {
                        startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
                    } catch (Exception ignored) {
                        Toast.makeText(
                                MainActivity.this,
                                "Could not download this file.",
                                Toast.LENGTH_SHORT
                        ).show();
                    }
                }
            }
        });

        if (savedInstanceState == null) {
            webView.loadUrl(START_URL);
        } else {
            webView.restoreState(savedInstanceState);
        }
    }

    private void showScrollSettings() {
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(20), dp(8), dp(20), dp(5));

        TextView help = new TextView(this);
        help.setTextSize(14f);
        help.setTextColor(Color.rgb(85, 85, 85));
        help.setText(
                "Slow finger movement stays slow. The faster you swipe, the more the app "
                        + "ramps toward the maximum below."
        );
        help.setPadding(0, 0, 0, dp(12));

        LinearLayout stepRow = new LinearLayout(this);
        stepRow.setOrientation(LinearLayout.HORIZONTAL);
        stepRow.setGravity(Gravity.CENTER_VERTICAL);

        Button minus = new Button(this);
        minus.setText("−");
        minus.setTextSize(22f);
        minus.setMinWidth(0);
        minus.setMinimumWidth(0);

        TextView valueLabel = new TextView(this);
        valueLabel.setTextSize(19f);
        valueLabel.setTextColor(Color.rgb(40, 40, 40));
        valueLabel.setGravity(Gravity.CENTER);

        Button plus = new Button(this);
        plus.setText("+");
        plus.setTextSize(20f);
        plus.setMinWidth(0);
        plus.setMinimumWidth(0);

        stepRow.addView(minus, new LinearLayout.LayoutParams(dp(58), dp(48)));
        stepRow.addView(
                valueLabel,
                new LinearLayout.LayoutParams(0, dp(48), 1f)
        );
        stepRow.addView(plus, new LinearLayout.LayoutParams(dp(58), dp(48)));

        SeekBar slider = new SeekBar(this);
        slider.setMax(MAX_SCROLL_TENTHS - MIN_SCROLL_TENTHS);

        int currentTenths = webView.getMaxMultiplierTenths();
        slider.setProgress(currentTenths - MIN_SCROLL_TENTHS);
        updateSpeedLabel(valueLabel, currentTenths);

        slider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                int tenths = MIN_SCROLL_TENTHS + progress;
                webView.setMaxMultiplierTenths(tenths);
                updateSpeedLabel(valueLabel, tenths);
            }

            @Override
            public void onStartTrackingTouch(SeekBar seekBar) { }

            @Override
            public void onStopTrackingTouch(SeekBar seekBar) { }
        });

        minus.setOnClickListener(v -> {
            int next = Math.max(
                    MIN_SCROLL_TENTHS,
                    webView.getMaxMultiplierTenths() - 1
            );
            webView.setMaxMultiplierTenths(next);
            slider.setProgress(next - MIN_SCROLL_TENTHS);
            updateSpeedLabel(valueLabel, next);
        });

        plus.setOnClickListener(v -> {
            int next = Math.min(
                    MAX_SCROLL_TENTHS,
                    webView.getMaxMultiplierTenths() + 1
            );
            webView.setMaxMultiplierTenths(next);
            slider.setProgress(next - MIN_SCROLL_TENTHS);
            updateSpeedLabel(valueLabel, next);
        });

        TextView range = new TextView(this);
        range.setTextSize(12f);
        range.setTextColor(Color.rgb(110, 110, 110));
        range.setText("0.1×                                                           100.0×");
        range.setPadding(0, 0, 0, dp(2));

        panel.addView(help);
        panel.addView(stepRow);
        panel.addView(slider);
        panel.addView(range);

        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("Scroll sensitivity")
                .setView(panel)
                .setPositiveButton("Done", null)
                .setNeutralButton("Reset to 5.5×", null)
                .create();

        dialog.setOnShowListener(d -> dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v -> {
            webView.setMaxMultiplierTenths(DEFAULT_SCROLL_TENTHS);
            slider.setProgress(DEFAULT_SCROLL_TENTHS - MIN_SCROLL_TENTHS);
            updateSpeedLabel(valueLabel, DEFAULT_SCROLL_TENTHS);
        }));

        dialog.show();
    }

    private void updateSpeedLabel(TextView label, int tenths) {
        label.setText(String.format(
                java.util.Locale.US,
                "%.1f×",
                tenths / 10f
        ));
    }

    private GradientDrawable makeRoundedBackground(int fill, int stroke, int radiusDp) {
        GradientDrawable background = new GradientDrawable();
        background.setShape(GradientDrawable.RECTANGLE);
        background.setCornerRadius(dp(radiusDp));
        background.setColor(fill);
        background.setStroke(dp(1), stroke);
        return background;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == FILE_CHOOSER_REQUEST) {
            Uri[] result = WebChromeClient.FileChooserParams.parseResult(resultCode, data);
            if (fileCallback != null) {
                fileCallback.onReceiveValue(result);
            }
            fileCallback = null;
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        if (webView != null) {
            webView.saveState(outState);
        }
        super.onSaveInstanceState(outState);
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }

    private static class FastWebView extends WebView {
        // Slow gestures stay at (or below) 1x. Faster gestures ramp progressively
        // toward the user's selected maximum. Cubic ramp keeps slow movement precise
        // even when the maximum is extremely high, such as 100x.
        private static final float SPEED_START = 100f;
        private static final float SPEED_FOR_MAX = 2800f;

        private final int touchSlop;
        private final SharedPreferences preferences;

        private int maxMultiplierTenths;
        private float downX;
        private float downY;
        private float lastRawY;
        private float virtualY;
        private long lastEventTime;
        private boolean verticalScroll;
        private float smoothedSpeed;
        private float lastMultiplier;

        FastWebView(Context context) {
            super(context);
            touchSlop = ViewConfiguration.get(context).getScaledTouchSlop();
            preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);

            if (preferences.contains(KEY_SCROLL_TENTHS)) {
                maxMultiplierTenths = clampTenths(
                        preferences.getInt(KEY_SCROLL_TENTHS, DEFAULT_SCROLL_TENTHS)
                );
            } else {
                float previous = preferences.getFloat(
                        OLD_KEY_SCROLL_SPEED,
                        DEFAULT_SCROLL_TENTHS / 10f
                );
                maxMultiplierTenths = clampTenths(Math.round(previous * 10f));
                preferences.edit().putInt(KEY_SCROLL_TENTHS, maxMultiplierTenths).apply();
            }

            resetGestureValues();
        }

        int getMaxMultiplierTenths() {
            return maxMultiplierTenths;
        }

        void setMaxMultiplierTenths(int tenths) {
            maxMultiplierTenths = clampTenths(tenths);
            preferences.edit().putInt(KEY_SCROLL_TENTHS, maxMultiplierTenths).apply();
        }

        @Override
        public boolean onTouchEvent(MotionEvent event) {
            final int action = event.getActionMasked();

            if (action == MotionEvent.ACTION_DOWN) {
                downX = event.getX();
                downY = event.getY();
                lastRawY = downY;
                virtualY = downY;
                lastEventTime = event.getEventTime();
                verticalScroll = false;
                smoothedSpeed = 0f;
                lastMultiplier = slowMultiplier();
                return super.onTouchEvent(event);
            }

            MotionEvent transformed = MotionEvent.obtain(event);

            if (action == MotionEvent.ACTION_MOVE) {
                float totalDx = event.getX() - downX;
                float totalDy = event.getY() - downY;

                if (!verticalScroll
                        && Math.abs(totalDy) >= touchSlop
                        && Math.abs(totalDy) > Math.abs(totalDx) * 1.08f) {
                    verticalScroll = true;
                }

                float rawDeltaY = event.getY() - lastRawY;
                long now = event.getEventTime();
                long dtMs = Math.max(1L, now - lastEventTime);

                if (verticalScroll) {
                    float instantaneousSpeed = Math.abs(rawDeltaY) * 1000f / dtMs;

                    // Light filtering prevents one noisy touch sample from causing
                    // a huge speed spike when the maximum is set very high.
                    smoothedSpeed =
                            (smoothedSpeed * 0.55f)
                                    + (instantaneousSpeed * 0.45f);

                    float t = clamp01(
                            (smoothedSpeed - SPEED_START)
                                    / (SPEED_FOR_MAX - SPEED_START)
                    );

                    // Cubic response: slow stays slow, medium grows gradually,
                    // and genuinely fast swipes can reach the selected maximum.
                    float curve = t * t * t;
                    float low = slowMultiplier();
                    float high = maxMultiplierTenths / 10f;
                    float target = low + ((high - low) * curve);

                    // Smooth the multiplier itself so acceleration is continuous.
                    lastMultiplier += (target - lastMultiplier) * 0.60f;
                } else {
                    lastMultiplier = slowMultiplier();
                }

                virtualY += rawDeltaY * lastMultiplier;
                transformed.setLocation(event.getX(), virtualY);

                lastRawY = event.getY();
                lastEventTime = now;

                boolean handled = super.onTouchEvent(transformed);
                transformed.recycle();
                return handled;
            }

            if (action == MotionEvent.ACTION_UP) {
                if (verticalScroll) {
                    float rawDeltaY = event.getY() - lastRawY;
                    virtualY += rawDeltaY * lastMultiplier;
                    transformed.setLocation(event.getX(), virtualY);
                }

                // WebView receives the accelerated gesture and still performs its
                // own native momentum/coasting after the finger is released.
                boolean handled = super.onTouchEvent(transformed);
                transformed.recycle();
                return handled;
            }

            if (action == MotionEvent.ACTION_CANCEL && verticalScroll) {
                transformed.setLocation(event.getX(), virtualY);
            }

            boolean handled = super.onTouchEvent(transformed);
            transformed.recycle();
            return handled;
        }

        private float slowMultiplier() {
            // When the selected maximum is below 1x, the entire gesture is reduced.
            // Otherwise slow movement remains true 1:1.
            return Math.min(1.0f, maxMultiplierTenths / 10f);
        }

        private void resetGestureValues() {
            smoothedSpeed = 0f;
            lastMultiplier = slowMultiplier();
        }

        private static float clamp01(float value) {
            return Math.max(0f, Math.min(1f, value));
        }

        private static int clampTenths(int value) {
            return Math.max(MIN_SCROLL_TENTHS, Math.min(MAX_SCROLL_TENTHS, value));
        }
    }
}
