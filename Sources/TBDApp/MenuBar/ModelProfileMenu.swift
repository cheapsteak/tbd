import SwiftUI
import AppKit
import TBDShared

/// Menu bar "Model Profile" submenu. Shows the keychain login fallback as
/// "Default (logged in)", followed by each stored profile. The current
/// global default has a checkmark. Selecting a row updates the global
/// default (affects new spawns only — running terminals keep their
/// resolved profile).
///
/// Tab pre-selection in Settings is deferred — "Manage profiles…" simply
/// opens the Settings window and the user clicks the Model Profiles tab.
struct ModelProfileMenu: Commands {
    var appState: AppState

    var body: some Commands {
        CommandMenu("Model Profile") {
            ModelProfileMenuContent()
                .environment(appState)
        }
    }
}

/// Extracted into a `View` so SwiftUI re-renders the menu body when the
/// `AppState` properties it reads change. A `Commands` body does not reliably
/// re-evaluate on state changes — that was true of `@ObservedObject` before and
/// is true of Observation now — so anything whose *rendering* depends on
/// `AppState` belongs in a nested `View` like this one.
private struct ModelProfileMenuContent: View {
    @Environment(AppState.self) var appState

    var body: some View {
        Button(action: {
            Task { @MainActor in
                await appState.setDefaultProfile(id: nil)
            }
        }) {
            if appState.defaultProfileID == nil {
                Label("Default (logged in)          —", systemImage: "checkmark")
            } else {
                Text("Default (logged in)")
            }
        }

        ForEach(appState.modelProfiles, id: \.profile.id) { entry in
            let profileID = entry.profile.id
            Button(action: {
                Task { @MainActor in
                    await appState.setDefaultProfile(id: profileID)
                }
            }) {
                if appState.defaultProfileID == profileID {
                    Label(Self.formatRow(entry: entry), systemImage: "checkmark")
                } else {
                    Text(Self.formatRow(entry: entry))
                }
            }
        }

        Divider()

        Button("Manage profiles…") {
            NSApp.sendAction(
                Selector(("showSettingsWindow:")),
                to: nil,
                from: nil
            )
        }
    }

    /// Profile name plus a short login-identity suffix (" — email" /
    /// " — needs /login") for oauth profiles; bare name for other kinds.
    private static func formatRow(entry: ModelProfileWithUsage) -> String {
        ProfileLoginPresentation.menuItemTitle(for: entry)
    }
}
