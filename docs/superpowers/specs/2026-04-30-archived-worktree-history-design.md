# Archived Worktree Conversation History

**Date:** 2026-04-30
**Status:** Design

## Problem

Active worktrees expose their Claude conversation history through `HistoryPaneView` — a master-detail of session list (left) + transcript (right) toggled from the worktree's main pane. Archived worktrees expose nothing equivalent: `ArchivedWorktreesView` is a flat list with inline Revive buttons. Users want to browse archived conversations the same way they browse live ones, and revive directly into a chosen past session.

## Goals

- Browse archived worktrees' Claude sessions and transcripts using the same interaction model as active worktrees.
- Reuse `HistoryPaneView` rather than reimplementing master-detail logic.
- Provide a one-click "revive and resume this conversation" path.
- Keep recently-revived rows visible briefly so the action feels acknowledged, without making the archived list stale on return visits.

## Non-Goals

- Bulk operations (revive multiple, delete archived, etc.).
- Editing or annotating archived sessions.
- Surfacing archived sessions outside the archived view (e.g. global search).

## Design

### Layout — nested master-detail (option C)

`ArchivedWorktreesView` becomes an outer `HSplit`:

- **Left rail:** archived-worktree list. Default width 280pt, draggable, clamped 220–400. Rows become *selectable* (accent tint matches active sidebar). Header strip and empty state stay as-is.
- **Right pane:** the existing `HistoryPaneView(worktreeID:)` rendered against the selected archived worktree. Its internal session-list/transcript divider stays draggable and independent.

If the selected archived worktree has zero Claude sessions, the right pane shows an empty state with a plain **Revive** button (nothing to resume).

### `HistoryPaneView` parameterization

`HistoryPaneView` gains one parameter:

```swift
enum TranscriptAction {
    case resume                    // active worktree: open new terminal resuming the session
    case reviveWithSession         // archived worktree: revive worktree, resume selected session
}

struct HistoryPaneView: View {
    let worktreeID: UUID
    let transcriptAction: TranscriptAction = .resume   // default preserves current call sites
    ...
}
```

The transcript header dispatches on `transcriptAction`:

- `.resume` → button label "Resume", calls existing `appState.resumeSession(worktreeID:sessionId:)`.
- `.reviveWithSession` → button label "Revive with this session", calls new `appState.reviveWithSession(worktreeID:sessionId:)`.

No other branching inside `HistoryPaneView`.

### `AppState` additions

```swift
@Published var selectedArchivedWorktreeIDs: [UUID: UUID] = [:]   // repoID → archivedWorktreeID

enum ReviveState {
    case inFlight(snapshot: Worktree)
    case done(snapshot: Worktree)
}
@Published var revivingArchived: [UUID: ReviveState] = [:]       // worktreeID → state
```

New methods:

```swift
func reviveWithSession(worktreeID: UUID, sessionId: String) async
```

Calls the revive RPC with a new optional `preferredSessionID` parameter. The daemon, when provided, reorders the worktree's stored `archivedClaudeSessions` so the preferred ID is first, then runs the existing setup-terminals path (which already resumes `archivedClaudeSessions.first`). Reordering happens in the daemon, not the client, so the on-disk DB state stays consistent if the user reverts.

### Auto-selection

Two rules, both applied in `AppState`:

1. **Archived row auto-select.** When `ArchivedWorktreesView` appears or when `archivedWorktrees[repoID]` changes, if `selectedArchivedWorktreeIDs[repoID]` is unset OR points to a worktree no longer in the archived list, set it to the most-recently-archived row (top of the existing `archivedAt` sort).

2. **First-session auto-select (universal).** When `historyLoadStates[wt]` transitions to `.loaded(sessions)` and `selectedSessionIDs[wt]` is unset and `sessions` is non-empty, select `sessions.first` and call `selectSession` to load its transcript. This applies to active worktrees too — the simpler universal rule replaces today's "select nothing until clicked" default.

