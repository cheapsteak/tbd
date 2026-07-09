# Nav-header worktree title + repo notepad

**Date:** 2026-07-09
**Branch/worktree:** `nav-header-notes`
**Status:** Design approved, ready for implementation planning

## Summary

Replace the static "TBD" window title that macOS renders in the toolbar (between the
back/next chevrons and the primary-action controls) with a compact, useful header
showing the **selected worktree's display name** followed by its **repo name** in
smaller non-bold text, and add a **notes button** that toggles a popover holding a
free-text notepad **shared across the repo** (or scoped to the worktree for scratch
worktrees). Notes are stored **on disk**, mirroring how preSession/setup hooks are
managed — no daemon, RPC, or database involvement.

## Goals

1. Kill the literal "TBD" toolbar title; show `worktree.displayName` (14 pt, semibold)
   followed by the repo name (11 pt, regular, secondary color) inline.
2. Overall title treatment reads smaller/lighter than the current bold window title.
3. A notes button trailing the repo name opens/closes an interactive notes editor.
   Clicking the button expands it; clicking outside closes it (native popover behavior).
4. Notes contents are shared across all worktrees of a repo (repo-scoped), or scoped
   to the worktree for scratch worktrees that have no repo.
5. Notes live on disk under `~/tbd`, consistent with the hooks pattern.

## Non-goals (YAGNI)

- No live cross-worktree sync while two popovers are open simultaneously.
- No live file-watching (FSEvents/`FileWatcher`) of the notes file while the popover
  is open.
- No real conflict merge — last-writer-wins in the (practically impossible) concurrent
  edit case.
- No change to the existing per-worktree `note` list feature (DB-backed, shown as tabs).
  This notepad is a separate, additive feature.
- No cleanup of orphaned notes files on repo/worktree removal (matches the existing
  hooks behavior — see "Cleanup" below).

## Context / current state

- The "TBD" text is **the window title**, not a hand-placed `Text`. It is set by
  `Window("TBD", id: "main")` in `Sources/TBDApp/TBDApp.swift:449` and made visible by
  `.windowToolbarStyle(.unified(showsTitle: true))` at `Sources/TBDApp/TBDApp.swift:483`.
  There is no `.navigationTitle` anywhere overriding it.
- The toolbar lives on the detail pane in `Sources/TBDApp/ContentView.swift` (`.toolbar`
  at line 114). Back/next are a `ToolbarItemGroup(placement: .navigation)` at lines
  115–133. The window title renders in the gap between that group and the
  `.primaryAction` items (repo filter picker, PR split button, file-panel toggle).
- Selected worktree: `ContentView.selectedWorktree` (lines 17–21) =
  `appState.findWorktree(id: appState.selectedWorktreeIDs.first)`.
- `Worktree.displayName` (`Sources/TBDShared/Models.swift:117`), `Worktree.repoID: UUID?`
  (line 115, `nil` ⇒ scratch), `Worktree.isScratch` (line 156).
- Repo name: `AppState.repoName(for repoID:) -> String?`
  (`Sources/TBDApp/AppState+Repos.swift:11–13`).
- **Hooks storage pattern to mirror:** preSession/setup/etc. hook scripts are plain
  files at `~/tbd/repos/<repoUUID>/hooks/<eventName>`, path-computed by
  `TBDConstants.hookPath(repoID:eventName:environment:)`
  (`Sources/TBDShared/Constants.swift:74–84`). They are written **directly by the app
  UI** (`Sources/TBDApp/Settings/RepoHooksSettingsView.swift` — `readHook`/`writeHook`
  via `FileManager`, empty content deletes the file) and read directly by the daemon via
  `HookResolver`. **No RPC, store, `DaemonClient` method, or DB row is involved.**
  `TBDConstants` base dir honors the `TBD_HOME` env override via an `environment:`
  injection seam.

## Design

### Component 1 — Storage (on disk, no daemon)

