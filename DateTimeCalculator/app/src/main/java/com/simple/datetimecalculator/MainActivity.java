package com.simple.datetimecalculator;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {
    private WebView webView;

    private static final String PAGE_FIX_SCRIPT =
            "(function(){" +
            "var style=document.createElement('style');" +
            "style.textContent='" +
            ".calcpage{overflow:hidden!important;padding-bottom:0!important;}" +
            ".calcpage .calcview{flex:1 1 auto!important;min-height:0!important;overflow-y:auto!important;overflow-x:hidden!important;}" +
            ".calcpage .subtabs{flex:0 0 42px!important;position:relative!important;left:auto!important;right:auto!important;bottom:auto!important;z-index:20!important;margin:10px 18px 11px!important;background:#eceaed!important;}" +
            ".calcpage #calc-time{min-height:0!important;overflow-y:auto!important;}" +
            ".calcpage #calc-time .time-tape{min-height:0!important;height:auto!important;}" +
            ".wheel{overscroll-behavior-y:contain!important;touch-action:pan-y!important;scroll-snap-type:y mandatory!important;-webkit-overflow-scrolling:touch;}" +
            ".wheel .opt{scroll-snap-stop:normal!important;}" +
            "';document.head.appendChild(style);" +
            "function relativeDay(id){" +
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
            "window.makeWheel=function(el,items,selected,onpick){" +
            "el.innerHTML='<div class=\"pad\"></div>'+items.map(function(x,i){return '<div class=\"opt\" data-i=\"'+i+'\">'+x+'</div>';}).join('')+'<div class=\"pad\"></div>';" +
            "var opts=Array.prototype.slice.call(el.querySelectorAll('.opt'));" +
            "var current=Math.max(0,Math.min(items.length-1,selected)),lastFired=current,raf=0,timer=0;" +
            "function mark(i,fire){i=Math.max(0,Math.min(items.length-1,i));current=i;for(var k=0;k<opts.length;k++)opts[k].classList.toggle('active',k===i);el.dataset.i=i;if(fire&&i!==lastFired){lastFired=i;onpick(i);}}" +
            "function center(i,behavior){var top=opts[i].offsetTop-(el.clientHeight-43)/2;try{el.scrollTo({top:top,behavior:behavior||'auto'});}catch(x){el.scrollTop=top;}}" +
            "requestAnimationFrame(function(){mark(current,false);center(current,'auto');});" +
            "el.addEventListener('scroll',function(){if(!raf){raf=requestAnimationFrame(function(){raf=0;var i=Math.round((el.scrollTop-0.5)/43);mark(i,false);});}clearTimeout(timer);timer=setTimeout(function(){var i=Math.round((el.scrollTop-0.5)/43);mark(i,true);},135);},{passive:true});" +
            "opts.forEach(function(o,i){o.addEventListener('click',function(){mark(i,true);center(i,'smooth');});});" +
            "return{select:function(i){mark(i,true);center(i,'smooth');}};" +
            "};" +
            "try{makeWheel=window.makeWheel;buildDateWheel();buildTimeWheel();buildMainDtWheel();buildCalcDtWheel();}catch(e){}" +
            "setInterval(function(){relativeDay('cDtFrom');relativeDay('cDtTo');},180);" +
            "})();";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        getWindow().setStatusBarColor(Color.rgb(247, 247, 247));
        getWindow().setNavigationBarColor(Color.WHITE);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING);
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);

        webView = new WebView(this);
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(true);
        settings.setBuiltInZoomControls(false);
        settings.setDisplayZoomControls(false);
        settings.setSupportZoom(false);
        settings.setTextZoom(100);

        webView.setBackgroundColor(Color.rgb(242, 242, 247));
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
                view.evaluateJavascript(PAGE_FIX_SCRIPT, null);
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
