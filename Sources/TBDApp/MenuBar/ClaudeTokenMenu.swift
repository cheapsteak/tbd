import SwiftUI
import AppKit
import TBDShared

/// Menu bar "Claude Token" submenu. Shows the keychain login fallback as
/// "Default (logged in)", followed by each stored token with its 5h / 7d
/// usage. The current global default has a checkmark. Selecting a row
/// updates the global default (affects new spawns only — running terminals
/// keep their resolved token).
///
/// Tab pre-selection in Settings is deferred — "Manage tokens…" simply
/// opens the Settings window and the user clicks the Claude Tokens tab.
struct ClaudeTokenMenu: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("Claude Token") {
            ClaudeTokenMenuContent()
                .environmentObject(appState)
        }
    }
}

/// Extracted into a `View` so SwiftUI re-renders the menu body when
/// `@Published` properties on `AppState` change. `Commands` bodies do not
/// always observe `@ObservedObject` mutations reliably for nested content.
private struct ClaudeTokenMenuContent: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // Default (keychain login fallback) row
        Button(action: {
            Task { @MainActor in
                await appState.setGlobalDefaultClaudeToken(id: nil)
            }
        }) {
            if appState.globalDefaultClaudeTokenID == nil {
                Label("Default (logged in)          —", systemImage: "checkmark")
            } else {
                Text("Default (logged in)")
            }
        }

        ForEach(appState.claudeTokens, id: \.token.id) { entry in
            let tokenID = entry.token.id
            Button(action: {
                Task { @MainActor in
                    await appState.setGlobalDefaultClaudeToken(id: tokenID)
                }
            }) {
                if appState.globalDefaultClaudeTokenID == tokenID {
                    Label(Self.formatRow(entry: entry), systemImage: "checkmark")
                } else {
                    Text(Self.formatRow(entry: entry))
                }
            }
        }

        Divider()

        Button("Manage tokens…") {
            NSApp.sendAction(
                Selector(("showSettingsWindow:")),
                to: nil,
                from: nil
            )
        }
    }

    /// Format a token row. Usage display is currently disabled (the
    /// `/api/oauth/usage` endpoint requires a `user:profile` scope that
    /// `claude setup-token` does not grant), so we render the bare name.
    private static func formatRow(entry: ClaudeTokenWithUsage) -> String {
        entry.token.name
    }
}
