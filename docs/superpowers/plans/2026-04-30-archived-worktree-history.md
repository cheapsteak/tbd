# Archived Worktree Conversation History — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Browse Claude conversation history for archived worktrees in a nested master-detail view, with revive-with-session as the primary action.

**Architecture:** `ArchivedWorktreesView` becomes an outer `HSplit`: left rail = selectable archived-worktree list, right pane = the existing `HistoryPaneView` rendered against the selected worktree's UUID. `HistoryPaneView` gains a `transcriptAction` parameter to swap "Resume" for "Revive with this session" in archived mode. Auto-select the most-recent archived row and the first session in any history view. Recently-revived rows linger with a status pill until the user navigates away.

**Tech Stack:** Swift 6, SwiftUI, GRDB (daemon DB), NIO (RPC). macOS native unbundled SPM executable.

**Spec:** [`docs/superpowers/specs/2026-04-30-archived-worktree-history-design.md`](../specs/2026-04-30-archived-worktree-history-design.md)

---

## Pre-flight

- [ ] **Verify clean working tree.** Run `git status` — must be clean before starting. If not, ask the user how to proceed.
- [ ] **Read the spec end-to-end** before starting any task. It is the source of truth for behavior.

## Task 1: Add `preferredSessionID` to revive RPC params

**Files:**
- Modify: `Sources/TBDShared/RPCProtocol.swift:346-356` (extend `WorktreeReviveParams`)

- [ ] **Step 1: Extend `WorktreeReviveParams`**

Replace the struct at `Sources/TBDShared/RPCProtocol.swift:346-356` with:

```swift
public struct WorktreeReviveParams: Codable, Sendable {
    public let worktreeID: UUID
    /// Initial tmux window size in cells (see WorktreeCreateParams).
    public let cols: Int?
    public let rows: Int?
    /// When set, the daemon reorders the worktree's stored
    /// `archivedClaudeSessions` so this ID is first before resuming the
    /// primary Claude terminal. Optional — nil preserves existing order.
    public let preferredSessionID: String?
    public init(worktreeID: UUID, cols: Int? = nil, rows: Int? = nil, preferredSessionID: String? = nil) {
        self.worktreeID = worktreeID
        self.cols = cols
        self.rows = rows
        self.preferredSessionID = preferredSessionID
    }
}
```

The parameter must be optional with a default so existing call sites compile unchanged. Codable's auto-synthesis will decode-or-default-nil when the field is missing in old daemon JSON, but since both sides ship together this is just defense in depth.

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDShared/RPCProtocol.swift
git commit -m "feat(rpc): add preferredSessionID to WorktreeReviveParams"
```

---

## Task 2: Daemon reorders `archivedClaudeSessions` on revive

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift` (revive path)
- Modify: `Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift` (forward param)
- Test: `Tests/TBDDaemonTests/WorktreeReviveReorderTests.swift` (new)

- [ ] **Step 1: Read the existing revive lifecycle**

Read `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift` from line 70 onward to see the `reviveWorktree(worktreeID:cols:rows:skipClaude:)` signature and how it loads the worktree, then calls `setupTerminals(...,  archivedClaudeSessions: worktree.archivedClaudeSessions, ...)`.

- [ ] **Step 2: Extend the lifecycle function signature**

In `WorktreeLifecycle+Archive.swift`, locate the `reviveWorktree` function (around line 70). Add a `preferredSessionID: String? = nil` parameter at the end of the signature.

Inside the function, immediately before the `try await setupTerminals(...)` call (around line 135), build the session list with the preferred ID floated to the front:

```swift
let sessions: [String]?
if let preferred = preferredSessionID,
   let stored = worktree.archivedClaudeSessions,
   stored.contains(preferred) {
    sessions = [preferred] + stored.filter { $0 != preferred }
} else {
    sessions = worktree.archivedClaudeSessions
}
```

Then change the call site to pass `archivedClaudeSessions: sessions` instead of `worktree.archivedClaudeSessions`.

- [ ] **Step 3: Persist the reordered list back to the DB**

Right after computing `sessions` and before `setupTerminals`, persist the new order so a subsequent re-archive preserves the user's last-resumed-first ordering:

