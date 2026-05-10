# Pending AskUserQuestion Rendering — Design

## Problem

When Claude Code asks an `AskUserQuestion`, the assistant `tool_use` line is **not** appended to the JSONL transcript file until the user has answered. Verified empirically: in
`~/.claude/projects/-Users-chang-projects-maven-dashboard/1D7BF9A8-401C-47EE-843E-4BACB67AE5FA.jsonl`, the session was in `status: "waiting"` / `waitingFor: "approve AskUserQuestion"` while the file's last `AskUserQuestion` entry already had a matching `tool_result`. The currently-asked question existed in the running Claude process but not on disk.

Consequence in TBD's transcript pane: a pending question is invisible until the user has selected an option in the terminal — exactly when seeing the question is most useful.

## Goal

Render the question (header, prompt, options) inside the TBD transcript pane as soon as Claude asks it, with a "Waiting for response…" affordance until the user answers. When the answer arrives, the rendering must transition seamlessly to the JSONL-backed render of the same question with no flicker, duplicates, or layout jumps.

## Non-Goals

- **Answering from inside TBD.** Routing keystrokes back through tmux into the Claude TUI is a separate, larger problem.
- **Tmux screen-scrape fallback.** If the hook didn't fire (daemon was down, hook overlay not picked up by an already-running session), the synthetic card will not appear. The user still sees the question in the terminal pane itself; the transcript pane just won't show it until JSONL catches up after the answer. This is the same degraded-but-correct behavior we have today.
- **Other pending states.** This design covers `AskUserQuestion` only. It does not attempt to surface permission prompts (`approve Bash`, etc.) — those have a different UX shape.

## Signal Source

Anthropic's hook system fires `PreToolUse:AskUserQuestion` **before** Claude renders the picker, with the full tool input (the `questions` array, including options and headers) and the assigned `tool_use_id`. The matching `PostToolUse:AskUserQuestion` fires after the user answers, before Claude resumes.

This is structured, version-stable, and addressable per matcher — strictly better than the alternatives:

- The session file `~/.claude/sessions/<pid>.json` carries `status: "waiting"` and `waitingFor: "approve AskUserQuestion"` but never the question content.
- Tmux pane capture has the rendered TUI but parsing it is brittle to formatting changes.
- The JSONL records `attachment.type: "hook_success"` lines after PreToolUse hooks run, but these don't carry `tool_input`.

## Architecture

### 1. Hook overlay entries

Extend `ClaudeHookOverlay.generateBody()` (`Sources/TBDDaemon/Hooks/ClaudeHookOverlay.swift`) with two new hook registrations alongside the existing `SessionStart` and `Stop` entries:

```jsonc
"PreToolUse": [
  {
    "matcher": "AskUserQuestion",
    "hooks": [
      { "type": "command", "command": "tbd ask-user-question pre 2>/dev/null || true" }
    ]
  }
],
"PostToolUse": [
  {
    "matcher": "AskUserQuestion",
    "hooks": [
      { "type": "command", "command": "tbd ask-user-question post 2>/dev/null || true" }
    ]
  }
]
```

Same overlay file (`~/tbd/runtime/claude-overlay.json`), same `--settings` injection path through `ClaudeSpawnCommandBuilder`, same per-spawn scope. No changes to the user's `~/.claude/settings.json`. No changes for non-TBD-spawned Claude sessions.

The overlay is regenerated on every daemon startup, so the new hooks take effect on the next worktree open after upgrade. Already-running Claude sessions started under the old overlay continue working unchanged — they just won't get pending-question cards until they restart through TBD.

### 2. New CLI subcommand: `tbd ask-user-question`

Add `Sources/TBDCLI/Commands/AskUserQuestionEventCommand.swift`, modeled directly on `SessionEventCommand`. Two subcommands:

- `tbd ask-user-question pre` — invoked from `PreToolUse`. Reads stdin, decodes Claude's hook payload (`tool_use_id`, `tool_input`, plus the standard envelope fields), reads `TBD_TERMINAL_ID` from env, RPCs `terminal.askUserQuestionPending`. Silent on every error path; exit 0 always.
- `tbd ask-user-question post` — invoked from `PostToolUse`. Same shape, RPCs `terminal.askUserQuestionCleared`.

Both commands cap stdin at 1 MiB matching `SessionEventCommand`. Both return immediately if `TBD_TERMINAL_ID` is missing or malformed (covers non-TBD-spawned sessions that somehow inherit the overlay).

The PreToolUse stdin payload, per Claude Code's hook contract, includes `tool_input` as a structured JSON object containing the questions array. The CLI command re-serializes `tool_input` with `JSONSerialization` (sorted keys) into a string and passes it through. The daemon does no further interpretation — it stores the JSON verbatim and lets the SwiftUI card decode it the same way it decodes JSONL-backed input.

