from pathlib import Path

root = Path('FloatingSecondsBuildPayload/FloatingSeconds')

# ---------------- Settings ----------------
settings = root / 'SettingsStore.swift'
s = settings.read_text()

s = s.replace('static let backgroundMode = "secondsOnlyBackgroundModeV21"', 'static let backgroundMode = "secondsOnlyBackgroundModeV22"')
s = s.replace(
    '        static let backgroundOpacity = "secondsOnlyBackgroundOpacityV21"\n',
    '        static let backgroundOpacity = "secondsOnlyBackgroundOpacityV21"\n'
    '        static let autoMatchResponsiveness = "secondsOnlyAutoMatchResponsivenessV22"\n'
)
s = s.replace(
    '    @Published var backgroundOpacity: Double { didSet { save(backgroundOpacity, Key.backgroundOpacity) } }\n',
    '    @Published var backgroundOpacity: Double { didSet { save(backgroundOpacity, Key.backgroundOpacity) } }\n'
    '    @Published var autoMatchResponsiveness: Double { didSet { save(autoMatchResponsiveness, Key.autoMatchResponsiveness) } }\n'
)
s = s.replace(
    '        backgroundMode = ClockBackground(rawValue: defaults.string(forKey: Key.backgroundMode) ?? "white") ?? .white\n',
    '        backgroundMode = ClockBackground(rawValue: defaults.string(forKey: Key.backgroundMode) ?? "autoMatch") ?? .autoMatch\n'
)
s = s.replace(
    '        backgroundOpacity = defaults.object(forKey: Key.backgroundOpacity) as? Double ?? 1.0\n',
    '        backgroundOpacity = defaults.object(forKey: Key.backgroundOpacity) as? Double ?? 1.0\n'
    '        autoMatchResponsiveness = defaults.object(forKey: Key.autoMatchResponsiveness) as? Double ?? 0.72\n'
)
s = s.replace(
    '    case transparent, white, lightGray, gray, darkGray, black, customGray\n',
    '    case autoMatch, transparent, white, lightGray, gray, darkGray, black, customGray\n'
)
s = s.replace(
    '        switch self {\n        case .transparent: return "Transparent (iOS may show black)"\n',
    '        switch self {\n        case .autoMatch: return "Auto Match (screen scan)"\n        case .transparent: return "Transparent (iOS may show black)"\n'
)
s = s.replace(
    '        switch self {\n        case .transparent: return .clear\n',
    '        switch self {\n        case .autoMatch: return AutoMatchState.shared.currentColor\n        case .transparent: return .clear\n'
)
settings.write_text(s)

