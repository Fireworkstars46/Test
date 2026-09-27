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
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;

public class MainActivity extends Activity {
    private static final String START_URL = "https://www.icloud.com/notes/";
    private static final int FILE_CHOOSER_REQUEST = 401;

    private static final String PREFS_NAME = "icloud_notes_preferences";
    private static final String KEY_SCROLL_SPEED = "fast_scroll_multiplier";
    private static final float DEFAULT_SCROLL_SPEED = 5.5f;
    private static final float MIN_SCROLL_SPEED = 1.0f;
    private static final float MAX_SCROLL_SPEED = 12.0f;
    private static final float SCROLL_SPEED_STEP = 0.5f;

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

        webView = new FastWebView(this);
        webView.setBackgroundColor(Color.WHITE);
        webView.setLayerType(View.LAYER_TYPE_HARDWARE, null);
        webView.setVerticalScrollBarEnabled(false);
        webView.setHorizontalScrollBarEnabled(false);
        webView.setOverScrollMode(View.OVER_SCROLL_NEVER);
        webView.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false);

        root.addView(
                webView,
                new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                )
        );

        TextView settingsButton = new TextView(this);
        settingsButton.setText("⚙");
        settingsButton.setTextSize(21f);
        settingsButton.setTextColor(Color.rgb(70, 70, 70));
        settingsButton.setGravity(Gravity.CENTER);
        settingsButton.setContentDescription("Scroll settings");
        settingsButton.setAlpha(0.72f);
        settingsButton.setElevation(dp(5));

        GradientDrawable gearBackground = new GradientDrawable();
        gearBackground.setShape(GradientDrawable.OVAL);
        gearBackground.setColor(Color.argb(235, 255, 255, 255));
        gearBackground.setStroke(dp(1), Color.argb(130, 150, 150, 150));
        settingsButton.setBackground(gearBackground);
        settingsButton.setOnClickListener(v -> showScrollSettings());

        FrameLayout.LayoutParams gearParams = new FrameLayout.LayoutParams(dp(42), dp(42));
        gearParams.gravity = Gravity.END | Gravity.BOTTOM;
        gearParams.setMargins(dp(8), dp(8), dp(12), dp(12));
        root.addView(settingsButton, gearParams);

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
        panel.setPadding(dp(22), dp(8), dp(22), dp(4));

        TextView valueLabel = new TextView(this);
        valueLabel.setTextSize(18f);
        valueLabel.setTextColor(Color.rgb(45, 45, 45));
        valueLabel.setGravity(Gravity.CENTER_HORIZONTAL);

        TextView help = new TextView(this);
        help.setTextSize(14f);
        help.setTextColor(Color.rgb(95, 95, 95));
        help.setText("Higher values make quick swipes move farther and faster. Slow movement stays close to normal. v2.0 used 5.5×.");
        help.setPadding(0, dp(8), 0, dp(10));

        SeekBar slider = new SeekBar(this);
        int steps = Math.round((MAX_SCROLL_SPEED - MIN_SCROLL_SPEED) / SCROLL_SPEED_STEP);
        slider.setMax(steps);

        float current = webView.getMaxMultiplier();
        slider.setProgress(Math.round((current - MIN_SCROLL_SPEED) / SCROLL_SPEED_STEP));
        updateSpeedLabel(valueLabel, current);

        slider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                float value = MIN_SCROLL_SPEED + (progress * SCROLL_SPEED_STEP);
                webView.setMaxMultiplier(value);
                updateSpeedLabel(valueLabel, value);
            }

            @Override
            public void onStartTrackingTouch(SeekBar seekBar) { }

            @Override
            public void onStopTrackingTouch(SeekBar seekBar) { }
        });

        panel.addView(valueLabel);
        panel.addView(help);
        panel.addView(slider);

        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("Scroll sensitivity")
                .setView(panel)
                .setPositiveButton("Done", null)
                .setNegativeButton("Reset to 5.5×", null)
                .create();

        dialog.setOnShowListener(d -> dialog.getButton(AlertDialog.BUTTON_NEGATIVE).setOnClickListener(v -> {
            webView.setMaxMultiplier(DEFAULT_SCROLL_SPEED);
            slider.setProgress(Math.round(
                    (DEFAULT_SCROLL_SPEED - MIN_SCROLL_SPEED) / SCROLL_SPEED_STEP
            ));
            updateSpeedLabel(valueLabel, DEFAULT_SCROLL_SPEED);
        }));

        dialog.show();
    }

    private void updateSpeedLabel(TextView label, float value) {
        label.setText(String.format(java.util.Locale.US, "Fast scroll speed: %.1f×", value));
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
        private static final float MIN_MULTIPLIER = 1.0f;
        private static final float SPEED_START = 140f;
        private static final float SPEED_FOR_MAX = 1900f;

        private final int touchSlop;
        private final SharedPreferences preferences;

        private float maxMultiplier;
        private float downX;
        private float downY;
        private float lastRawY;
        private float virtualY;
        private long lastEventTime;
        private boolean verticalScroll;
        private float lastMultiplier = 1.0f;

        FastWebView(Context context) {
            super(context);
            touchSlop = ViewConfiguration.get(context).getScaledTouchSlop();
            preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
            maxMultiplier = clamp(
                    preferences.getFloat(KEY_SCROLL_SPEED, DEFAULT_SCROLL_SPEED),
                    MIN_SCROLL_SPEED,
                    MAX_SCROLL_SPEED
            );
        }

        float getMaxMultiplier() {
            return maxMultiplier;
        }

        void setMaxMultiplier(float value) {
            maxMultiplier = clamp(value, MIN_SCROLL_SPEED, MAX_SCROLL_SPEED);
            preferences.edit().putFloat(KEY_SCROLL_SPEED, maxMultiplier).apply();
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
                lastMultiplier = 1.0f;
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
                    float speed = Math.abs(rawDeltaY) * 1000f / dtMs;
                    float t = clamp01((speed - SPEED_START) / (SPEED_FOR_MAX - SPEED_START));
                    float eased = t * t * (3f - 2f * t);
                    lastMultiplier =
                            MIN_MULTIPLIER
                                    + (maxMultiplier - MIN_MULTIPLIER) * eased;
                } else {
                    lastMultiplier = 1.0f;
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

        private static float clamp01(float value) {
            return Math.max(0f, Math.min(1f, value));
        }

        private static float clamp(float value, float min, float max) {
            return Math.max(min, Math.min(max, value));
        }
    }
}
