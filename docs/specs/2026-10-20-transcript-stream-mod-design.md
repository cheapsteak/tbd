# Transcript streaming through the session mod

The transcript pane shows a Claude answer only once Claude Code writes it to
the session's JSONL file, which happens seconds after the model produced it.
Transcript streaming closes that gap with a provisional row that fills in as
the model writes. Until now the text came from `TBDModelProxy`, a loopback
HTTP proxy that every routed session sent its API traffic through.

This design moves the job into the session mod as a feature,
`transcript-stream`. The mod sees each piece of the model's output from inside
Claude Code and writes a small snapshot file into the session's directory; the
pane reads that file. The proxy, its supervisor, its routing and everything
else that exists only for it are deleted. The feature keeps the existing
default-off flag, `transcript_streaming_enabled`, and works on both terminal
transports.

This design supersedes the
[model-proxy design](2026-09-05-transcript-streaming-model-proxy-design.md) and
the [model-proxy tool-search design](2026-09-21-model-proxy-tool-search-design.md).
Related: [session mod](2026-10-19-tbd-session-mod-design.md),
[named-reconciler doctrine](2026-08-15-named-reconciler-doctrine-design.md).

## Problem

The proxy works, but its cost is out of proportion to the job:

- **It sits in the request path of every routed session.** A routed session
  sends every API request through a TBD process. If that process hangs or
  dies, the session's requests fail. Keeping that safe took a supervisor with
  adoption checks, draining, a hang ladder, port reuse rules and a route table,
  about 6,000 lines with about 300 tests.
- **It changes how Claude Code treats the session.** A non-Anthropic
  `ANTHROPIC_BASE_URL` makes Claude Code treat the session as going through a
  third-party gateway. That turned off tool search and blew the context window
  on the first message, and it needed extra environment variables to undo.
  Remote Control is still unavailable on routed sessions.
- **It covers only part of the fleet.** Routing exists only on the holder
  transport and only for Anthropic-hosted sessions.

The proxy design rested on one fact: no Claude Code interface exposed model
output before the JSONL. That is no longer true.

## Facts this design rests on

Measured on Claude Code 2.1.303 with an observer mod passed through
`--plugin-dir` and a local fake of the Messages API that spaces its deltas
250–400 ms apart:

- **`turn.step` delivers each delta within 1 ms of the server sending it.** A
  `turn.step` hook is an async generator over the step's chunks (`text`,
  `thinking`, `tool`, `input`, `stop`, `engine`). Yielding each chunk object
  unchanged leaves the response untouched. Two observer mods stacked on one
  session logged the same millisecond, so the hop costs well under 1 ms.
- **Side requests raise no step.** The session-title request and the auto-mode
  classifier never reach `turn.step`. Subagent steps carry an `agentId`; main
  loop steps have none.
- **`session.append` fires once per assistant content block, at the block's
  end**, and its `uuid` equals the `uuid` of the JSONL line written later. The
  mod never sees the API `message.id`.
- **The JSONL still lags.** A step's lines reach the file 0.1–1.3 s after the
  step ends, and only after any tool permission or classifier wait, which was
  12 s in one run and can last as long as the person takes to decide. A text
  block reached the file about 3.5 s after it ended.
- **An interrupt keeps partial text.** Pressing Escape mid-answer still writes
  the partial text as a row with a `uuid`. The step ends with a null stop
  reason and `turn.complete` reports `aborted`.
- **`$.fs` writes whole files only.** It has read, write, list, exists and
  stat; no append, rename or delete. A write of about 10 KB took 0–12 ms. A
  write is not atomic, so a reader can see a cut-off file.
- **Thinking is mostly unreadable.** In about 47,000 thinking blocks from a
  week of real transcripts (Opus 5.5, Fable 5.1, Sonnet 5.5; Claude Code up to
  2.1.305), every block carried an encrypted signature. About 11% also carried
  a short readable summary (median 230 characters, at most about 530), written
  as a progress note. The rest had no readable text.

