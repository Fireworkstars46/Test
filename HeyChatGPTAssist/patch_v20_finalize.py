from pathlib import Path
p = Path('app/src/main/java/com/example/heychatgptassist/MainActivity.java')
s = p.read_text()
s = s.replace('Hey ChatGPT Assist v1.9', 'Hey ChatGPT Assist v2.0')
s = s.replace('downloads a ~429 MB Qwen2.5 0.5B model once', 'downloads a corrected ~353 MB Qwen2.5 0.5B model once')
s = s.replace('DOWNLOAD FREE LOCAL MODEL (~429 MB)', 'DOWNLOAD FREE LOCAL MODEL (~353 MB)')
s = s.replace(
    'The small animated voice bubble only exists while the local/API assistant popup is open. It disappears completely when the popup closes; nothing is left floating over games or other apps.',
    'The response card now sits above a separate Siri-style orb at the bottom of the screen. The orb only exists while the local/API assistant popup is open and disappears completely when you close it.')
s = s.replace(
    'No API credits or subscription needed. The first setup downloads a corrected ~353 MB Qwen2.5 0.5B model once, then answers are generated on your S22 itself.',
    'No API credits or subscription needed. v2.0 uses a corrected ~353 MB Qwen2.5 0.5B model because the v1.9 model could fail with UnsupportedArchitectureException. Download it once, then answers are generated on your S22 itself.')
p.write_text(s)

p = Path('app/build.gradle')
s = p.read_text()
if 'versionCode 19' not in s or 'versionName "1.9"' not in s:
    raise SystemExit('v2.0: expected v1.9 version fields not found')
s = s.replace('versionCode 19', 'versionCode 20', 1)
s = s.replace('versionName "1.9"', 'versionName "2.0"', 1)
p.write_text(s)