```swift
if let sessions, sessions != worktree.archivedClaudeSessions {
    try await db.worktrees.setArchivedClaudeSessions(id: worktreeID, sessions: sessions)
}
```

If `WorktreeStore` does not have a `setArchivedClaudeSessions(id:sessions:)` method, add it. Check `Sources/TBDDaemon/Database/WorktreeStore.swift` first — there's an existing JSON-encode-and-store pattern around line 190 (`record.archivedClaudeSessions = try String(...)`). Mirror that pattern.

If you add the method, signature:

```swift
func setArchivedClaudeSessions(id: UUID, sessions: [String]) async throws {
    try await db.write { db in
        guard var record = try WorktreeRecord.fetchOne(db, key: id) else { return }
        let json = try String(data: JSONEncoder().encode(sessions), encoding: .utf8) ?? "[]"
        record.archivedClaudeSessions = json
        try record.update(db)
    }
}
```

- [ ] **Step 4: Forward the param from the RPC handler**

In `Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift` find the revive handler (around line 71). Replace:

```swift
let worktree = try await lifecycle.reviveWorktree(worktreeID: params.worktreeID, cols: params.cols, rows: params.rows)
```

with:

```swift
let worktree = try await lifecycle.reviveWorktree(
    worktreeID: params.worktreeID,
    cols: params.cols,
    rows: params.rows,
    preferredSessionID: params.preferredSessionID
)
```

- [ ] **Step 5: Write a focused test**

Create `Tests/TBDDaemonTests/WorktreeReviveReorderTests.swift`:

```swift
import XCTest
@testable import TBDDaemon
import TBDShared

final class WorktreeReviveReorderTests: XCTestCase {
    func testReorderFloatsPreferredSessionFirst() {
        let stored = ["a", "b", "c"]
        let preferred = "b"
        let result = reorderSessions(stored: stored, preferred: preferred)
        XCTAssertEqual(result, ["b", "a", "c"])
    }

    func testNilPreferredKeepsOrder() {
        let stored = ["a", "b", "c"]
        let result = reorderSessions(stored: stored, preferred: nil)
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testUnknownPreferredKeepsOrder() {
        let stored = ["a", "b", "c"]
        let result = reorderSessions(stored: stored, preferred: "z")
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testNilStoredStaysNil() {
        let result = reorderSessions(stored: nil, preferred: "anything")
        XCTAssertNil(result)
    }
}
```

To make the logic testable without spinning up the full lifecycle, extract the reorder block into a free `internal func reorderSessions(stored: [String]?, preferred: String?) -> [String]?` near the top of `WorktreeLifecycle+Archive.swift` and call it from both places. The function:

```swift
internal func reorderSessions(stored: [String]?, preferred: String?) -> [String]? {
    guard let preferred, let stored, stored.contains(preferred) else { return stored }
    return [preferred] + stored.filter { $0 != preferred }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter WorktreeReviveReorderTests`
Expected: 4 tests pass.

- [ ] **Step 7: Build everything**

Run: `swift build`
Expected: builds clean (no daemon callers broke).

- [ ] **Step 8: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift \
        Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift \
        Sources/TBDDaemon/Database/WorktreeStore.swift \
        Tests/TBDDaemonTests/WorktreeReviveReorderTests.swift
git commit -m "feat(daemon): reorder archivedClaudeSessions on revive when preferredSessionID provided"
```

---

## Task 3: Update `DaemonClient.reviveWorktree` to pass `preferredSessionID`

**Files:**
- Modify: `Sources/TBDApp/DaemonClient.swift:406` (and the function body just below)

- [ ] **Step 1: Locate the function**

Read `Sources/TBDApp/DaemonClient.swift` around line 406. The current signature is `func reviveWorktree(id: UUID, cols: Int? = nil, rows: Int? = nil) async throws`.

- [ ] **Step 2: Add the parameter**

Add `preferredSessionID: String? = nil` as the last parameter, and pass it into the `WorktreeReviveParams` initializer in the function body.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/DaemonClient.swift
git commit -m "feat(app): plumb preferredSessionID through DaemonClient.reviveWorktree"
```

---

## Task 4: Add `TranscriptAction` parameter to `HistoryPaneView`

**Files:**
- Modify: `Sources/TBDApp/Panes/HistoryPaneView.swift`