**Path helpers** in `TBDConstants` (`Sources/TBDShared/Constants.swift`), alongside
`hookPath` / `reposDir`:

- `worktreesDir(environment:)` → `configDir/worktrees` (new, parallel to `reposDir`
  and `scratchDir`).
- `notesPath(repoID: UUID, environment:)` → `reposDir/<repoID.uuidString>/notes.md`.
  Sits next to the existing `hooks/` directory for that repo; shared by every worktree
  of the repo.
- `notesPath(worktreeID: UUID, environment:)` →
  `worktreesDir/<worktreeID.uuidString>/notes.md`. Used only for scratch worktrees
  (`repoID == nil`).
- Both honor `TBD_HOME` through the same `environment:` seam as `hookPath` — no
  `setenv` needed in tests.

**`NotesFileStore`** — a small plain struct (in `Sources/TBDApp/`, testable; not inlined
into the SwiftUI view the way `RepoHooksSettingsView` inlines its read/write):

- `read(at path: String) -> String` — returns the file contents, or `""` if the file
  does not exist.
- `write(_ content: String, to path: String)` — trims; if empty/whitespace-only,
  **deletes** the file (`FileManager.removeItem`, mirroring hooks' empty-save behavior);
  otherwise `createDirectory(withIntermediateDirectories: true)` for the parent dir and
  writes atomically.

No RPC, `DaemonClient`, store, `Note` model, or migration. The daemon never reads or
writes notes (nothing in worktree lifecycle needs them).

### Component 2 — Toolbar title replacement

- In `Sources/TBDApp/TBDApp.swift:483`, change `.windowToolbarStyle(.unified(showsTitle:
  true))` → `showsTitle: false` so macOS stops drawing the "TBD" window title. (The
  literal `Window("TBD", …)` string may stay — it is the window's accessibility/identity
  title and is no longer rendered in the toolbar.)
- In `ContentView`'s `.toolbar`, add a `ToolbarItem(placement: .principal)` rendering a
  new **`WorktreeTitleView`**. Given the selected worktree, it renders an `HStack`
  (baseline-aligned) of:
  - `Text(worktree.displayName)` — `.font(.system(size: 14, weight: .semibold))`.
  - repo name `Text` — `.font(.system(size: 11))`, `.foregroundStyle(.secondary)`;
    resolved via `worktree.repoID.flatMap { appState.repoName(for: $0) }`. Hidden for
    scratch worktrees (no repo).
  - the **notes button** (Component 3), trailing the repo name.
- Layout is **inline / horizontal** (name · repo · button on one line), per the
  "followed by" / "following the repo name" wording.
- No worktree selected → the principal item renders empty (no title, no button).
- Respect the macOS 26 Liquid Glass toolbar grouping rules noted in
  `Sources/TBDApp/CLAUDE.md` if the notes button needs its own capsule boundary.

### Component 3 — Notes button + popover

- The notes button uses a **static** SF Symbol (`note.text`), regardless of whether the
  repo has notes (no content-based indicator — decided).
- Tapping it toggles `.popover(isPresented:)`. Native popover behavior: clicking the
  button expands it; clicking outside auto-dismisses it. This satisfies "clicking the
  button should expand it; clicking outside should close it" directly.
- **`NotepadPopoverView`**:
  - On appear, resolves **scope** from the selected worktree: `repoID != nil` → repo
    scope → `TBDConstants.notesPath(repoID:)`; else → worktree scope →
    `TBDConstants.notesPath(worktreeID: worktree.id)`.
  - **Read-on-open:** reads the file fresh via `NotesFileStore.read(at:)` into
    `@State content`, and records a `loadedContent` baseline.
  - `TextEditor` bound to `content`, with a **500 ms debounced autosave** (reuse the
    debounce pattern from `Sources/TBDApp/Panes/NotePaneView.swift`) plus a flush on
    dismiss (`onDisappear`).
  - **Dirty-tracking on the write side:** only call `NotesFileStore.write` when
    `content != loadedContent` (the user actually edited). Opening and not typing
    performs no write, so an external edit is never clobbered by a no-op autosave. After
    a successful write, update `loadedContent = content`.

### External-edit handling

Because a native popover dismisses on focus loss, the popover is only ever open while it
has focus — to edit `notes.md` in an external editor you must click away from TBD, which
closes the popover. Therefore **read-on-open always reflects the latest on-disk content**
for the only realistic external-edit case (edited while the popover was closed).
Dirty-tracking guarantees an untouched open never overwrites an external edit. The
degenerate "open + typing + external edit in the same instant" case is effectively
impossible under focus-based dismissal and resolves last-writer-wins.

### Cleanup (accepted limitation)

Strictly mirroring the hooks pattern means **no cleanup**: hook files are already
orphaned under `~/tbd/repos/<repoID>/` when a repo is removed
(`handleRepoRemove` deletes DB rows only), and worktree archival never touches per-repo
files. The notepad inherits this — a stray tiny `notes.md` may be left on disk after
repo/worktree removal. This is consistent with the existing feature and accepted for
this design.

## Data flow

1. User selects a worktree → `ContentView.selectedWorktree` updates.
2. `WorktreeTitleView` renders `displayName` (14 pt) + repo name (11 pt) + notes button.
3. User clicks notes button → popover opens → `NotepadPopoverView.onAppear` resolves the
   scope path and reads `notes.md` from disk into `content` / `loadedContent`.
4. User types → debounced (500 ms) autosave writes to disk **only if
   `content != loadedContent`**; `loadedContent` is updated after each write.
5. User clicks outside → popover dismisses → `onDisappear` flushes any pending dirty
   write.

## Error handling

- Missing file on read → treat as empty string (first-time notepad).
- Write failure (permissions, disk) → log via `os.Logger` (per the no-`print` rule); the
  in-memory content is preserved so the next autosave/dismiss retries. No user-facing
  error dialog (consistent with hooks' silent file writes).
- Directory creation is `withIntermediateDirectories: true` (idempotent).

## Testing

Per CLAUDE.md, add a test for **each branch** of the scope conditional (repo vs
worktree).

- **`TBDConstants` path tests** (mirroring `ConstantsTests`, using the `environment:`
  injection seam — no `setenv`):
  - `notesPath(repoID:environment:)` composes `reposDir/<repoID>/notes.md` and follows a
    custom `TBD_HOME` in the injected environment.
  - `notesPath(worktreeID:environment:)` composes `worktreesDir/<worktreeID>/notes.md`
    and follows `TBD_HOME`.
  - `worktreesDir(environment:)` = `configDir/worktrees`.
- **`NotesFileStore` roundtrip tests** (writing under a temp dir, never `~/tbd`):
  - write → read returns the content.
  - write empty / whitespace-only → file is deleted; subsequent read returns `""`.
  - write to a path whose parent dir doesn't exist → parent is created, content written.
- **Dirty-tracking logic**, if factored into a testable helper: no write when
  `content == loadedContent`; write when they differ.
- **Toolbar / popover are SwiftUI and live-only** — verified via `scripts/restart.sh`
  (full restart, since `TBDShared`/`Constants.swift` changed) + screenshot, not headless.

## Files touched (anticipated)

- `Sources/TBDShared/Constants.swift` — add `worktreesDir`, `notesPath(repoID:)`,
  `notesPath(worktreeID:)`.
- `Sources/TBDApp/TBDApp.swift` — `showsTitle: false`.
- `Sources/TBDApp/ContentView.swift` — add `.principal` toolbar item hosting
  `WorktreeTitleView`.
- `Sources/TBDApp/` — new `WorktreeTitleView`, `NotepadPopoverView`, `NotesFileStore`
  (file layout TBD during planning; likely a small new file or two).
- Tests under `Tests/TBDDaemonTests` (Constants) and the app test target
  (`NotesFileStore`).

## Open questions

None blocking. File/type layout (one file vs several) to be decided during
implementation planning.