# ---------------- Auto-match receiver ----------------
auto = root / 'AutoMatch.swift'
auto.write_text(r'''import Foundation
import UIKit
import Network

extension Notification.Name {
    static let autoMatchColorDidChange = Notification.Name("FloatingSecondsAutoMatchColorDidChange")
}

final class AutoMatchState {
    static let shared = AutoMatchState()

    private let lock = NSLock()
    private var storedColor = UIColor.white

    private init() {}

    var currentColor: UIColor {
        lock.lock()
        defer { lock.unlock() }
        return storedColor
    }

    func update(red: UInt8, green: UInt8, blue: UInt8, responsiveness: Double) {
        let target = UIColor(
            red: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: 1.0
        )

        let amount = CGFloat(max(0.12, min(1.0, responsiveness)))
        lock.lock()
        let old = storedColor
        let blended = Self.blend(old, target, amount: amount)
        let changed = Self.distance(old, blended) > 0.012
        storedColor = blended
        lock.unlock()

        if changed {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .autoMatchColorDidChange, object: nil)
            }
        }
    }

    static func contrastingTextColor(for color: UIColor) -> UIColor {
        var r: CGFloat = 1
        var g: CGFloat = 1
        var b: CGFloat = 1
        var a: CGFloat = 1
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .black }

        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.42 ? .black : .white
    }

    private static func blend(_ from: UIColor, _ to: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 1, g1: CGFloat = 1, b1: CGFloat = 1, a1: CGFloat = 1
        var r2: CGFloat = 1, g2: CGFloat = 1, b2: CGFloat = 1, a2: CGFloat = 1
        guard from.getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              to.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return to }
        let inv = 1 - amount
        return UIColor(red: r1 * inv + r2 * amount,
                       green: g1 * inv + g2 * amount,
                       blue: b1 * inv + b2 * amount,
                       alpha: 1)
    }

    private static func distance(_ a: UIColor, _ b: UIColor) -> CGFloat {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        guard a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa),
              b.getRed(&br, green: &bg, blue: &bb, alpha: &ba) else { return 1 }
        return abs(ar - br) + abs(ag - bg) + abs(ab - bb)
    }
}

final class AutoMatchReceiver {
    static let shared = AutoMatchReceiver()

    private let queue = DispatchQueue(label: "FloatingSeconds.AutoMatchReceiver")
    private var listener: NWListener?
    private weak var settings: SettingsStore?

    private init() {}

    func start(settings: SettingsStore) {
        self.settings = settings
        guard listener == nil, let port = NWEndpoint.Port(rawValue: 49555) else { return }
        do {
            let listener = try NWListener(using: .udp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    print("Auto Match listener failed: \(error)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("Auto Match listener error: \(error)")
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self else { return }
            if let data, data.count >= 3 {
                let bytes = [UInt8](data.prefix(3))
                let responsiveness = self.settings?.autoMatchResponsiveness ?? 0.72
                AutoMatchState.shared.update(red: bytes[0], green: bytes[1], blue: bytes[2], responsiveness: responsiveness)
            }
            if error == nil, let connection {
                self.receive(on: connection)
            }
        }
    }
}
''')

# ---------------- Renderer ----------------
renderer = root / 'ClockRenderer.swift'
r = renderer.read_text()
r = r.replace(
    '        let attributesText: [NSAttributedString.Key: Any] = [\n            .font: font,\n            .foregroundColor: settings.textColor.uiColor\n        ]\n',
    '        let foregroundColor = settings.backgroundMode == .autoMatch\n'
    '            ? AutoMatchState.contrastingTextColor(for: background)\n'
    '            : settings.textColor.uiColor\n'
    '        let attributesText: [NSAttributedString.Key: Any] = [\n'
    '            .font: font,\n'
    '            .foregroundColor: foregroundColor\n'
    '        ]\n'
)
renderer.write_text(r)

# ---------------- PiP manager live refresh ----------------
pip = root / 'PiPClockManager.swift'
p = pip.read_text()
p = p.replace(
    '    private var settingsCancellable: AnyCancellable?\n',
    '    private var settingsCancellable: AnyCancellable?\n'
    '    private var autoMatchObserver: NSObjectProtocol?\n'
)
p = p.replace(
    '        configureAudioSession()\n        startClockTimer()\n',
    '        configureAudioSession()\n'
    '        AutoMatchReceiver.shared.start(settings: settings)\n'
    '        autoMatchObserver = NotificationCenter.default.addObserver(\n'
    '            forName: .autoMatchColorDidChange, object: nil, queue: .main\n'
    '        ) { [weak self] _ in\n'
    '            guard let self, self.settings.backgroundMode == .autoMatch else { return }\n'
    '            self.renderNow()\n'
    '        }\n'
    '        startClockTimer()\n'
)
p = p.replace(
    '        possibleObservation?.invalidate()\n    }\n',
    '        possibleObservation?.invalidate()\n'
    '        if let autoMatchObserver { NotificationCenter.default.removeObserver(autoMatchObserver) }\n'
    '    }\n',
    1
)
pip.write_text(p)

# ---------------- ReplayKit picker in main app ----------------
picker = root / 'BroadcastPicker.swift'
picker.write_text(r'''import SwiftUI
import ReplayKit

struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.showsMicrophoneButton = false
    }
}
''')

