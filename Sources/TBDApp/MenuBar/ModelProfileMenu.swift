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
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("Model Profile") {
            ModelProfileMenuContent()
                .environmentObject(appState)
        }
    }
}

/// Extracted into a `View` so SwiftUI re-renders the menu body when
/// `@Published` properties on `AppState` change. `Commands` bodies do not
/// always observe `@ObservedObject` mutations reliably for nested content.
private struct ModelProfileMenuContent: View {
    @EnvironmentObject var appState: AppState

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

    private static func formatRow(entry: ModelProfileWithUsage) -> String {
        entry.profile.name
    }
}
