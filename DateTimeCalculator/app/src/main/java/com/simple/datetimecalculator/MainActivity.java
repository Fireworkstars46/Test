package com.simple.datetimecalculator;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.View;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {
    private WebView webView;

    private static final String RELATIVE_DAY_SCRIPT =
            "(function(){" +
            "function fix(id){" +
            "var e=document.getElementById(id);if(!e)return;" +
            "var t=(e.textContent||'').trim();" +
            "if(!t||/^(Today|Tomorrow|Yesterday) at /.test(t))return;" +
            "var m=t.match(/^(.*) at (.*)$/);if(!m)return;" +
            "var d=new Date(m[1]);if(isNaN(d.getTime()))return;" +
            "var n=new Date();" +
            "var a=Date.UTC(n.getFullYear(),n.getMonth(),n.getDate());" +
            "var b=Date.UTC(d.getFullYear(),d.getMonth(),d.getDate());" +
            "var diff=Math.round((b-a)/86400000);" +
            "var label=diff===0?'Today':diff===1?'Tomorrow':diff===-1?'Yesterday':null;" +
            "if(label)e.textContent=label+' at '+m[2];" +
            "}" +
            "setInterval(function(){fix('cDtFrom');fix('cDtTo');},100);" +
            "})();";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        getWindow().setStatusBarColor(Color.rgb(247, 247, 247));
        getWindow().setNavigationBarColor(Color.WHITE);
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);

        webView = new WebView(this);
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(true);
        settings.setBuiltInZoomControls(false);
        settings.setDisplayZoomControls(false);
        settings.setTextZoom(100);

        webView.setBackgroundColor(Color.rgb(242, 242, 247));
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
                view.evaluateJavascript(RELATIVE_DAY_SCRIPT, null);
            }
        });
        webView.loadUrl("file:///android_asset/index.html");
        setContentView(webView);
    }

    @Override
    protected void onDestroy() {
        if (webView != null) {
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }
}