- [ ] **Step 1: Add the enum and parameter**

At the top of `Sources/TBDApp/Panes/HistoryPaneView.swift` (just below the imports), add:

```swift
/// The action exposed in the transcript header. Determines the button
/// label and which AppState method the button invokes.
enum TranscriptAction {
    /// Active worktree: open a new terminal in the same worktree resuming
    /// the selected Claude session.
    case resume
    /// Archived worktree: revive the worktree and resume the selected
    /// session in its primary terminal.
    case reviveWithSession
}
```

- [ ] **Step 2: Thread the parameter through `HistoryPaneView`**

Modify the `HistoryPaneView` struct (around line 6):

```swift
struct HistoryPaneView: View {
    let worktreeID: UUID
    var transcriptAction: TranscriptAction = .resume
    @EnvironmentObject var appState: AppState
    ...
}
```

In `body`, where `SessionTranscriptView(...)` is constructed (around line 54), pass the action through:

```swift
SessionTranscriptView(
    sessionId: summary.sessionId,
    worktreeID: worktreeID,
    summary: summary,
    action: transcriptAction
)
```

- [ ] **Step 3: Branch in `SessionTranscriptView`**

Modify `SessionTranscriptView` (around line 259):

```swift
struct SessionTranscriptView: View {
    let sessionId: String
    let worktreeID: UUID
    let summary: SessionSummary
    let action: TranscriptAction
    @EnvironmentObject var appState: AppState
    ...
}
```

In its `body`, replace the existing `Button("Resume") { ... }` block (around line 288) with:

```swift
Button(actionLabel) {
    Task {
        switch action {
        case .resume:
            await appState.resumeSession(worktreeID: worktreeID, sessionId: sessionId)
        case .reviveWithSession:
            await appState.reviveWithSession(worktreeID: worktreeID, sessionId: sessionId)
        }
    }
}
.buttonStyle(.borderedProminent)
.controlSize(.small)
```

Add a computed property to `SessionTranscriptView`:

```swift
private var actionLabel: String {
    switch action {
    case .resume: return "Resume"
    case .reviveWithSession: return "Revive with this session"
    }
}
```

`appState.reviveWithSession(...)` will be added in Task 7. The build will fail until then — that's fine, we'll fix the order if we batch it, otherwise this task ends with a known-broken build that Task 7 resolves. (See Step 4.)

- [ ] **Step 4: Skip build verification for now**

Do NOT run `swift build` after this task — the call to `reviveWithSession` will not yet exist. The next tasks add it. This is the only task in the plan that ends with a non-building tree.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDApp/Panes/HistoryPaneView.swift
git commit -m "feat(app): add TranscriptAction parameter to HistoryPaneView"
```

---

## Task 5: Add `selectedArchivedWorktreeIDs` and `revivingArchived` state

**Files:**
- Modify: `Sources/TBDApp/AppState.swift`

- [ ] **Step 1: Add the published properties**

In `Sources/TBDApp/AppState.swift`, immediately after the existing `historyActiveWorktrees` / `historyLoadStates` / `selectedSessionIDs` block (around lines 174-178), add:

```swift
/// Selected archived worktree per repo (left rail of the archived view's nested master-detail).
@Published var selectedArchivedWorktreeIDs: [UUID: UUID] = [:]

/// Worktrees the user just revived from the archived view. Keeps the row
/// visible with a status indicator until the user navigates away from the
/// archived section. Cleared by `AppState+Navigation` when the active
/// sidebar selection moves elsewhere.
@Published var revivingArchived: [UUID: ReviveState] = [:]
```

- [ ] **Step 2: Add the `ReviveState` enum**

Define `ReviveState` at file scope (above the `AppState` class declaration, near line 8):

```swift
/// Transition state for a worktree being revived from the archived view.
/// Holds a snapshot of the `Worktree` so the row can keep rendering even
/// after the daemon removes it from `archivedWorktrees`.
enum ReviveState: Equatable {
    case inFlight(snapshot: Worktree)
    case done(snapshot: Worktree)