Selection changes for archived rows trigger `fetchSessions(worktreeID:)` via the existing path.

### Lingering revived rows

When the user revives an archived worktree from this view, its row stays visible — with feedback — until they navigate away from the archived section.

- **On revive start:** snapshot the `Worktree`, set `revivingArchived[id] = .inFlight(snapshot)`.
  - Row shows a small `ProgressView` and "Reviving…" subtitle in place of the archived-at timestamp.
  - Row becomes non-selectable; if it was the current selection, advance selection to the next archived row.
- **On revive success:** flip to `.done(snapshot)`. Row shows a green "Revived ✓" pill.
- **On revive failure:** clear `revivingArchived[id]`, surface error via existing `handleConnectionError` path.
- **Row list computation:** `archived = (archivedWorktrees[repoID] ∪ revivingArchived.snapshots.filter { $0.repoID == repoID })` deduped by id, sorted by `archivedAt` desc. During the in-flight window the worktree is in both sets; once the daemon reconciles, only the snapshot keeps it visible.
- **Clear-on-navigate-away:** in `AppState+Navigation`, when the active sidebar selection changes to anything other than this repo's Archived entry, drop all `revivingArchived` entries belonging to that repo. Coming back → list is fresh, no lingering rows.
- **Edge case:** if the user navigates away while a revive is `.inFlight`, the RPC continues in the background. The worktree appears in the active sidebar normally; on return to the archived view, no lingering row is shown.

### Per-row affordances

- **Inline Revive button:** removed. The transcript-header "Revive with this session" covers the common case (auto-selected first session is the most recent conversation).
- **Context menu on row:** add a single **Revive** item that calls the existing session-less revive (equivalent to today's button). Useful when the user wants to revive without picking a specific session.
- **Selection styling:** accent tint (`Color.accentColor.opacity(0.18)`) matches the active sidebar's row treatment. The existing `highlightedArchivedWorktreeID` flash animation is unaffected.

### Daemon-side considerations

`handleSessionList` currently resolves the Claude project dir from `worktree.path`. After archive, the worktree row in the DB still has its `path` field, and Claude's JSONL files in `~/.claude/projects/...` are not deleted when the worktree dir is removed. So the existing RPC works for archived worktrees without daemon changes. (Verify during implementation: if the path-based resolution returns nil for some reason, the daemon may need to fall back to `archivedClaudeSessions` to filter sessions explicitly.)

## Component map

- `Sources/TBDApp/ArchivedWorktreesView.swift` — outer `HSplit`, row selection, lingering-revive merging, context menu.
- `Sources/TBDApp/Panes/HistoryPaneView.swift` — add `transcriptAction` parameter, dispatch in header.
- `Sources/TBDApp/AppState.swift` — add `selectedArchivedWorktreeIDs`, `revivingArchived`.
- `Sources/TBDApp/AppState+History.swift` — add `reviveWithSession(...)`, add universal first-session auto-select in the post-load path.
- `Sources/TBDApp/AppState+Worktrees.swift` — auto-select most-recent archived row on archived-list updates.
- `Sources/TBDApp/AppState+Navigation.swift` — clear `revivingArchived` for repo on navigate-away.

Daemon: extend `WorktreeReviveParams` with `preferredSessionID: String?`, and the lifecycle revive path reorders `archivedClaudeSessions` accordingly before `setupTerminals`. No schema changes.

## Testing

- Selecting an archived row triggers session fetch; sessions load → first session auto-selected → transcript loads.
- Most-recently-archived row is selected on first appearance.
- "Revive with this session" reorders sessions and revives; new terminal resumes the chosen session.
- Lingering row shows `Reviving…` then `Revived ✓`; disappears after navigate-away → return.
- Context menu Revive works for rows with no sessions.
- Empty-state right pane shows Revive button when archived worktree has zero sessions.
- Active-worktree history view (existing call site) still works — first session auto-selects on initial load (new behavior; verify it matches expectations).

## Open questions

None.
