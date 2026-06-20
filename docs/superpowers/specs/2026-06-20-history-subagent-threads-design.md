# History Pane Subagent Threads Column — Design

**Date:** 2026-06-20
**Status:** Approved (design)
**Scope:** History pane only (`HistoryPaneView`). Live transcript pane unchanged.

## Problem

When a Claude session dispatches subagents via the `Task` tool, each subagent
runs its own conversation. Claude Code persists these as separate JSONL files at
`<projectDir>/<sessionID>/subagents/agent-<id>.jsonl` (each line tagged
`isSidechain: true`), with a sidecar `agent-<id>.meta.json`
(`{agentType, description, toolUseId}`).

TBD already parses these: `TranscriptParser` resolves each `Task` tool call to
its subagent JSONL, reads the meta for `agentType`, and nests a `Subagent`
(`agentID`, `agentType`, `items: [TranscriptItem]`) onto the
`.toolCall(...)` item. In the transcript a subagent surfaces as a thin inline
`✨ Agent · <description>` card (`AgentCard`) plus a gray `SubagentSummaryRow`;
clicking the card opens an overlay (`AgentCardBody`) that renders the nested
transcript.

The gap: there is **no way to browse or focus a subagent conversation as a
first-class thread**. In a real session (longeye-app worktree
`20260619-bewildered-parakeet`, session `860D6437…`) a single conversation
spawned **99 subagents** — far too many to navigate via per-row overlays, with
no session-level index. The inline cards are easy to scroll past, and the
overlay shows one subagent at a time with no cross-navigation.

## Goal

Extend the History pane's master–detail layout with a **middle "Threads"
column**. Selecting a session auto-selects its **Main** conversation (today's
behavior). The new column additionally lists each subagent as a selectable
thread; selecting one renders that subagent's conversation **in the existing
transcript panel**, reusing the same rendering path.

Non-goals (this pass): the Live transcript pane, the overlay used by the Live
pane, nested-subagent hierarchy visualization, per-thread cost/duration
analytics.

## Key insight: no backend changes

The data is already client-side. `appState.sessionTranscripts[sessionId]` holds
`[TranscriptItem]`, and every subagent's full `items` are already nested inside
its `.toolCall(name: "Task", subagent:)`. The entire feature is derivable in the
**App layer** — no daemon, RPC, parser, or model changes.

## Architecture

`HistoryPaneView` becomes three columns:

```
HistoryPaneView (HStack)
 ├ Sessions list          (existing — unchanged)
 ├ Threads column         (NEW — shown only when session has ≥1 subagent)
 └ SessionTranscriptView  (existing — renders selected thread's items)
```

### Components & boundaries

1. **`SessionThread` (model, App layer)** — a plain value type describing one
   selectable thread:
   - `id: String` — the parent `Task` toolCall's `id` (stable, and identical to
     the inline `AgentCard.id`, which makes card→thread linking trivial).
   - `description: String?` — decoded from the toolCall's input JSON
     (`description` field).
   - `agentType: String?` — from `Subagent.agentType`.
   - `itemCount: Int` — `subagent.items.count`.
   - `isError: Bool` — whether the parent toolCall's result is an error.
   - `items: [TranscriptItem]` — the subagent's conversation.

2. **`sessionThreads(from items: [TranscriptItem]) -> [SessionThread]`** — a
   pure free function. Walks the items in order, and **recursively** descends
   into each subagent's `items`, collecting every `.toolCall` that carries a
   non-nil `subagent`. Produces a **flat** list ordered by first appearance.
   (Recursion means a hypothetical depth-2 subagent still appears as its own
   flat row; real data observed is all depth-1.) No SwiftUI dependency →
   unit-testable against fixtures.

3. **`ThreadSelection` (enum)** — `.main` | `.subagent(id: String)`.
   Stored in `AppState` keyed by worktree (mirroring `selectedSessionIDs`), so
   it survives view rebuilds. Resets to `.main` whenever the selected session
   changes.

