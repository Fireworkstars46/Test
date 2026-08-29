import Foundation
import SwiftUI
import UIKit

final class SettingsStore: ObservableObject {
    private enum Key {
        static let textScale = "secondsOnlyTextScaleV16"
        static let windowScale = "secondsOnlyWindowScale"
        static let shape = "secondsOnlyShape"
        static let fontWeight = "secondsOnlyFontWeight"
        static let textColor = "secondsOnlyTextColor"
        static let clockX = "secondsOnlyClockX"
        static let clockY = "secondsOnlyClockY"
    }

    @Published var textScale: Double { didSet { save(textScale, Key.textScale) } }
    @Published var windowScale: Double { didSet { save(windowScale, Key.windowScale) } }
    @Published var shape: ClockShape { didSet { save(shape.rawValue, Key.shape) } }
    @Published var fontWeight: ClockFontWeight { didSet { save(fontWeight.rawValue, Key.fontWeight) } }
    @Published var textColor: ClockColor { didSet { save(textColor.rawValue, Key.textColor) } }
    @Published var clockX: Double { didSet { save(clockX, Key.clockX) } }
    @Published var clockY: Double { didSet { save(clockY, Key.clockY) } }

    private let defaults = UserDefaults.standard

    init() {
        textScale = defaults.object(forKey: Key.textScale) as? Double
            ?? defaults.object(forKey: "textScale") as? Double
            ?? 1.20
        windowScale = defaults.object(forKey: Key.windowScale) as? Double
            ?? defaults.object(forKey: "windowScale") as? Double
            ?? 0.10
        shape = ClockShape(rawValue: defaults.string(forKey: Key.shape)
            ?? defaults.string(forKey: "shape")
            ?? "pixelThin") ?? .pixelThin
        fontWeight = ClockFontWeight(rawValue: defaults.string(forKey: Key.fontWeight)
            ?? defaults.string(forKey: "fontWeight")
            ?? "bold") ?? .bold
        textColor = ClockColor(rawValue: defaults.string(forKey: Key.textColor)
            ?? defaults.string(forKey: "textColor")
            ?? "white") ?? .white
        clockX = defaults.object(forKey: Key.clockX) as? Double
            ?? defaults.object(forKey: "clockX") as? Double
            ?? 0.0
        clockY = defaults.object(forKey: Key.clockY) as? Double
            ?? defaults.object(forKey: "clockY") as? Double
            ?? 0.0
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    func formattedSeconds(for date: Date = Date()) -> String {
        let second = Calendar.current.component(.second, from: date)
        return String(format: "%02d", second)
    }

    func resetPosition() {
        clockX = 0
        clockY = 0
    }

    var canvasSize: CGSize {
        shape.pixelSize
    }
}

enum ClockShape: String, CaseIterable, Identifiable {
    case pixelThin
    case ultraThin
    case statusBar
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pixelThin: return "Pixel-thin 40:1"
        case .ultraThin: return "Ultra-thin 20:1"
        case .statusBar: return "Status-bar style 12:1"
        case .compact: return "Compact 6:1"
        }
    }

    var pixelSize: CGSize {
        switch self {
        case .pixelThin: return CGSize(width: 800, height: 20)
        case .ultraThin: return CGSize(width: 800, height: 40)
        case .statusBar: return CGSize(width: 800, height: 66)
        case .compact: return CGSize(width: 800, height: 132)
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
