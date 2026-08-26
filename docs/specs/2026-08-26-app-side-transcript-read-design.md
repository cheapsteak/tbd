# App-side transcript reading

The transcript pane renders a Claude Code session's JSONL. Today the app never
touches that file: it asks the daemon, which parses the whole file, encodes the
entire result, and ships it over the unix socket — every 1.5 seconds, per open
pane. This design moves the read into the app and makes it incremental, so a
tick costs what was appended rather than what the file contains.

## The problem

Three RPCs serve transcript content — `terminal.transcript`,
`terminal.transcriptItemFullBody`, and `session.messages`. Each has exactly one
consumer: TBDApp. No CLI command and no supervision path calls them. They are
pure file-parsing proxies.

`handleTerminalTranscript` reads the JSONL, parses it to `[TranscriptItem]`,
JSON-encodes that array into a `String`, then encodes that string again as a
field inside `RPCResponse` — so the payload crosses the socket double-encoded
with escaping. `TableTranscriptPaneView` calls it on a 1.5-second timer and
deep-compares the whole array against what it already had.

Measured against a live daemon with 131 tracked terminals:

| session | JSONL | RPC response | warm round-trip |
|---|---|---|---|
| p25 | 1.53 MB | 0.26 MB | 115 ms |
| p50 | 2.93 MB | 0.58 MB | 539 ms |
| p90 | 8.37 MB | 1.59 MB | 510 ms |
| worst observed | 27.5 MB | 6.51 MB | 4606 ms |

Those are cache-warm numbers — encode and transfer only, no parsing. Round-trip
time tracks the encoded item count rather than the raw file size, which is why
the p90 session is not the slower of the two middle rows. The worst session
cannot complete a single round-trip inside its own 1.5-second poll interval.

The parse cache makes this worse rather than better. `TranscriptParseCache`
keys on modification time and size, so it hits only while the file is *not*
changing. For the live session a user is actually watching, every tick is a
full re-parse on top of the encode and transfer above.

Two further measurements shape the design. Sampling every tracked transcript at
100 ms for 90 seconds: only 9 of 131 files appended at all, and a full `stat()`
sweep over all 131 costs 1.0 ms at p50, 2.2 ms at p90. Change detection across
an entire fleet is therefore cheaper than one of today's RPCs, and no file
watchers are needed to get it.

The same sampling establishes the freshness floor. Claude Code appends whole
message-lines in 0.5–15 KB chunks, with gaps between appends ranging from 0.2
to 52 seconds. The terminal renders tokens as they arrive from the API; the
JSONL learns of a message only once it is complete. A transcript pane can
therefore never track the terminal token-by-token. What it can do is show each
message the moment its line lands.

## Design

### The parser moves to TBDShared

`TranscriptParser` imports only Foundation, `os`, and `TBDShared`, so it lifts
into `TBDShared` unchanged apart from its `Logger` subsystem. Its daemon
callers — the session scanner, the context-load reader, the peer-origin
extractor — are unaffected. `AskUserQuestionMerger`, which is a pure function over parsed
items, moves with it; `PendingQuestionStore` stays in the daemon. Parser tests
move to `TBDSharedTests`.

### TranscriptSource

A new actor under `Sources/TBDApp/TranscriptSource/` owns, per session id:

- the absolute path, and the size and modification time it last consumed
- `byteOffset` — how far into the file it has parsed
- the built `[TranscriptItem]`
- `toolResultsByID`
- an index from `toolUseID` to that item's position in the array

The source publishes into `AppState.sessionTranscripts`, which all three
consumers — the live pane, the history pane, and the transcript overlay — already
read. The view layer is therefore unchanged, and the flag-off path keeps working
untouched. What changes is that the source writes only when it knows something
changed, because the incremental step tells it so. Today's per-tick deep compare
of the whole array exists only to answer that question and goes away with it.

### The incremental step, and the one forward reference

`buildItems` is already documented as a pure function of the lines handed to
it — "every item must be derivable from its own row. Do not add cross-row
state" — an invariant that exists because `parseTail` passes only the lines
inside a byte window. Item construction is row-local.

The only cross-line dependency in the parser is `toolResultsByID`. A `tool_use`
line resolves its result from a `user` line that arrives later, possibly much
later. An append-only reader gets this wrong in a way that looks like nothing
until a tool card sits at "running" forever, so the incremental step is defined
to produce both new items and updates to existing ones:

1. Seek to `byteOffset`, read to EOF. Truncate the buffer at its last newline
   and advance `byteOffset` only to there.
2. Parse the new lines. Merge their `tool_result` blocks into the retained
   `toolResultsByID`, noting which `tool_use_id`s are newly resolved.
3. Run `buildItems` over the new lines alone and append the result — legal
   precisely because item construction is row-local.
4. For each newly resolved `tool_use_id` that the index maps to an
   already-built item, rebuild that one item in place.

`terminal.transcriptItemFullBody` becomes a direct call to
`TranscriptParser.lookupDetail` against the same path — a single bounded JSONL
pass, on demand, when a row is opened. It needs none of the retained state
above.

A tick therefore costs O(appended bytes). Raw line dictionaries are
deliberately not retained: holding every parsed `[String: Any]` for a 27 MB
JSONL would cost more memory than the design saves in transfer.

Truncating at the last newline before decoding also means a chunk boundary can
never split a multi-byte character, and a half-written trailing line is simply
re-read whole on the next tick.

### Cadence

Panes register a session id with the source on appear and deregister on
disappear, declaring themselves foreground (on screen) or background (alive but
not visible — the viewer-slot LRU keeps up to eight). The source is told its
tier rather than deriving one, so it carries no panel-surface knowledge and is
testable without constructing a `WorkspaceTabSurface`.

