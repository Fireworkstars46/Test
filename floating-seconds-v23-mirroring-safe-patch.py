from pathlib import Path

root = Path('FloatingSecondsBuildPayload/FloatingSeconds')

# -------- Settings: add a mirroring-safe system Light/Dark auto mode --------
settings = root / 'SettingsStore.swift'
s = settings.read_text()

s = s.replace('secondsOnlyBackgroundModeV21', 'secondsOnlyBackgroundModeV23')
s = s.replace(
    'backgroundMode = ClockBackground(rawValue: defaults.string(forKey: Key.backgroundMode) ?? "white") ?? .white',
    'backgroundMode = ClockBackground(rawValue: defaults.string(forKey: Key.backgroundMode) ?? "systemAppearance") ?? .systemAppearance'
)
s = s.replace(
    'case transparent, white, lightGray, gray, darkGray, black, customGray',
    'case systemAppearance, transparent, white, lightGray, gray, darkGray, black, customGray'
)
s = s.replace(
    'switch self {\n        case .transparent: return "Transparent (iOS may show black)"',
    'switch self {\n        case .systemAppearance: return "Auto Light / Dark (mirroring safe)"\n        case .transparent: return "Transparent (iOS may show black)"'
)
s = s.replace(
    'switch self {\n        case .transparent: return .clear',
    'switch self {\n        case .systemAppearance:\n            let dark = UIScreen.main.traitCollection.userInterfaceStyle == .dark\n            return UIColor(white: dark ? 0.0 : 1.0, alpha: a)\n        case .transparent: return .clear'
)
settings.write_text(s)

# -------- Renderer: automatic black/white seconds in Auto Light/Dark --------
renderer = root / 'ClockRenderer.swift'
r = renderer.read_text()
r = r.replace(
    '        let attributesText: [NSAttributedString.Key: Any] = [\n            .font: font,\n            .foregroundColor: settings.textColor.uiColor\n        ]',
    '        let numberColor: UIColor\n        if settings.backgroundMode == .systemAppearance {\n            let dark = UIScreen.main.traitCollection.userInterfaceStyle == .dark\n            numberColor = dark ? .white : .black\n        } else {\n            numberColor = settings.textColor.uiColor\n        }\n        let attributesText: [NSAttributedString.Key: Any] = [\n            .font: font,\n            .foregroundColor: numberColor\n        ]'
)
renderer.write_text(r)

# -------- UI: explain safe auto mode and show automatic number color --------
content = root / 'ContentView.swift'
c = content.read_text()
c = c.replace('Picker("Banner color", selection:', 'Picker("Banner mode", selection:', 1)
c = c.replace(
    'Text("Default: white banner with black seconds. On Walmart and other white pages, the PiP interior should blend into the page so mostly the black seconds remain visible. iOS may still draw a faint rounded edge or shadow.")',
    'Text("Default: Auto Light / Dark. Light Mode uses a white banner with black seconds; Dark Mode uses a black banner with white seconds. This version does NOT screen-scan or use ReplayKit, so it will not take over or interrupt iPhone screen mirroring. Manual colors are still available above.")'
)

old_picker = '''                    Picker("Number color", selection: Binding(
                        get: { settings.textColor },
                        set: { value in
                            settings.textColor = value
                            refreshClock()
                        }
                    )) {
                        ForEach(ClockColor.allCases) { color in
                            HStack {
                                Circle().fill(color.swiftUIColor).frame(width: 12, height: 12)
                                Text(color.title)
                            }
                            .tag(color)
                        }
                    }
'''
new_picker = '''                    if settings.backgroundMode == .systemAppearance {
                        HStack {
                            Text("Number color")
                            Spacer()
                            Text("Automatic black / white")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Picker("Number color", selection: Binding(
                            get: { settings.textColor },
                            set: { value in
                                settings.textColor = value
                                refreshClock()
                            }
                        )) {
                            ForEach(ClockColor.allCases) { color in
                                HStack {
                                    Circle().fill(color.swiftUIColor).frame(width: 12, height: 12)
                                    Text(color.title)
                                }
                                .tag(color)
                            }
                        }
                    }
'''
if old_picker not in c:
    raise SystemExit('Number color picker marker not found')
c = c.replace(old_picker, new_picker, 1)

# Add a clear mirroring-safe note before outside-app controls.
marker = '                Section("Outside-app controls") {'
note = '''                Section("Mirroring-safe auto") {
                    Text("Auto Light / Dark only reads the iPhone system appearance. It does not start a screen recording or broadcast session, so AirPlay / screen mirroring remains available.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

'''
if marker not in c:
    raise SystemExit('Outside-app section marker not found')
c = c.replace(marker, note + marker, 1)
content.write_text(c)

# -------- Version --------
project = Path('FloatingSecondsBuildPayload/project.yml')
p = project.read_text()
p = p.replace('MARKETING_VERSION: "2.1"', 'MARKETING_VERSION: "2.3"')
p = p.replace('CURRENT_PROJECT_VERSION: "12"', 'CURRENT_PROJECT_VERSION: "14"')
project.write_text(p)

print('Floating Seconds v2.3 mirroring-safe Auto Light/Dark patch applied')
