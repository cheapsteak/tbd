# Live Transcript Pane for Claude Terminal Tabs

**Date:** 2026-05-04
**Status:** Design approved; awaiting implementation plan

## Problem

Claude Code tabs in TBD render as terminal output. Most of what Claude says is English prose, and a fixed-width monospace grid makes long-form responses clunky to read — it's a chat-style conversation forced into a code-style frame. Switching the terminal font to a proportional face isn't an option: SwiftTerm requires fixed cell metrics, and breaking the grid corrupts the input box, slash-command menus, plan diffs, and permission prompts.

We can't replace the terminal — Claude Code's TUI handles input, slash commands, plan mode, file pickers, and permission prompts in ways that aren't reproducible without rebuilding the client. But we can render the *output* (the conversation transcript) separately, in a chat-style view, alongside the terminal. The terminal stays as the input/control surface; the new view is a read-only, prose-friendly follower.

## Goals

- Add a header action on Claude terminal panes that opens a chat-style live transcript next to the terminal.
- Reuse the existing JSONL transcript renderer used by `HistoryPaneView`.
- One small daemon-side addition: a new `terminal.transcript` RPC that returns the full `[ChatMessage]` for a terminal's current Claude session. The existing `terminal.conversation` RPC is shaped for last-N-messages activity tracking, not transcripts; `session.messages` needs a file path the app doesn't have. The new RPC is ~15 lines of daemon code that resolves terminal → session ID → project dir → JSONL → messages, reusing the parsing already used by `session.messages`.
- Survive Claude session rollover (`/clear`, `/compact`, suspend/resume) without user intervention.

## Non-goals

- Streaming token-by-token display. The TUI already shows that; the pretty pane shows committed messages only.
- Replacing the terminal output. The terminal remains the source of truth for live interaction.
- Custom rendering of tool calls, code blocks, markdown, or plan diffs. The bubble used today is plain text; this design keeps that behavior. See "Follow-up" below.
- Resume / fork / branch actions inside the pane. Archived sessions still go through `HistoryPaneView`.
- Keyboard shortcut for opening the pane.
- Push-based updates from the daemon. Polling is sufficient for v1.

## Design

### Trigger and visibility

A new toolbar button in `PanePlaceholder.toolbarActions`, sibling to **Split Right** and **Split Down**.

- **Visibility gate:** shown only when `content` is `.terminal(terminalID)` AND the resolved `Terminal.claudeSessionID` is non-nil. Shell tabs do not get the button. (`claudeSessionID` is set at terminal-create time for Claude tabs, not after Claude boots, so the button appears immediately.)
- **Label:** "Transcript".
- **Icon:** `text.bubble` — chat-bubble glyph, visually distinct from the rectangle-split icons.
- **Click action:** opens a new pane to the right of the current pane via the existing `LayoutNode.splitPane` API, with the new pane's content set to `.liveTranscript(terminalID:)`. The terminal pane stays put.
- **Direction:** right only. Side-by-side reads naturally for prose; "down" is rarely useful and would clutter the toolbar. Users can rearrange after the fact via existing layout controls.

### New PaneContent case

Add to `PaneContent` (in `Sources/TBDApp/Terminal/PaneContent.swift`):

```swift
case liveTranscript(id: UUID, terminalID: UUID)
```

The case carries **two** UUIDs deliberately. `id` is the pane's identity in the layout tree (must be unique across panes — two transcript panes pointing at the same terminal must each have their own pane ID, and the transcript pane's ID must not collide with the terminal pane's ID, which today reuses the terminal UUID). `terminalID` is the binding target — when Claude rolls over (`/clear`, `/compact`, suspend/resume), the daemon updates `Terminal.claudeSessionID` and the pane observes that field to re-target the new session automatically.

`PaneContent.paneID` gains the case:

```swift
case .liveTranscript(let id, _): return id
```

`PanePlaceholder.paneBody` gains a routing case:

```swift
case .liveTranscript(_, let terminalID):
    LiveTranscriptPaneView(terminalID: terminalID, worktreeID: worktree.id)
```

`PanePlaceholder.toolbarActions` gains a sibling button when the content is `.terminal` and the terminal is a Claude tab:

```swift
Button(action: { openTranscript(terminalID: terminalID) }) {
    HStack(spacing: 2) {
        Image(systemName: "text.bubble")
        Text("Transcript")
    }
    .font(.caption)
}
.buttonStyle(.borderless)
```

`openTranscript` mirrors `createTerminalSplit`, but allocates a fresh UUID for the new pane and uses `.liveTranscript(id:terminalID:)` as the new content (no daemon round-trip needed):

```swift
private func openTranscript(terminalID: UUID) {
    layout = layout.splitPane(
        id: content.paneID,
        direction: .horizontal,
        newContent: .liveTranscript(id: UUID(), terminalID: terminalID)
    )
}
```

### Live transcript view

`LiveTranscriptPaneView(terminalID: UUID, worktreeID: UUID)` is a new SwiftUI view in `Sources/TBDApp/Panes/`.

**Data layer:**