One timer, one tier per registered session:

- **Foreground, app active** — 100 ms
- **Background** — 2 s
- **App not active** — everything drops to 10 s

The inactive tier is stated rather than inherited. A backgrounded TBDApp has its
delayed work coalesced by App Nap regardless; an uncoalesced 100 ms timer buys
no freshness and only enlarges the wake-up burst. The timer takes an injected
clock.

Nothing unregistered is ever stat'd, and at 1 ms per 131-file sweep the
pathological case costs nothing.

### Pending AskUserQuestion state

`PendingQuestionStore` holds captures the `PreToolUse` hook saw before the
`tool_use` reached the JSONL, and today `handleTerminalTranscript` merges them
in. Two side effects ride on that same call: the 900-second expiry sweep and
the clear-on-satisfied.

The daemon keeps the authoritative store and broadcasts a
`terminalPendingQuestionsChanged` delta on set and clear; the app merges
locally through `AskUserQuestionMerger`. The expiry sweep moves to its own timer
with an injected clock. Keeping the state daemon-side means an app restart
re-syncs on reconnect, which a pure relay would not.

### Failure handling

- A read failure or a vanished file never replaces a non-empty transcript with
  an empty one. `TranscriptParser.parse` returns `[]` when a file cannot be
  read and `TranscriptPollDiff.changed` treats that as a change, so today a
  transient failure blanks the pane. The source keeps its last good items and
  retries.
- A file that shrank, a modification time that moved backwards, or a changed
  `transcriptPath` discards the retained state and re-parses in full. These are
  the `/clear`, `/compact`, and session-rollover cases.

### Paths are handed in, never resolved

`TranscriptSource` takes absolute paths from `terminal.transcriptPath` and
`SessionSummary.filePath`. It performs no `TBD_HOME` or profile-directory
resolution of its own. This keeps `TBDAppTests` off the developer's real
`~/.claude` without `setenv`, which is legal only under `TBDHomeSerialized` in
`TBDDaemonTests`, and it avoids the static-path-helper shape that has defeated
the test fence before.

`session.messages` guards its path against `~/.claude/projects` because the app
supplies it. Reading directly retires that guard. This is safe because both path
sources originate from the daemon's own database rows and session records, so no
untrusted input crosses the boundary — but it is a removed check and belongs in
the record as a deliberate one.

## Feature flag

The change wholesale-replaces a load-bearing render path, so it ships behind
`appSideTranscriptRead`: a UserDefaults key, default off, read as
`object(forKey:) as? Bool ?? appSideTranscriptReadDefault`. That is the shape
`enableTranscriptKey` uses, and it keeps "never chose" distinct from "chose
false", so graduation reaches everyone who never touched the toggle while
preserving explicit opt-outs.

Off is today's three RPCs verbatim. Both paths compile and are tested for the
duration of the soak. Enable it in Settings to soak; graduate by changing the
one default constant; delete the three RPCs and the daemon-side parse cache in
a follow-up once the flag is gone.

## Testing

Both flag branches are covered, per the repository rule on gated behavior.

1. **Chunk-split equivalence.** Feed a real captured JSONL to the source in
   randomized chunk splits and assert the result equals
   `TranscriptParser.parse` over the whole file. At least one fixture must place
   a `tool_use` and its `tool_result` in different chunks. That is the case an
   append-only reader fails; without it the test passes against the bug.
2. Truncate or replace the file mid-stream and assert a correct full re-parse.
3. A read failure retains prior items and does not blank the pane.
4. With the flag off the file-reader seam is never called; with it on the RPC
   client is never called.
5. A pending-question delta renders a synthetic item, which is replaced rather
   than duplicated once the real JSONL line lands.
6. Cadence tiers, against an injected clock: 100 ms foreground, 2 s background,
   10 s inactive.

Fixtures are real captured bytes. Hand-authored JSON has twice exercised a
fallback path in this repository and produced real-looking wrong results.

## Success criteria

- A p50 live session costs 539 ms of daemon work and 0.58 MB of transfer per
  1.5-second tick today. After the change it transfers nothing and parses only
  what was appended.
- The worst observed session cannot complete one round-trip inside its poll
  interval today. After the change its per-tick cost is bounded by its append
  size.
- The delay from a line being written to its row appearing drops from up to
  1.5 seconds plus the round-trip to roughly 100 ms on the focused pane.

## Durable resources

This introduces none. The source reads files and holds memory bounded by the
pane registration set; nothing it creates outlives the tick that created it, so
no reconciler is needed.

## Non-goals

- **Remote and cloud lanes.** No lane provider declares a `transcript`
  capability — `ClaudeCloudDescribe` records that absence as a fact about the
  vendor surface — and the existing handler already rejects non-local
  worktrees. The transcript pane is local-only by construction, and reading
  files directly neither closes nor widens that gap.
- **Token-level streaming.** The JSONL gains a message only once it is
  complete. Closing the remaining gap between the terminal and the transcript
  would require a source other than the transcript file.

## Rejected alternatives

**Move the read without making it incremental.** The app would call
`TranscriptParser.parse` on the same 1.5-second tick. This removes the IPC and
the double encoding, but relocates a full re-parse of up to 27 MB into the UI
process every tick — trading a daemon bottleneck for an app one, in the process
that renders frames.

**Keep the daemon as owner and push deltas.** The daemon would watch the files
and broadcast appends over the existing subscription channel. This fixes both
the volume and the re-derivation without moving the parser, but leaves the
daemon doing work that only the app consumes, and requires it to track
per-client cursor state that the app can hold for itself.
