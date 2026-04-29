import SwiftUI
import AppKit
import TBDShared

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        let worktreeName = detectWorktreeName()
        NSApp.applicationIconImage = generateAppIcon(worktreeName: worktreeName)
    }
}

@main
struct TBDAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("TBD", id: "main") {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            TBDCommands(appState: appState)
            ClaudeTokenMenu(appState: appState)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