4. **Threads column (view)** — a dumb `List` bound to the derived threads and
   the selection. Pinned **Main** row at top; one row per `SessionThread`.

5. **`SessionTranscriptView`** — unchanged rendering path; its `items` source
   becomes: `selection == .main ? messages : thread.items`.

## Threads column UI

- **Visibility gate:** the column is shown only when
  `!sessionThreads(from: messages).isEmpty`. Sessions with no subagents stay
  two-column (no empty column).
- **Rows:**
  - Pinned **"Main conversation"** row, icon `bubble.left.and.bubble.right`,
    selected by default.
  - One row per subagent: `✨` icon + `description` (1–2 lines) + a small
    `agentType` capsule badge + a metadata line (`N events`, plus an `error`
    chip when `isError`).
  - Selected row uses the same `accentColor.opacity(0.15)` background as the
    session list's selected row.
- **Width/divider:** a third draggable divider with its own `@State` width
  (default ~260), clamped like the existing one (`max(180, min(500, …))`). No
  auto-hide beyond the visibility gate.
- **Transcript header breadcrumb:** when a subagent thread is selected, the
  `SessionTranscriptView` header shows `Main ▸ <description>`; clicking `Main`
  returns to `.main`. The **Resume** button is unchanged and always targets the
  real Claude session (never a subagent).

## Inline card ↔ column sync

Per the "keep card, click selects thread" decision:

- The inline `AgentCard` currently calls the `\.openTranscriptOverlay`
  environment action with its `id`. In the **History pane only**,
  `SessionTranscriptView` injects an action that **selects the matching thread**
  (`.subagent(id:)`) and swaps the transcript, instead of opening the overlay.
  The card's `id` is exactly the `SessionThread.id`, so the lookup is direct.
- The **Live pane keeps its existing overlay behavior** — untouched, because the
  override is scoped through the environment injection that `SessionTranscriptView`
  already owns.
- **Sync is one-way:** card click → selection update → transcript re-renders.
  The selected thread also highlights in the column.
- **Back out:** select **Main** in the column or click the header breadcrumb.
  Inline cards remain visible within the Main transcript as anchors.
- **Depth-2 edge:** a subagent thread may contain its own inline `✨ Agent`
  cards. Because the column is a flat list of all subagents at any depth,
  clicking those selects their row identically.

## Performance (issue #129)

Rendering each thread standalone **avoids** the inline-nesting recursion that
drove #129: the transcript panel renders exactly one thread's flat
`[TranscriptItem]` via the existing `TranscriptItemsView` (`LazyVStack` of
constant-shape rows). The Threads column is a flat `List` of lightweight rows.
No nested `ForEach` of transcripts is introduced.

## Testing

- **Unit (pure):** `sessionThreads(from:)` against fixtures —
  - zero subagents → empty list;
  - N flat subagents → N rows in appearance order, correct `description` /
    `agentType` / `itemCount` / `isError`;
  - a nested subagent (depth-2) → still produces a flat row for the inner agent.
- **Selection reset:** changing the selected session resets `ThreadSelection`
  to `.main`.
- **Visibility branch (per CLAUDE.md, both branches):** column hidden when the
  session has zero subagents; shown when ≥1.
- **Card→thread linking:** the inline `AgentCard.id` equals the matching
  `SessionThread.id` for a given `Task` toolCall (guards the lookup).

## Files (anticipated)

- `Sources/TBDApp/Panes/HistoryPaneView.swift` — add third column + divider,
  thread selection plumbing, breadcrumb header.
- `Sources/TBDApp/Panes/Transcript/` — new `SessionThread` model + threads
  column view (new file(s)); the `sessionThreads(from:)` helper.
- `Sources/TBDApp/AppState*.swift` — `ThreadSelection` state keyed by worktree;
  reset on session change.
- `Tests/TBDAppTests/` (or existing app test target) — unit tests for the
  helper and selection/visibility branches.
