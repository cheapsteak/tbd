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
- **Subagent (Task) AskUserQuestion.** When a Task subagent calls `AskUserQuestion`, the eventual real `tool_use` lands nested inside the parent `toolCall`'s `Subagent.items`, not at the top level. Top-level dedupe + top-level placement would render the synthetic incorrectly. Subagent questions therefore degrade to today's behavior (visible only after answer). Recursing into `Subagent.items` for dedupe and rendering the synthetic in the correct nested slot is tracked as a follow-up. We can detect this at the CLI bridge by inspecting `cwd` / `transcript_path` from the hook payload against the parent terminal's main JSONL — if they diverge (subagent transcripts live under a `subagents/` sibling), the bridge does not RPC the daemon at all. This keeps the synthetic out of the top-level items list for subagent calls.

## Signal Source

Anthropic's hook system fires `PreToolUse:AskUserQuestion` **before** Claude renders the picker, with the full tool input (the `questions` array, including options and headers) and the assigned `tool_use_id`. The matching `PostToolUse:AskUserQuestion` fires after the user answers, before Claude resumes.

This is structured, version-stable, and addressable per matcher — strictly better than the alternatives:

- The session file `~/.claude/sessions/<pid>.json` carries `status: "waiting"` and `waitingFor: "approve AskUserQuestion"` but never the question content.
- Tmux pane capture has the rendered TUI but parsing it is brittle to formatting changes.
- The JSONL records `attachment.type: "hook_success"` lines after PreToolUse hooks run, but these don't carry `tool_input`.

### Empirically verified payload shape

Captured live from Claude Code 2.1.138 by installing a `cat > file` hook on `PreToolUse:AskUserQuestion`:

```json
{
  "session_id": "B88113CA-EAF0-41D7-AEF7-C4AB2FB449CF",
  "transcript_path": "/Users/chang/.claude/projects/.../<sid>.jsonl",
  "cwd": "...",
  "permission_mode": "bypassPermissions",
  "effort": { "level": "high" },
  "hook_event_name": "PreToolUse",
  "tool_name": "AskUserQuestion",
  "tool_input": { "questions": [ { "question": "...", "header": "...", "options": [ ... ], "multiSelect": false } ] },
  "tool_use_id": "toolu_01JLbNo3vYeQp2TVif7Cd8Mn"
}
```

Confirms the load-bearing assumption: `tool_use_id` is present on PreToolUse for this matcher, in the same `toolu_…` format that the assistant `tool_use.id` later carries into the JSONL. Exact-string match works as a dedupe key.

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
- `tbd ask-user-question post` — invoked from `PostToolUse`. Same shape, RPCs `terminal.askUserQuestionCleared` (which is a no-op today; see §3).

Both commands cap stdin at 1 MiB matching `SessionEventCommand`. Both return immediately if `TBD_TERMINAL_ID` is missing or malformed (covers non-TBD-spawned sessions that somehow inherit the overlay).

The PreToolUse stdin payload includes `tool_input` as a structured JSON object containing the questions array (empirically verified — see §Signal Source). The CLI command re-serializes `tool_input` with `JSONSerialization` (sorted keys) into a string and passes it through. The daemon does no further interpretation — it stores the JSON verbatim and lets the SwiftUI card decode it the same way it decodes JSONL-backed input.

**Subagent detection.** Before issuing the RPC, the `pre` subcommand compares the payload's `transcript_path` to a hint about the parent terminal's expected JSONL path. If the path lives under a `subagents/` subdirectory of the project, the subagent-question case (see §Non-Goals), the CLI exits silently without RPCing. This keeps subagent questions out of the synthetic-merge path entirely. Tests cover both branches (main-agent path: RPC fires; subagent path: no RPC).

**Observability.** Each subcommand emits exactly one `logger.debug` line via `os.Logger` (subsystem `com.tbd.cli`, category `askUserQuestion`) — `"pre delivered toolUseID=… terminalID=…"` or `"pre suppressed reason=subagent|noTerminalID|rpcFailed"`. Per project policy, debug-level logs are silent by default and surfaced via `log stream --level debug`. This is the only diagnostic path; hook stderr stays empty so nothing leaks into the user's terminal.

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

PostToolUse is intentionally a defensive signal only — see §6 for why we don't clear on PostToolUse. The `…Cleared` RPC exists so the daemon could choose to drop a pending entry early in the rare case of a same-cycle redundant question, but the *default* merger path doesn't call it. Concretely, `handleTerminalAskUserQuestionCleared` is a no-op today (logs only); we keep the wire format reserved so we don't have to ship a protocol change if we later want it.

