from pathlib import Path

root = Path('FloatingSecondsBuildPayload/FloatingSeconds')

settings = root / 'SettingsStore.swift'
s = settings.read_text()
s = s.replace(
    '        static let clockX = "secondsOnlyClockX"\n',
    '        static let clockX = "secondsOnlyClockX"\n'
    '        static let backgroundMode = "secondsOnlyBackgroundMode"\n'
    '        static let backgroundBrightness = "secondsOnlyBackgroundBrightness"\n'
    '        static let backgroundOpacity = "secondsOnlyBackgroundOpacity"\n'
)
s = s.replace(
    '    @Published var clockX: Double { didSet { save(clockX, Key.clockX) } }\n',
    '    @Published var clockX: Double { didSet { save(clockX, Key.clockX) } }\n'
    '    @Published var backgroundMode: ClockBackground { didSet { save(backgroundMode.rawValue, Key.backgroundMode) } }\n'
    '    @Published var backgroundBrightness: Double { didSet { save(backgroundBrightness, Key.backgroundBrightness) } }\n'
    '    @Published var backgroundOpacity: Double { didSet { save(backgroundOpacity, Key.backgroundOpacity) } }\n'
)
s = s.replace(
    '        clockX = defaults.object(forKey: Key.clockX) as? Double ?? 0.0\n',
    '        clockX = defaults.object(forKey: Key.clockX) as? Double ?? 0.0\n'
    '        backgroundMode = ClockBackground(rawValue: defaults.string(forKey: Key.backgroundMode) ?? "white") ?? .white\n'
    '        backgroundBrightness = defaults.object(forKey: Key.backgroundBrightness) as? Double ?? 0.95\n'
    '        backgroundOpacity = defaults.object(forKey: Key.backgroundOpacity) as? Double ?? 1.0\n'
)
s += '''\n\nenum ClockBackground: String, CaseIterable, Identifiable {\n    case transparent, white, lightGray, gray, darkGray, black, customGray\n    var id: String { rawValue }\n    var title: String {\n        switch self {\n        case .transparent: return "Transparent (iOS may show black)"\n        case .white: return "White"\n        case .lightGray: return "Light gray"\n        case .gray: return "Gray"\n        case .darkGray: return "Dark gray"\n        case .black: return "Black"\n        case .customGray: return "Custom gray"\n        }\n    }\n    func uiColor(customBrightness: Double, opacity: Double) -> UIColor {\n        let a = CGFloat(max(0.0, min(1.0, opacity)))\n        switch self {\n        case .transparent: return .clear\n        case .white: return UIColor(white: 1.0, alpha: a)\n        case .lightGray: return UIColor(white: 0.85, alpha: a)\n        case .gray: return UIColor(white: 0.55, alpha: a)\n        case .darkGray: return UIColor(white: 0.22, alpha: a)\n        case .black: return UIColor(white: 0.0, alpha: a)\n        case .customGray: return UIColor(white: CGFloat(max(0.0, min(1.0, customBrightness))), alpha: a)\n        }\n    }\n}\n'''
settings.write_text(s)

renderer = root / 'ClockRenderer.swift'
r = renderer.read_text()
r = r.replace(
    '        context.clear(canvasRect)\n',
    '        context.clear(canvasRect)\n\n'
    '        let background = settings.backgroundMode.uiColor(customBrightness: settings.backgroundBrightness, opacity: settings.backgroundOpacity)\n'
    '        if background.cgColor.alpha > 0 {\n'
    '            context.setFillColor(background.cgColor)\n'
    '            context.fill(canvasRect)\n'
    '        }\n'
)
renderer.write_text(r)

content = root / 'ContentView.swift'
c = content.read_text()
marker = '                Section("Size") {'
camouflage = '''                Section("Camouflage background") {\n                    Picker("Background", selection: Binding(\n                        get: { settings.backgroundMode },\n                        set: { value in settings.backgroundMode = value; refreshClock() }\n                    )) {\n                        ForEach(ClockBackground.allCases) { background in\n                            Text(background.title).tag(background)\n                        }\n                    }\n\n                    if settings.backgroundMode == .customGray {\n                        VStack(alignment: .leading, spacing: 8) {\n                            HStack {\n                                Text("Custom brightness")\n                                Spacer()\n                                Text("\\(Int(settings.backgroundBrightness * 100))%")\n                                    .foregroundColor(.secondary)\n                            }\n                            Slider(value: Binding(\n                                get: { settings.backgroundBrightness },\n                                set: { value in settings.backgroundBrightness = value; refreshClock() }\n                            ), in: 0...1, step: 0.01)\n                        }\n                    }\n\n                    if settings.backgroundMode != .transparent {\n                        VStack(alignment: .leading, spacing: 8) {\n                            HStack {\n                                Text("Background opacity")\n                                Spacer()\n                                Text("\\(Int(settings.backgroundOpacity * 100))%")\n                                    .foregroundColor(.secondary)\n                            }\n                            Slider(value: Binding(\n                                get: { settings.backgroundOpacity },\n                                set: { value in settings.backgroundOpacity = value; refreshClock() }\n                            ), in: 0.05...1.0, step: 0.01)\n                        }\n                    }\n\n                    Text("White is best for Walmart/Safari light pages; Black for dark apps. Custom gray and opacity let you tune the match. iOS may still leave a rounded edge or shadow.")\n                        .font(.caption)\n                        .foregroundColor(.secondary)\n                }\n\n'''
if marker not in c:
    raise SystemExit('Size section marker not found')
c = c.replace(marker, camouflage + marker, 1)
c = c.replace(
    '                    HStack {\n                        Text("Background")\n                        Spacer()\n                        Text("Transparent")\n                            .foregroundColor(.secondary)\n                    }\n',
    '                    HStack {\n                        Text("Background")\n                        Spacer()\n                        Text(settings.backgroundMode.title)\n                            .foregroundColor(.secondary)\n                    }\n',
    1
)
content.write_text(c)

project = Path('FloatingSecondsBuildPayload/project.yml')
p = project.read_text()
p = p.replace('MARKETING_VERSION: "1.0"', 'MARKETING_VERSION: "2.0"')
p = p.replace('CURRENT_PROJECT_VERSION: "1"', 'CURRENT_PROJECT_VERSION: "11"')
project.write_text(p)

print('Camouflage patch applied')