# ---------------- Main UI ----------------
content = root / 'ContentView.swift'
c = content.read_text()
section_start = c.index('                Section("Camouflage banner") {')
section_end = c.index('                Section("Size") {', section_start)
auto_section = r'''                Section("Auto background match") {
                    Picker("Banner mode", selection: Binding(
                        get: { settings.backgroundMode },
                        set: { value in settings.backgroundMode = value; refreshClock() }
                    )) {
                        ForEach(ClockBackground.allCases) { background in
                            Text(background.title).tag(background)
                        }
                    }

                    if settings.backgroundMode == .autoMatch {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Start / Stop screen scan")
                                Text("Tap the broadcast button and choose Floating Seconds Auto Match.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            BroadcastPickerButton()
                                .frame(width: 44, height: 44)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Match responsiveness")
                                Spacer()
                                Text("\(Int(settings.autoMatchResponsiveness * 100))%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: Binding(
                                get: { settings.autoMatchResponsiveness },
                                set: { settings.autoMatchResponsiveness = $0 }
                            ), in: 0.12...1.0, step: 0.02)
                        }

                        Text("While the iOS screen broadcast is running, the app samples the dominant color of the current screen several times per second. The banner follows that color and the seconds automatically switch between black and white for contrast.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("iOS will show its screen-recording/broadcast indicator while scanning. Auto Match cannot secretly read another app without that broadcast permission.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        if settings.backgroundMode == .customGray {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Custom brightness")
                                    Spacer()
                                    Text("\(Int(settings.backgroundBrightness * 100))%")
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: Binding(
                                    get: { settings.backgroundBrightness },
                                    set: { value in settings.backgroundBrightness = value; refreshClock() }
                                ), in: 0...1, step: 0.01)
                            }
                        }

                        if settings.backgroundMode != .transparent {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Banner opacity")
                                    Spacer()
                                    Text("\(Int(settings.backgroundOpacity * 100))%")
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: Binding(
                                    get: { settings.backgroundOpacity },
                                    set: { value in settings.backgroundOpacity = value; refreshClock() }
                                ), in: 0.05...1.0, step: 0.01)
                            }
                        }
                    }
                }

'''
c = c[:section_start] + auto_section + c[section_end:]

appearance_start = c.index('                Section("Number appearance") {')
appearance_end = c.index('                Section("Outside-app controls") {', appearance_start)
appearance = r'''                Section("Number appearance") {
                    if settings.backgroundMode == .autoMatch {
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

                    HStack {
                        Text("Banner")
                        Spacer()
                        Text(settings.backgroundMode.title)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("App border / padding")
                        Spacer()
                        Text("None")
                            .foregroundColor(.secondary)
                    }
                }

'''
c = c[:appearance_start] + appearance + c[appearance_end:]
content.write_text(c)

# ---------------- Broadcast upload extension ----------------
ext_dir = Path('FloatingSecondsBuildPayload/FloatingSecondsBroadcast')
ext_dir.mkdir(parents=True, exist_ok=True)