### 4. Daemon state store

New file `Sources/TBDDaemon/AskUserQuestion/PendingQuestionStore.swift`:

```swift
actor PendingQuestionStore {
    private var pending: [Key: PendingAskUserQuestion] = [:]
    struct Key: Hashable, Sendable { let terminalID: UUID; let toolUseID: String }

    func set(terminalID: UUID, _ value: PendingAskUserQuestion)
    func clear(terminalID: UUID, toolUseID: String)
    func clear(terminalID: UUID)              // called on terminal-close
    func entries(forTerminal: UUID) -> [PendingAskUserQuestion]
    func gcExpired(now: Date, maxAge: Duration)
}

struct PendingAskUserQuestion: Sendable {
    let toolUseID: String
    let inputJSON: String
    let timestamp: Date
}
```

Keyed on `(terminalID, toolUseID)` rather than `terminalID` alone — so two pending questions on the same terminal coexist (rare, but happens during session restore/replay, or if a hook bug double-fires). Stored as a list returned by `entries(forTerminal:)`; merger iterates them.

Memory-only — daemon restart wipes it. After a daemon restart, the JSONL is the only authoritative source and any in-flight question simply doesn't get a synthetic card until answered. Acceptable degradation.

`clear(terminalID:)` (no toolUseID) is invoked from terminal-close paths so a closed pane never leaves a phantom entry on the next reopen.

**TTL.** Stranded entries (e.g., a user-installed PreToolUse hook on the same matcher returned `decision: "block"`, so no answer ever comes; or daemon-vs-Claude lifetime mismatch) are reaped via `gcExpired` called from `handleTerminalTranscript` with `maxAge: .seconds(900)` (15 min). Cheap — runs O(entries) per poll, entries are tiny.

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

### 6. Transcript merge — and lazy cleanup that avoids flicker

In `handleTerminalTranscript` (`Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift`), after `messages = TranscriptParser.parse(...)` (or cache hit), perform GC + merge before building the response:

```swift
await pendingQuestions.gcExpired(now: Date(), maxAge: .seconds(900))

let jsonlIDs: Set<String> = {
    var ids = Set<String>()
    for item in messages {
        if case let .toolCall(id, _, _, _, _, _, _, _) = item { ids.insert(id) }
    }
    return ids
}()

var finalMessages = messages
for pending in await pendingQuestions.entries(forTerminal: params.terminalID) {
    if jsonlIDs.contains(pending.toolUseID) {
        // JSONL caught up. Drop the entry now — keeps the store small,
        // avoids ever surfacing a "ghost" synthetic for an answered question.
        await pendingQuestions.clear(terminalID: params.terminalID,
                                     toolUseID: pending.toolUseID)
        continue
    }
    finalMessages.append(.toolCall(
        id: pending.toolUseID,
        name: "AskUserQuestion",
        inputJSON: pending.inputJSON,
        inputTruncatedTo: nil,   // synthetic input is always uncapped
        result: nil,
        subagent: nil,
        timestamp: pending.timestamp,
        usage: nil
    ))
}
```

The cache (`TranscriptParseCache`) continues to cache the JSONL-derived items only; the synthetic merge happens post-cache-lookup so pending-state changes are reflected on every poll without cache invalidation.

**Why lazy cleanup avoids flicker.** A naive design clears pending state when the PostToolUse hook fires. But Claude flushes the assistant `tool_use` line to JSONL slightly *after* PostToolUse returns. A poll landing in that gap would show the synthetic disappear and then the real card appear with the answer — a visible flicker. Lazy cleanup means the synthetic stays visible (with "Waiting for response…") until the JSONL line lands, at which point the real card replaces it in the same render slot. PostToolUse becomes a defensive-only signal — see §3.

The dedupe key is `tool_use_id`, which Claude assigns once and reuses in both the PreToolUse hook payload (empirically verified, see §Signal Source) and the eventual JSONL `tool_use` block.