### 3. RPC additions

In `Sources/TBDShared/RPCProtocol.swift`:

```swift
public static let terminalAskUserQuestionPending = "terminal.askUserQuestionPending"
public static let terminalAskUserQuestionCleared = "terminal.askUserQuestionCleared"

public struct TerminalAskUserQuestionPendingParams: Codable, Sendable {
    public let terminalID: UUID
    public let toolUseID: String
    public let inputJSON: String
    public let timestampMillis: Int64
}

public struct TerminalAskUserQuestionClearedParams: Codable, Sendable {
    public let terminalID: UUID
    public let toolUseID: String
}
```

Both return void (`.ok()`). No client-side response handling needed.

### 4. Daemon state store

New file `Sources/TBDDaemon/AskUserQuestion/PendingQuestionStore.swift`:

```swift
actor PendingQuestionStore {
    private var pending: [UUID: PendingAskUserQuestion] = [:]
    func set(terminalID: UUID, _ value: PendingAskUserQuestion)
    func clear(terminalID: UUID, toolUseID: String)
    func clear(terminalID: UUID)              // called on terminal-close
    func get(terminalID: UUID) -> PendingAskUserQuestion?
}

struct PendingAskUserQuestion: Sendable {
    let toolUseID: String
    let inputJSON: String
    let timestamp: Date
}
```

Single instance held by the daemon, injected into the relevant RPC handlers. Memory-only — daemon restart wipes it, which is correct behavior: after a daemon restart, the JSONL is the only authoritative source and any in-flight question will simply not get a synthetic card until answered. This is acceptable degradation.

`clear(terminalID:)` (no toolUseID) is invoked from terminal-close paths so a closed pane never leaves a phantom card on the next reopen.

### 5. RPC handlers

New file `Sources/TBDDaemon/Server/RPCRouter+AskUserQuestionHandlers.swift`:

```swift
func handleTerminalAskUserQuestionPending(_ paramsData: Data) async throws -> RPCResponse {
    let p = try decoder.decode(TerminalAskUserQuestionPendingParams.self, from: paramsData)
    await pendingQuestions.set(
        terminalID: p.terminalID,
        PendingAskUserQuestion(
            toolUseID: p.toolUseID,
            inputJSON: p.inputJSON,
            timestamp: Date(timeIntervalSince1970: TimeInterval(p.timestampMillis) / 1000)
        )
    )
    return .ok()
}

func handleTerminalAskUserQuestionCleared(_ paramsData: Data) async throws -> RPCResponse {
    let p = try decoder.decode(TerminalAskUserQuestionClearedParams.self, from: paramsData)
    await pendingQuestions.clear(terminalID: p.terminalID, toolUseID: p.toolUseID)
    return .ok()
}
```

Wire into `RPCRouter.route(...)` next to existing terminal handlers.

### 6. Transcript merge

In `handleTerminalTranscript` (`Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift`), after `messages = TranscriptParser.parse(...)` (or cache hit), perform the synthetic-item merge before building the response:

```swift
var finalMessages = messages
if let pending = await pendingQuestions.get(terminalID: params.terminalID) {
    let alreadyInJSONL = messages.contains { item in
        if case let .toolCall(id, _, _, _, _, _, _, _) = item {
            return id == pending.toolUseID
        }
        return false
    }
    if !alreadyInJSONL {
        finalMessages.append(.toolCall(
            id: pending.toolUseID,
            name: "AskUserQuestion",
            inputJSON: pending.inputJSON,
            inputTruncatedTo: nil,
            result: nil,
            subagent: nil,
            timestamp: pending.timestamp,
            usage: nil
        ))
    }
}
```

The cache (`TranscriptParseCache`) continues to cache the JSONL-derived items only; the synthetic merge happens post-cache-lookup so pending-state changes are reflected on every poll without cache invalidation.

The dedupe key is `tool_use_id`, which Claude assigns once and reuses in both the PreToolUse hook payload and the eventual JSONL `tool_use` block. A real JSONL line landing for the same `tool_use_id` always wins.

### 7. Terminal-close cleanup

In the terminal lifecycle paths that already exist (closing a terminal, archiving a worktree), call `pendingQuestions.clear(terminalID:)`. This is a single line in each cleanup site.

### 8. UI

No changes. `AskUserQuestionCard` in `Sources/TBDApp/Panes/Transcript/AskUserQuestionCard.swift` already handles `result: nil` by rendering the question bubble plus a `WaitingForResponseRow` ("Waiting for response…" with spinner). Once the answer arrives via JSONL, the synthetic item is suppressed and the JSONL-backed card renders the answer bubble in the same slot. Layout is consistent because both renders go through the same `AskUserQuestionCard`.

