package com.fireworkstars46.icloudnotes;

import android.app.Activity;
import android.app.DownloadManager;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
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
import android.widget.Toast;

public class MainActivity extends Activity {
    private static final String START_URL = "https://www.icloud.com/notes/";
    private static final int FILE_CHOOSER_REQUEST = 401;

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

                // Avoid CSS smooth-scroll fighting Android's own touch/fling physics.
                view.evaluateJavascript(
                        "(function(){"
                                + "var id='s22-notes-scroll-tweaks';"
                                + "if(!document.getElementById(id)){"
                                + "var s=document.createElement('style');"
                                + "s.id=id;"
                                + "s.textContent='html,body,*{scroll-behavior:auto!important;overscroll-behavior:none!important;}';"
                                + "document.documentElement.appendChild(s);"
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
        // Slow finger movement stays controllable, while fast movement becomes very sensitive.
        private static final float MIN_DRAG_MULTIPLIER = 1.35f;
        private static final float MAX_DRAG_MULTIPLIER = 4.75f;
        private static final float SPEED_FOR_MAX_MULTIPLIER = 2600f;

        // A fast release gets a strong but still smooth WebView fling.
        private static final float CUSTOM_FLING_THRESHOLD = 950f;
        private static final float FLING_MULTIPLIER = 4.1f;
        private static final int MAX_FLING_VELOCITY = 65000;
        private static final float MIN_GESTURE_DP = 22f;

        private VelocityTracker velocityTracker;
        private float rawDownX;
        private float rawDownY;
        private float lastRawY;
        private float virtualY;
        private long lastEventTime;

        FastWebView(Context context) {
            super(context);
        }

        @Override
        public boolean onTouchEvent(MotionEvent event) {
            final int action = event.getActionMasked();
            MotionEvent transformed = MotionEvent.obtain(event);

            if (action == MotionEvent.ACTION_DOWN) {
                recycleTracker();
                velocityTracker = VelocityTracker.obtain();
                velocityTracker.addMovement(event);

                rawDownX = event.getX();
                rawDownY = event.getY();
                lastRawY = rawDownY;
                virtualY = rawDownY;
                lastEventTime = event.getEventTime();

                transformed.setLocation(event.getX(), virtualY);
                boolean handled = super.onTouchEvent(transformed);
                transformed.recycle();
                return handled;
            }

            if (velocityTracker != null) {
                velocityTracker.addMovement(event);
            }

            if (action == MotionEvent.ACTION_MOVE) {
                long now = event.getEventTime();
                long dtMs = Math.max(1L, now - lastEventTime);
                float rawDeltaY = event.getY() - lastRawY;
                float instantaneousSpeed = Math.abs(rawDeltaY) * 1000f / dtMs;

                float t = Math.min(1f, instantaneousSpeed / SPEED_FOR_MAX_MULTIPLIER);
                // Ease the multiplier upward so it feels smooth rather than switching modes.
                float eased = t * t * (3f - 2f * t);
                float multiplier =
                        MIN_DRAG_MULTIPLIER
                                + (MAX_DRAG_MULTIPLIER - MIN_DRAG_MULTIPLIER) * eased;

                virtualY += rawDeltaY * multiplier;
                transformed.setLocation(event.getX(), virtualY);

                lastRawY = event.getY();
                lastEventTime = now;

                boolean handled = super.onTouchEvent(transformed);
                transformed.recycle();
                return handled;
            }

            if (action == MotionEvent.ACTION_UP && velocityTracker != null) {
                velocityTracker.computeCurrentVelocity(1000);

                float velocityY = velocityTracker.getYVelocity();
                float dx = event.getX() - rawDownX;
                float dy = event.getY() - rawDownY;
                float minGesture =
                        MIN_GESTURE_DP * getResources().getDisplayMetrics().density;

                boolean verticalGesture =
                        Math.abs(dy) >= minGesture
                                && Math.abs(dy) > Math.abs(dx) * 1.10f;

                if (verticalGesture && Math.abs(velocityY) >= CUSTOM_FLING_THRESHOLD) {
                    // Cancel WebView's ordinary slow fling, then start a much faster native
                    // WebView fling. flingScroll stays animated/smooth instead of jumping.
                    transformed.setAction(MotionEvent.ACTION_CANCEL);
                    transformed.setLocation(event.getX(), virtualY);
                    super.onTouchEvent(transformed);

                    int boostedVelocity = clamp(
                            Math.round(-velocityY * FLING_MULTIPLIER),
                            -MAX_FLING_VELOCITY,
                            MAX_FLING_VELOCITY
                    );

                    post(() -> flingScroll(0, boostedVelocity));

                    transformed.recycle();
                    recycleTracker();
                    return true;
                }

                transformed.setLocation(event.getX(), virtualY);
                boolean handled = super.onTouchEvent(transformed);
                transformed.recycle();
                recycleTracker();
                return handled;
            }

            if (action == MotionEvent.ACTION_CANCEL) {
                recycleTracker();
            }

            transformed.setLocation(event.getX(), virtualY);
            boolean handled = super.onTouchEvent(transformed);
            transformed.recycle();
            return handled;
        }

        private void recycleTracker() {
            if (velocityTracker != null) {
                velocityTracker.recycle();
                velocityTracker = null;
            }
        }

        private static int clamp(int value, int min, int max) {
            return Math.max(min, Math.min(max, value));
        }
    }
}