(ext_dir / 'SampleHandler.swift').write_text(r'''import ReplayKit
import Network
import CoreVideo
import Foundation

final class SampleHandler: RPBroadcastSampleHandler {
    private let sendQueue = DispatchQueue(label: "FloatingSeconds.AutoMatchSender")
    private var connection: NWConnection?
    private var lastScanTime: TimeInterval = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        connectIfNeeded()
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        connection?.cancel()
        connection = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScanTime >= 0.25 else { return }
        lastScanTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let rgb = dominantColor(in: pixelBuffer) else { return }
        send(rgb)
    }

    private func connectIfNeeded() {
        guard connection == nil, let port = NWEndpoint.Port(rawValue: 49555) else { return }
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .udp)
        connection.start(queue: sendQueue)
        self.connection = connection
    }

    private func send(_ rgb: (UInt8, UInt8, UInt8)) {
        connectIfNeeded()
        let data = Data([rgb.0, rgb.1, rgb.2])
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.connection?.cancel()
                self?.connection = nil
            }
        })
    }

    private func dominantColor(in pixelBuffer: CVPixelBuffer) -> (UInt8, UInt8, UInt8)? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 8, height > 8 else { return nil }

        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]

        func add(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
            let key = (Int(r >> 5) << 6) | (Int(g >> 5) << 3) | Int(b >> 5)
            var entry = bins[key] ?? (0, 0, 0, 0)
            entry.count += 1
            entry.r += Int(r)
            entry.g += Int(g)
            entry.b += Int(b)
            bins[key] = entry
        }

        let columns = 20
        let rows = 14

        if format == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<rows {
                let y = min(height - 1, max(0, Int(Double(height) * (0.07 + 0.86 * Double(row) / Double(rows - 1)))))
                for col in 0..<columns {
                    let x = min(width - 1, max(0, Int(Double(width) * (0.04 + 0.92 * Double(col) / Double(columns - 1)))))
                    let index = y * stride + x * 4
                    add(bytes[index + 2], bytes[index + 1], bytes[index])
                }
            }
        } else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                   format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                  CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
                  let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let yBytes = yBase.assumingMemoryBound(to: UInt8.self)
            let uvBytes = uvBase.assumingMemoryBound(to: UInt8.self)

            for row in 0..<rows {
                let y = min(height - 1, max(0, Int(Double(height) * (0.07 + 0.86 * Double(row) / Double(rows - 1)))))
                for col in 0..<columns {
                    let x = min(width - 1, max(0, Int(Double(width) * (0.04 + 0.92 * Double(col) / Double(columns - 1)))))
                    let yValue = Double(yBytes[y * yStride + x])
                    let uvIndex = (y / 2) * uvStride + (x / 2) * 2
                    let cb = Double(uvBytes[uvIndex]) - 128.0
                    let cr = Double(uvBytes[uvIndex + 1]) - 128.0

                    let r = yValue + 1.5748 * cr
                    let g = yValue - 0.1873 * cb - 0.4681 * cr
                    let b = yValue + 1.8556 * cb

                    func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, Int(v.rounded())))) }
                    add(clamp(r), clamp(g), clamp(b))
                }
            }
        } else {
            return nil
        }

        guard let winner = bins.values.max(by: { $0.count < $1.count }), winner.count > 0 else { return nil }
        return (UInt8(winner.r / winner.count), UInt8(winner.g / winner.count), UInt8(winner.b / winner.count))
    }
}
''')

(ext_dir / 'Info.plist').write_text(r'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Floating Seconds Auto Match</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.broadcast-services-upload</string>
        <key>NSExtensionPrincipalClass</key>
        <string>$(PRODUCT_MODULE_NAME).SampleHandler</string>
    </dict>
</dict>
</plist>
''')

# ---------------- XcodeGen project ----------------
project = Path('FloatingSecondsBuildPayload/project.yml')
y = project.read_text()
y = y.replace('MARKETING_VERSION: "2.1"', 'MARKETING_VERSION: "2.2"')
y = y.replace('CURRENT_PROJECT_VERSION: "12"', 'CURRENT_PROJECT_VERSION: "13"')

scheme_marker = '    scheme:\n      gatherCoverageData: false\n'
if scheme_marker not in y:
    raise SystemExit('App scheme marker not found in project.yml')
y = y.replace(
    scheme_marker,
    '    dependencies:\n'
    '      - target: FloatingSecondsBroadcast\n'
    '        embed: true\n'
    + scheme_marker,
    1
)

y += '''\n  FloatingSecondsBroadcast:\n    type: app-extension\n    platform: iOS\n    deploymentTarget: "16.0"\n    sources:\n      - path: FloatingSecondsBroadcast\n    info:\n      path: FloatingSecondsBroadcast/Info.plist\n    settings:\n      base:\n        PRODUCT_BUNDLE_IDENTIFIER: com.local.FloatingSeconds.AutoMatchBroadcast\n        PRODUCT_NAME: FloatingSecondsAutoMatch\n        MARKETING_VERSION: "2.2"\n        CURRENT_PROJECT_VERSION: "13"\n        TARGETED_DEVICE_FAMILY: "1"\n        SKIP_INSTALL: YES\n        APPLICATION_EXTENSION_API_ONLY: YES\n        CODE_SIGN_STYLE: Automatic\n'''
project.write_text(y)

print('Floating Seconds v2.2 Auto Match patch applied')
