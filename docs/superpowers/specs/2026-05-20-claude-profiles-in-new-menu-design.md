# Claude profiles in the "+" new-session menu

**Date:** 2026-05-20
**Status:** Approved design

## Problem

TBD supports multiple Claude model profiles (OAuth/API-key/Bedrock), but the "+"
tab menu only offers a single "Claude" option. That option spawns a session
whose profile is resolved by the existing precedence chain (per-repo override →
global `defaultProfileID` → keychain login). There is no way to start a new
Claude session pinned to a *specific* profile — the user must spawn a session
and then use the "Swap profile" context menu, which forks the session.

## Goal

List the configured Claude profiles directly in the "+" menu, nested under the
existing "Claude" item, so a user can start a session on a chosen profile in one
click. The plain "Claude" item keeps its current behavior unchanged.

## Behavior

The "+" menu becomes:

```
  Shell
  Claude               ← click = default (unchanged resolution chain)
    Work (sonnet)       ← indented; click = spawn pinned to this profile
    Personal (oauth)
    Bedrock (us-east-1)
  Codex
  ──────────
  Note
```

- The "Claude" item stays a direct, clickable `NSMenuItem` (no submenu). Clicking
  it spawns a default Claude session exactly as today.
- Below it, one indented item per configured profile, in the same order as
  `appState.modelProfiles`. Clicking one spawns a Claude session pinned to that
  profile via `overrideProfileID`.
- Item labels reuse the existing `formatProfileSubmenuLabel()` formatter used by
  the "Swap profile" context menu, for consistency. No "Claude ·" prefix —
  indentation conveys that they are Claude sessions.
- If no profiles are configured, only the plain "Claude" item shows; no
  sub-items, no separator.
- The "Codex" and "Note" items are unchanged.
- The menu is rebuilt on every open (`showMenu()`), so the profile list is
  always current; no refresh logic needed.

## Scope

This is a UI-only change. `overrideProfileID` already flows end-to-end
(`TerminalCreateParams.overrideProfileID` → `handleTerminalCreate` → daemon
resolves and pins it → `Terminal.profileID` is stored). No daemon, RPC-protocol,
or database changes are required.

## Components & data flow

1. **`Sources/TBDApp/TabBar.swift` — `AddTabButton`**
   - Gains an input for the profile list (`[ModelProfileWithUsage]`, sourced from
     `appState.modelProfiles`) and a new callback `onAddClaudeProfile: (UUID) -> Void`.
   - `showMenu()` inserts indented `NSMenuItem`s immediately after the "Claude"
     item. Each carries its profile `UUID` in `representedObject` and uses
     `indentationLevel = 1`.

2. **`Sources/TBDApp/TabBar.swift` — `MenuCoordinator`**
   - Gains one new `@objc` action, `addClaudeProfile(_ sender: NSMenuItem)`,
     which reads `sender.representedObject as? UUID` and forwards it to the
     `onAddClaudeProfile` closure. A single selector + `representedObject` is used
     rather than one selector per profile.
   - The coordinator must be retained for the menu's lifetime exactly as the
     existing one is (it is currently held via the menu's `representedObject` /
     associated reference — match whatever the current code does).

3. **`Sources/TBDApp/TabBar.swift` — `TabBar.body`**
   - Passes `appState.modelProfiles` into `AddTabButton`.
   - Wires `onAddClaudeProfile` to `Task { await appState.createClaudeTerminal(worktreeID:, profileID:) }`.

4. **`Sources/TBDApp/AppState+Terminals.swift` — `createClaudeTerminal()`**
   - Gains an optional parameter `profileID: UUID? = nil`, forwarded as the
     `overrideProfileID` argument of the `daemonClient.createTerminal(...)` call.
   - Existing call sites pass nothing and are unaffected (still send `nil`).

## Error handling

No new failure modes. Spawning a profile-pinned session uses the identical RPC
path as the existing "Claude" item; daemon-side resolution failures already fall
back to keychain login with a logged warning.

## Testing

Per CLAUDE.md, the new conditional (profile-pinned vs. default spawn) gets a test
for each branch.

- **Menu construction:** Given N profiles, the items produced by `showMenu()`'s
  building logic contain the plain "Claude" item plus N indented items whose
  `representedObject` UUIDs match the input profiles in order. Given zero
  profiles, only the plain "Claude" item is present (no sub-items, no extra
  separator). If menu building is not currently unit-testable, extract the
  item-list construction into a pure helper function and test that.
- **`createClaudeTerminal(profileID:)`:** Calling with a profile UUID sends that
  value as `overrideProfileID`; calling with no argument sends `nil`. Both
  branches verified.

## Out of scope

- Codex profiles (Codex has no model-profile concept here).
- Reordering or grouping profiles, or marking which profile the plain "Claude"
  item resolves to.
- Any change to the "Swap profile" context menu on existing tabs.
