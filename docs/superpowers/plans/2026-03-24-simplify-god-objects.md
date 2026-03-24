# Simplify God Objects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the three largest files (WorktreeLifecycle 505 lines, AppState 504 lines, RPCRouter 433 lines) into focused, single-responsibility units.

**Architecture:** Pure refactoring — extract code into new files using Swift extensions and new types. No behavior changes. Every task must leave the build green and all tests passing. The split boundaries follow existing `// MARK:` sections.

**Tech Stack:** Swift 6.0, SwiftUI, GRDB, SPM

---

## File Structure

### WorktreeLifecycle split (505 → ~4 files)

Current `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle.swift` has 5 MARK sections (Create, Archive, Revive, Git Status, Reconcile) plus the struct definition and error enum. Split into:

```
Sources/TBDDaemon/Lifecycle/
├── WorktreeLifecycle.swift          # Struct definition, properties, init, error enum (~50 lines)
├── WorktreeLifecycle+Create.swift   # Create flow + setupTerminals helper (~200 lines)
├── WorktreeLifecycle+Archive.swift  # Archive + Revive (~120 lines)
└── WorktreeLifecycle+Reconcile.swift # Reconcile + Git Status refresh (~130 lines)
```

### AppState split (504 → ~5 files)

Current `Sources/TBDApp/AppState.swift` has the class definition, polling, connection, and 7 MARK sections. Split into:

```
Sources/TBDApp/
├── AppState.swift                   # Class definition, published properties, init, polling, connection (~100 lines)
├── AppState+Repos.swift             # Repo CRUD actions (~40 lines)
├── AppState+Worktrees.swift         # Worktree CRUD + keyboard shortcut actions (~150 lines)
├── AppState+Terminals.swift         # Terminal actions (~40 lines)
└── AppState+Notifications.swift     # Notification + daemon status + helpers (~80 lines)
```

### RPCRouter split (433 → ~4 files)

Current `Sources/TBDDaemon/Server/RPCRouter.swift` has a big switch statement and handler methods grouped by MARK. Split into:

```
Sources/TBDDaemon/Server/
├── RPCRouter.swift                  # Class definition, handle() switch dispatch (~90 lines)
├── RPCRouter+RepoHandlers.swift     # Repo add/remove/list handlers (~110 lines)
├── RPCRouter+WorktreeHandlers.swift # Worktree create/list/archive/revive/rename handlers (~100 lines)
└── RPCRouter+TerminalHandlers.swift # Terminal + notification + cleanup + status handlers (~130 lines)
```

---

### Task 1: Split WorktreeLifecycle

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle.swift`
- Create: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift`
- Create: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift`
- Create: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift`

- [ ] **Step 1: Read WorktreeLifecycle.swift and identify exact line ranges for each section**

Read the file. Map the MARK sections to line numbers. The sections are:
- Struct definition + error enum + properties + init: lines 1-54
- Create (MARK - Create): from `// MARK: - Create` to next MARK
- Archive + Revive (MARK - Archive, MARK - Revive): from `// MARK: - Archive` to next MARK
- Git Status (MARK - Git Status): from `// MARK: - Git Status` to next MARK
- Reconcile (MARK - Reconcile): from `// MARK: - Reconcile` to end

- [ ] **Step 2: Create WorktreeLifecycle+Create.swift**

Extract the Create section into a new file as an extension:
```swift
import Foundation
import TBDShared

extension WorktreeLifecycle {
    // MARK: - Create
    // ... paste the Create section and setupTerminals helper
}
```

- [ ] **Step 3: Create WorktreeLifecycle+Archive.swift**

Extract the Archive and Revive sections:
```swift
import Foundation
import TBDShared

extension WorktreeLifecycle {
    // MARK: - Archive
    // ... paste archive method

    // MARK: - Revive
    // ... paste revive method
}
```

- [ ] **Step 4: Create WorktreeLifecycle+Reconcile.swift**

Extract the Reconcile and Git Status sections:
```swift
import Foundation
import TBDShared

extension WorktreeLifecycle {
    // MARK: - Git Status
    // ... paste git status methods

    // MARK: - Reconcile
    // ... paste reconcile method
}
```

- [ ] **Step 5: Trim WorktreeLifecycle.swift to just the struct definition**

The original file should only contain:
- The error enum
- The struct definition with properties and init
- The `defaultShell` computed property

- [ ] **Step 6: Verify build and tests**

Run: `swift build && swift test`
Expected: Build succeeds, all tests pass. No behavior changes.

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/
git commit -m "refactor: split WorktreeLifecycle into focused extensions (Create, Archive, Reconcile)"
```

---

### Task 2: Split AppState

**Files:**
- Modify: `Sources/TBDApp/AppState.swift`
- Create: `Sources/TBDApp/AppState+Repos.swift`
- Create: `Sources/TBDApp/AppState+Worktrees.swift`
- Create: `Sources/TBDApp/AppState+Terminals.swift`
- Create: `Sources/TBDApp/AppState+Notifications.swift`

- [ ] **Step 1: Read AppState.swift and identify exact line ranges**

Map the MARK sections. Key boundaries:
- Class definition + properties + init + polling + connection: keep in main file
- Repo Actions: extract
- Worktree Actions + Keyboard Shortcut Actions: extract together (shortcuts call worktree methods)
- Terminal Actions: extract
- Notification Actions + Daemon Status + Helpers: extract together

- [ ] **Step 2: Create AppState+Repos.swift**

```swift
import Foundation
import TBDShared

extension AppState {
    // MARK: - Repo Actions
    // ... addRepo, removeRepo
}
```

- [ ] **Step 3: Create AppState+Worktrees.swift**

```swift
import Foundation
import TBDShared

