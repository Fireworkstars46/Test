import SwiftUI
import UIKit

extension Notification.Name {
    static let floatingSecondsExternalCommand = Notification.Name("FloatingSecondsExternalCommand")
}

final class FloatingSecondsAppDelegate: NSObject, UIApplicationDelegate {
    static let startCommand = "com.local.FloatingSeconds.start"
    static let stopCommand = "com.local.FloatingSeconds.stop"
    static var pendingCommand: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let shortcut = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            Self.pendingCommand = shortcut.type
            return false
        }
        return true
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Self.pendingCommand = nil
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .floatingSecondsExternalCommand,
                object: shortcutItem.type
            )
        }
        completionHandler(true)
    }
}

@main
struct FloatingSecondsApp: App {
    @UIApplicationDelegateAdaptor(FloatingSecondsAppDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsStore
    @StateObject private var pipManager: PiPClockManager

    init() {
        let store = SettingsStore()
        _settings = StateObject(wrappedValue: store)
        _pipManager = StateObject(wrappedValue: PiPClockManager(settings: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(pipManager)
                .onAppear {
                    if let command = FloatingSecondsAppDelegate.pendingCommand {
                        FloatingSecondsAppDelegate.pendingCommand = nil
                        handleExternalCommand(command)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .floatingSecondsExternalCommand)) { notification in
                    if let command = notification.object as? String {
                        handleExternalCommand(command)
                    }
                }
                .onOpenURL { url in
                    guard url.scheme?.lowercased() == "floatingseconds" else { return }
                    let command = (url.host ?? url.path).lowercased()
                    handleExternalCommand(command)
                }
        }
    }

    private func handleExternalCommand(_ command: String) {
        let normalized = command.lowercased()
        if normalized == FloatingSecondsAppDelegate.stopCommand.lowercased() || normalized.contains("stop") {
            pipManager.stopPiP()
            return
        }

        if normalized == FloatingSecondsAppDelegate.startCommand.lowercased() || normalized.contains("start") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                pipManager.startPiP()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !pipManager.isPiPActive {
                    pipManager.startPiP()
                }
            }
        }
    }
}
