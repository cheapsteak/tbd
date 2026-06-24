# Subagent Thread Navigation — Design

**Date:** 2026-06-20
**Status:** Approved (design)
**Scope:** History pane (`HistoryPaneView`) gets a Threads column. Both the
History pane and the Live transcript pane (`LiveTranscriptPaneView`) get
in-place subagent-thread navigation with a back button, replacing the overlay
for subagent cards.

## Problem

When a Claude session dispatches subagents via the `Task` tool, each subagent
runs its own conversation. Claude Code persists these as separate JSONL files at
`<projectDir>/<sessionID>/subagents/agent-<id>.jsonl` (each line tagged
`isSidechain: true`), with a sidecar `agent-<id>.meta.json`
(`{agentType, description, toolUseId}`).

TBD already parses these: `TranscriptParser` resolves each `Task` tool call to
its subagent JSONL, reads the meta for `agentType`, and nests a `Subagent`
(`agentID`, `agentType`, `items: [TranscriptItem]`) onto the `.toolCall(...)`
item. In the transcript a subagent surfaces as a thin inline
`✨ Agent · <description>` card (`AgentCard`) plus a gray `SubagentSummaryRow`;
clicking the card opens an overlay (`AgentCardBody`) that renders the nested
transcript.

The gaps:
- There is **no way to browse subagent conversations as first-class threads**.
  In a real session (longeye-app worktree `20260619-bewildered-parakeet`,
  session `860D6437…`) one conversation spawned **99 subagents** — too many to
  navigate via per-row overlays, with no session-level index.
- The **overlay** is a cramped way to read a full subagent conversation, and it
  is a different interaction from how the user reads the main transcript.

## Goal

1. Give the **History pane** a middle **Threads** column listing the Main
   conversation plus each subagent, so any subagent transcript can be selected
   and rendered in the existing transcript panel.
2. Replace the **overlay-on-subagent-card** behavior (both panes) with **in-place
   thread navigation**: clicking a subagent card swaps the transcript to that
   subagent's conversation, and a **back button in the pane heading** returns.

Non-goals (this pass): per-thread cost/duration analytics, nested-subagent
hierarchy *visualization* (nested drilling is supported, but the column is a
flat list), changes to the overlay for non-subagent cards (Read/Edit/Bash/
full-output/file links keep using it).

## Key insight: no backend changes

The data is already client-side. `appState.sessionTranscripts[sessionId]` holds
`[TranscriptItem]`, and every subagent's full `items` are already nested inside
its `.toolCall(name: "Task", subagent:)`. The entire feature is derivable in the
**App layer** — no daemon, RPC, parser, or model changes.

## The unifying primitive: a thread navigation path

Both panes share one concept — a **thread path**: a stack of subagent IDs
describing how deep the user has drilled.

- Empty path → the **Main** conversation.
- `[id]` → the subagent whose parent `Task` toolCall has that `id`.
- Deeper → a subagent reached from inside another subagent (the depth-2 edge),
  popped one level at a time.

Two pure, SwiftUI-free, unit-testable functions:

- **`resolveThread(root: [TranscriptItem], path: [String]) -> [TranscriptItem]`**
  — walk `root`, find the `Task` toolCall whose `id == path[0]`, descend into its
  `subagent.items`, repeat for each path element. Empty path returns `root`. An
  unresolvable id (stale path) falls back to the deepest resolvable prefix.
- **`sessionThreads(from items: [TranscriptItem]) -> [SessionThread]`** — walk
  the items in order, **recursively** descending into each subagent's `items`,
  collecting every `.toolCall` carrying a non-nil `subagent`. Produces a **flat**
  list ordered by appearance (used to populate the History Threads column).

### `SessionThread` (model, App layer)

A plain value type describing one selectable thread:

- `id: String` — the parent `Task` toolCall's `id` (stable; identical to the
  inline `AgentCard.id`, making card→thread linking direct).
- `description: String?` — decoded from the toolCall's input JSON.
- `agentType: String?` — from `Subagent.agentType`.
- `itemCount: Int` — `subagent.items.count`.
- `isError: Bool` — whether the parent toolCall's result is an error.

### State storage

The thread path lives in `AppState`, keyed per surface, mirroring existing
per-surface dictionaries (`sessionTranscripts`, `selectedSessionIDs`):

- `liveThreadPath[terminalID]: [String]` — the Live pane.
- `historyThreadPath[worktreeID]: [String]` — the History pane.

Each resets to empty when its target changes (Live: terminal's
`claudeSessionID` rollover; History: selected session changes).

## Killing the overlay for subagent cards

Today the inline `AgentCard` calls the `\.openTranscriptOverlay` environment
action with its `id`. We add a sibling environment action,
`\.navigateToThread(id)`. In **any transcript pane**, `AgentCard` calls
`navigateToThread` instead of `openTranscriptOverlay` — pushing the subagent's
`id` onto that pane's thread path.

- The overlay (`TranscriptOverlayCoordinator`) and its file/full-output frames
  remain for **every other** card type. Only subagent cards stop opening it.
