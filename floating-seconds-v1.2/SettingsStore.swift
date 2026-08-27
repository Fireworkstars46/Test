import Foundation
import SwiftUI
import UIKit

final class SettingsStore: ObservableObject {
    private enum Key {
        static let showHours = "showHours"
        static let showMinutes = "showMinutes"
        static let showSeconds = "showSeconds"
        static let showAMPM = "showAMPM"
        static let use24Hour = "use24Hour"
        static let showDate = "showDate"
        static let textScale = "textScale"
        static let windowScale = "windowScale"
        static let borderWidth = "borderWidth"
        static let shape = "shape"
        static let fontWeight = "fontWeight"
        static let textColor = "textColor"
        static let backgroundColor = "backgroundColor"
        static let borderColor = "borderColor"
    }

    @Published var showHours: Bool { didSet { save(showHours, Key.showHours); keepOneTimePartEnabled() } }
    @Published var showMinutes: Bool { didSet { save(showMinutes, Key.showMinutes); keepOneTimePartEnabled() } }
    @Published var showSeconds: Bool { didSet { save(showSeconds, Key.showSeconds); keepOneTimePartEnabled() } }
    @Published var showAMPM: Bool { didSet { save(showAMPM, Key.showAMPM) } }
    @Published var use24Hour: Bool { didSet { save(use24Hour, Key.use24Hour) } }
    @Published var showDate: Bool { didSet { save(showDate, Key.showDate) } }
    @Published var textScale: Double { didSet { save(textScale, Key.textScale) } }
    @Published var windowScale: Double { didSet { save(windowScale, Key.windowScale) } }
    @Published var borderWidth: Double { didSet { save(borderWidth, Key.borderWidth) } }
    @Published var shape: ClockShape { didSet { save(shape.rawValue, Key.shape) } }
    @Published var fontWeight: ClockFontWeight { didSet { save(fontWeight.rawValue, Key.fontWeight) } }
    @Published var textColor: ClockColor { didSet { save(textColor.rawValue, Key.textColor) } }
    @Published var backgroundColor: ClockColor { didSet { save(backgroundColor.rawValue, Key.backgroundColor) } }
    @Published var borderColor: ClockColor { didSet { save(borderColor.rawValue, Key.borderColor) } }

    private var correctingTimeParts = false
    private let defaults = UserDefaults.standard

    init() {
        showHours = defaults.object(forKey: Key.showHours) as? Bool ?? true
        showMinutes = defaults.object(forKey: Key.showMinutes) as? Bool ?? true
        showSeconds = defaults.object(forKey: Key.showSeconds) as? Bool ?? true
        showAMPM = defaults.object(forKey: Key.showAMPM) as? Bool ?? true
        use24Hour = defaults.object(forKey: Key.use24Hour) as? Bool ?? false
        showDate = defaults.object(forKey: Key.showDate) as? Bool ?? false
        textScale = defaults.object(forKey: Key.textScale) as? Double ?? 0.78
        windowScale = defaults.object(forKey: Key.windowScale) as? Double ?? 1.0
        borderWidth = defaults.object(forKey: Key.borderWidth) as? Double ?? 0.0
        shape = ClockShape(rawValue: defaults.string(forKey: Key.shape) ?? "compact") ?? .compact
        fontWeight = ClockFontWeight(rawValue: defaults.string(forKey: Key.fontWeight) ?? "bold") ?? .bold
        textColor = ClockColor(rawValue: defaults.string(forKey: Key.textColor) ?? "white") ?? .white
        backgroundColor = ClockColor(rawValue: defaults.string(forKey: Key.backgroundColor) ?? "black") ?? .black
        borderColor = ClockColor(rawValue: defaults.string(forKey: Key.borderColor) ?? "white") ?? .white
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func keepOneTimePartEnabled() {
        guard !correctingTimeParts else { return }
        if !showHours && !showMinutes && !showSeconds {
            correctingTimeParts = true
            showSeconds = true
            correctingTimeParts = false
        }
    }

    func formattedTime(for date: Date = Date()) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour24 = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0

        var parts: [String] = []
        if showHours {
            if use24Hour {
                parts.append(String(format: "%02d", hour24))
            } else {
                let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
                parts.append(String(hour12))
            }
        }
        if showMinutes { parts.append(String(format: "%02d", minute)) }
        if showSeconds { parts.append(String(format: "%02d", second)) }

        var result = parts.joined(separator: ":")
        if showAMPM && !use24Hour && showHours {
            result += hour24 >= 12 ? " PM" : " AM"
        }
        if showDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d"
            result += "  " + formatter.string(from: date)
        }
        return result
    }

    var canvasSize: CGSize {
        let base = shape.pixelSize
        let scale = max(0.10, min(1.0, windowScale))
        return CGSize(width: max(2, base.width * scale), height: max(2, base.height * scale))
    }
}

enum ClockShape: String, CaseIterable, Identifiable {
    case pixelThin
    case ultraThin
    case statusBar
    case compact
    case wide
    case standard
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pixelThin: return "Pixel-thin 40:1"
        case .ultraThin: return "Ultra-thin 20:1"
        case .statusBar: return "Status-bar style 12:1"
        case .compact: return "Compact"
        case .wide: return "Wide"
        case .standard: return "16:9"
        case .square: return "Square"
        }
    }

    var pixelSize: CGSize {
        switch self {
        case .pixelThin: return CGSize(width: 800, height: 20)
        case .ultraThin: return CGSize(width: 800, height: 40)
        case .statusBar: return CGSize(width: 800, height: 66)
        case .compact: return CGSize(width: 800, height: 180)
        case .wide: return CGSize(width: 800, height: 260)
        case .standard: return CGSize(width: 640, height: 360)
        case .square: return CGSize(width: 480, height: 480)
        }
    }

    var aspectRatio: CGFloat { pixelSize.width / pixelSize.height }
}

enum ClockFontWeight: String, CaseIterable, Identifiable {
    case regular
    case semibold
    case bold

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var uiWeight: UIFont.Weight {
        switch self {
        case .regular: return .regular
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

enum ClockColor: String, CaseIterable, Identifiable {
    case white
    case black
    case gray
    case red
    case orange
    case yellow
    case green
    case cyan
    case blue
    case purple
    case pink

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var uiColor: UIColor {
        switch self {
        case .white: return .white
        case .black: return .black
        case .gray: return .systemGray
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .cyan: return .cyan
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        }
    }

    var swiftUIColor: Color { Color(uiColor) }
}
