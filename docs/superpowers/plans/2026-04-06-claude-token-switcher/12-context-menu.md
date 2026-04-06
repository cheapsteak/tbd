# Phase 12: Claude Tab Context Menu

> **Parent plan:** [../2026-04-06-claude-token-switcher.md](../2026-04-06-claude-token-switcher.md)
> **Depends on:** Phase 06 (swap RPC), Phase 08 (client wiring)
> **Unblocks:** nothing (final phase)

**Scope:** Add a "Token" section to the claude tab context menu (`TabBar.swift:contextMenuContent`) containing a disabled header row showing the current token + 5h/7d usage and a "Swap token →" submenu that triggers a one-shot mid-conversation swap via `terminal.swapClaudeToken`.

---

## Context

Spec section: **"Claude tab context menu — new section"** (`docs/superpowers/specs/2026-04-06-claude-token-switcher-design.md` §223–238).

Target file: `Sources/TBDApp/TabBar.swift`. The relevant view is `TabBarItem` (private struct, ~line 150) and its `contextMenuContent` `@ViewBuilder` (~lines 249–269). The existing `if isClaudeTerminal { ... }` block currently contains:

1. Fork Session button
2. Suspend/Resume Claude button
3. `Divider()`

The new Token section must sit **above** these items (still inside the same `if isClaudeTerminal` block), with its own trailing `Divider()` separating it from Fork/Suspend.

`TabBarItem` already receives a `terminal: Terminal?` prop (line 154) — `terminal.claudeTokenID` (added in Phase 01) is reachable from there. No new prop threading is needed for the token ID itself.

What **is** needed: access to `appState.claudeTokens` (added in Phase 08) to look up token name + usage, and access to `appState.swapClaudeTokenOnTerminal(terminalID:newTokenID:)` to invoke the swap. `TabBarItem` is currently pure-prop and does not see `AppState`. Cleanest path: add an `@EnvironmentObject var appState: AppState` to `TabBarItem` (the parent `TerminalTabView` already has one, and SwiftUI propagates environment objects automatically — no parent change required). This is preferable to threading a token list + a swap closure through `TabBar` → `TabBarItem` props because the data is read-only inside the menu and the menu rebuilds on every open.

The `Terminal` model field name from Phase 01 is assumed to be `claudeTokenID: UUID?`. The `ClaudeToken` model is assumed to expose `id: UUID`, `name: String`, and an optional `usage: ClaudeTokenUsage?` (with `fiveHourPercent: Int?` and `sevenDayPercent: Int?`). Confirm exact field names against Phase 01 / Phase 08 output during implementation and adjust formatting helpers accordingly.

---

## Tasks

### Task 1: Expose AppState to TabBarItem

- [ ] Add `@EnvironmentObject private var appState: AppState` to `TabBarItem` in `Sources/TBDApp/TabBar.swift`.
- [ ] Verify `TabBar`'s parent (`TerminalTabView`) already injects `AppState` into the environment. If not, add `.environmentObject(appState)` at the appropriate ancestor (do **not** re-inject inside `TabBar` — environment objects flow down automatically).
- [ ] `swift build` to confirm no preview/wiring breakage.

### Task 2: Add a token-display formatting helper

- [ ] Inside `TabBarItem`, add a private helper:
  ```swift
  private func formatTokenHeader(_ tokenID: UUID?) -> String {
      guard let tokenID else { return "Token: Default (logged in)" }
      guard let token = appState.claudeTokens.first(where: { $0.id == tokenID }) else {
          return "Token: (missing)"
      }
      if let usage = token.usage,
         let fiveH = usage.fiveHourPercent,
         let sevenD = usage.sevenDayPercent {
          return "Token: \(token.name) · 5h \(fiveH)% · 7d \(sevenD)%"
      }
      return "Token: \(token.name)"
  }
  ```
- [ ] Add a sibling helper `formatTokenSubmenuLabel(_ token: ClaudeToken) -> String` that returns `"<name>  5h NN% · 7d NN%"` or just `"<name>"` when usage is nil. Verify field names against the Phase 01/08 model and adjust as needed.

### Task 3: Insert the disabled header row

- [ ] In `contextMenuContent`, inside the existing `if isClaudeTerminal { ... }` block, **above** the Fork button, add:
  ```swift
  Button(formatTokenHeader(terminal?.claudeTokenID)) {}
      .disabled(true)
  ```
