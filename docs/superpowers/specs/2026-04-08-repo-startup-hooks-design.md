# Per-Repo Startup Hooks

**Date:** 2026-04-08  
**Status:** Approved

## Problem

Users who haven't checked `conductor.json` or `.dmux-hooks` into a repo (e.g. they're evaluating TBD, or want personal hooks that don't belong in version control) have no way to configure per-repo setup or archive behavior. The hook resolver already reserves the highest-priority slot for "app per-repo config" but every call site passes `nil`.

## Solution

Wire up the existing `appHookPath` slot in `HookResolver.resolve()` using scripts stored at `~/tbd/repos/<repo-id>/hooks/<event>`. Add a UI section in `RepoSettingsView` to author and manage these scripts.

## Resolution Order (unchanged)

First match wins, no chaining:

1. **App per-repo config** (`~/tbd/repos/<repo-id>/hooks/<event>`) ← new
2. `conductor.json` scripts in repo root
3. `.dmux-hooks/<event>` in repo root
4. Global default (`~/tbd/hooks/default/<event>`)

## Data Layer

No database changes. Hooks are plain executable files; the path is deterministic from `repoID`.

### New constants in `TBDConstants`

```swift
static let reposDir = configDir.appendingPathComponent("repos")

static func hookPath(repoID: UUID, event: HookEvent) -> String {
    reposDir
        .appendingPathComponent(repoID.uuidString)
        .appendingPathComponent("hooks")
        .appendingPathComponent(event.rawValue)
        .path
}
```

`configDir` is `~/tbd`, so a setup hook for repo `A1B2...` lives at:
`~/tbd/repos/A1B2.../hooks/setup`

### File lifecycle

- **Save non-empty content:** create parent dirs, write content, `chmod +x`
- **Save empty content:** delete the file if it exists
- **Missing file:** treated as "no hook" by `HookResolver` (existing behavior)

### Call site wiring

Two nil call sites become real paths:

- `WorktreeLifecycle+Create.swift` — pass `TBDConstants.hookPath(repoID: worktree.repoID, event: .setup)`
- `WorktreeLifecycle+Archive.swift` — pass `TBDConstants.hookPath(repoID: worktree.repoID, event: .archive)`

No changes to `HookResolver` itself.

## UI

A new `RepoHooksSettingsView` component added to `RepoSettingsView`, below the existing Claude token picker.

### Layout

Two labeled subsections — **Setup hook** and **Archive hook** — each containing:

1. A monospaced `TextEditor` for inline script content  
   (e.g. `npm install && brew bundle` or `./scripts/my-setup.sh`)
2. A **Save** button (explicit save, not auto-save — avoids partial scripts executing mid-edit)
3. A dimmed filepath row with a copy-to-clipboard button:  
   `~/tbd/repos/A1B2C3.../hooks/setup  [⎘]`  
   This lets users hand the path to an LLM agent to author the script.

### Behavior

- On appear: read file content into editor if file exists; otherwise empty
- Save: write content + chmod +x, or delete file if content is blank
- The path row is always visible (even when no script is saved), so users can copy it before writing anything

### New file

`Sources/TBDApp/Settings/RepoHooksSettingsView.swift`  
`RepoSettingsView` calls it inline — no new tabs or navigation.

## Scope

- Events: `setup` and `archive` only (both actively invoked today)
- `preMerge` / `postMerge` are defined in `HookEvent` but not invoked — excluded from this design
- No RPC changes — the app writes files directly (same pattern as `RepoInstructionsView`)

## Testing

- Unit tests in `HookResolverTests` already cover `appConfigTrumpsAll()` — verify this passes once call sites are wired
- Manual: create a setup hook via UI, create a worktree, confirm the hook runs in Terminal 2
- Manual: clear the hook, confirm the file is deleted and resolution falls through to conductor/dmux
