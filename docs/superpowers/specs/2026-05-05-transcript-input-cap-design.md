# Transcript: cap tool-call input size

Follow-up to PR #99. Tool *results* in the transcript are size-capped
(`bodyCharCap=2000`, `bodyLineCap=20`) but tool *inputs* are passed through
verbatim. A single `Write` of a real source file can carry hundreds of KB
through the daemon→app `terminal.transcript` channel and is then held in
the app's `sessionTranscripts` LRU and the daemon's `TranscriptParseCache`,
each sized for 50 sessions. Several `Write`s in one session = several MB
duplicated across both caches and re-sent on every 1.5s poll.

## Goal

Apply the same truncation contract to inputs that already exists for
results: cap large string fields in the input dict, surface a
`TruncationFooter` in cards, fetch the full body on demand via the
existing `terminal.transcriptItemFullBody` RPC.

## Design

### Parser: per-field truncation

In `Sources/TBDDaemon/Claude/TranscriptParser.swift`, the path that
serializes `inputJSON` for a tool-use block walks the input dict before
serializing and replaces any string value exceeding `bodyCharCap` chars
or `bodyLineCap` lines with its truncated form, reusing the existing
`truncate(_:)` helper. After truncation, the dict is JSON-serialized as
today (sortedKeys). Result: the `inputJSON` string is always valid JSON
and always ≤ a bounded size (cap × number of string fields), so cards
keep parsing without changes.

Recursion: nested arrays and dicts are walked too (covers
`MultiEdit.edits[*].old_string`/`new_string` and any future tool with
nested string fields).

### Wire change: `inputTruncatedTo`

`Sources/TBDShared/Models.swift` — extend `TranscriptItem.toolCall`:

```swift
case toolCall(id: String, name: String, inputJSON: String,
              inputTruncatedTo: Int?,
              result: ToolResult?, subagent: Subagent?, timestamp: Date?)
```

Semantics: `inputTruncatedTo` is the char count of the *original full
inputJSON* (before any per-field truncation), set iff any field was
truncated, otherwise `nil`. Mirrors `ToolResult.truncatedTo`.

`TranscriptItem` is auto-synthesized Codable. The new positional-but-
labeled associated value is optional, so old encoded items decode as
`nil` (same pattern used when `subagent: Subagent?` was added). All
constructors and `switch case .toolCall(...)` sites need the extra
binding.

### Full-body RPC: `<tool_use_id>#input` suffix

Reuse `terminal.transcriptItemFullBody`. Extend
`TranscriptParser.lookupFullBody(filePath:itemID:)` with one new branch:

- itemID has form `<tool_use_id>#input` → split on `#`, scan assistant
  lines' `content` array for `tool_use` blocks where `id` matches the
  prefix, re-serialize that block's `input` dict using the same options
  (`.sortedKeys`) and return the full string.

No RPC signature change. App calls
`daemonClient.transcriptItemFullBody(filePath:, itemID: "\(toolUseID)#input")`
and re-parses the returned string.

### Cards: opt-in plumbing

Four cards display content that can be large. Each adds:

1. `let inputTruncatedTo: Int?` parameter (passed from
   `TranscriptItemView`).
2. `@State private var fullInputJSON: String? = nil`.
3. Compute `effectiveInputJSON = fullInputJSON ?? inputJSON`; existing
   `decodeInput()` consumes that.
4. Below the body, when `inputTruncatedTo != nil && fullInputJSON == nil
   && terminalID != nil`, render `TruncationFooter(truncatedTo:
   inputTruncatedTo!, currentLength: inputJSON.count)` whose action
   fetches via RPC and assigns `fullInputJSON`.

Cards in scope:

- `WriteCard` — `content` field is the file body. Primary win.
- `EditCard` — `old_string`, `new_string`, and `MultiEdit.edits[*]`.
- `AgentCard` — `prompt` field; subagent prompts run 5–10KB.
- `BashCard` — `command` is usually short but rare long heredocs/scripts
  benefit from the cap.

Cards out of scope: `ReadCard`, `GrepCard`, `GlobCard` — inputs are paths
and patterns, never large.

### `TranscriptItemView` wiring

`Sources/TBDApp/Panes/Transcript/TranscriptItemView.swift` (or wherever
`.toolCall` is destructured) passes the new `inputTruncatedTo` to each
card initializer.

## Caps

Same constants for inputs as for results: `bodyCharCap=2000`,
`bodyLineCap=20`. No per-tool tuning. Rationale: consistent UX, single
knob to tune, and the affected fields (file content, prompts, edit
hunks) all benefit from the same scale.

## Backward compatibility

- Old encoded `TranscriptItem.toolCall` rows decode with
  `inputTruncatedTo = nil`. No-op for cards.
- `TranscriptParseCache` entries cached before the upgrade decode the
  same way; on next parse they get the new field populated.
- Old daemons with new app: the field is missing from the wire payload,
  decodes as `nil`, no truncation footer shows. No crash.
- New daemon with old app: old app ignores the unknown field via Codable
  defaults. No crash.

## Testing

`Tests/TBDDaemonTests/TranscriptParserTests.swift`:

- New test: a synthetic JSONL line with a tool_use whose `input.content`
  is 5000 chars yields a `TranscriptItem.toolCall` with truncated
  `inputJSON` and non-nil `inputTruncatedTo` equal to the pre-truncation
  full-JSON char count.
- New test: a tool_use with all-small inputs yields
  `inputTruncatedTo == nil`.
- New test: `MultiEdit` with one large `new_string` inside `edits[]`
  truncates the nested string and sets `inputTruncatedTo`.
- New test: `lookupFullBody(filePath:, itemID: "\(toolUseID)#input")`
  returns the full un-truncated input JSON.

## Out of scope

- No new tool-card types. Truncation only retrofits existing cards.
- No change to caps for results.
- No change to the LRU sizing — this fix reduces memory pressure within
  the existing 50-session window.
