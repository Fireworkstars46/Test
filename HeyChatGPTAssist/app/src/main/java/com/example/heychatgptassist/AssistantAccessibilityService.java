package com.example.heychatgptassist;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

public final class AssistantAccessibilityService {
    private static final String CHATGPT_PACKAGE = "com.openai.chatgpt";
    private static final String CHATGPT_ASSISTANT_ACTIVITY = "com.openai.voice.assistant.AssistantActivity";

    private AssistantAccessibilityService() {}

    public static boolean showAssistant(Context context) {
        try {
            Intent direct = new Intent();
            direct.setComponent(new ComponentName(CHATGPT_PACKAGE, CHATGPT_ASSISTANT_ACTIVITY));
            direct.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            context.startActivity(direct);
            return true;
        } catch (Throwable directError) {
            try {
                Intent fallback = new Intent(Intent.ACTION_VIEW, Uri.parse("https://chat.com/?mode=voice"));
                fallback.setPackage(CHATGPT_PACKAGE);
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
                context.startActivity(fallback);
                return true;
            } catch (Throwable packageFallbackError) {
                try {
                    Intent browserFallback = new Intent(Intent.ACTION_VIEW, Uri.parse("https://chat.com/?mode=voice"));
                    browserFallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    context.startActivity(browserFallback);
                    return true;
                } catch (Throwable ignored) {
                    return false;
                }
            }
        }
    }
}
