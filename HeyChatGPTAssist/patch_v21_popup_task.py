from pathlib import Path
import re

# v2.1: keep popup activities in a separate transient task so waking the
# assistant never drags MainActivity out of Recents/background.
p = Path('app/src/main/AndroidManifest.xml')
s = p.read_text()

def isolate_activity(text, name):
    pat = rf'(<activity\s+android:name="\\.{name}"[^>]*)(/>)'
    m = re.search(pat, text, flags=re.S)
    if not m:
        raise SystemExit(f'v2.1: manifest activity {name} missing')
    head = m.group(1)
    # Drop any previous versions before adding our exact set.
    for attr in [
        'android:taskAffinity',
        'android:noHistory',
        'android:finishOnTaskLaunch',
        'android:excludeFromRecents'
    ]:
        head = re.sub(r'\s+' + re.escape(attr) + r'="[^"]*"', '', head)
    head += '\n            android:taskAffinity="com.example.heychatgptassist.popup"'
    head += '\n            android:noHistory="true"'
    head += '\n            android:finishOnTaskLaunch="true"'
    head += '\n            android:excludeFromRecents="true"'
    return text[:m.start()] + head + ' />' + text[m.end():]

s = isolate_activity(s, 'LocalModeActivity')
s = isolate_activity(s, 'SiriModeActivity')
p.write_text(s)

p = Path('app/src/main/java/com/example/heychatgptassist/WakeListenerService.java')
s = p.read_text()
popup_flags = ('Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_MULTIPLE_TASK | '
               'Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS | Intent.FLAG_ACTIVITY_NO_HISTORY')

# Only change our two popup launches; leave the normal ChatGPT/Shizuku path alone.
for cls in ('LocalModeActivity', 'SiriModeActivity'):
    marker = f'new Intent(this, {cls}.class);'
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit(f'v2.1: {cls} launch missing')
    add = s.find('open.addFlags(', pos)
    end = s.find(');', add)
    if add < 0 or end < 0:
        raise SystemExit(f'v2.1: {cls} flags missing')
    s = s[:add] + f'open.addFlags({popup_flags})' + s[end+1:]
p.write_text(s)

# When a popup closes (X, timeout, TTS completion, error), remove only its
# transient task and reveal whatever app was actually underneath.
for rel in [
    'app/src/main/java/com/example/heychatgptassist/LocalModeActivity.kt',
    'app/src/main/java/com/example/heychatgptassist/SiriModeActivity.java'
]:
    p = Path(rel)
    s = p.read_text()
    s = s.replace('finish()', 'finishAndRemoveTask()')
    p.write_text(s)

# Clearer migration wording: this is not a fresh inference failure; it means
# v1.9's old model is still installed and v2.0/v2.1's corrected model has not
# been downloaded yet.
p = Path('app/src/main/java/com/example/heychatgptassist/LocalModeActivity.kt')
s = p.read_text()
s = s.replace(
    '"v1.9\'s local model was incompatible. Open the helper and download the corrected ~353 MB v2.0 model."',
    '"The old v1.9 model is still installed. Download the corrected ~353 MB local model once from the helper, then Local AI will work."'
)
p.write_text(s)

p = Path('app/src/main/java/com/example/heychatgptassist/MainActivity.java')
s = p.read_text().replace('Hey ChatGPT Assist v2.0', 'Hey ChatGPT Assist v2.1')
p.write_text(s)

p = Path('app/build.gradle')
s = p.read_text()
if 'versionCode 20' not in s or 'versionName "2.0"' not in s:
    raise SystemExit('v2.1: expected v2.0 version fields missing')
s = s.replace('versionCode 20', 'versionCode 21', 1)
s = s.replace('versionName "2.0"', 'versionName "2.1"', 1)
p.write_text(s)