**`inputTruncatedTo` is always `nil` on synthetic items.** The CLI bridge never caps the JSON; the merger never sets the field. This keeps the synthetic out of the truncation-footer code path in `AskUserQuestionCard` (which would otherwise call `terminal.transcriptItemFullBody` with a `tool_use_id` that doesn't exist in JSONL yet, getting back "Output no longer available.").

### 7. Terminal-close cleanup

Call `pendingQuestions.clear(terminalID:)` from every code path that terminates a terminal so the store can't grow phantom entries. The exhaustive list — verified by grepping for terminal teardown sites in `Sources/TBDDaemon/` — is:

- Worktree archive (`Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift`).
- `tbd terminal close` / explicit terminal close (`RPCRouter+TerminalHandlers.swift` close handlers).
- Tmux session death detection (the existing watcher that detects tmux-side closes and updates terminal status).
- Daemon shutdown (memory-only store, so no action needed — process exit clears it).

Each non-shutdown site adds one line. Tests cover each path's call into the clear method.

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
- Given a representative PreToolUse stdin payload (real shape captured from a live session — checked into the test fixtures), the command extracts `tool_use_id` and a re-serialized `tool_input` JSON.
- Missing `TBD_TERMINAL_ID`: command exits silently.
- Malformed JSON: command exits silently.
- Stdin > 1 MiB: command exits silently.
- Subagent transcript path (`transcript_path` under `/subagents/`): command exits silently without RPCing the daemon.
- Main-agent transcript path: command issues the RPC.

**`PendingQuestionStore`**
- `set` then `entries(forTerminal:)` returns the stored value.
- `clear(terminalID:toolUseID:)` for the matching toolUseID removes the entry; mismatched toolUseID is a no-op.
- `clear(terminalID:)` removes all entries for that terminal regardless of toolUseID.
- Two `set` calls on the same terminal with different toolUseIDs → both entries present.
- `gcExpired(now:, maxAge:)` removes entries older than `maxAge`; younger entries are kept.

**Transcript merge (the branching gate)**
- Pending state present, no matching JSONL item → synthetic `toolCall` appended at tail with `inputTruncatedTo: nil`, `result: nil`, `subagent: nil`.
- Pending state present, JSONL contains a `tool_use` with the same `tool_use_id` → no synthetic appended (real wins) AND the entry is removed from `PendingQuestionStore` by the merger (lazy cleanup).
- Pending state absent → output byte-identical to `TranscriptParser.parse(filePath:)` (the gated-off ungated-behavior check).
- Two pending entries on the same terminal with different `toolUseID`s → both appear in the output (keying preserves both).
- Pending entry older than 15 minutes → reaped by `gcExpired`, not surfaced.

**RPC round-trip**
- `terminal.askUserQuestionPending` then `terminal.transcript` returns a transcript including the synthetic.
- A second `terminal.transcript` call once the JSONL contains the real `tool_use`+`tool_result` → no synthetic; pending store is empty for that terminalID.
- `terminal.askUserQuestionCleared` is a no-op today; test asserts `entries(forTerminal:)` is unchanged after calling it (the wire format reservation, not behavior).

## Restart and verification per CLAUDE.md

After daemon-side or shared-code changes, restart the worktree with `scripts/restart.sh` (the worktree's own copy, not the main project's), then verify exactly one `TBDDaemon` and one `TBDApp` are running from this worktree path with `ps aux | grep -E "\.build/debug/TBD"`.

Manual verification: open a TBD-spawned Claude session, ask Claude to invoke `AskUserQuestion`, confirm the card appears in the transcript pane with "Waiting for response…" before answering, answer in the terminal, confirm the card transitions to the answered state without flicker.

## Risks and mitigations

- **Hook didn't fire (daemon was down when PreToolUse triggered).** Synthetic card won't appear; user sees the question in the terminal pane only. Same degraded behavior as today. Acceptable.
- **Flicker on answer (PostToolUse clears too early).** Mitigated by lazy cleanup inside the merger — pending state lives until the JSONL match is observed, so the synthetic stays on-screen continuously through the transition.
- **Stale pending entry.** Two pressure-release valves: `gcExpired` (15-minute TTL) handles the "user-installed PreToolUse blocked the call" case where no answer/JSONL ever lands; terminal-close paths handle the "user killed the terminal mid-question" case; daemon restart handles everything else.
- **Hook overlay merge order vs. user hooks on the same matcher.** Claude merges `--settings` array entries with the user's settings.json by concatenation + dedupe. If the user has their own `PreToolUse:AskUserQuestion` hook, both run. If theirs returns `decision: "block"`, Claude skips the tool call entirely — our pending entry strands until TTL reaps it. Acceptable failure mode.
- **Concurrent same-terminal questions.** Keying on `(terminalID, toolUseID)` rather than `terminalID` alone means two pending questions coexist; merger surfaces both. Order in the items list reflects pending-store insertion order; identical to JSONL ordering once they flush.
- **Subagent (Task) AskUserQuestion.** The CLI bridge suppresses the RPC for subagent transcripts (see §Non-Goals and §2 in Architecture), so the synthetic never appears at the top level. Subagent questions are visible only after answer — same as today.

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
