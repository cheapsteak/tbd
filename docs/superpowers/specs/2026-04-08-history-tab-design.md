# History Tab — Design Spec

**Date:** 2026-04-08  
**Branch:** history-tab  
**Status:** Approved

---

## Overview

Add a History tab to TBDApp that lets the user browse past Claude Code sessions for the currently-selected worktree and resume any of them with one click.

Motivating use case: Claude's `~/.claude/sessions/*.json` live registry can get reset, but all session transcripts remain intact under `~/.claude/projects/`. `claude --resume <uuid>` from the worktree cwd works. This tab makes that recovery path visible and clickable.

---

## Data Source

Claude Code stores session transcripts as `.jsonl` files at:

```
~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl
```

**Encoding:** Replace every `/` and `.` with `-`.  
Example: `/Users/chang/projects/foo/.tbd/worktrees/20260403-bar` → `-Users-chang-projects-foo--tbd-worktrees-20260403-bar`

Each `.jsonl` has one JSON object per line. Relevant types:
- `{"type":"user", "message":{"role":"user","content":"..."}, ...}` — user turn
- `{"type":"assistant", ...}` — assistant turn
- `{"type":"permission-mode", ...}` — header (has `sessionId`, `cwd`, `gitBranch`)
- `{"type":"file-history-snapshot", ...}` — ignored

---

## Section 1 — Data Layer

### `SessionSummary` (TBDShared/Models.swift)

```swift
public struct SessionSummary: Codable, Sendable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String       // full UUID
    public let filePath: String        // absolute .jsonl path
    public let modifiedAt: Date        // mtime
    public let fileSize: Int64
    public let lineCount: Int          // total lines in .jsonl (all events)
    public let firstUserMessage: String?  // truncated to 300 chars
    public let lastUserMessage: String?   // truncated to 300 chars
    public let cwd: String?
    public let gitBranch: String?
}
```

### `UserMessageClassifier` (TBDDaemon/Claude/UserMessageClassifier.swift)

Single isolated function: `isRealUserMessage(_ line: [String: Any]) -> Bool`

A line is a real user message if:
- `type == "user"` and `message.role == "user"`
- `message.content` is:
  - A **string** that does not start with `<system-reminder`, `<command-`, `<tool_result`, or `<local-command-`
  - An **array** whose first `{type:"text"}` element's text does not start with any of those prefixes
  - Not purely an array of `tool_result` blocks

This function is the single place to update detection heuristics. It has no dependencies and is covered by fixture-driven unit tests.

### `ClaudeProjectDirectory` (TBDDaemon/Claude/ClaudeSessionScanner.swift)

Three-tier lookup for `~/.claude/projects/<encoded-cwd>/`, tried in order:

1. **Exact:** Replace `/` and `.` with `-`
2. **Regex:** Replace any non-alphanumeric run with `-`
3. **Scan:** Read first `.jsonl` in each `~/.claude/projects/*/` subdir; pick the one whose `cwd` field matches the worktree path

Result cached in `[String: URL]` keyed by worktree path.

### `ClaudeSessionScanner` (TBDDaemon/Claude/ClaudeSessionScanner.swift)

`listSessions(projectDir: URL) -> [SessionSummary]`

- Lists all `.jsonl` files in the project dir
- For each file: stat for mtime + size, then stream line-by-line (never load whole file)
- Accumulates: line count, first real user message, last real user message
- Truncates first/last message to 300 chars server-side
- Returns array sorted by mtime descending

### RPC Method `session.list` (TBDShared/RPCProtocol.swift)

```swift
public static let sessionList = "session.list"

public struct SessionListParams: Codable, Sendable {
    public let worktreeID: UUID
}
// Result type: [SessionSummary]
```

Handler: `TBDDaemon/Server/RPCRouter+SessionHandlers.swift`

### Resume

No new RPC. Existing `terminal.create` already accepts `resumeSessionID: String?` in `TerminalCreateParams`. The app calls `createTerminal(worktreeID:, resumeSessionID: sessionId)`. `ClaudeSpawnCommandBuilder` already handles `resumeID` → `claude --resume <id> --dangerously-skip-permissions`.

---

## Section 2 — App Layer

### `PaneContent` (TBDApp/Terminal/PaneContent.swift)

Add one case:

```swift
case history
```

No associated value — there is exactly one history view per worktree.

### Tab Placement (TBDApp/TabBar.swift)

