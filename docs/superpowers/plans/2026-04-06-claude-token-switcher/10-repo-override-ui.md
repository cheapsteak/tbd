# Phase 10: Repo Override Picker

> **Parent plan:** [../2026-04-06-claude-token-switcher.md](../2026-04-06-claude-token-switcher.md)
> **Depends on:** Phase 08
> **Unblocks:** nothing

**Scope:** Add a "Claude token override" picker to the per-repo settings UI. Options: "Inherit global default" (nil) or one of the stored tokens. Caption shows the currently-effective global default so users understand inheritance.

## Context

There is no separate per-repo settings sheet — `Sources/TBDApp/Settings/SettingsView.swift` renders each repo inline as a `RepoSettingsRow` (lines 132–212). The picker is added to that row.

Phase 08 has already exposed:

- `appState.claudeTokens: [ClaudeToken]`
- `appState.setRepoClaudeTokenOverride(repoID:tokenID:)`
- `repo.claudeTokenOverrideID: UUID?`

We also assume the global default is reachable as `appState.defaultClaudeTokenID: UUID?` (set in earlier phases). If the actual property name differs, adjust during implementation — do not invent new state.

## Design decision: no "force keychain login" option per repo

The per-repo picker offers exactly two kinds of choices:

1. **Inherit global default** — stored as `nil` in `repo.claudeTokenOverrideID`.
2. **A specific named token** — stored as that token's UUID.

We deliberately do **not** offer a third "Default (claude keychain login)" option at the per-repo level. Doing so would require distinguishing "inherit" from "force keychain" while both naturally map to `nil`. The two options to resolve that were:

- **(a) Drop the option.** Per-repo override is either inherit or a specific token. Simpler, no schema change. The user can still force keychain login for *every* repo by clearing the global default in the global settings UI.
- **(b) Introduce a sentinel UUID** (e.g. all-zero) meaning "force keychain even if a global default is set". Requires schema/model carve-outs and special-casing in the spawn path.

We pick **(a)**. The tradeoff: a user who has set a global default token but wants *one specific repo* to use raw keychain login has no way to express that without clearing the global default. We accept this — it's an unusual workflow, and Phase 11+ can revisit if real users hit it.

The caption below the picker makes the inheritance behavior visible so users aren't confused about what `nil` resolves to.

## Tasks

### Task 1: Add picker state and binding helper to `RepoSettingsRow`

In `Sources/TBDApp/Settings/SettingsView.swift`, inside `RepoSettingsRow`, add a computed `Binding<UUID?>` that reads `repo.claudeTokenOverrideID` and on `set` calls `appState.setRepoClaudeTokenOverride(repoID: repo.id, tokenID: newValue)` inside a `Task`. Do not add `@State` for the selection — the source of truth is `appState.repos`, and the row already re-renders when `appState` publishes.

### Task 2: Render the picker

Below the existing `HStack` that shows branch + path (after line 194, still inside the outer `VStack`), add:

```swift
Picker("Claude token", selection: tokenOverrideBinding) {
    Text("Inherit global default").tag(UUID?.none)
    ForEach(appState.claudeTokens) { token in
        Text(token.name).tag(UUID?.some(token.id))
    }
}
.pickerStyle(.menu)
.controlSize(.small)
.font(.caption)
```

Tag types must match exactly (`UUID?.none` / `UUID?.some(...)`) or SwiftUI silently fails to preselect.

### Task 3: Render the inheritance caption

Directly under the picker, show a `Text` caption that resolves what `nil` currently means. Only render it when `repo.claudeTokenOverrideID == nil`:

- If `appState.defaultClaudeTokenID` is non-nil and matches a token in `appState.claudeTokens`: `"Inheriting global default: <token.name>"`.
- Otherwise: `"Inheriting global default: keychain login"`.

Style: `.font(.caption2).foregroundStyle(.secondary)`.

If `appState.defaultClaudeTokenID` doesn't exist under that exact name, locate the actual property added in earlier phases (search for `defaultClaudeToken` in `Sources/TBDApp/AppState.swift` and `Sources/TBDShared/Models.swift`) and use it. Do not introduce new state.

### Task 4: Empty-tokens edge case

If `appState.claudeTokens.isEmpty`, the picker still renders with only the "Inherit global default" row. That's acceptable — it degenerates to a no-op control. Do not hide the picker; users seeing a single-option picker is a useful hint that they need to add tokens in global settings.

### Task 5: Build

Run `swift build` and fix any errors. Pay attention to:

- Tag type inference (force `UUID?` if needed via explicit `as UUID?`).
- `ForEach` requires `ClaudeToken: Identifiable` — confirm it is, otherwise add `id: \.id`.
- `setRepoClaudeTokenOverride` is async; wrap in `Task { await ... }` inside the binding setter.

### Task 6: Manual verification

No automated SwiftUI tests in this phase. Verify by hand:

1. Open Settings → Repos. Confirm the picker appears under each repo with "Inherit global default" preselected.
2. With at least two named tokens in global settings, pick a non-default token for repo A. Caption disappears (since override is no longer nil).
3. Spawn a new terminal in a worktree of repo A. Spot-check (env var, log line, or whatever Phase 09 wired up) that the chosen token is used.
4. Switch repo A back to "Inherit global default". Confirm the caption returns and reflects the current global default name (or "keychain login" if none).
5. Clear the global default in global settings while repo A is set to inherit. Confirm caption updates live to "keychain login".
6. Restart the app. Confirm the per-repo selection persists.

Record any discrepancies as follow-up tasks; do not patch them in this phase.
