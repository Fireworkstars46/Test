# iCloud Notes Web for Android

A lightweight Android WebView wrapper that opens https://www.icloud.com/notes/ in a dedicated app.

Features:
- Dedicated launcher icon
- JavaScript + DOM storage enabled
- Cookies and third-party cookies enabled for iCloud sign-in
- File chooser support
- Downloads to Android Downloads
- Back button navigates WebView history
- External non-web links open in their matching Android app
- Optimized WebView scrolling and hardware acceleration
- Android 16 safe-area handling so the iCloud header is not hidden under the status bar
- Native WebView momentum after release so scrolling keeps moving and gradually slows down
- v2.0 accelerates the actual touch coordinates WebView receives instead of adding a second fling afterward
- Slow movement stays near 1x while fast vertical finger movement ramps up to about 5.5x before WebView calculates its own native coast
- Permanent release signing supported from v1.2 onward

Package: com.fireworkstars46.icloudnotes