## The feature

### Shape

`transcript-stream` follows the session mod's feature pattern:

- `SessionMod/hooks/features/transcript-stream.ts` holds the hooks, exported as
  named functions.
- `SessionMod/hooks/register.ts` dispatches `turn.step`, `session.append` and
  `turn.complete` to it when the spawn's feature list names it.
- `SessionModFeature.transcriptStream` (raw value `transcript-stream`) is
  enabled by `config.transcriptStreamingEnabled`.
- `scripts/gen-session-mod-content.py` regenerates
  `Sources/TBDShared/SessionModContent.swift`.

The daemon already lists enabled features in `TBD_MOD_FEATURES` for every
Claude spawn on both transports, so the spawn path gains no code.

### Hooks

- **`turn.step`.** A pass-through generator. It yields each chunk object
  unchanged and at once, and never awaits anything between receiving a chunk
  and yielding it. It acts only on main-loop steps (`agentId` undefined).
  - It records `text` and `thinking` chunks into an in-memory snapshot of the
    step, in the order the step produced its blocks.
  - It ignores `tool`, `input` and `engine` chunks.
  - When the step returns, it records the stop reason. A null stop reason
    marks an interrupted step.
- **`session.append`.** For each assistant row kept from the main loop, it
  attaches the row's `uuid` to the earliest ended block of the same kind in the
  current step that has none yet. Every thinking block takes part in this
  matching, including those with no readable text, so the order stays aligned
  with the rows.
- **`turn.complete`.** Records that the turn finished, with its reason.

Every hook carries the mod's `.catch` that passes the event on, so a failing
feature leaves the session as it would be without the mod.

### The snapshot file

The mod writes `~/tbd/sessions/<claudeSessionID>/transcript-stream.json`. The
file is a live view, not a history. It holds:

- `schemaVersion`, `sessionId`, `updatedAtMs`;
- `turn`: the turn's id and, once known, how it completed;
- `steps`: the current main-loop step and the one before it. Each step holds
  its index, whether it ended, its stop reason, and its blocks. Each block holds
  its `kind` (`text` or `thinking`), the text so far, whether it ended, and its
  `uuid` once `session.append` supplied one.

A thinking block with no readable text is left out of the file. The mod still
tracks it in memory for `uuid` matching.

The mod clears the file's steps when a new turn starts.

### Writing

A separate task writes the file; the `turn.step` hook only updates memory and
marks the snapshot changed.

- At most one write is in flight. The newest snapshot wins; intermediate ones
  are skipped.
- A write follows the previous one by at least 100 ms while text streams.
- The write that records a block's end, a step's end or a turn's end goes out
  without waiting for the 100 ms.
- A failed write is ignored; the next write replaces the whole file.

The throttle reads time through a clock passed into the feature, so tests
drive it without waiting.

A long answer is about 40 KB, so a full rewrite every 100 ms is a few
milliseconds of work per second. The file stays far below `$.fs`'s 4 MiB
write limit because it carries no tool input.

## The app

### Reading the file

The pane builds the path from `TBDConstants.sessionsDir` and the terminal's
`claudeSessionID`; it stops reading `Terminal.transcriptStreamPath`. A `/clear`
gives the session a new ID, and the pane already follows that change.

`TranscriptPollScheduler` reads the file on its existing schedule (100 ms in
the foreground, 2 s in the background, 10 s inactive). `StreamFileReader`
becomes a whole-file decoder:

- **A missing file** means there is no stream.
- **A file that does not parse, or has an unknown `schemaVersion`,** is no
  news: the pane keeps the last good snapshot. A cut-off read is the expected
  cause, and the next read 100 ms later sees the finished write.

The line folding, the chunk splitting and the 10,000-line cap are removed.

### Showing it