## Live update cadence

The App's `LiveTranscriptPaneView` polls `terminal.transcript` on a fixed interval. The synthetic card therefore appears on the first poll after the PreToolUse hook fires — sub-second under normal conditions. No additional push channel is needed.

## Tests

Per project policy on branching conditionals, every new branch gets a test on each side.

**`ClaudeHookOverlay` JSON snapshot**
- `generateBody()` output contains the new `PreToolUse` and `PostToolUse` entries with `matcher: "AskUserQuestion"` and the expected commands.
- Existing `SessionStart` and `Stop` entries are unchanged.

**`AskUserQuestionEventCommand` payload parsing**
- Given a representative PreToolUse stdin payload (real shape captured from a live session), the command extracts `tool_use_id` and a re-serialized `tool_input` JSON.
- Missing `TBD_TERMINAL_ID`: command exits silently.
- Malformed JSON: command exits silently.
- Stdin > 1 MiB: command exits silently.

**`PendingQuestionStore`**
- `set` then `get` returns the stored value.
- `clear(terminalID:toolUseID:)` for the matching toolUseID removes the entry; mismatched toolUseID is a no-op.
- `clear(terminalID:)` removes the entry regardless of toolUseID.

**Transcript merge (the branching gate)**
- Pending state present, no matching JSONL item → synthetic `toolCall` appended at tail.
- Pending state present, JSONL contains a `tool_use` with the same `tool_use_id` → no synthetic appended (real wins).
- Pending state absent → output byte-identical to `TranscriptParser.parse(filePath:)` (the gated-off ungated-behavior check).
- Synthetic appended once cleared by `terminal.askUserQuestionCleared` → next call returns no synthetic.

**RPC round-trip**
- `terminal.askUserQuestionPending` then `terminal.transcript` returns a transcript including the synthetic.
- Then `terminal.askUserQuestionCleared` then `terminal.transcript` returns a transcript without the synthetic.

## Restart and verification per CLAUDE.md

After daemon-side or shared-code changes, restart the worktree with `scripts/restart.sh` (the worktree's own copy, not the main project's), then verify exactly one `TBDDaemon` and one `TBDApp` are running from this worktree path with `ps aux | grep -E "\.build/debug/TBD"`.

Manual verification: open a TBD-spawned Claude session, ask Claude to invoke `AskUserQuestion`, confirm the card appears in the transcript pane with "Waiting for response…" before answering, answer in the terminal, confirm the card transitions to the answered state without flicker.

## Risks and mitigations

- **Hook didn't fire (daemon was down when PreToolUse triggered).** Synthetic card won't appear; user sees the question in the terminal pane only. Same degraded behavior as today. Acceptable.
- **PostToolUse failed to fire (daemon down between Pre and Post).** JSONL dedupe handles it: when the assistant `tool_use` lands in JSONL after the answer, the synthetic is suppressed by `tool_use_id` match.
- **Stale pending entry from a crashed Claude session.** Daemon restart wipes the in-memory store. Terminal-close also clears the entry. The only stuck-state path is "Claude crashed, daemon kept running, terminal still open." Manageable scope; if it becomes common, add a TTL.
- **Hook overlay merge order.** Claude merges `--settings` array entries with the user's settings.json by concatenation + dedupe. Adding new matchers cannot conflict with user hooks on the same matcher — both run. Confirmed by the existing `SessionStart` overlay coexisting with user hooks.

## Files touched

- `Sources/TBDDaemon/Hooks/ClaudeHookOverlay.swift` — extend `generateBody()`.
- `Sources/TBDCLI/Commands/AskUserQuestionEventCommand.swift` — new.
- `Sources/TBDCLI/TBDCLI.swift` (or wherever subcommands are registered) — register new command.
- `Sources/TBDShared/RPCProtocol.swift` — new method names + param structs.
- `Sources/TBDDaemon/AskUserQuestion/PendingQuestionStore.swift` — new actor.
- `Sources/TBDDaemon/Server/RPCRouter+AskUserQuestionHandlers.swift` — new handlers.
- `Sources/TBDDaemon/Server/RPCRouter.swift` — route the two new methods.
- `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift` — synthetic merge in `handleTerminalTranscript`; inject `PendingQuestionStore`.
- `Sources/TBDDaemon/Daemon.swift` (or composition root) — instantiate `PendingQuestionStore`, wire to RPCRouter.
- Terminal-close paths (existing files) — call `pendingQuestions.clear(terminalID:)`.
- `Tests/TBDDaemonTests/` and `Tests/TBDCLITests/` — tests above.

No SwiftUI files modified.