The tab bar HStack layout becomes:

```
[existing tabs...] [+ add button]   [Spacer]   [🕐 history tab]
```

- History tab is pinned to the right edge via `Spacer()`
- History tab has **no close button** (permanent, like a settings tab)
- Icon: `clock.arrow.circlepath` (SF Symbol)
- No text label

### Loading State

```swift
// AppState+History.swift
enum HistoryLoadState {
    case idle
    case loading(previous: [SessionSummary])  // stale data remains visible
    case loaded
    case failed(Error)
}

@Published var sessions: [UUID: [SessionSummary]] = [:]
@Published var sessionsLoadingState: [UUID: HistoryLoadState] = [:]
```

`fetchSessions(worktreeID:)` is called when the History tab becomes active (on each tab switch — no background polling). It:
1. Sets state to `.loading(previous: current)` — stale list stays visible
2. Calls `daemonClient.listSessions(worktreeID:)` async
3. On completion, diffs against previous list to count new entries
4. Sets state to `.loaded` with new/same session list

### `HistoryPaneView` (TBDApp/Panes/HistoryPaneView.swift)

**Header row** (fixed height, never shifts the list):
- **Loading:** spinner + "Checking for new sessions…"
- **Done, no new:** "Up to date" — fades out after 2s, row collapses
- **Done, N new:** `Button("↑ N new sessions — click to show")` — clicking swaps the displayed list in place (no scroll jump)
- **Failed:** "Failed to load — click to retry"

**Session list:** `List` of `SessionRowView`:
- Session ID (first 8 chars) — monospaced
- Relative timestamp (mtime: "3h ago", "yesterday")
- Line count + file size (e.g. "1,240 events · 2.1 MB")
- First user message (truncated, gray, 1 line)
- Last user message (truncated, 1 line) — omitted if same as first

**Row click:** calls `appState.resumeSession(worktreeID:, sessionId:)` which calls `createTerminal` with `resumeSessionID`. This spawns a new terminal tab running `claude --resume <sessionId>` and switches focus to it.

---

## Section 3 — Testing

### `Tests/Fixtures/sample-session.jsonl`

~20 representative lines covering:
- Real user messages: string content, array content
- System-reminder blocks (filter out)
- Tool result blocks (filter out)
- `<command-name>` slash-command invocations (classified as real user messages — slash commands are user intent)
- Permission-mode header line
- Assistant turns

### `TBDDaemonTests/UserMessageClassifierTests.swift`

- `testFiltersSystemReminder`
- `testFiltersToolResult`
- `testPassesRealStringMessage`
- `testPassesArrayContentMessage`
- `testPassesSlashCommandMessage`

### `TBDDaemonTests/ClaudeSessionScannerTests.swift`

Uses same fixture file:
- `testLineCount`
- `testFirstUserMessage`
- `testLastUserMessage`
- `testTruncatesAt300Chars`
- `testEmptyFile`

Directory resolution tested with a temp dir fixture.

---

## Files Created / Modified

| Action | File |
|--------|------|
| Modify | `Sources/TBDShared/Models.swift` — add `SessionSummary` |
| Modify | `Sources/TBDShared/RPCProtocol.swift` — add `session.list` method + params |
| Create | `Sources/TBDDaemon/Claude/UserMessageClassifier.swift` |
| Create | `Sources/TBDDaemon/Claude/ClaudeSessionScanner.swift` |
| Create | `Sources/TBDDaemon/Server/RPCRouter+SessionHandlers.swift` |
| Modify | `Sources/TBDApp/DaemonClient.swift` — add `listSessions(worktreeID:)` |
| Modify | `Sources/TBDApp/Terminal/PaneContent.swift` — add `case history` |
| Modify | `Sources/TBDApp/TabBar.swift` — add history tab pinned right |
| Create | `Sources/TBDApp/AppState+History.swift` |
| Create | `Sources/TBDApp/Panes/HistoryPaneView.swift` |
| Create | `Tests/TBDDaemonTests/UserMessageClassifierTests.swift` |
| Create | `Tests/TBDDaemonTests/ClaudeSessionScannerTests.swift` |
| Create | `Tests/Fixtures/sample-session.jsonl` |

---

## Out of Scope (v1)

- Background polling / file-system watcher (load-on-tab-switch only)
- Searching or filtering sessions
- Showing full session transcript inline
- Deleting sessions
- Sessions across multiple worktrees
