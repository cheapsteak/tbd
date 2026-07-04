import SwiftUI
import AppKit
import TBDShared

/// Menu bar "Nightwatch" menu. Displays the current nightwatch mode and
/// allows toggling between off, daywatch, and nightwatch modes. Three
/// affordances: "Step out" → daywatch, "Go away" → nightwatch, "I'm back" → off.
///
/// The menu TITLE carries the active mode (🌙 / ◐) so "am I being watched?"
/// is answerable at a glance without opening the menu.
struct NightwatchStatusItem: Commands {
    @ObservedObject var appState: AppState

    private var title: String {
        switch appState.nightwatchMode {
        case .off: return "Nightwatch"
        case .daywatch: return "Nightwatch ◐"
        case .nightwatch: return "Nightwatch 🌙"
        }
    }

    var body: some Commands {
        CommandMenu(title) {
            NightwatchStatusContent()
                .environmentObject(appState)
        }
    }
}

/// Extracted into a `View` so SwiftUI re-renders the menu body when
/// `@Published` properties on `AppState` change. `Commands` bodies do not
/// always observe `@ObservedObject` mutations reliably for nested content.
private struct NightwatchStatusContent: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        modeButton("I'm back", mode: .off)
        modeButton("Step out", mode: .daywatch)
        modeButton("Go away for the night", mode: .nightwatch)
    }

    @ViewBuilder
    private func modeButton(_ label: String, mode: NightwatchMode) -> some View {
        Button(action: {
            Task { @MainActor in
                await appState.setNightwatchMode(mode)
            }
        }) {
            if appState.nightwatchMode == mode {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }
}
