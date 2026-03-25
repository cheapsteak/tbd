# Lucide Icons + Git Status Cleanup

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Octicon SVGs with Lucide icons, remove the separate git status icon column, and fold conflict detection into the unified worktree icon.

**Architecture:** Simplify the two-column icon system (git status + PR status) into a single icon slot per worktree row. Remove dead `GitStatus` enum values (`merged`, `behind`), keeping only a boolean `hasConflicts` on `Worktree`. Replace all 4 bundled Octicon SVGs with Lucide equivalents and add `git-merge-conflict`. The conflict icon displays when conflicts are detected, trumping the PR icon (you can't merge anyway).

**Tech Stack:** SwiftUI, GRDB (database migration), Lucide SVGs

---

### Task 1: Download Lucide SVGs

**Files:**
- Create: `Sources/TBDApp/Resources/Icons/git-pull-request.svg` (overwrite)
- Create: `Sources/TBDApp/Resources/Icons/git-merge.svg` (overwrite)
- Create: `Sources/TBDApp/Resources/Icons/git-pull-request-closed.svg` (overwrite)
- Create: `Sources/TBDApp/Resources/Icons/git-merge-conflict.svg`
- Delete: `Sources/TBDApp/Resources/Icons/x-circle.svg` (unused)

- [ ] **Step 1: Fetch Lucide SVGs from GitHub**

Download the 16px versions from `https://unpkg.com/lucide-static@latest/icons/`. The filenames match: `git-pull-request.svg`, `git-merge.svg`, `git-pull-request-closed.svg` (check if this exists — may be `git-pull-request-closed`), `git-merge-conflict.svg`.

If `git-pull-request-closed` doesn't exist in Lucide, use `git-pull-request-draft` or construct from `git-pull-request` with an X overlay. Check https://lucide.dev/icons/ to confirm exact names.

- [ ] **Step 2: Replace the 4 existing SVGs and add the new one**

Overwrite the 3 matching files and add `git-merge-conflict.svg`. Delete `x-circle.svg` (grep confirmed it's unused).

- [ ] **Step 3: Rename the loader function**

In `Sources/TBDApp/Sidebar/WorktreeRowView.swift`, rename `loadOcticon` → `loadIcon` (it's no longer Octicon-specific). No logic changes.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Resources/Icons/ Sources/TBDApp/Sidebar/WorktreeRowView.swift
git commit -m "feat: replace Octicon SVGs with Lucide icons"
```

---

### Task 2: Simplify GitStatus → hasConflicts boolean

**Files:**
- Modify: `Sources/TBDShared/Models.swift` — remove `GitStatus` enum, add `hasConflicts: Bool` to `Worktree`
- Modify: `Sources/TBDDaemon/Database/Database.swift` — add migration replacing `gitStatus` column with `hasConflicts`
- Modify: `Sources/TBDDaemon/Database/WorktreeStore.swift` — update record type and `updateGitStatus` → `updateHasConflicts`
- Modify: `Sources/TBDDaemon/Server/StateSubscription.swift` — update delta type
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift` — simplify to set boolean
- Modify: `Tests/TBDDaemonTests/GitStatusTests.swift` — update all tests

- [ ] **Step 1: Write failing tests for the new boolean model**

Update `Tests/TBDDaemonTests/GitStatusTests.swift`:
- `newWorktreeHasCurrentGitStatus` → `newWorktreeHasNoConflicts`: `#expect(wt.hasConflicts == false)`
- `updateGitStatusToConflicts` → `updateHasConflictsToTrue`: set `hasConflicts = true`, verify
- Remove `updateGitStatusToBehind` (no longer a concept)
- `updateGitStatusRoundTrip` → `hasConflictsRoundTrip`: set true then false
- `refreshGitStatusesDetectsConflicts` → verify `hasConflicts == true`
- `refreshGitStatusesDetectsBehind` → remove (behind is no longer tracked)
- `refreshGitStatusesSkipsMerged` → remove (merged is no longer a status)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GitStatusTests`
Expected: compilation errors (GitStatus enum still exists, hasConflicts doesn't)

- [ ] **Step 3: Update Models.swift**

Remove the `GitStatus` enum entirely. On `Worktree`:
- Replace `public var gitStatus: GitStatus` with `public var hasConflicts: Bool`
- Update `init` — replace `gitStatus: GitStatus = .current` with `hasConflicts: Bool = false`

- [ ] **Step 4: Add database migration**

In `Sources/TBDDaemon/Database/Database.swift`, add a new migration (next sequential number after existing ones). The migration should:
1. Add column `hasConflicts` as `.boolean`, `.notNull()`, `.defaults(to: false)`
2. Copy `gitStatus == 'conflicts'` rows to `hasConflicts = true`: `UPDATE worktree SET hasConflicts = (gitStatus = 'conflicts')`
3. Drop column `gitStatus` (SQLite 3.35+ supports `ALTER TABLE DROP COLUMN`; if not available, recreate table)

**Important:** Since SQLite `DROP COLUMN` support varies, safer approach is to just add the new column and leave `gitStatus` in place — the record type simply won't map it. GRDB ignores extra columns.

- [ ] **Step 5: Update WorktreeStore.swift**

- `WorktreeRecord`: replace `var gitStatus: String` with `var hasConflicts: Bool`
- `init(from:)`: `self.hasConflicts = wt.hasConflicts`
- `toModel()`: `hasConflicts: hasConflicts`
- Rename `updateGitStatus(id:gitStatus:)` → `updateHasConflicts(id:hasConflicts:)` with `Bool` parameter

- [ ] **Step 6: Update StateSubscription.swift**

`WorktreeGitStatusDelta`:
- Rename to `WorktreeConflictDelta`
- Replace `let gitStatus: GitStatus` with `let hasConflicts: Bool`
- Update `StateDelta` case: `.worktreeGitStatusChanged` → `.worktreeConflictsChanged`

- [ ] **Step 7: Update WorktreeLifecycle+Reconcile.swift**

`refreshGitStatuses`:
- Remove the `if wt.gitStatus == .merged { continue }` skip (merged is gone)
- `computeGitStatus` → `checkHasConflicts` returning `Bool?`
  - If `isMergeBaseAncestor` returns true → `false` (no conflicts)
  - Otherwise run `checkMergeConflicts` → return `hasConflicts`
- Compare `newHasConflicts != wt.hasConflicts`, call `updateHasConflicts`, broadcast `.worktreeConflictsChanged`

- [ ] **Step 8: Run tests**

Run: `swift test --filter GitStatusTests`
Expected: all pass

- [ ] **Step 9: Commit**

```bash
git add Sources/TBDShared/Models.swift Sources/TBDDaemon/Database/ Sources/TBDDaemon/Server/StateSubscription.swift Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift Tests/TBDDaemonTests/GitStatusTests.swift
git commit -m "refactor: replace GitStatus enum with hasConflicts boolean"
```

---

### Task 3: Unify the icon column in WorktreeRowView

**Files:**
- Modify: `Sources/TBDApp/Sidebar/WorktreeRowView.swift`

- [ ] **Step 1: Replace the two icon slots with one unified icon**

Remove `gitStatusIcon`, `gitStatusColor` computed properties entirely.

Replace `prIcon` and `prIconColor` with a single `worktreeIcon` / `worktreeIconColor` pair:

```swift
private var worktreeIcon: String? {
    guard !isMain else { return nil }
    // Conflicts trump everything
    if worktree.hasConflicts {
        return "git-merge-conflict"
    }
    // PR status
    guard let status = appState.prStatuses[worktree.id] else { return nil }
    switch status.state {
    case .open, .changesRequested, .mergeable: return "git-pull-request"
    case .merged:                              return "git-merge"
    case .closed:                              return "git-pull-request-closed"
    }
}

private var worktreeIconColor: Color {
    guard !isMain else { return .secondary }
    if worktree.hasConflicts {
        return .orange
    }
    guard let status = appState.prStatuses[worktree.id] else { return .secondary }
    switch status.state {
    case .open:             return .secondary
    case .changesRequested: return .red
    case .mergeable:        return .green
    case .merged:           return .purple
    case .closed:           return .secondary
    }
}
```

- [ ] **Step 2: Update the body to use a single icon slot**

Remove the SF Symbol `gitStatusIcon` block (lines 96-100). Replace the `prIcon` block with:

```swift
if let icon = worktreeIcon, let nsImage = loadIcon(icon) {
    Image(nsImage: nsImage)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 12, height: 12)
        .foregroundStyle(worktreeIconColor)
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Sidebar/WorktreeRowView.swift
git commit -m "feat: unify worktree row into single Lucide icon slot"
```

---

### Task 4: Clean up Daemon.swift reference (if any)

- [ ] **Step 1: Grep for any remaining references to old names**

Search for `GitStatus`, `gitStatus`, `worktreeGitStatusChanged`, `loadOcticon` across the entire `Sources/` tree. Fix any remaining references.

**Known false positives to ignore:**
- `Sources/TBDApp/FileViewer/FileViewerPanel.swift` — has `GitFileStatus`, `loadGitStatus`, `parseGitStatus` which are unrelated (they parse `git status` CLI output for the file diff panel)
- `Sources/TBDDaemon/Daemon.swift` — calls `lifecycle.refreshGitStatuses(repoID:)` — this does NOT need changing since the method name is preserved, only its internals changed in Task 2

- [ ] **Step 2: Run full test suite**

Run: `swift test`
Expected: all tests pass

- [ ] **Step 3: Commit any remaining fixes**

```bash
git add -A && git commit -m "fix: clean up remaining GitStatus references"
```
