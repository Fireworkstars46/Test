from pathlib import Path

# prepare_v18.py builds Java source from Python strings. Fix two escape sequences
# that must remain escaped in Java 8 source.

p = Path('app/src/main/java/com/example/heychatgptassist/MainActivity.java')
s = p.read_text()
bad = '"\nNormal-popup detector: "'
good = r'"\nNormal-popup detector: "'
if bad not in s:
    raise SystemExit('MainActivity generated newline pattern not found')
s = s.replace(bad, good, 1)
p.write_text(s)

p = Path('app/src/main/java/com/example/heychatgptassist/WakeListenerService.java')
s = p.read_text()
bad = r'return rest.replaceFirst("^[\s,.:;!?-]+", "").trim();'
good = r'return rest.replaceFirst("^[\\s,.:;!?-]+", "").trim();'
if bad not in s:
    raise SystemExit('WakeListener generated regex pattern not found')
s = s.replace(bad, good, 1)
p.write_text(s)
