package com.example.heychatgptassist;

import android.accessibilityservice.AccessibilityService;
import android.view.accessibility.AccessibilityEvent;

public class AssistantAccessibilityService extends AccessibilityService {
    private static volatile AssistantAccessibilityService instance;

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        instance = this;
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        // No screen content is read. This service is only used to invoke the system Assistant action.
    }

    @Override
    public void onInterrupt() {
    }

    @Override
    public void onDestroy() {
        if (instance == this) instance = null;
        super.onDestroy();
    }

    public static boolean isConnected() {
        return instance != null;
    }

    public static boolean showAssistant() {
        AssistantAccessibilityService service = instance;
        return service != null && service.performGlobalAction(GLOBAL_ACTION_ASSIST);
    }
}