    var snapshot: Worktree {
        switch self {
        case .inFlight(let s), .done(let s): return s
        }
    }
}
```

`Worktree` already conforms to `Equatable` via its `Codable`/`Hashable` synthesis; verify by reading `Sources/TBDShared/Models.swift`. If it does not, replace `Equatable` above with `: Equatable where Worktree: Equatable` is unnecessary — instead drop the `Equatable` conformance and provide manual `==` based on `snapshot.id`. (Equatable is needed only so SwiftUI diffs the dictionary efficiently.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds clean (no consumers yet).

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/AppState.swift
git commit -m "feat(app): add ReviveState and per-repo archived selection state"
```

---

## Task 6: Universal first-session auto-select in `fetchSessions`

**Files:**
- Modify: `Sources/TBDApp/AppState+History.swift`
- Test: `Tests/TBDAppTests/HistoryAutoSelectTests.swift` (new)

- [ ] **Step 1: Modify `fetchSessions`**

In `Sources/TBDApp/AppState+History.swift`, locate the `fetchSessions(worktreeID:)` function (line 58). After the `historyLoadStates[worktreeID] = .loaded(fresh)` assignment, add auto-selection:

```swift
historyLoadStates[worktreeID] = .loaded(fresh)
// Auto-select the first session on initial load if nothing is selected yet.
// Applies to both active and archived worktrees.
if selectedSessionIDs[worktreeID] == nil, let first = fresh.first {
    await selectSession(first, worktreeID: worktreeID)
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Manual verification note**

Skip a unit test for this — `fetchSessions` calls into `daemonClient.listSessions` and the existing `TBDAppTests` target does not have a daemon mock pattern set up. Instead, after restarting we'll verify manually that opening the history pane on an active worktree now auto-selects the first session and loads its transcript. Add this to the test plan in Task 12.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/AppState+History.swift
git commit -m "feat(app): auto-select first session on initial history load"
```

---

## Task 7: Add `reviveWithSession` to AppState

**Files:**
- Modify: `Sources/TBDApp/AppState+History.swift` (add the method)
- Modify: `Sources/TBDApp/AppState+Worktrees.swift` (helper for shared revive flow)

- [ ] **Step 1: Add `reviveWithSession`**

At the bottom of `Sources/TBDApp/AppState+History.swift` (inside the `extension AppState {}` block), add:

```swift
/// Revive an archived worktree and resume the selected Claude session.
/// Marks the row as `inFlight` immediately so the archived view can show
/// a status pill, then flips to `.done` on success or clears on failure.
func reviveWithSession(worktreeID: UUID, sessionId: String) async {
    // Find the snapshot in archivedWorktrees so we can keep the row visible
    // after the daemon reconciles the worktree out of the archived list.
    guard let snapshot = archivedWorktrees.values
        .flatMap({ $0 })
        .first(where: { $0.id == worktreeID })
    else {
        return
    }
    revivingArchived[worktreeID] = .inFlight(snapshot: snapshot)

    // Advance the archived row selection if this row is currently selected
    // (rule: in-flight rows are non-selectable).
    advanceArchivedSelectionIfNeeded(worktreeID: worktreeID)

    do {
        let size = mainAreaTerminalSize()
        try await daemonClient.reviveWorktree(
            id: worktreeID,
            cols: size.cols,
            rows: size.rows,
            preferredSessionID: sessionId
        )
        revivingArchived[worktreeID] = .done(snapshot: snapshot)
        await refreshWorktrees()
        if let repoID = snapshot.repoID as UUID? {
            await refreshArchivedWorktrees(repoID: repoID)
        }
    } catch {
        revivingArchived.removeValue(forKey: worktreeID)
        handleConnectionError(error)
    }
}

/// If the in-flight worktree was the selected archived row for its repo,
/// move selection to the next-most-recent archived row (or clear).
private func advanceArchivedSelectionIfNeeded(worktreeID: UUID) {
    let repoID = archivedWorktrees.first(where: { (_, wts) in
        wts.contains(where: { $0.id == worktreeID })
    })?.key
    guard let repoID, selectedArchivedWorktreeIDs[repoID] == worktreeID else { return }
    let remaining = (archivedWorktrees[repoID] ?? [])
        .filter { $0.id != worktreeID }
        .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    if let next = remaining.first {
        selectedArchivedWorktreeIDs[repoID] = next.id
    } else {
        selectedArchivedWorktreeIDs.removeValue(forKey: repoID)
    }
}
```

