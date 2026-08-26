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
    var appState: AppState
    /// Gated behind the same Settings → Fleet Automation opt-in as the sidebar
    /// control, so the whole Nightwatch feature (both entry points) is off by
    /// default. Fail-closed to hidden when the user has never opted in.
    @AppStorage(AppState.nightwatchExperimentalKey) private var experimentalEnabled: Bool = false

    private var title: String {
        switch appState.nightwatchMode {
        case .off: return "Nightwatch"
        case .daywatch: return "Nightwatch ◐"
        case .nightwatch: return "Nightwatch 🌙"
        }
    }

    var body: some Commands {
        if experimentalEnabled {
            CommandMenu(title) {
                NightwatchStatusContent()
                    .environment(appState)
            }
        }
    }
}

/// Extracted into a `View` so SwiftUI re-renders the menu body when the
/// `AppState` properties it reads change. A `Commands` body does not reliably
/// re-evaluate on state changes — that was true of `@ObservedObject` before and
/// is true of Observation now — so anything whose *rendering* depends on
/// `AppState` belongs in a nested `View` like this one.
///
/// The menu TITLE is the one read this cannot cover: `CommandMenu` needs the
/// string at `Commands` level. It has therefore always been best-effort, and
/// still is.
private struct NightwatchStatusContent: View {
    @Environment(AppState.self) var appState

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
