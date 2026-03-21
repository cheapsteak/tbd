import SwiftUI
import TBDShared

@main
struct TBDAppMain: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("TBD", id: "main") {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            TBDCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
