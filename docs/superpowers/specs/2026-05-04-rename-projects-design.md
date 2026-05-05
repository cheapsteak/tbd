# Rename Projects in the Worktree List

**Date:** 2026-05-04
**Status:** Approved

## Goal

Let users rename projects (repos) shown in the sidebar's worktree list, using the same emoji-friendly inline input UX that already exists for worktree rename. Display-name only — no on-disk or git changes.

## UX

- Right-click on a repo's section header opens a context menu that includes **"Rename..."** (this is the only entry point for rename, to avoid conflicting with the existing click-to-expand/collapse on the header).
- Selecting "Rename..." swaps the section header's `Text` for an inline `TextField` in place.
- Typing `:query:` triggers the same emoji autocomplete panel used for worktree rename, with frecency-ranked suggestions.
- **Enter** commits, **Esc** cancels, blur commits — mirroring worktree rename.
- Empty / whitespace-only input cancels with no rename, matching worktree rename behavior.
- The rest of the header continues to expand/collapse the section as before. Single-click and double-click on the header do not enter rename mode.

## Component extraction: `RenameableLabel`

To avoid duplicating ~120 lines of inline-edit + emoji autocomplete logic, extract a reusable component.

**New file:** `Sources/TBDApp/Sidebar/RenameableLabel.swift`

Encapsulates:
- Display text vs. edit-mode toggle
- `TextField` + focus management
- `:emoji:` autocomplete panel (the logic currently around lines 272-316 of `WorktreeRowView.swift`)
- Enter / Esc / blur handling

Approximate public surface:

```swift
RenameableLabel(
    text: String,
    isEditing: Binding<Bool>,
    font: Font,
    onCommit: (String) -> Void,
    emojiFrecency: EmojiFrecency
)
```

Both `WorktreeRowView` and `RepoSectionView` consume it. `WorktreeRowView` keeps its outer row chrome (status icons, etc.) and delegates only the editable-name portion to `RenameableLabel`.

## Data flow

### Database / Store

`Sources/TBDDaemon/Database/RepoStore.swift`:

- Add `func rename(id: UUID, displayName: String) throws` — single-column update on `repo.displayName`, mirroring `WorktreeStore.rename`.
- No migration needed; the `displayName` column already exists on the `repo` table.

### Shared protocol

`Sources/TBDShared/RPCProtocol.swift`:

- New method name: `"repo.rename"`.
- New params type: `RepoRenameParams { repoID: UUID; displayName: String }`.

### RPC handler

`Sources/TBDDaemon/Server/RPCRouter+RepoHandlers.swift` (create if absent, else extend):

- Handler calls `db.repos.rename()` and broadcasts `RepoRenameDelta`.

### State delta

`Sources/TBDShared/StateDelta.swift`:

- New `RepoRenameDelta { repoID: UUID; displayName: String }`.
- App-side application path updates the repo in the `AppState` cache so the sidebar re-renders.

### App side

`Sources/TBDApp/AppState+Repos.swift` (create if absent, else extend the appropriate file):

- `func renameRepo(id: UUID, displayName: String)` — sends the RPC and optimistically updates local state, consistent with how `renameWorktree` works.

### CLI

Add `tbd repo rename <name-or-id> <new-name>` parallel to `tbd worktree rename`. Cheap to add, useful for scripting and parity.

## Testing

Per the CLAUDE.md branching-conditional rule and to maintain parity with worktree rename:

- `RepoStoreTests` — verify `rename()` updates the column; verify rename of a nonexistent ID throws the expected error.
- RPC-level test in the same style as the existing worktree rename RPC tests (if any) verifying the handler dispatches the delta.
- Manual smoke checks:
  - Rename a repo via the right-click menu and confirm the sidebar updates immediately.
  - Verify other open TBD windows receive the delta.
  - Verify the new name persists across `scripts/restart.sh`.

## Out of scope

- Repo rename does not affect the on-disk path or git remote — display name only.
- No bulk rename, no undo stack, no rename history.
- The `renamePrompt` column on `repo` (an LLM-rename suggestion prompt for *worktrees*, not the repo's own display name) is unrelated and untouched.
