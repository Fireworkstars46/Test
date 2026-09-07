Hey ChatGPT Assist v0.3

Fix for Samsung test producing a sound but no assistant window:
- Replaces ordinary ACTION_ASSIST launch with AccessibilityService.performGlobalAction(GLOBAL_ACTION_ASSIST).
- This is closer to Android's system assistant button action.
- Adds a proper adaptive launcher icon.

First test:
1. Keep ChatGPT selected as Digital assistant.
2. Install/update Hey ChatGPT Assist.
3. Open it.
4. Tap Open Accessibility settings.
5. Find Hey ChatGPT Assist and enable it.
6. Return to the app.
7. Tap TEST SYSTEM ASSISTANT.
8. Only after ChatGPT appears, test voice listening.

The Accessibility service has canRetrieveWindowContent=false and is used only to invoke Show Assistant.