- `AgentCardBody`'s subagent-transcript rendering path is **retired** (the
  overlay is no longer reached for subagents). Any now-dead subagent-only code
  in `AgentCardBody`/overlay (`pushItem` for subagents) is removed.

## History pane: Threads column

`HistoryPaneView` becomes three columns:

```
HistoryPaneView (HStack)
 ├ Sessions list          (existing — unchanged)
 ├ Threads column         (NEW — shown only when session has ≥1 subagent)
 └ SessionTranscriptView  (existing — renders resolveThread(messages, path))
```

- **Visibility gate:** shown only when `!sessionThreads(from: messages).isEmpty`.
  Sessions with no subagents stay two-column.
- **Rows:** a pinned **"Main conversation"** row (icon
  `bubble.left.and.bubble.right`), selected by default; one row per
  `SessionThread` — `✨` icon + `description` (1–2 lines) + a small `agentType`
  capsule badge + a metadata line (`N events`, plus an `error` chip when
  `isError`). Selected row uses the session list's
  `accentColor.opacity(0.15)` background.
- **Selection ⇄ path:** selecting **Main** sets path `[]`; selecting a subagent
  row sets path `[id]`. (Random access; the column is the flat index.)
- **Width/divider:** a third draggable divider with its own `@State` width
  (default ~260), clamped `max(180, min(500, …))`.
- **Header back affordance:** `SessionTranscriptView`'s header shows a leading
  `‹` back button when the path is non-empty (pops one level); the **Resume**
  button is unchanged and always targets the real Claude session.

## Live pane: back-button navigation

The Live pane (`LiveTranscriptPaneView`) has no room for a column, so navigation
is drill-in + back:

- The pane body renders `resolveThread(messages, liveThreadPath[terminalID])`
  through the same `TranscriptItemsView`.
- The **pane heading** is `PanePlaceholder`'s `toolbar` (the `.liveTranscript`
  case of `paneLabel`):
  - Path empty → unchanged (`text.bubble` icon + terminal label).
  - Path non-empty → a leading `‹` back button + the current subagent's
    `description` as the label; clicking `‹` pops one level.
- Background polling continues to update the Main session transcript while
  drilled in; popping back shows the latest. Subagent items live in the same
  parsed tree, so they stay current too.

## Inline card ↔ navigation

- Clicking an inline `✨ Agent` card pushes its `id` onto the active pane's
  thread path (via `navigateToThread`) — identical behavior in both panes.
- A subagent thread may contain its own inline `✨ Agent` cards (depth-2);
  clicking those pushes another level. The back button / column always provides
  the way out.

## Performance (issue #129)

Each thread renders standalone: the transcript panel renders exactly one
thread's flat `[TranscriptItem]` via the existing `TranscriptItemsView`
(`LazyVStack` of constant-shape rows). The Threads column is a flat `List`.
`resolveThread` and `sessionThreads` are pure and run outside `body`. No nested
`ForEach` of transcripts is introduced.

## Testing

- **Pure helpers (unit):**
  - `sessionThreads(from:)`: zero subagents → empty; N flat subagents → N rows in
    appearance order with correct `description`/`agentType`/`itemCount`/`isError`;
    a depth-2 subagent → still a flat row for the inner agent.
  - `resolveThread(root:path:)`: empty path → root; `[id]` → that subagent's
    items; nested path → deepest items; stale/unresolvable id → deepest
    resolvable prefix.
- **Selection / path reset:** changing the selected session (History) or terminal
  session rollover (Live) resets the path to empty.
- **Visibility branch (per CLAUDE.md, both branches):** Threads column hidden
  when the session has zero subagents; shown when ≥1.
- **Back-button branch (both branches):** back button absent when path empty,
  present and pops one level when path non-empty (assert in both panes' heading
  logic).
- **Card→navigate linking:** the inline `AgentCard.id` equals the matching
  `SessionThread.id` for a given `Task` toolCall.

## Files (anticipated)

- `Sources/TBDApp/Panes/Transcript/` — new `SessionThread` model + the pure
  `sessionThreads(from:)` and `resolveThread(root:path:)` helpers (new file);
  Threads column view (new file); `\.navigateToThread` environment action
  alongside `\.openTranscriptOverlay`; `AgentCard` repointed to it;
  `AgentCardBody`/overlay subagent path retired.
- `Sources/TBDApp/Panes/HistoryPaneView.swift` — third column + divider, path
  plumbing, header back button.
- `Sources/TBDApp/Panes/LiveTranscriptPaneView.swift` — render
  `resolveThread(messages, path)`; path reset on session rollover.
- `Sources/TBDApp/Panes/PanePlaceholder.swift` — `.liveTranscript` heading back
  button + current-thread label.
- `Sources/TBDApp/AppState*.swift` — `liveThreadPath` / `historyThreadPath`
  state; reset logic.
- `Tests/TBDAppTests/` — unit tests for the helpers and the
  selection/visibility/back-button branches.
