Hey ChatGPT Assist — prototype v0.2
=================================

New in v0.2
-----------
The activation phrase is no longer hard-coded.

You can type any phrase in the app, for example:
  Hey ChatGPT
  ChatGPT
  Computer
  Assistant
  Hey computer

Tap "Save activation phrase", then "Start listening".

The phrase is stored on the phone and the foreground notification shows the
currently selected phrase.

Flow
----
Custom phrase
-> listener detects it
-> listener releases microphone
-> Android ACTION_ASSIST is triggered
-> Android opens the current default Digital assistant
-> if ChatGPT is the default assistant, ChatGPT should open

First test
----------
1. Set ChatGPT as Android's default Digital assistant.
2. Install/open this app.
3. Grant microphone and notification permissions.
4. Tap "Test default assistant".
5. Confirm ChatGPT opens.
6. Return to this app.
7. Enter the activation phrase you want.
8. Tap "Save activation phrase".
9. Tap "Start listening".
10. Leave the app and say your chosen phrase.

Known Android limitation
------------------------
Modern Android can restrict an ordinary app from launching an activity while
fully backgrounded. If the phrase is detected but ChatGPT does not appear,
the next build can use a visible overlay approach.

A Discord, phone, or other VoIP call may also already be using/prioritizing
the microphone, which can prevent this listener or ChatGPT Voice from hearing you.