- Observes `appState.terminals` to read the current `Terminal.claudeSessionID` for `terminalID`.
- Calls the new `terminal.transcript` RPC (takes `terminalID`, returns `[ChatMessage]` and the resolved sessionID). Result writes into `appState.sessionTranscripts[sessionId]` — the same store `HistoryPaneView` already uses, so multiple consumers of the same session converge.
- A polling loop runs while the view is visible:
  - Started in a `.task` modifier — cancelled automatically when the view disappears.
  - Cycle: fetch → sleep 1.5s → fetch.
  - Skip re-render if the result didn't change since last tick (compare message count + last message timestamp/ID) to avoid pointless redraws.
  - Transient errors are logged and the loop continues. A persistent failure (configurable threshold, e.g., 3 consecutive failures) flips the view to a "Could not load transcript" state with a retry button.
- Session rollover handling: when `claudeSessionID` changes, the view scrolls to top, shows a brief separator marker ("New session started"), and starts polling the new ID.

**Rendering layer:**

- The chat-bubble list portion of `SessionTranscriptView` (`HistoryPaneView.swift` lines 341–349 today — the `ScrollView { LazyVStack { ForEach { ChatMessageView } } }` block) is factored into a smaller `TranscriptMessagesView(messages: [ChatMessage])` so both `SessionTranscriptView` (history pane chrome wrapping it) and `LiveTranscriptPaneView` (raw embed) can use it.
- `ChatMessageView` is currently `private` to `HistoryPaneView.swift`; promote it to file-internal (drop the `private` modifier) so the new view can use it. No other refactor.
- Auto-scroll: pinned to bottom by default. If the user scrolls up, autoscroll freezes and a floating "↓ Jump to latest" button appears. Tapping it resumes autoscroll. Standard chat-app behavior.
- Empty state: "Waiting for Claude to start the conversation…" when `claudeSessionID` is set but the JSONL file is missing or empty.

### Edge cases

- **Terminal suspended:** `claudeSessionID` stays valid; transcript continues showing the prior conversation. No special handling.
- **Terminal resumed into a new session:** `claudeSessionID` updates; view re-targets and polling switches to the new file. Same path as `/clear`.
- **Terminal destroyed:** existing orphan-pane cleanup removes the transcript pane.
- **Worktree archived:** same as terminal destroyed — orphan cleanup handles it.
- **JSONL file deleted underneath us:** fetch returns empty; view shows the empty state. Not treated as an error.
- **Daemon disconnected:** fetch fails; existing daemon reconnect logic resumes polling automatically once the connection comes back.
- **Underlying terminal is no longer a Claude tab (defensive — currently impossible):** view shows an empty/inactive state rather than crashing.

### Performance

A typical session JSONL is at most a few MB and the daemon already parses it for `HistoryPaneView`. At 1.5s polling per visible transcript pane, a user with four open Claude transcript panes generates ~3 RPCs/sec total — negligible.

## Files affected

- `Sources/TBDShared/RPCProtocol.swift` — declare the new `terminal.transcript` method, its `TerminalTranscriptParams` (`terminalID: UUID`), and its `TerminalTranscriptResult` (`messages: [ChatMessage]`, `sessionID: String?`).
- `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift` — handler that resolves terminal → claudeSessionID → worktree path → project dir → JSONL, parsing through the same path used by `session.messages`. Register the route in the router setup.
- `Sources/TBDApp/DaemonClient.swift` — `terminalTranscript(terminalID:)` async wrapper.
- `Sources/TBDApp/Terminal/PaneContent.swift` — add `.liveTranscript(id:terminalID:)` case and update the `paneID` switch.
- `Sources/TBDApp/Panes/PanePlaceholder.swift` — new toolbar button (visibility-gated to Claude terminals), new `paneBody` routing case, `openTranscript` helper.
- `Sources/TBDApp/Panes/HistoryPaneView.swift` — extract the bubble list block into a `TranscriptMessagesView`; promote `ChatMessageView` from `private` to file-internal so the new view can use it. `SessionTranscriptView` continues to wrap `TranscriptMessagesView`.
- `Sources/TBDApp/Panes/LiveTranscriptPaneView.swift` — new file; the view, polling loop, autoscroll state, error/empty states.

`PaneContent` is app-only and never crosses the daemon RPC boundary, so existing persisted layouts decode unchanged because the new case is additive. Daemon and shared code change requires a full restart per `Sources/TBDDaemon/CLAUDE.md` — `scripts/restart.sh`, not `scripts/restart.sh --app`. No DB migration.

## Testing

- Unit: `PaneContent` Codable round-trip with the new case.
- Integration / manual:
  - Open Claude tab → click Transcript → pane opens to the right and populates with current conversation.
  - Send messages in terminal → transcript updates within ~1.5s.
  - `/clear` in the terminal → transcript shows separator and starts the new session.
  - Close the terminal pane → transcript pane is cleaned up.
  - Shell tab → no Transcript button visible.
  - Open transcript with no messages yet → empty state shown.
  - Daemon restart while pane is open → polling resumes after reconnect.

## Follow-up (out of scope for this design)

`ChatMessageView` (the bubble used by `SessionTranscriptView` today) is minimal: role label + plain-text bubble with rounded corners and accent tint. No markdown, no syntax-highlighted code blocks, no tool-call expansion, no plan-diff rendering. The live transcript pane will look exactly as rich (or as plain) as the history pane does today, which is the intent of this spec.

Richer rendering — markdown, collapsible tool calls, syntax-highlighted code blocks, plan-diff display — is a separate enhancement to `ChatMessageView` (or its successor) that benefits both the history pane and the live transcript pane. It should be its own design once this lands.

## Open questions

None at this time. Implementation plan to follow.
