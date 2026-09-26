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

    private IOSMomentumWebView webView;
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

        webView = new IOSMomentumWebView(this);
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

                view.evaluateJavascript(
                        "(function(){"
                                + "var styleId='s22-notes-scroll-tweaks';"
                                + "if(!document.getElementById(styleId)){"
                                + "var st=document.createElement('style');"
                                + "st.id=styleId;"
                                + "st.textContent='html,body,*{scroll-behavior:auto!important;}';"
                                + "document.documentElement.appendChild(st);"
                                + "}"
                                + "window.__s22MomentumRAF=0;"
                                + "window.__s22StopIOSMomentum=function(){"
                                + "if(window.__s22MomentumRAF){cancelAnimationFrame(window.__s22MomentumRAF);window.__s22MomentumRAF=0;}"
                                + "};"
                                + "window.__s22FindScrollable=function(x,y){"
                                + "function ok(el){"
                                + "if(!el||!el.getBoundingClientRect)return false;"
                                + "var cs=getComputedStyle(el), oy=cs.overflowY;"
                                + "return el.scrollHeight>el.clientHeight+24 && (oy==='auto'||oy==='scroll'||oy==='overlay');"
                                + "}"
                                + "var el=document.elementFromPoint(x,y), p=el;"
                                + "while(p&&p!==document.documentElement){if(ok(p))return p;p=p.parentElement;}"
                                + "var root=document.scrollingElement||document.documentElement;"
                                + "if(root.scrollHeight>root.clientHeight+24)return root;"
                                + "var all=document.querySelectorAll('*'),best=null,bestScore=0;"
                                + "for(var i=0;i<all.length;i++){"
                                + "var n=all[i];if(!ok(n))continue;"
                                + "var r=n.getBoundingClientRect();"
                                + "if(r.bottom<0||r.top>innerHeight||r.height<120)continue;"
                                + "var score=Math.min(r.height,innerHeight)*(n.scrollHeight-n.clientHeight);"
                                + "if(score>bestScore){best=n;bestScore=score;}"
                                + "}"
                                + "return best||root;"
                                + "};"
                                + "window.__s22StartIOSMomentum=function(vy,xPx,yPx){"
                                + "window.__s22StopIOSMomentum();"
                                + "var dpr=window.devicePixelRatio||1;"
                                + "var x=xPx/dpr,y=yPx/dpr;"
                                + "var el=window.__s22FindScrollable(x,y);"
                                + "if(!el)return;"
                                + "var root=document.scrollingElement||document.documentElement;"
                                + "var isRoot=(el===root||el===document.body||el===document.documentElement);"
                                + "var velocity=(-vy/dpr);"
                                + "var decay=0.9978;"
                                + "var last=performance.now();"
                                + "function getTop(){return isRoot?root.scrollTop:el.scrollTop;}"
                                + "function setTop(v){if(isRoot){root.scrollTop=v;}else{el.scrollTop=v;}}"
                                + "function maxTop(){return Math.max(0,(isRoot?root.scrollHeight-root.clientHeight:el.scrollHeight-el.clientHeight));}"
                                + "function step(now){"
                                + "var dt=Math.max(1,Math.min(34,now-last));last=now;"
                                + "if(Math.abs(velocity)<6){window.__s22MomentumRAF=0;return;}"
                                + "var old=getTop();"
                                + "var next=Math.max(0,Math.min(maxTop(),old+velocity*dt/1000));"
                                + "setTop(next);"
                                + "var actual=getTop();"
                                + "if(Math.abs(actual-old)<0.05&&(next<=0||next>=maxTop())){window.__s22MomentumRAF=0;return;}"
                                + "velocity*=Math.pow(decay,dt);"
                                + "window.__s22MomentumRAF=requestAnimationFrame(step);"
                                + "}"
                                + "window.__s22MomentumRAF=requestAnimationFrame(step);"
                                + "};"
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

    private static class IOSMomentumWebView extends WebView {
        private static final float MOMENTUM_THRESHOLD = 420f;
        private static final float MIN_VERTICAL_GESTURE_DP = 10f;

        private VelocityTracker velocityTracker;
        private float downX;
        private float downY;

        IOSMomentumWebView(Context context) {
            super(context);
        }

        @Override
        public boolean onTouchEvent(MotionEvent event) {
            int action = event.getActionMasked();

            if (action == MotionEvent.ACTION_DOWN) {
                evaluateJavascript(
                        "window.__s22StopIOSMomentum&&window.__s22StopIOSMomentum();",
                        null
                );
                recycleTracker();
                velocityTracker = VelocityTracker.obtain();
                downX = event.getX();
                downY = event.getY();
            }

            if (velocityTracker != null) {
                velocityTracker.addMovement(event);
            }

            if (action == MotionEvent.ACTION_UP && velocityTracker != null) {
                velocityTracker.computeCurrentVelocity(1000);

                float velocityY = velocityTracker.getYVelocity();
                float dx = event.getX() - downX;
                float dy = event.getY() - downY;
                float minDistance =
                        MIN_VERTICAL_GESTURE_DP * getResources().getDisplayMetrics().density;

                boolean verticalGesture =
                        Math.abs(dy) >= minDistance
                                && Math.abs(dy) > Math.abs(dx) * 1.05f;

                if (verticalGesture && Math.abs(velocityY) >= MOMENTUM_THRESHOLD) {
                    // Keep the normal 1:1 drag that already happened, but prevent
                    // WebView's Android fling from starting. The page then gets the
                    // iPhone-style momentum curve measured from the reference video.
                    MotionEvent cancel = MotionEvent.obtain(event);
                    cancel.setAction(MotionEvent.ACTION_CANCEL);
                    super.onTouchEvent(cancel);
                    cancel.recycle();

                    float x = event.getX();
                    float y = event.getY();
                    evaluateJavascript(
                            "window.__s22StartIOSMomentum&&window.__s22StartIOSMomentum("
                                    + velocityY + "," + x + "," + y + ");",
                            null
                    );

                    recycleTracker();
                    return true;
                }

                boolean handled = super.onTouchEvent(event);
                recycleTracker();
                return handled;
            }

            if (action == MotionEvent.ACTION_CANCEL) {
                recycleTracker();
            }

            return super.onTouchEvent(event);
        }

        private void recycleTracker() {
            if (velocityTracker != null) {
                velocityTracker.recycle();
                velocityTracker = null;
            }
        }
    }
}