- **Text blocks** the JSONL has not matched show as the provisional row,
  with the ▍ cursor while the block is still streaming.
- **Thinking summaries** show through the existing `ThinkingRow`, marked as
  provisional.
- **Blocks show in the order the step produced them.**

### Retiring a provisional block

A provisional block leaves the pane when any of these holds:

1. **The JSONL has a row with the block's `uuid`.** `IncrementalTranscript`
   keeps the set of `uuid`s it has seen, in place of
   `assistantTextMessageIDs`. An interrupted block retires this way too,
   because its partial text still becomes a row.
2. **The terminal exits.**
3. **The session's heartbeat is stale.** `alive.json` is older than 90 s. To
   read it, the app needs the `alive.json` record and the 90 s constant. They
   move from the daemon target into `TBDShared`; the liveness logic stays in
   the daemon.
4. **The block is no longer in the snapshot,** because a new turn cleared the
   steps or a newer step pushed it out.

There is no fixed timer. A tool permission wait can hold the JSONL write for
minutes, and a timer would drop the row in the middle of that wait.
`ProvisionalRetireTimer`, the 60 s unconfirmed rule, the 600 s silent rule
(`ModelProxyLimits.drainCap`) and the `message.id` matching are removed.

### Sessions without the mod

Claude Code does not load the mod in an untrusted workspace or under an
organization policy that blocks mods, and a crashed mod worker writes nothing.
Such a session has no file, and the pane works from the JSONL alone, as it does
with the flag off. Nothing else in TBD depends on the stream.

## Removing the proxy

Everything that exists only for the proxy is deleted:

- **The program:** the `TBDModelProxy` target and its test target in
  `Package.swift`.
- **Shared types:** `Sources/TBDShared/ModelProxy/`.
- **The daemon:**
  - `Sources/TBDDaemon/ModelProxy/`: the supervisor, spawner, client, pid
    file, port probe, route store and route attachment.
  - The proxy wiring in `Daemon.swift`.
  - Route attachment at the four routed spawn sites (worktree create,
    `terminal.create`, wake and the holder profile swap), and the matching
    route retirement on dispose, reconcile and park.
  - `TerminalStore.hasLiveRoutedSession` and `ClaudeHookOverlay.overlaySetsEnv`.
  - The first-party environment variables (`_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL`,
    `ENABLE_TOOL_SEARCH`) and the first-party probe.
- **Configuration:**
  - The coupling between the two flags and the port mint in `ConfigStore`.
  - `Config.transcriptStreamingEffective`.
  - `config.setModelProxyEnabled` and the proxy fields of the capabilities
    result.
  - The proxy toggle in Settings.
- **Reclaiming:** `ModelProxyFileCollector`, its OrphanGC leg, and the
  `TBDModelProxy` entry in `OrphanProcessCollector`'s protected binaries.
- **Scripts and docs:** the product lists in `scripts/restart-bundle-lib.sh`
  and `scripts/update-release-lib.sh` and their test assertions, the
  `.swiftlint.yml` scopes, and the proxy passages in `docs/updating.md` and
  `docs/profile-exec.md`.
- **Tests** of all of the above, including `FakeModelProxySupervisor` and the
  proxy cases in `TerminalCreateTransportGateTests`.

The `NIOHTTP1` dependency stays; the daemon's HTTP server uses it.

### Columns

`config.model_proxy_enabled`, `config.model_proxy_port` and
`terminal.transcript_stream_path` stay in the database, because landed
migrations are never changed. Nothing reads them. They leave the Swift models
where decoding allows it; a field that must stay for decoding carries a
comment saying it is unused.

### Leftovers on disk

At daemon start, a one-time step removes `~/tbd/proxy` and `~/tbd/streams` if
they exist. It logs what it removed and ignores errors.

A proxy process still running at upgrade is not touched: it retires itself
after 24 hours without a supervisor. A session still routed through it fails
its next request after that, and must be restarted. That cost is accepted: the
proxy flag was experimental and default-off, and a session started after the
upgrade is never routed.