`snapshot.repoID` is a non-optional `UUID` on `Worktree`; the `as UUID?` cast above is wrong — drop it. Use `snapshot.repoID` directly:

```swift
await refreshArchivedWorktrees(repoID: snapshot.repoID)
```

(Remove the `if let repoID = ... as UUID?` block. The corrected version is just two lines.)

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds clean. The `HistoryPaneView` call site from Task 4 now resolves.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/AppState+History.swift
git commit -m "feat(app): add reviveWithSession with lingering revive state"
```

---

## Task 8: Auto-select most-recent archived row

**Files:**
- Modify: `Sources/TBDApp/AppState+Worktrees.swift` (in `refreshArchivedWorktrees`)

- [ ] **Step 1: Add auto-select logic to `refreshArchivedWorktrees`**

In `Sources/TBDApp/AppState+Worktrees.swift`, locate `refreshArchivedWorktrees(repoID:)` (line 192). Replace the body with:

```swift
func refreshArchivedWorktrees(repoID: UUID) async {
    do {
        let archived = try await daemonClient.listWorktrees(repoID: repoID, status: .archived)
        archivedWorktrees[repoID] = archived
        ensureArchivedSelectionValid(repoID: repoID)
    } catch {
        logger.error("Failed to list archived worktrees: \(error)")
    }
}