- [ ] Confirm visually that a disabled `Button` renders as a non-interactive header line in a SwiftUI `.contextMenu`. (SwiftUI menus do not support arbitrary `Text`; a disabled Button is the standard idiom.)

### Task 4: Insert the "Swap token" submenu

- [ ] Directly below the header row (still above Fork), add:
  ```swift
  Menu("Swap token") {
      // Default option
      Button {
          guard let terminalID = terminal?.id else { return }
          appState.swapClaudeTokenOnTerminal(terminalID: terminalID, newTokenID: nil)
      } label: {
          let prefix = terminal?.claudeTokenID == nil ? "● " : "  "
          Text("\(prefix)Default (logged in)")
      }

      Divider()

      ForEach(appState.claudeTokens) { token in
          Button {
              guard let terminalID = terminal?.id else { return }
              appState.swapClaudeTokenOnTerminal(terminalID: terminalID, newTokenID: token.id)
          } label: {
              let prefix = terminal?.claudeTokenID == token.id ? "● " : "  "
              Text("\(prefix)\(formatTokenSubmenuLabel(token))")
          }
      }
  }
  ```
- [ ] Confirm `ClaudeToken` is `Identifiable` (or use `id: \.id`).
- [ ] The selected-state marker uses a leading `●` for the current token and two spaces of padding for the others to keep labels aligned. SwiftUI's menu does not support `Image(systemName:)` checkmarks as a leading affordance reliably across the macOS menu styles, so a unicode bullet is the simplest and matches the spec mockup (`●`/`○`).

### Task 5: Add the trailing divider

- [ ] After the `Menu("Swap token") { ... }` block and **before** the existing `Button(action: onFork)`, insert a `Divider()`.
- [ ] The result inside `if isClaudeTerminal` should read in this order:
  1. Disabled header `Button`
  2. `Menu("Swap token") { ... }`
  3. `Divider()`
  4. `Button(action: onFork) { ... }` (unchanged)
  5. `Button(action: isSuspended ? onResume : onSuspend) { ... }` (unchanged)
  6. `Divider()` (the existing one)

### Task 6: Build verification

- [ ] `swift build` passes.
- [ ] No new warnings introduced in `TabBar.swift`.
- [ ] If `Sources/TBDApp/AppState.swift` does not yet expose `claudeTokens` or `swapClaudeTokenOnTerminal(terminalID:newTokenID:)`, halt and report — this phase **depends on Phase 08** and should not stub them locally.

### Task 7: Manual verification

Per CLAUDE.md, no automated UI test exists for context menus. Verify by hand:

- [ ] Restart with `scripts/restart.sh`.
- [ ] Open a worktree, spawn a Claude tab with **no** token configured. Right-click the tab. Verify the header shows `"Token: Default (logged in)"` and the submenu lists "Default (logged in)" with a leading `●` plus all configured tokens unmarked.
- [ ] Configure at least one token in Settings (Phase 09). Right-click again. Verify the submenu lists that token with a usage badge (e.g. `"Personal  5h 42% · 7d 18%"`) and no leading `●`.
- [ ] Click that token in the submenu. Verify the daemon respawns claude with `--resume`, the broadcast updates `terminal.claudeTokenID`, and on re-opening the menu the header now shows `"Token: Personal · 5h 42% · 7d 18%"` and the bullet has moved.
- [ ] Inside the resumed pane, type a message and confirm prior conversation context is preserved (the spec's correctness criterion for swap).
- [ ] Verify the **global default** in the menu bar (Phase 11) and the **repo override** in Repo Settings (Phase 10) are **unchanged** — this swap is one-shot per the spec.
- [ ] Right-click a non-claude (shell) tab. Verify the Token section does **not** appear (still gated by `isClaudeTerminal`).

### Task 8: Commit

- [ ] Stage only `Sources/TBDApp/TabBar.swift` (and any environment-object plumbing file you had to touch in Task 1, if applicable).
- [ ] Commit with `feat: add token swap section to claude tab context menu`.

---

## Out of scope (explicitly dropped during brainstorming)

- "Clone tab with different token" action
- "Pin to token" action
- A "Refresh usage now" menu item
- Any change to repo override or global default from this menu — swap is **one-shot per terminal**