### Reclaiming the new file

The snapshot lives in the session's directory, which the OrphanGC arm over
`~/tbd/sessions/` already reclaims. No new reconciler is needed.

## Flag

`transcript_streaming_enabled` keeps its meaning: stream into the transcript
pane. It stays default-off and tri-state, and it no longer depends on a second
flag.

- **Settings:** the toggle stays. Its help text says it applies to sessions
  started after it is turned on, and only where Claude Code loads TBD's mod.
- **RPC:** `config.setTranscriptStreamingEnabled` stays and no longer touches
  any proxy setting.
- **Soak:** turn the toggle on in Settings, start new sessions on both
  transports, and compare the provisional rows against the final JSONL rows.
  Check that thinking summaries stream as deltas rather than arriving whole.
- **Graduation:** flip `Config.transcriptStreamingEnabledDefault` once the soak
  shows no lost or stuck rows.

## Delivery

Three pull requests, in order:

1. **The mod feature and the app.** `transcript-stream`, the
   `SessionModFeature` case, the new decoder and retire rules, and the end of
   the coupling between the two flags: turning streaming on no longer turns
   the proxy on. From this change on, the pane reads only the mod's file; the
   proxy still runs when its own flag is on, but nothing reads its output.
2. **The proxy removal.** Everything under "Removing the proxy".
3. **The leftovers cleanup.** The one-time removal of `~/tbd/proxy` and
   `~/tbd/streams`.

## Testing

- **The mod** (`SessionMod/tests/`, calling the exported handlers):
  - main-loop filtering: a subagent step writes nothing;
  - chunk pass-through: every chunk is yielded unchanged and in order;
  - a thinking block with no text is left out of the file but still takes its
    `uuid`, so the following text block gets the right one;
  - `uuid` attachment order across thinking and text blocks;
  - an interrupted step records a null stop reason;
  - the throttle, with a fake clock: one write in flight, newest wins, block
    and step ends write at once;
  - a new turn clears the steps.
- **The app:**
  - the decoder: missing file, cut-off file, unknown version, good file;
  - each retire rule;
  - flag off: the file is never read and the pane is unchanged;
  - flag on with no file: the pane matches flag off.
- **The daemon:** the feature list contains `transcript-stream` exactly when
  the flag is on; the leftovers step removes both folders and survives their
  absence.
- **CI:** the existing session-mod job runs the generator check,
  `claude plugin validate --strict` and `claude plugin test`.

## Out of scope

- **Tool input.** `input` chunks stream the JSON of a tool call. Showing it
  needs tool cards that render half-written JSON, and large inputs would grow
  the snapshot toward the write limit.
- **Subagent streams.** Only the main loop streams, as before.
- **Sessions that do not load the mod.** They keep the JSONL-only pane.

## Rejected alternatives

- **Keeping the proxy beside the mod.** Two ways to produce the same rows
  doubles the code to keep correct, and the proxy's costs (request-path risk,
  gateway treatment, holder-only) remain.
- **One file per write, as an append log.** Each write stays small whatever
  the answer length, but the mod cannot delete, so a long session leaves tens
  of thousands of files until its directory is reclaimed. A fixed ring of
  reused names bounds the count, at the price of sequence numbers and
  overwrite detection in the reader. The snapshot's one cost, rewriting the
  whole file, matters only at sizes this feature does not carry.
- **One snapshot per step.** Only the live step's file can be cut off, but
  every step leaves a file. It gains nothing over a snapshot that holds two
  steps.
- **A fixed time limit on unconfirmed rows.** A permission wait can hold the
  JSONL write for minutes; the heartbeat and terminal exit cover a dead
  session without dropping a live row.
- **Streaming full thinking.** The API sends the model's reasoning encrypted;
  only the occasional summary is readable, and the feature shows those.
