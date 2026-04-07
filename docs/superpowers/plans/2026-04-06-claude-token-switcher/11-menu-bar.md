# Phase 11: Menu Bar Claude Token Submenu

> **Parent plan:** [../2026-04-06-claude-token-switcher.md](../2026-04-06-claude-token-switcher.md)
> **Depends on:** Phase 08
> **Unblocks:** nothing

**Scope:** Add a "Claude Token" section to the app menu bar showing each stored token with its 5h/7d usage, a checkmark on the current global default, and a "Manage tokens…" link into Settings. Selecting a row updates the global default (affects new spawns only).

## Context

The app uses SwiftUI `CommandMenu` for menu bar items, wired in `Sources/TBDApp/TBDApp.swift` via `TBDCommands(appState: appState)` inside `.commands { ... }`. Existing menus live in `Sources/TBDApp/Helpers/KeyboardShortcuts.swift` (`TBDCommands: Commands` with `@ObservedObject var appState: AppState`). They use plain `Button { ... }` with optional `.keyboardShortcut`, no checkmarks.

Phase 08 already added `appState.claudeTokens: [ClaudeToken]`, `appState.globalDefaultClaudeTokenID: String?`, and `appState.setGlobalDefaultClaudeToken(id:)`. Each token is assumed to expose optional `usage5h: Double?` and `usage7d: Double?` (percentages 0–100); render `—` when nil.

`CommandMenu`'s body re-evaluates when its enclosing `Commands` struct's observed state changes — `TBDCommands` already uses `@ObservedObject var appState`, so adding bindings to `appState.claudeTokens` / `appState.globalDefaultClaudeTokenID` will reactively update the menu without further wrapping.

For "Manage tokens…": SwiftUI provides no documented way to pre-select a Settings tab from a `Button` action. Use `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` (the macOS 13+ selector) and let the user click the Claude Tokens tab. If a `SettingsLink` pattern already exists elsewhere, prefer that.

## Tasks

### Task 1: Create `ClaudeTokenMenu.swift`

Create `Sources/TBDApp/MenuBar/ClaudeTokenMenu.swift` with a `ClaudeTokenMenu: Commands` struct:

```swift
import SwiftUI
import TBDShared

struct ClaudeTokenMenu: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("Claude Token") {
            // Default (logged in) row
            Button(action: {
                Task { @MainActor in
                    appState.setGlobalDefaultClaudeToken(id: nil)
                }
            }) {
                Label(
                    "Default (logged in)          —",
                    systemImage: appState.globalDefaultClaudeTokenID == nil
                        ? "checkmark"
                        : ""
                )
            }

            ForEach(appState.claudeTokens, id: \.id) { token in
                Button(action: {
                    let id = token.id
                    Task { @MainActor in
                        appState.setGlobalDefaultClaudeToken(id: id)
                    }
                }) {
                    Label(
                        Self.formatRow(token: token),
                        systemImage: appState.globalDefaultClaudeTokenID == token.id
                            ? "checkmark"
                            : ""
                    )
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
    }

    private static func formatRow(token: ClaudeToken) -> String {
        let five = token.usage5h.map { String(format: "5h %2.0f%%", $0) } ?? "5h —"
        let seven = token.usage7d.map { String(format: "7d %2.0f%%", $0) } ?? "7d —"
        return "\(token.name)  \(five) · \(seven)"
    }
}
```

Adjust property names (`usage5h`, `usage7d`, `name`, `id`) to match the actual `ClaudeToken` model from Phase 08. If usage fields differ, mirror them here.

### Task 2: Verify `mkdir` of `MenuBar` directory

`Sources/TBDApp/MenuBar/` likely does not exist yet. Confirm with `ls Sources/TBDApp` and create the directory before writing the file. SPM picks it up automatically (no Package.swift edit needed).

### Task 3: Wire menu into `TBDApp.swift`

Edit `Sources/TBDApp/TBDApp.swift`. In the `.commands { ... }` block, add `ClaudeTokenMenu(appState: appState)` after `TBDCommands(appState: appState)`:

```swift
.commands {
    TBDCommands(appState: appState)
    ClaudeTokenMenu(appState: appState)
}
```

### Task 4: Confirm reactivity assumption

After build, open the running app, change the global default via the Settings UI (Phase 09/10), then open the menu bar — the checkmark should reflect the new default without restarting. If it doesn't, the body isn't observing changes; fix by extracting the menu contents into a small `View` with `@EnvironmentObject var appState: AppState` and rendering it inside the `CommandMenu`. (This is the documented escape hatch for `Commands` reactivity.)

### Task 5: Verify "Manage tokens…" opens Settings

Click "Manage tokens…" from the menu bar. The Settings window should appear. Pre-selecting the Claude Tokens tab is out of scope — note in a code comment that tab pre-selection is deferred.

### Task 6: Build

Run `swift build`. Fix any property-name mismatches against the actual `ClaudeToken` model. The menu must compile cleanly.

### Task 7: Manual verification

1. Launch the app, open the **Claude Token** menu in the menu bar.
2. Confirm "Default (logged in)" has a checkmark on first launch (no global default).
3. Confirm each stored token appears with `name  5h NN% · 7d NN%` (or `—` placeholders if usage is unavailable).
4. Select a non-default token. Reopen the menu — the checkmark should move.
5. Spawn a **new** Claude terminal in a worktree with no override; spot-check that its environment uses the newly-selected token (e.g. `echo $ANTHROPIC_API_KEY` or whatever env var Phase 08 sets).
6. Confirm any **already-running** terminal continues to use its original token (no live swap).
7. Confirm "Manage tokens…" opens the Settings window.

## Out of Scope

- Pre-selecting the Claude Tokens tab in Settings.
- Live-updating running terminals (spec explicitly: new spawns only).
- Per-repo override surfacing in this menu (lives in repo context menu, separate phase).
- Automated tests — this phase is manual-verification only, consistent with the rest of the menu bar code.
