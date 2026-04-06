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
                Text("Default (logged in)          —")
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

    /// Format a token row as `name  5h NN% · 7d NN%`. Returns `—` placeholder
    /// when usage is nil or the token is an api_key (no usage available).
    private static func formatRow(entry: ClaudeTokenWithUsage) -> String {
        let name = entry.token.name
        guard entry.token.kind == .oauth, let usage = entry.usage else {
            return "\(name)          —"
        }
        let five = usage.fiveHourPct.map { String(format: "5h %2.0f%%", $0 * 100) } ?? "5h —"
        let seven = usage.sevenDayPct.map { String(format: "7d %2.0f%%", $0 * 100) } ?? "7d —"
        return "\(name)  \(five) · \(seven)"
    }
}