/// Ensure `selectedArchivedWorktreeIDs[repoID]` points to a row that
/// actually exists in the archived list (or in `revivingArchived` for that
/// repo). If unset or stale, set it to the most-recently-archived row.
/// Also kicks off the session fetch for the newly-selected worktree.
private func ensureArchivedSelectionValid(repoID: UUID) {
    let archived = (archivedWorktrees[repoID] ?? [])
    let lingering = revivingArchived.values
        .map(\.snapshot)
        .filter { $0.repoID == repoID }
    let allIDs = Set(archived.map(\.id) + lingering.map(\.id))

    let current = selectedArchivedWorktreeIDs[repoID]
    let needsNew = current == nil || !allIDs.contains(current!)
    guard needsNew else { return }

    let mostRecent = archived
        .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        .first
    if let pick = mostRecent {
        selectedArchivedWorktreeIDs[repoID] = pick.id
        Task { await fetchSessions(worktreeID: pick.id) }
    } else {
        selectedArchivedWorktreeIDs.removeValue(forKey: repoID)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/AppState+Worktrees.swift
git commit -m "feat(app): auto-select most-recently-archived row on refresh"
```

---

## Task 9: Clear `revivingArchived` on navigate-away

**Files:**
- Modify: `Sources/TBDApp/AppState+Navigation.swift`

- [ ] **Step 1: Add a clear-on-leave hook**

In `Sources/TBDApp/AppState+Navigation.swift`, modify `applyNavigationEntry` (around line 66) to clear lingering revive state for any repo whose archived view we are leaving:

```swift
private func applyNavigationEntry(_ entry: NavigationEntry) {
    let leavingRepoID = selectedRepoID
    switch entry {
    case .worktrees(let ids):
        if let leavingRepoID { clearRevivingArchived(repoID: leavingRepoID) }
        selectedRepoID = nil
        selectedWorktreeIDs = Set(ids)
        selectionOrder = ids
    case .repo(let id):
        if let leavingRepoID, leavingRepoID != id {
            clearRevivingArchived(repoID: leavingRepoID)
        }
        selectedWorktreeIDs = []
        selectedRepoID = id
        Task { await refreshArchivedWorktrees(repoID: id) }
    }
}
```

This handles back/forward. The forward "fresh navigation" path (e.g. clicking another sidebar entry) goes through `selectedWorktreeIDs.didSet` / `selectedRepoID.didSet` in `AppState.swift`. Add the same cleanup there.

- [ ] **Step 2: Add the helper**

At the bottom of `AppState+Navigation.swift` (still inside `extension AppState`), add:

```swift
/// Drop any lingering revive snapshots that belong to the given repo —
/// called when the user leaves that repo's archived view, so coming back
/// shows a fresh list without "Revived ✓" rows.
func clearRevivingArchived(repoID: UUID) {
    revivingArchived = revivingArchived.filter { _, state in
        state.snapshot.repoID != repoID
    }
}
```

- [ ] **Step 3: Wire fresh navigation in `AppState.swift`**

In `Sources/TBDApp/AppState.swift`, update the `selectedWorktreeIDs` `didSet` (lines 17-39). Inside the existing `if !selectedWorktreeIDs.isEmpty { ... }` block at line 35, add a clear call before `recordNavigation`:

```swift
if !selectedWorktreeIDs.isEmpty {
    if let leaving = selectedRepoID { clearRevivingArchived(repoID: leaving) }
    selectedRepoID = nil
    recordNavigation(.worktrees(selectionOrder))
}
```

Update the `selectedRepoID` `didSet` (lines 44-49) to clear the OLD repo's lingering state when switching to a different repo:

```swift
@Published var selectedRepoID: UUID? = nil {
    didSet {
        if let old = oldValue, old != selectedRepoID {
            clearRevivingArchived(repoID: old)
        }
        guard selectedRepoID != oldValue, let id = selectedRepoID else { return }
        recordNavigation(.repo(id))
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDApp/AppState.swift Sources/TBDApp/AppState+Navigation.swift
git commit -m "feat(app): clear lingering revive snapshots on navigate-away"
```

---

## Task 10: Refactor `ArchivedWorktreesView` into nested HSplit

**Files:**
- Modify: `Sources/TBDApp/ArchivedWorktreesView.swift` (full rewrite)

- [ ] **Step 1: Read the existing file**

Read the current `Sources/TBDApp/ArchivedWorktreesView.swift` end-to-end. Note the empty state, the header row, and the `ArchivedWorktreeRow` styling — the new version preserves these patterns.

- [ ] **Step 2: Rewrite the file**

Replace the entire contents with:

```swift
import SwiftUI
import TBDShared

struct ArchivedWorktreesView: View {
    let repoID: UUID
    @EnvironmentObject var appState: AppState

    @State private var listWidth: CGFloat = 280
    @State private var dragStartWidth: CGFloat? = nil

    /// Display rows = archived worktrees ∪ lingering revive snapshots,
    /// deduped by id, sorted by archivedAt desc.
    private var rows: [ArchivedRow] {
        let archived = (appState.archivedWorktrees[repoID] ?? [])
        let lingering = appState.revivingArchived
            .compactMap { (id, state) -> Worktree? in
                guard state.snapshot.repoID == repoID else { return nil }
                return state.snapshot
            }
        var byID: [UUID: Worktree] = [:]
        for wt in archived { byID[wt.id] = wt }
        for wt in lingering where byID[wt.id] == nil { byID[wt.id] = wt }
        return byID.values
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
            .map { wt in
                ArchivedRow(worktree: wt, reviveState: appState.revivingArchived[wt.id])
            }
    }

    private var selectedID: UUID? {
        appState.selectedArchivedWorktreeIDs[repoID]
    }

    var body: some View {
        if rows.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                leftRail
                    .frame(width: listWidth)
                divider
                rightPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Left rail

    private var leftRail: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Archived")
                    .font(.title3)
                    .fontWeight(.medium)
                Spacer()
                Text("\(rows.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rows) { row in
                            ArchivedWorktreeRow(
                                row: row,
                                isSelected: selectedID == row.id,
                                onSelect: { select(row) }
                            )
                            .id(row.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: appState.highlightedArchivedWorktreeID, initial: true) { _, newValue in
                    guard let id = newValue, rows.contains(where: { $0.id == id }) else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(900))
                        if appState.highlightedArchivedWorktreeID == id {
                            appState.highlightedArchivedWorktreeID = nil
                        }
                    }
                }
            }
        }
        .onAppear {
            // Trigger initial selection if nothing is set yet. The async refresh
            // path also calls into `ensureArchivedSelectionValid`, but on
            // re-appearances (cached `archivedWorktrees`) we still need this.
            if selectedID == nil, let first = rows.first?.worktree {
                appState.selectedArchivedWorktreeIDs[repoID] = first.id
                Task { await appState.fetchSessions(worktreeID: first.id) }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .contentShape(Rectangle().inset(by: -3))
            .cursor(.resizeLeftRight)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = listWidth }
                        let newWidth = (dragStartWidth ?? listWidth) + value.translation.width
                        listWidth = max(220, min(400, newWidth))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }

    // MARK: - Right pane

    @ViewBuilder
    private var rightPane: some View {
        if let id = selectedID,
           let row = rows.first(where: { $0.id == id }) {
            if (row.worktree.archivedClaudeSessions ?? []).isEmpty {
                noSessionsState(for: row.worktree)
            } else {
                HistoryPaneView(worktreeID: id, transcriptAction: .reviveWithSession)
            }
        } else {
            VStack(spacing: 8) {
                Text("Select a worktree")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func noSessionsState(for worktree: Worktree) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No archived sessions")
                .foregroundStyle(.secondary)
                .font(.callout)
            Button("Revive") {
                Task { await appState.reviveWorktree(id: worktree.id) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty list state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No Archived Worktrees")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func select(_ row: ArchivedRow) {
        // In-flight or done revives are non-selectable.
        guard row.reviveState == nil else { return }
        appState.selectedArchivedWorktreeIDs[repoID] = row.id
        Task { await appState.fetchSessions(worktreeID: row.id) }
    }
}

// MARK: - Row model

private struct ArchivedRow: Identifiable {
    let worktree: Worktree
    let reviveState: ReviveState?
    var id: UUID { worktree.id }
}

// MARK: - Row view

private struct ArchivedWorktreeRow: View {
    let row: ArchivedRow
    let isSelected: Bool
    let onSelect: () -> Void
    @EnvironmentObject var appState: AppState

    private var hasClaudeSessions: Bool {
        row.worktree.archivedClaudeSessions?.isEmpty == false
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.worktree.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    statusPill
                }
                HStack(spacing: 6) {
                    Label(row.worktree.branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                    if let archivedAt = row.worktree.archivedAt, row.reviveState == nil {
                        Text("·")
                        Text(archivedAt, format: .relative(presentation: .named))
                    }
                    if hasClaudeSessions, row.reviveState == nil {
                        let count = row.worktree.archivedClaudeSessions?.count ?? 0
                        Text("·")
                        Text("\(count) session\(count == 1 ? "" : "s")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowBackground)
        .cornerRadius(6)
        .padding(.horizontal, 8)
        .onTapGesture { onSelect() }
        .contextMenu {
            if row.reviveState == nil {
                Button("Revive") {
                    Task { await appState.reviveWorktree(id: row.worktree.id) }
                }
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch row.reviveState {
        case .inFlight:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Reviving…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .done:
            Text("Revived ✓")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.12), in: Capsule())
        case .none:
            EmptyView()
        }
    }

    private var rowBackground: Color {
        if appState.highlightedArchivedWorktreeID == row.worktree.id {
            return Color.accentColor.opacity(0.25)
        }
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        return Color.primary.opacity(0.03)
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/ArchivedWorktreesView.swift
git commit -m "feat(app): nested master-detail layout for archived worktrees"
```

---

## Task 11: Restart and manual verification

**Files:** none (runtime testing)

- [ ] **Step 1: Full restart**

This touches daemon + shared code. Per `CLAUDE.md`, use the worktree's own script and verify only one daemon/app pair is running.

Run from the worktree root: `scripts/restart.sh`

Then verify exactly one TBDDaemon and one TBDApp from this worktree path:

```bash
ps aux | grep -E "\.build/debug/TBD" | grep -v grep
```

If stale processes exist: `pkill -f TBDDaemon; pkill -f TBDApp` then re-run `scripts/restart.sh`.

- [ ] **Step 2: Verify active-worktree history auto-select**

In TBD, select an active worktree that has past Claude sessions. Open the history pane (existing toggle). Expected: the first session is selected on initial load and its transcript renders without manual clicking. (This is the universal auto-select behavior added in Task 6.)

- [ ] **Step 3: Verify archived view layout**

Click a repo's "Archived" sidebar entry. Expected:
- Left rail shows the archived list, draggable divider on its right edge.
- Right pane shows the most-recently-archived worktree's session list and the first session's transcript.
- No inline Revive buttons on rows.

- [ ] **Step 4: Verify selection switching**

Click a different archived row. Expected: right pane updates to show that worktree's sessions; the first session is auto-selected and its transcript loads.

- [ ] **Step 5: Verify revive-with-session**

With an archived row selected and a session selected in the middle column, click "Revive with this session" in the transcript header. Expected:
- The archived row immediately shows a `ProgressView` + "Reviving…".
- The row becomes non-selectable; selection moves to the next archived row.
- After revive completes, the row shows "Revived ✓" pill (green).
- The revived worktree appears in the active sidebar list.
- The new active worktree's primary terminal is resuming the chosen Claude session (verify by reading the terminal contents — it should show the conversation, not a fresh `claude` invocation).

- [ ] **Step 6: Verify lingering-row-clear-on-navigate**

With a "Revived ✓" row visible, click any other sidebar entry (active worktree or different repo's archived). Then click the original repo's "Archived" entry again. Expected: the revived row is gone — list is fresh.

- [ ] **Step 7: Verify context-menu Revive**

Right-click any archived row. Expected: a "Revive" menu item appears. Selecting it kicks off a session-less revive (uses stored `archivedClaudeSessions.first` order), with the same in-flight / done UI feedback as Step 5.

- [ ] **Step 8: Verify empty-archived-sessions state**

Find or create an archived worktree with no Claude sessions (the `archivedClaudeSessions` field is nil/empty). Select it. Expected: right pane shows "No archived sessions" + a plain "Revive" button. Clicking the button revives the worktree.

- [ ] **Step 9: Verify path-based session resolution survives archive**

For an archived worktree with sessions, confirm the right pane's session list actually populates (not empty). This validates the spec's assumption that `worktree.path` is preserved in the DB after archive and that Claude's `~/.claude/projects/...` JSONLs still resolve. If the list is unexpectedly empty for an archived worktree that *did* have sessions before archive, escalate — the daemon's `handleSessionList` may need a fallback path that uses `archivedClaudeSessions` IDs to find files.

- [ ] **Step 10: Note manual results**

Reply with which steps passed and which (if any) revealed issues. Do not commit anything in this task — it's verification only.

---

## Self-Review

Run this checklist after writing all the tasks above (the agent doing the implementation does NOT need to repeat this — it's for the planner).

**Spec coverage:**
- Layout (HSplit, draggable, 220–400 clamp): Task 10 ✓
- HistoryPaneView parameterization: Task 4 ✓
- AppState additions (selectedArchivedWorktreeIDs, revivingArchived, ReviveState): Task 5 ✓
- reviveWithSession method: Task 7 ✓
- Daemon reorder support: Tasks 1–3 ✓
- Universal first-session auto-select: Task 6 ✓
- Most-recent-archived auto-select: Task 8 ✓ + onAppear safety net in Task 10 ✓
- Lingering revived rows + clear-on-navigate-away: Tasks 7, 9 ✓
- Per-row inline Revive removed; context-menu Revive added: Task 10 ✓
- Empty-state right pane Revive button: Task 10 ✓

**Placeholder scan:** no TBD/TODO/"add appropriate" — fixed inline corrections in Tasks 5 and 7 (the `Equatable` aside, the `as UUID?` cast). All code blocks are complete.

**Type consistency:** `ReviveState` defined in Task 5 used in Tasks 7, 9, 10. `TranscriptAction` defined in Task 4 used in Task 10. `WorktreeReviveParams.preferredSessionID` defined in Task 1, plumbed through Tasks 2–3, called in Task 7. `reviveWithSession` defined in Task 7, called in Task 4's view (build-broken-then-fixed gap noted explicitly).

---

## Execution Notes for the Implementer

1. **Tasks 1–3 are tightly coupled** (shared-types + daemon + client) — execute as a unit, verify build at end of Task 3 before moving on.
2. **Task 4 ends with a non-building tree** — this is intentional and called out. Task 7 closes the gap. Do not commit a "skip-build" note in the actual commit.
3. **Task 6's auto-select change affects active worktrees too.** This is by design (per the spec). Manual verification step 2 in Task 11 covers the active-worktree path.
4. **Watch for `Worktree` Equatable**: if Step 2 of Task 5 fails because `Worktree` isn't `Equatable`, drop the `: Equatable` from `ReviveState` and SwiftUI will fall back to identity-based diffs — fine for our use.
5. **Restart correctly** (Task 11 Step 1): use `scripts/restart.sh`, not the absolute path to main's copy. Verify only one daemon/app pair via `ps`.
