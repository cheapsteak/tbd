# Fork profile picker — design

**Date:** 2026-07-06
**Branch:** `fork-profile-picker`
**Status:** Approved (brainstorming)

## Problem

PR #343 changed "Swap profile" to swap **in place** — the intuitive default. But a
common need was actually *fork + switch profile* (open a new tab resuming the session
under a different profile), which now takes two clicks (Fork Session, then Swap). The
tab-bar **"Fork Session"** action is a single button that forks only onto the terminal's
*current* profile, so there is no one-gesture "fork into profile X".

## Goal

Expand the tab-bar "Fork Session" action into a submenu — matching the "Swap profile"
menu directly above it — that lets the user choose which Claude profile to fork the
session into. Forking onto the current profile remains available.

## Decisions (from brainstorming)

- **No model-family filter for now.** Every profile in the picker is already
  Claude-compatible (OAuth / Proxy / Bedrock all run Claude), and swap/fork are already
  gated to Claude terminals (`isClaudeTerminal`). The picker lists the same profiles as
  the Swap menu. There is no such thing as a "gemini" or "codex" *profile* today (codex
  is a separate `TerminalKind`), so a model-family filter would be a no-op. Revisit only
  if gemini/codex profiles ever exist. (YAGNI.)
- **Codex/non-Claude terminals unchanged.** Fork is Claude-only today (no fork button on
  codex terminals); it stays that way. No new fork surface is added.
- **Menu label stays "Fork Session"** (keeps the `arrow.triangle.branch` icon). Accurate:
  you fork the *session*; the profile is the target.
- **Unify on the swap-fork path and remove the old fork path.** Single fork code path.

## The change (client-side only)

Everything below is in `Sources/TBDApp`. No daemon / RPC / CLI changes — the daemon
already supports "fork into an arbitrary profile" via `terminal.swapProfile` with
`mode: .fork` (the sidebar row menu already uses it).

### 1. `TabBar.swift` — replace the Fork button with a Fork menu

Currently (`TabBar.swift:772-774`), inside the `if isClaudeTerminal` block:

```swift
Button(action: onFork) {
    Label("Fork Session", systemImage: "arrow.triangle.branch")
}
```

Replace with a `Menu` mirroring the "Swap profile" menu (`TabBar.swift:748-768`), but
dispatching `mode: .fork`:

```swift
Menu {
    Button {
        guard let terminalID = terminal?.id else { return }
        Task { await appState.swapTerminalProfile(terminalID: terminalID, newProfileID: nil, mode: .fork) }
    } label: {
        let prefix = terminal?.profileID == nil ? "● " : "  "
        Text("\(prefix)Default (logged in)")
    }

    Divider()

    ForEach(appState.modelProfiles, id: \.profile.id) { entry in
        Button {
            guard let terminalID = terminal?.id else { return }
            Task { await appState.swapTerminalProfile(terminalID: terminalID, newProfileID: entry.profile.id, mode: .fork) }
        } label: {
            let prefix = terminal?.profileID == entry.profile.id ? "● " : "  "
            Text("\(prefix)\(formatProfileSubmenuLabel(entry))")
        }
    }
} label: {
    Label("Fork Session", systemImage: "arrow.triangle.branch")
}
```

Notes:
- The `●` marks the terminal's *current* profile (parity with Swap), signalling
  "fork here = duplicate as-is".
- Reuses the existing `formatProfileSubmenuLabel(_:)` helper (`TabBar.swift:710`).
- The `Default (logged in)` item forks under the ambient keychain login (nil profile),
  matching the Swap menu and the sidebar fork's nil-profile support.

### 2. Remove the now-dead old fork path

With the tab bar routing through `swapTerminalProfile(mode: .fork)`, these have no
remaining callers and are removed:

- `AppState+Terminals.swift:371` — `func forkClaudeTerminal(worktreeID:sessionID:tokenID:)`
- `TerminalContainerView.swift:195-203` — the `onForkTab:` closure
- `TabBar.swift` — the `onForkTab` (line 99) / `onFork` (line 477) closure plumbing and
  the `onFork: { onForkTab(tab.id) }` wiring (line 123)

**Behavior change to note:** same-profile fork now resumes via the swap RPC
(`terminal.swapProfile`, `mode: .fork`) instead of `terminal.create` with a resume
session id. Net effect is the same — a new tab resuming the session — plus the swap
path's blank-session planning and transcript-carry (harmless / no-op when the target
config dir equals the source).

## Why the swap path (not `terminal.create`)

`terminal.swapProfile` with `mode: .fork` (handler at
`RPCRouter+TerminalHandlers.swift:789+`, fork branch `forkSwapNewTab` ~998) performs
**transcript-carry**: it copies the session `.jsonl` into the *destination* profile's
config dir so `claude --resume <id>` finds it. The old `forkClaudeTerminal` path used
`terminal.create` with `resumeSessionID`, which always keeps the source profile and skips
transcript-carry — structurally unable to fork into a different profile. Unifying on the
swap path is what makes the profile picker actually work.

## Preconditions / edge cases

- The swap RPC requires `claudeSessionID` (errors "not a Claude terminal" otherwise). The
  old fork guarded on the same field (`guard let sessionID = terminal?.claudeSessionID`),
  and the whole menu lives under `isClaudeTerminal` — so the precondition is unchanged and
  identical to the existing Swap menu's.

## Non-goals

- No daemon / RPC / CLI changes.
- No model-family or gemini/codex filtering.
- No fork surface added for codex/non-Claude terminals.
- Sidebar row-menu fork (`RowActionMenuActions.swift:174` `.forkSession`) already has a
  profile chooser via the swap path — untouched.

## Testing

- `swift build` — compiles.
- `swift test` — confirm removing `forkClaudeTerminal` / `onForkTab` breaks no test
  (grep tests for the removed symbols first).
- Live-verify (UI wiring is live-only): from a running Claude terminal's tab context
  menu, "Fork Session" now opens a submenu; forking into (a) the current profile,
  (b) another OAuth/Proxy profile, and (c) "Default (logged in)" each opens a **new tab**
  resuming the session under the chosen profile. Confirm the `●` marks the current
  profile.

No new behavior-gating conditional is introduced (the change replaces a button with a
menu routing to an existing gated RPC), so no new unit-test branch is required.

## Files touched

- `Sources/TBDApp/TabBar.swift` — Fork button → Fork menu; remove `onFork`/`onForkTab` plumbing.
- `Sources/TBDApp/Terminal/TerminalContainerView.swift` — remove `onForkTab:` closure.
- `Sources/TBDApp/AppState+Terminals.swift` — remove `forkClaudeTerminal`.