extension AppState {
    // MARK: - Worktree Actions
    // ... createWorktree, archiveWorktree, reviveWorktree, renameWorktree

    // MARK: - Keyboard Shortcut Actions
    // ... allWorktreesOrdered, focusedRepoID, newWorktreeInFocusedRepo, etc.
}
```

- [ ] **Step 4: Create AppState+Terminals.swift**

```swift
import Foundation
import TBDShared

extension AppState {
    // MARK: - Terminal Actions
    // ... createTerminal, sendToTerminal
}
```

- [ ] **Step 5: Create AppState+Notifications.swift**

```swift
import Foundation
import TBDShared

extension AppState {
    // MARK: - Notifications
    // ... notify, markNotificationsRead

    // MARK: - Daemon Status
    // ... fetchDaemonStatus, startDaemonAndConnect

    // MARK: - Helpers
    // ... handleConnectionError, showAlert
}
```

- [ ] **Step 6: Trim AppState.swift to core**

Keep only: class definition, published properties, init, polling, connection methods, refresh methods.

- [ ] **Step 7: Verify build and tests**

Run: `swift build && swift test`
Expected: Build succeeds, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/TBDApp/AppState*.swift
git commit -m "refactor: split AppState into focused extensions (Repos, Worktrees, Terminals, Notifications)"
```

---

### Task 3: Split RPCRouter

**Files:**
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift`
- Create: `Sources/TBDDaemon/Server/RPCRouter+RepoHandlers.swift`
- Create: `Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift`
- Create: `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift`

- [ ] **Step 1: Read RPCRouter.swift and identify exact line ranges**

The switch statement in `handle()` stays in the main file. Each handler method moves to its extension.

- [ ] **Step 2: Create RPCRouter+RepoHandlers.swift**

```swift
import Foundation
import TBDShared

extension RPCRouter {
    // handleRepoAdd, handleRepoRemove, handleRepoList
}
```

Note: `handleRepoAdd` is the largest handler (~60 lines) because it creates the main worktree and triggers reconciliation. It stays as-is — just moves to its own file.

- [ ] **Step 3: Create RPCRouter+WorktreeHandlers.swift**

```swift
import Foundation
import TBDShared

extension RPCRouter {
    // handleWorktreeCreate, handleWorktreeList, handleWorktreeArchive,
    // handleWorktreeRevive, handleWorktreeRename
}
```

- [ ] **Step 4: Create RPCRouter+TerminalHandlers.swift**

```swift
import Foundation
import TBDShared

extension RPCRouter {
    // handleTerminalCreate, handleTerminalList, handleTerminalSend
    // handleNotify, handleNotificationsList, handleNotificationsMarkRead
    // handleCleanup, handleDaemonStatus, handleResolvePath
}
```

- [ ] **Step 5: Trim RPCRouter.swift to just class definition + dispatch**

Keep: class definition, properties, init, the `handle()` method with the switch statement.

- [ ] **Step 6: Verify build and tests**

Run: `swift build && swift test`
Expected: Build succeeds, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter*.swift
git commit -m "refactor: split RPCRouter into focused handler extensions (Repo, Worktree, Terminal)"
```

---

### Task 4: Fix polling comparison bug

While we're cleaning up, fix the `map(\.id)` optimization that silently drops property changes (review items #3 and #4).

**Files:**
- Modify: `Sources/TBDApp/AppState.swift` (or `AppState+Repos.swift` after Task 2)

- [ ] **Step 1: Replace ID-only comparisons with full equality checks**

In `refreshRepos()`:
```swift
// Before (drops property changes):
if fetchedRepos.map(\.id) != repos.map(\.id) {
    repos = fetchedRepos
}

// After (detects all changes):
if fetchedRepos != repos {
    repos = fetchedRepos
}
```

This requires `Repo` to conform to `Equatable`. Check if it already does — if not, add conformance.

Do the same for `refreshWorktrees()` and `refreshTerminals()`.

- [ ] **Step 2: Add Equatable conformance if needed**

In `Sources/TBDShared/Models.swift`, ensure `Repo`, `Worktree`, and `Terminal` conform to `Equatable`. Since they're structs with all Equatable properties, Swift can auto-synthesize this.

- [ ] **Step 3: Verify build and tests**

Run: `swift build && swift test`

- [ ] **Step 4: Commit**

```bash
git add Sources/
git commit -m "fix: polling now detects property changes, not just ID changes"
```

---

### Task 5: Add logging to silent try? calls

Fix review item #5 — reconcile's silent error swallowing.

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift` (after Task 1)

- [ ] **Step 1: Replace bare try? with try? + logging**

Find all `try?` in reconcile and archive. Replace:
```swift
// Before:
try? await tmux.killWindow(server: ..., windowID: ...)

// After:
do {
    try await tmux.killWindow(server: ..., windowID: ...)
} catch {
    debugLog("RECONCILE: failed to kill window \(terminal.tmuxWindowID): \(error)")
}
```

Use the existing `debugLog` function (writes to `/tmp/tbd-bridge.log`). Only add logging to the cleanup/reconcile paths — keep `try?` for truly best-effort operations like post-hooks.

- [ ] **Step 2: Verify build and tests**

Run: `swift build && swift test`

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/
git commit -m "fix: log errors in reconcile instead of silently swallowing"
```

---

## Post-Completion Verification

After all tasks:

1. `swift build` — all targets compile
2. `swift test` — all tests pass
3. Line count check: no file over 200 lines except word lists (Adjectives.swift, Animals.swift)
4. `scripts/restart.sh` — daemon + app still work end-to-end
5. Run `/update-project-docs` to regenerate file map
