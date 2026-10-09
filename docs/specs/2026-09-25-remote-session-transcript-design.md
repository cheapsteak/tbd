# Remote session transcript and composer

## Problem

A remote session's pane in TBD shows only its terminal. There is no transcript view and no way to send a message except by typing into the attached terminal or, when nothing is attached, through a single-line raw-keystroke footer. Local Claude sessions have both: a live transcript pane beside the terminal, and a composer in that pane that submits messages reliably.

The pieces that exist for remote sessions do not add up to either feature:

- The daemon's `remote.transcript` RPC runs the provider's `transcript` verb, re-downloads the whole conversation on every call, drops the cursor, and stores nothing. Only `tbd remote transcript` calls it; the app has no client for it and never checks the capability.
- The live transcript pane (`TableTranscriptPaneView`) is keyed on a local `Terminal` row and a `LocalWorktree`, so it cannot render a remote session at all.
- The contract's `send` delivers raw keystrokes. Reliable message submission into Claude Code needs the body as one bracketed paste followed by a separate Enter; an unbracketed write of 64 bytes or more with `\r` in the same write does not submit, and past roughly 1 KB a keystroke burst is coalesced into a paste that absorbs the Enter (the 64-byte threshold is measured in `docs/specs/2026-09-05-transcript-composer-design.md`, the ~1 KB coalescing in `docs/submit-reliability.md`). Locally the daemon owns that mechanism (`tmux paste-buffer -p` then `send-keys Enter`). Over raw `send` the caller would have to reproduce it without seeing the remote terminal's paste mode, across a transport it cannot observe, and with no evidence that the message landed.
- The contract gives a caller no signal when `transcript` answers `--since` from the beginning — a cursor the provider can no longer honor, or a conversation restarted by `/clear` or a resume — so an appending caller would duplicate records or splice two conversations together.
- A transcript fetched only while its pane is on screen is stale whenever the user opens it: a session that worked for an hour unwatched owes the whole hour on open, over a transport that may page at tens of seconds per call. And a forward read can only start at the beginning, so a long conversation the user has never opened streams in from its first record while the user wants its last.

## Goals

- Show a remote session's transcript beside its terminal, live, using the existing transcript renderer.
- Send messages to a remote session from a composer in that transcript, with the same delivery guarantees the local composer has.
- Keep what is fetched, so reopening a transcript, relaunching the app, or restarting the daemon fetches only what is new. Some providers' transports are slow per call and cap output per call, so a full refetch of a long transcript takes many round trips.
- Keep remote sessions' transcripts up to date without the user opening them, so a pane opens over a current cache.
- Never load a transcript eagerly in full. A session new to the cache, or far behind it, loads only its last 12 message records; earlier history loads only when the user scrolls up to it.

## Non-goals

- New tabs, note tabs, or `⌘T` on remote sessions.
- A slash-command menu, image attachments, or waking an exited session from the remote composer.
- Transcripts for providers that do not declare `transcript.read`.
- Background sync for a provider that does not report the transcript hint, or tail-first loading for one that does not declare `transcript.tail`. Such a provider syncs only while its pane is open, reading forward from the beginning.
- Earlier history in the local transcript pane or Session History. Both read local files and are unchanged.

## Contract changes

All changes are to `docs/remote-provider-contract.md`. None requires a new major.

### Transcript operations share a namespace

The four transcript operations become subcommands of one verb, each with its own capability string:

- **`transcript read <id> [--since <cursor>]`** – capability `transcript.read`. Reads a live session's conversation.
- **`transcript retain <id>`** – capability `transcript.retain`. Stores a session's conversation in the provider's durable store and returns a receipt.
- **`transcript import`** – capability `transcript.import`. Stores Claude Code JSONL read from stdin and returns a receipt.
- **`transcript recall <key>`** – capability `transcript.recall`. Reads a stored conversation back.

Each remains a separate capability because each has different prerequisites: a provider may snapshot its own sessions without accepting foreign blobs, or serve live transcripts without a durable store. `delete <id> --retain` is valid only where `transcript.retain` is declared. `create`'s `seed` field keeps its own capability, `seed`, because it gates a field of `create`, not a transcript operation.

The invocation model generalizes accordingly: a verb is one word or, for `transcript`, one word and a subcommand, followed by its arguments.

**This rename happens within the current majors, against the versioning rule that a rename needs a new one.** The rule protects implementers the contract's owner cannot coordinate with, and this contract has none: every provider that implements it is maintained alongside TBD. A major bump would also cost more than the rename. A provider declaring only major 1 would fail negotiation with a caller that required the new major, making the whole provider unusable rather than just two of its verbs. Renamed in place, a provider that still declares `retain` or `recall` keeps working, and TBD simply stops offering those two operations until the provider adopts the new spellings, because a caller ignores capability strings it does not recognize. This is an exception justified by the absence of outside implementers, not a precedent for later renames.

### `transcript read` envelope: `reset` and `more`

The stderr envelope gains two optional booleans:

```json
{"cursor": "opaque-provider-string", "reset": true, "more": true}
```

- **`reset: true`** – this output starts from the beginning of the session's current conversation, and the caller discards anything it holds from earlier calls. A provider MUST set it whenever it answers a `--since` request from the beginning: a cursor it can no longer honor, or a conversation that has moved to a new transcript (`/clear`, a resume). A call without `--since` is a reset by definition, whether or not the flag is set. The transcript is the session's *current* conversation, just as a local transcript pane follows the new Claude session after `/clear`.
- **`more: true`** – the provider stopped at its own size limit before reaching the end, and the caller calls again with the returned cursor at once. This lets a provider whose transport caps output per call return a long transcript in pages instead of exceeding the 60-second timeout. `more` requires a cursor; `more` without one is a contract violation, read as though `more` were absent.

A provider with no incremental support still emits no envelope. The caller then refetches the whole transcript each time, treats each response as a reset, and considers itself caught up.

### `send <id> --submit`

A new capability, `send-submit`, admits one flag on the existing `send` verb:

- stdin is the message as UTF-8 text, not keystrokes. The provider places it in the agent's input as a single paste, so embedded newlines belong to the message, and then submits it with a separate Enter.
- Exit 0 means the message was delivered and submitted; it does not mean the agent has acted on it.
- A caller MUST NOT pass `--submit` to a provider that has not declared `send-submit`. `send` without the flag is unchanged: raw keystrokes, nothing appended.

The flag makes `send` read the way it reads everywhere else in TBD — `tbd terminal send --text … --submit` locally — while leaving the raw form intact for providers that implement only that.

Paste mechanics stay with the provider because the provider owns the transport and can see the terminal: whether bracketed paste is on, when the input box is ready, how long to wait before Enter. A caller composing bracketed paste over raw `send` would encode one TUI's timing across a hop it cannot observe, and would depend on the provider's keystroke path passing escape bytes through untouched. The machine-interface rule applies unchanged: a provider may verify delivery however it likes, and TBD reads only the exit status.

### `transcript read --tail` and `--before`

A new capability, `transcript.tail`, admits two forms of `transcript read` that read a conversation from its end. Both count in **message records**: JSONL records the pane renders as a message. A record is a message record when both of these hold:

- it does not carry `"isSidechain": true`, and
- it is one of:
  - a `type: "assistant"` record whose `message.content` is a non-empty string, or an array holding at least one `text` block with non-empty `text`;
  - a `type: "user"` record whose `message.content` is a non-empty string, or an array holding at least one `text` block with non-empty `text` — an array of only `tool_result` blocks does not count — unless that text (the string, or the array's first `text` block) begins with `<system-reminder`, `<local-command-`, `<environment_details`, `<task-notification`, `<tool_result`, `[SYSTEM NOTIFICATION`, or `Base directory for this skill:`, which mark injected context rather than a message;
  - a `type: "attachment"` record whose `attachment.type` is `queued_command`, which is how Claude Code records a prompt typed while the agent was mid-turn.

Every other record — tool calls, tool results, thinking, injected context, and any other type — comes along with the message records it sits among, and is not counted. The rule follows `TranscriptParser` and `UserMessageClassifier`: the records it admits are the ones that become `.userPrompt`, `.assistantText`, or `.peerMessage` items, which the pane draws as chat bubbles, and the prefixes it excludes are the ones `UserMessageClassifier` routes to a system kind, which the pane folds into an activity group. A slash-command envelope (`<command-name>…`) is a message, because the pane draws it as the user's bubble, and so is a user line marked `isMeta`, because the pane draws it too.

- **`transcript read <id> --tail <n>`** returns the end of the current conversation, starting at the record boundary of the n-th-from-last message record and including everything after it, or the whole conversation when it holds fewer than n. It is always a reset. The envelope carries `cursor`, which continues forward on `--since` like any other cursor, and `before`: an opaque cursor for the history above this output, absent when the output already starts at the conversation's beginning. It never sets `more`.
- **`transcript read <id> --before <cursor> --tail <n>`** returns the n message records, with the records among them, that end immediately before `<cursor>`, or everything from the conversation's beginning when fewer than n remain. The envelope carries only `before`, absent once the page reaches the conversation's beginning. A `before` cursor names a position in one specific conversation and stays valid after `/clear`, because it still points into the conversation it came from. A provider that can no longer serve it fails with the error code `cursor_expired`.

In both forms a provider MAY return fewer than n message records to stay within its own byte budget, but MUST return at least one message record, with the records among them, when one exists before the requested position, even past multi-megabyte records; when none remains before the position, it MUST return every record from the conversation's beginning up to it. Either way paging progresses: every page brings a visible message or reaches the beginning. `--tail` is not combined with `--since`. A caller MUST NOT use either form without `transcript.tail`.

The unit is the message record because it is one message in the pane. Tool calls, tool results, thinking, and injected context fold into a collapsed activity row, so a page counted in them can arrive with no visible message at all; counting only message records makes each page bring about 12 messages. The rule reads only a record's own JSON, so a provider applies it without TBD's renderer, and its edges are not load-bearing: a provider that counts a rare record differently from the pane changes only how many records a page carries, never which positions the cursors name. The count is TBD's request parameter, not a contract constant: TBD asks for 12, for a tail reset and for each page of earlier history alike.

### The transcript hint

A session object on `list` and `events` may carry an optional hint:

```json
"transcript": {"id": "opaque-conversation-id", "size": 1048576}
```

- **`id`** – opaque, and changes when the session moves to a new conversation (`/clear`, a resume).
- **`size`** – the conversation's length in bytes. It never decreases for a given `id`.

The hint is only a change signal. A caller compares it with the hint it recorded and never constructs a cursor from it. It needs no capability: like every optional session field, a caller that does not read it ignores it.

## Daemon

### `RemoteTranscriptSync`

A new actor under `Sources/TBDDaemon/Remote/` gives each `(provider, sessionID)` a serialized fetch lane:

- One `transcript read` runs per session at a time. A sync request arriving while one is in flight waits for it, plus at most one follow-up, so a burst of requests costs at most two fetches. A load of earlier history (see "RPCs") takes the same lane: the lane admits syncs and loads one at a time, in arrival order, so a load never runs beside a sync and a sync never runs beside a load. The coalescing applies to syncs only.
- It pages while the envelope says `more`, writing each page before fetching the next. A sync stops after a page cap and reports that it is not caught up, so a provider that never clears `more` cannot hold the lane forever; the next sync resumes from the stored cursor.
- The page cap is one page, for an initial load and an incremental sync alike. A page is the unit the pane can show, and it is slow: over a provider transport measured at about 60 KB/s, one full `transcript read` page of about 860 KB takes about 22 seconds. The round trip that ends one sync and starts the next — a local RPC, a `state.json` load, and the app reading the appended bytes — costs milliseconds. Returning after every page therefore puts first content on screen one page in, at no measurable cost to throughput, and keeps each lane hold to a single provider call, so a sync asked for by a send waits behind one page rather than several. The app's driver re-syncs at once while a sync reports it is not caught up (see "Refreshing"), so a long first load streams in page by page. An incremental delta is almost always one page, so a separate cap for it would buy nothing.
- A `--since` answer that comes without a valid envelope, absent or malformed, is discarded rather than written: that output is only the delta after the cursor, so reading it as a reset would wipe the history held before it. The sync drops the cursor and refetches from the beginning within the same sync. The discarded answer does not count toward the page cap; the refetch does. With a one-page cap, a discard that used the sync up would leave the stored cursor in place, so the next sync would send it again, be discarded again, and never progress. The loop stays bounded because the refetch carries no cursor and so cannot itself be discarded: every discard is followed by a persisted page. On the envelope's own side, a `{`-prefixed stderr line that is not valid JSON is a diagnostic and is passed over; only an object naming `cursor`, `reset`, `more`, or `before` that then fails the strict decode is malformed.
- When the flag (see "Gating") is on and the provider declares `transcript.tail`, the actor chooses between a tail reset and a forward read on every sync, for the on-screen pane and background sync alike. It compares the session's current hint, taken from the hint store (see "Transcript hint store"), with the hint recorded in `state.json` at the last caught-up sync. It runs `--tail 12` when the cache is empty — it holds no forward cursor, so a forward read would fetch the whole conversation — when the current hint's `id` differs from the recorded one, or when the current hint's `size` has grown by more than 512 KB past the recorded one; otherwise it reads forward with `--since`. The 512 KB threshold is a constant pinned by a test, not configuration. A far-behind session therefore drops its cache in the reset, and the history it held becomes earlier history, loaded on scroll-up. The cache is always one contiguous run ending at the newest record, never one with gaps.
- A comparison needs both hints. When the current hint is unknown — the hint store holds nothing for the session, as after a daemon restart until the first `list` or `events` sighting — or the cache recorded none, as a cache written before the hint existed, a non-empty cache reads forward. Neither case is evidence that the session is far behind, and a tail reset would discard history the cache holds. An unknown current hint also leaves the recorded hint in place, so the first sighting after a restart still matches it.
- A `--tail` answer without a valid envelope, or with an envelope that carries no `cursor`, is discarded rather than written: it gives the cache nothing to continue forward from. The sync falls back to a full forward read, with no cursor, within the same sync, exactly as for a discarded `--since` answer. The discarded answer does not count toward the page cap, and the forward read cannot itself be discarded, so the sync always persists a page.
- With the flag off, the actor never passes `--tail` or `--before`, and makes no decision from the hint. A cache that holds a non-null `before`, left from a period with the flag on, is refetched in full — a reset without `--tail` — on its next sync, so the whole conversation returns. The same holds with the flag on for a provider that does not declare `transcript.tail`: the history above such a cache is unreachable, so the cache starts over rather than keep a `before` it can never follow.
- Every sync that ends caught up records the current hint, when known, in `state.json`, whether or not the flag is on. The flag governs decisions, not bookkeeping: a hint recorded only while the flag was on would be stale by the time the flag came back, and the first sync would read all the growth in between as far behind.
- The sync actors and the `remote.sendMessage` serializer never sleep, poll, or time out on their own. Each provider call's timeout is enforced by `ProviderRunner` through `RemoteProviderManager.invoke(timeout:)`, and the refresh cadence lives in the app's sync driver, which takes the injected clock.

### Cache

Each session's transcript is cached under `~/tbd/remote-transcripts/<provider>/<sessionID>/`, through a new `TBDConstants` helper that honors `TBD_HOME` and escapes both components the way `retainedTranscriptPath` does. The directory holds two files:

- **`transcript.jsonl`** – the conversation.
- **`state.json`** – `{cursor, length, generation, before, head, hint}`. `before` is the provider's cursor for earlier history, null once the cache reaches the conversation's beginning. `head` is a counter bumped on every prepend. `hint` is the transcript hint recorded at the last caught-up sync, so background sync survives a daemon restart without refetching every session. A reset that changes the file clears `hint`, and the sync records it again once caught up.

The two files are kept consistent by write order:

- **Append.** A page is appended to `transcript.jsonl` first. Then `state.json` is written atomically with the new cursor and the file's new length. On load, `transcript.jsonl` is truncated to the recorded `length`, so a crash between the two writes cannot leave records that the next fetch returns again.
- **Reset.** Three steps, in this order. First `state.json` is written atomically with no cursor, a `length` of 0, and `generation` incremented, so readers know to discard what they hold. Then the page is written to a temporary file and renamed over `transcript.jsonl`. Last, `state.json` is written again with the new cursor and length, and for a tail reset with the envelope's `before`. A crash after the first step leaves a state that records nothing: load truncates `transcript.jsonl` to zero bytes, and the next sync fetches from the beginning, which is itself a reset. No crash point can pair a new file with an old cursor. Load also removes any temporary file a crash left between the write and the rename.
- **Prepend.** Earlier history goes at the front of the one file, in four steps. First `state.json` is written atomically with a `pendingPrepend` marker. Then the fetched page followed by the current file is written to a temporary file, which is renamed over `transcript.jsonl`. Last, `state.json` is written atomically with the new `length`, `before`, and `head`, and the marker cleared. A load that finds the marker resets the cache, at the cost of one tail refetch. Without the marker, a crash between the rename and the last write would leave a file longer than `length` beside an old `before`, and the truncation on load would cut the newly prepended file in the wrong place.
- **Repair on load.** Beyond truncating uncommitted bytes, load clears `transcript.jsonl` and drops the cursor when the file is shorter than the recorded `length` or `state.json` cannot be read, so the next sync fetches from the beginning. Every repair increments `generation`, so a reader never keeps records the cache no longer holds.
- **Unchanged reset.** A reset whose page is byte-identical to the committed file keeps its `generation` and rewrites only the cursor. A provider with no incremental support answers every call with the whole conversation, and bumping `generation` each time would make the pane discard and re-render an unchanged transcript on every sync.

The cache sits outside the Claude projects store on purpose: `ClaudeSessionScanner` searches under project roots, so a TBD-owned root keeps remote conversations from being listed as local sessions. The daemon only writes this root and the app reads it directly, so no daemon read RPC needs to admit a second permitted transcript root.

### Transcript hint store

The hint never enters the mirrored `remote_session` row. `RemoteSessionStore` detects a change by comparing the encoded payload, and the hint's `size` grows with every record the agent writes, so a mirrored hint would rebroadcast `.remoteSessionsChanged` to the app on every poll and every `events` line. The mirror stores each session's payload without the hint.

The daemon instead keeps each session's latest hint in a small in-memory store, `RemoteTranscriptHints` under `Sources/TBDDaemon/Remote/`. `RemoteProviderManager` feeds it every sighting it processes in `apply(snapshot:)` and `applyUpsert`, after deletion suppression, with the hint intact; it records hints whether or not the flag is on. The store serves both readers of the current hint: background sync's admission, and the tail-or-forward choice in `RemoteTranscriptSync` for every sync, on-screen syncs included. A sighting without a hint removes the session's entry. The store starts empty, so after a daemon restart every session's current hint is unknown until its first sighting.

### Background sync

A second actor, `RemoteTranscriptBackgroundSync` under `Sources/TBDDaemon/Remote/`, keeps unopened sessions' caches current. It runs no timers. Its only input is the sightings `RemoteProviderManager.apply(snapshot:)` and `applyUpsert` already process, handed over with their hints: it enqueues a session once when the sighting's hint differs from the hint recorded in `state.json` at the session's last caught-up sync, and repeated changes before that sync runs coalesce into one entry.

- **Skips** – dismissed sessions; providers that do not declare both `transcript.read` and `transcript.tail`; sessions whose sighting carries no hint; and everything while the flag is off.
- **Pacing** – one sync at a time per provider. Each runs on the session's lane in `RemoteTranscriptSync`, so it coalesces with the on-screen pane's 3-second syncs rather than racing them. A sync that ends not caught up goes to the back of its provider's queue, so one long backlog cannot starve the other sessions. A sync that fails is dropped, not retried; the session's next sighting enqueues it again, since its hint still differs from the recorded one.
- **Restart** – the recorded hint lives in `state.json`, so after a daemon restart a session whose first sighting's hint matches it is not refetched.

A provider that reports no hint gets no background sync: its sessions sync only while their pane is open. The daemon cannot tell what changed on such a provider without asking, and the rejected alternatives below cover the ways it could ask.

### RPCs

- **`remote.transcriptSync {provider, sessionID}`** returns `{path, generation, head, caughtUp, hasEarlier}`. The app calls it for an on-screen pane; the daemon's only other sync path is background sync, which runs on sightings, not timers. It is refused unless the provider declares `transcript.read`, and it is refused for a dismissed session, so a pane still open after a dismiss cannot rebuild the cache the dismiss discarded. `hasEarlier` is true only when the flag is on, the provider declares `transcript.tail`, and the cache holds a `before`.
- **`remote.transcriptLoadEarlier {provider, sessionID}`** returns `{generation, head, reachedStart, expired}`. It runs `transcript read <id> --before <cached before> --tail 12` on the session's lane and prepends the page. It is refused while the flag is off, unless the provider declares `transcript.tail`, for a dismissed session, and when the cache's `before` is null.
  - **Generation** – the daemon notes the cache's `generation` when the request arrives. If a sync queued ahead of the load on the lane changes it, the load makes no provider call and returns the new generation, which the pane handles as it does any generation change. While the load holds the lane no sync can run, so nothing else can change the cache between the provider call and the prepend.
  - **Start reached** – an answer whose envelope carries no `before`, or that has no envelope at all, has reached the conversation's beginning: the page is prepended, `before` is cleared, and the result reports `reachedStart`.
  - **No progress** – a page that is empty, or whose `before` equals the cursor just sent, cannot advance. The daemon logs it as a contract violation, prepends a non-empty page, clears `before`, and reports `reachedStart`, so a scroll-up can never loop on the same request.
  - **Failure** – a malformed envelope is a failure that writes nothing, as is a non-zero exit other than `cursor_expired`. On `cursor_expired` the daemon clears `before` and reports `reachedStart` and `expired`.
- **`remote.sendMessage {provider, sessionID, text}`** invokes `send <id> --submit` with `text` on stdin and a 30-second timeout. It is refused:
  - unless the provider declares `send-submit`;
  - when the provider's snapshot is stale, as `remote.send` is;
  - while the mirrored `agent_state` is `waiting_input`, because the agent is blocked on a prompt and an Enter would choose its highlighted option — the refusal says to answer the prompt in the terminal;
  - when the session has exited.

  Sends to one session are serialized, and each is recorded in the actuation log, as `remote.send` is.

  The result has three outcomes, not two. **Sent** is exit 0. **Not sent** is a non-zero exit with the provider's error object. **Unknown** is a call that ended without an exit status: the 30-second timeout fired or the provider process died, and the provider may already have pressed Enter. The daemon never retries a send, and reports unknown as its own outcome rather than as a failure.

The existing `remote.transcript` RPC and `tbd remote transcript` keep their full-fetch behavior and invoke `transcript read`. `remote.retain`, `remote.import`, `remote.recall`, and `remote.delete`'s retain path check the namespaced capabilities and invoke the namespaced verbs.

### Gating

The pane, the composer, and forward sync carry no feature flag. `remote.transcriptSync`, the pane, and the composer are gated by the provider's own declarations — `transcript.read` for the sync and the pane, `send-submit` for the composer — under the remote-backends gate and the cloud gate every provider-named verb already sits behind. The daemon checks those declarations itself, so a direct RPC call cannot do what the hidden pane or composer would not.

Tail-first loading, loading earlier history, and background sync sit behind one default-off flag, the config column `remote_transcript_live_sync_enabled INTEGER`, added with no SQL default so that NULL means unset. `ConfigRecord.toModel()` reads it as `?? Config.remoteTranscriptLiveSyncEnabledDefault`, which is `false`. The flag is required because background sync acts without a user gesture, and because the prepend-and-anchor reflow is the transcript viewer's riskiest UI path. With the flag off, every sync is a forward read: the daemon makes no decision from the hint, though it still records it, never passes `--tail` or `--before`, refuses `remote.transcriptLoadEarlier`, and refetches in full any cache that holds a `before`.

One flag covers all three because they are not independently useful. Background sync without tail-first loading would fetch every session's whole history in the background, which is the eager load the design avoids.

The flag lives only in TBD's daemon. Providers never see it: they declare `transcript.tail` and report the hint regardless. The daemon reads the flag at each decision — background-sync admission, the tail-or-forward choice in `RemoteTranscriptSync`, and the `remote.transcriptLoadEarlier` refusal — so a change takes effect on the next sync without a restart, and background sync drops its queue when the flag goes off. The app's pane never reads the flag; it acts on the `hasEarlier` the daemon returns.

The flag is set by a toggle, "Keep remote transcripts up to date in the background", in the Remote Sessions section of Settings. Like every flag's toggle, it has its own setter RPC, `config.setRemoteTranscriptLiveSyncEnabled {enabled}`, and reads its state from the `remoteTranscriptLiveSyncEnabled` field of `daemon.capabilities`; `config.get` carries the field too. Turning the flag off through the setter also drops background sync's queue at once. Its help text says background sync fetches only from providers that report a transcript hint.

### Reclaiming the cache

The cache directory is a new kind of durable resource, and `OrphanGC` reclaims it in a new leg under `gcEnabled`:

- A session directory is reclaimed when TBD no longer tracks its `(provider, sessionID)` and nothing has been written to it within `gcGraceSeconds`, the grace window every other leg uses. A session is tracked while a `remote_session` row for it has `dismissed = 0` or a `worktree` row for it has a status other than `archived`. Row absence alone would not do: dismissing sets `dismissed = 1` and keeps the row, and archiving keeps the worktree row, so a sweep that waited for rows to disappear would never reclaim a dismissed or archived session's cache. A session un-dismissed or unarchived after its cache was reclaimed simply refetches. The window keeps a sync that raced a dismiss from losing its file mid-write.
- Background sync introduces no new kind of resource: it writes the same directory, and this leg covers it. The leg matters more with background sync on, because caches then exist for sessions nobody opened.
- A successful `remote.delete` and `remote.dismiss` remove the session's directory immediately. A sync already in flight for that session drops what it fetched instead of writing it back into a recreated directory. The sweep is the guarantee; the eager removal is only prompt cleanup.

The leg needs no soak flag of its own, unlike the retained-transcripts leg beside it, which ships behind `gc_retained_transcripts_enabled`. That leg deletes database rows and unlinks transcripts that may be the only copy left once the provider's own copy expires, so a wrong decision there loses data. This leg deletes no rows, and everything it removes is a copy of what the provider still serves: a directory is eligible only after TBD has stopped tracking the session altogether, and if the session reappears, the next sync rebuilds its cache from the provider. The worst a wrong reclaim can cost is one refetch. The default-off rule exists for behavior that can destroy state someone needs, and a derived cache of an untracked session is not that state. An install whose providers never served a transcript has no such directories, so the leg finds nothing. The leg walks the whole cache root against the rows rather than a record of what it created, so it also reclaims directories written before it existed.

## App

### Opening the transcript

Remote sessions get a **Transcript** toggle in the window toolbar beside Reconnect and Stop, shown only when the provider declares `transcript.read`.

With the flag on, background sync keeps the cache current, so the pane opens over it and the cached first paint described under "Layout" shows it at once. For a session with no cache yet, the first sync is a tail reset, so the pane fills from 12 message records rather than streaming the whole history page by page.

Whether the transcript is open is one preference shared by every remote session, stored in `UserDefaults` under `remoteTranscriptOpen`. Unset reads as open, so the first remote session a user views shows its transcript. Closing it with the toggle stores `false`, and every remote session then opens without it until the toggle stores `true` again.

### Layout

`RemoteSessionDetailView`'s content area becomes a horizontal split:

- **Left** – what the pane shows today: the attached terminal, the detached prompt, or the log fallback. `RemoteAttachPager` stays mounted whether or not the split is open, because unmounting it drops every live attach connection. Both halves are on screen together, so no hidden terminal is left receiving input.
- **Right** – `RemoteTranscriptPaneView`, built the way Session History's transcript view is: `TableTranscriptView` and `TranscriptPresentation` with a `TranscriptCardContext` whose `terminalID` is nil.

The pane tails the cache file with the existing `TranscriptSource`, keyed in `sessionTranscripts` as `remote:<provider>/<sessionID>`. When `generation` changes it drops its items, reads the file from the start, and scrolls to the bottom. When `head` changes it also re-reads the whole file, which stays small, but first records the top visible row and its offset, and restores both afterwards so the rows on screen do not move. The anchor is the record `uuid` behind that row; when no visible row has one, the pane keeps its old distance from the bottom.

The pane does not wait for a sync to learn where the file is. The cache path is deterministic — `TBDConstants.remoteTranscriptDir` plus `transcript.jsonl`, following `TBD_HOME` exactly as the daemon does — so when the pane mounts it shows whatever the cache already holds, before the first sync returns. It takes the generation from `state.json` beside the file, or 0 when that file is missing or unreadable. The first sync's generation is authoritative: if it differs, the pane drops what it read and re-reads from the start, the same path a provider reset takes. A long first load can take a minute or more over a slow transport, and a pane that had to wait for a sync would spin over a cache already on disk. While no sync has reported `caughtUp`, the header shows a non-blocking "Syncing…" and cached records stay readable. The full-pane loading state is only for a session with no cache file yet. "Show full output" looks the record up in the cache file on the app side. Links to file paths are suppressed, because those paths name files on another machine.

### Refreshing

While the pane is visible and the app is active, the app calls `remote.transcriptSync` every 3 seconds, and stops when the pane is hidden or the app is inactive. It also syncs at once after a successful send and whenever the session's `agent_state` changes. A sync that succeeds without being caught up is followed by the next at once rather than after the interval, so a long first load arrives one page per sync: each completed sync bumps the pane's refresh token, the pane reads the page just persisted, and the 3-second cadence resumes once a sync reports `caughtUp`. A failed sync always waits the interval, so a daemon that refuses the call is not retried in a tight loop. A provider that never clears `more` therefore keeps a visible pane syncing back to back, one provider call at a time: the page cap bounds how long a sync holds its lane, not how often the pane asks. The syncs never overlap — the driver starts the next only after the last returns — and hiding the pane or deactivating the app stops the catch-up just as it stops the cadence: no sync starts while inactive. A sync already in flight at that moment still publishes when it returns, because the daemon has persisted what it fetched either way and the result is for the same session; discarding it would only leave the pane spinning over data already on disk when it comes back. A result is dropped in two cases only. The first is a driver retired because the pane went away or its selection moved to another session, since a driver must never publish into a pane showing a different session. The second is a result older than one already published, so a slow sync finishing after a restart cannot move the pane backwards. The cadence takes an injected clock.

### Loading earlier history

When the table scrolls to within about five rows of its top and the last sync reported `hasEarlier`, the pane calls `remote.transcriptLoadEarlier`. One call is in flight per pane at a time. A successful call that leaves the table within that zone, with more history above, is followed by the next one at once, because a page of tool activity can add few rows or none — it folds into the activity group already at the top — and the table would otherwise sit in the zone with no further scroll to report. A failed call is never followed that way: it waits for the next scroll, or the header's button, to retry.

A slim header shows where the history stands. It is an overlay pinned to the top of the table, not a row in it, so showing or hiding it never shifts the rows and the table's row model is unchanged. It is visible while the table is scrolled near its top, while a call is in flight, and after a failure, in one of four states:

- **Loading** – a spinner while a call is in flight.
- **Failed** – a "Load earlier messages" button after a failure.
- **Start of conversation** – after `reachedStart`.
- **Expired** – "Earlier history is no longer available" after `cursor_expired`.

### Composer

The remote pane reuses `MessageComposerView` and its send coordinator. A composer target type, `terminal(…)` or `remote(selection)`, replaces the terminal UUID as the key for drafts and focus.

For a remote target:

- **Visibility** – shown only when the provider declares `send-submit`.
- **Disabled states** – "Session has exited" when it has; "Waiting on a prompt — answer it in the terminal" while `agent_state` is `waiting_input`.
- **Omissions** – no slash-command menu, since the completion inventory comes from a local terminal (a typed `/command` is still sent as text); no image attachments, since staged images are local paths the remote machine cannot read; no wake path for an exited session.
- **Submission** – submit calls `remote.sendMessage`. The text stays in the composer until the call succeeds, and success triggers a sync. Not sent shows the composer's failure banner. Unknown shows a distinct banner — "May have been sent — check the transcript before sending again" — triggers a sync so the transcript can answer the question, and keeps the text without offering a one-keystroke resend: the user must edit the text or confirm before it can be sent again. Neither outcome resubmits automatically.

The attached terminal and the composer are independent writers to the same session. Text left unsent in the agent's own input box is prefixed to the composer's message. This is the limitation the local composer already accepts.

The composer, sidebar rows, and send footer do not depend on the flag. The existing send footer appears only when no terminal is live and the composer is not on screen taking messages. A composer that is shown but cannot send — blocked on a prompt, starting, unknown, or exited — leaves the footer in place, because with no live terminal its raw keystrokes are the only way to answer a prompt.

## Testing

Each gate is tested on both branches.

- **Envelope parsing** – `cursor` alone, with `reset`, with `more`; no envelope (a reset that is caught up); `more` without a cursor; a malformed envelope; a non-JSON `{` diagnostic beside a valid envelope; `before`, including `before` without `cursor`; `cursor_expired` mapped to its own error.
- **Sync actor**, against a scripted provider invoker:
  - append and cursor round-trip;
  - reset rewrites the file and increments `generation`;
  - paging continues while `more`, stops at the page cap without being caught up, and persists each page;
  - the default cap returns after every page of a long load, each sync resuming from the stored cursor;
  - a `--since` answer with an absent or malformed envelope keeps what is held and ends in a full refetch within the same sync, even with a one-page cap: the discarded answer does not count toward the cap and the refetch does;
  - concurrent requests coalesce;
  - a `transcript.jsonl` longer than `state.json`'s `length` is truncated on load;
  - paths follow `TBD_HOME`;
  - with the flag on, a tail reset on an empty cache, on a changed hint `id`, and on `size` growth past 512 KB, and `--since` at or below 512 KB;
  - an unknown current hint, as with an empty hint store after a daemon restart, reads forward and leaves the recorded hint in place;
  - a non-empty cache with no recorded hint, as one written before the hint existed, reads forward and records the hint, even when the current hint is far past any threshold;
  - a `--tail` answer without an envelope, or with one that has no `cursor`, is discarded and the same sync ends in a full forward read;
  - with the flag off, never `--tail`, and a full reset fetch for a cache holding a non-null `before`; with the flag on and no `transcript.tail`, never `--tail` and the same full refetch;
  - the hint is recorded at a caught-up sync with the flag off, and not recorded by a sync that ends not caught up;
  - prepend round-trip; a `pendingPrepend` marker found on load resets the cache;
  - a load of earlier history with no envelope reaches the start; a malformed envelope writes nothing; an empty page, or one whose `before` equals the cursor sent, clears `before` and reports `reachedStart`, still prepending a non-empty page;
  - a load and a sync never run at once on one lane, and a load queued behind a sync that resets the cache makes no provider call and returns the new generation;
  - a discard drops an in-flight load of earlier history.
- **Hint store and mirror** – a sighting whose only change is the hint's `size` broadcasts no `.remoteSessionsChanged` and leaves the mirrored payload unchanged; the hint store receives both `apply(snapshot:)` and `applyUpsert` sightings with their hints intact, records them with the flag off, and drops a session's entry on a sighting without a hint.
- **Background sync** – idle with the flag off and enqueuing with it on, with the three flag states (NULL, 0, 1) distinguishable, an explicit `false` surviving a change to the default constant, and NULL following it; skips sessions with no hint, dismissed sessions, and providers missing a capability; hint changes coalesce; one sync per provider at a time; a sync not caught up re-queues at the back; no refetch after a daemon restart when the stored `hint` matches, and one sync when it does not; a failed sync is dropped and enqueued again by the next sighting; the queue is dropped when the flag goes off, including through `config.setRemoteTranscriptLiveSyncEnabled`.
- **RPC gates**:
  - `remote.transcriptSync` refused without `transcript.read`, or for a dismissed session, and its result carries `head` and `hasEarlier`;
  - `remote.transcriptLoadEarlier` refused with the flag off, without `transcript.tail`, for a dismissed session, and with a null `before`; its `reachedStart` and `expired` outcomes;
  - `remote.sendMessage` refused without `send-submit`, on a stale snapshot, while `waiting_input`, and after exit;
  - on success it invokes `send <id> --submit` with the text on stdin, and concurrent sends to one session are serialized;
  - a provider that times out or dies yields the unknown outcome, never a failure and never a retry; the composer's unknown banner requires an edit or confirmation before resending.
- **Namespace cutover** – read, retain, import, recall, and `delete --retain` require the namespaced capabilities and invoke the namespaced verbs; a provider declaring the bare `transcript` is refused by `remote.transcriptSync` and offered no transcript pane, and one declaring only `retain` is offered neither retain nor `--retain`.
- **OrphanGC leg** – keeps a directory whose session has an undismissed `remote_session` row or an unarchived `worktree` row, keeps one written within `gcGraceSeconds`, reclaims one outside the window whose only rows are dismissed or archived, reclaims one with no rows at all, and does nothing with `gcEnabled` off; a successful `remote.delete` and `remote.dismiss` remove only their own session's directory, and a failed delete removes nothing.
- **Sync driver**, on an injected clock – the 3-second cadence; a sync that is not caught up is followed at once, after its page is published, until one catches up and the cadence resumes; a failed sync waits the interval even mid-load; hiding the pane mid-load starts no further sync while the one in flight still publishes; a sync finishing after the driver is retired, or after a switch to another session, publishes nothing; a pane mounted over an existing cache has the file's path and `state.json`'s generation before any sync completes, and no cache file leaves it in the full loading state.
- **App gates** – toolbar toggle visibility against the capability; the open preference unset, closed, and reopened, on an isolated `UserDefaults(suiteName:)`; composer state hidden, running, exited, and blocked; the Settings toggle writes through `config.setRemoteTranscriptLiveSyncEnabled` and reads back from `daemon.capabilities`, and a failed write leaves the capabilities unchanged.
- **Earlier history in the pane** – scrolling near the top triggers exactly one load; the anchor row stays put across a `head` bump; a `generation` bump scrolls to the bottom; the header overlay's four states, and the overlay hidden while idle away from the top.

## Rollout

- The namespace rename is a hard cutover in TBD. A provider that has not adopted the namespaced spellings loses, until it does, every transcript operation it declares under a bare spelling — `transcript` (read), `retain`, `import`, and `recall` alike. Every other capability keeps working. No provider shipped the bare `transcript` or `import`, so in practice an un-updated provider loses retain and recall.
- Provider implementations of `transcript read` (with paging and `reset`), `send --submit`, and the renamed verbs are tracked with each provider.
- Providers implement `transcript.tail` and the transcript hint, tracked with each provider; the first provider gains both alongside TBD. A provider without both gets neither background sync nor tail-first loading, and behaves as it does with the flag off.
- `remote_transcript_live_sync_enabled` ships default-off. The soak enables it with the Settings toggle on a dogfood machine. Graduation flips `Config.remoteTranscriptLiveSyncEnabledDefault`, and a later change deletes the flag.

## Rejected alternatives

- **Composing bracketed paste over raw `send`.** Needs no contract change, but puts one TUI's paste timing in the caller across a transport it cannot observe, depends on the provider's keystroke path passing escape bytes through intact, and yields no delivery evidence.
- **A separate `prompt` verb.** Equivalent to `send --submit`, but gives a second name to what TBD calls sending everywhere else.
- **Deduplicating records by `uuid` instead of a `reset` flag.** Handles a replay of the same conversation but not a switch to a new one, and some record types carry no `uuid`.
- **Holding transcripts only in app memory.** No files and no reclaimer, but every launch and every eviction refetches the whole conversation, which is the slowest path on a transport that pages.
- **Pushing transcript records on `events`.** Lowest latency, but it is a per-session stream shape the remote design has already declined; cursor polling comes first, and the evidence that would reopen this is a sync cadence users find too slow.
- **A per-session open state for the transcript.** Hiding the transcript is a standing preference about how a user views remote sessions, not a fact about one session, and a per-session state would make every newly viewed session ignore it.
- **A new contract major for the rename.** Makes an un-updated provider unusable instead of degrading two of its verbs; see the namespace section.
- **A `before` cursor that the provider refuses once the session moves to a new conversation.** Simpler for the provider, but a `/clear` landing between a sync and a scroll-up is a benign race, and this would turn it into an error.
- **Two flags, one for tail-first loading and one for background sync that requires it.** Background sync without tail mode fetches every session's whole history in the background, so the halves are not independently useful and a second flag only adds a combination nobody should run.
- **Slow timed `--since` polling for providers without the hint.** Puts unasked load on exactly the providers that cannot say what changed.
- **Triggering background sync on `agent_state` edges.** Misses records written mid-turn, while the state stays `working`.
- **Keeping the old cache on a far-behind session and filling the gap.** Leaves holes in the cache and needs gap markers in the pane; a cache that is one contiguous run ending at the newest record needs neither.
- **Tail resets only for a session with no cache.** A long-idle session would catch up slowly and spend background bandwidth on history nobody is reading.
- **Twelve user turns, or a byte budget alone, as the tail unit.** One user turn can carry hundreds of tool calls, so its size is unpredictable; a byte budget alone yields a wildly varying number of messages. The message record maps to one message in the pane.
- **Counting every `user` and `assistant` record as the tail unit.** Simpler to state, but in Claude Code's JSONL a tool call is an `assistant` record and its result a `user` record, so a page of 12 can be nothing but tool activity, which the pane folds into one collapsed row. Measured live: three earlier-history pages counted this way added about 400 KB to the cache and no visible message.
- **Earlier history in segment files (`earlier-0001.jsonl`, …).** `TranscriptSource` reads one file, and the cache stays small enough to prepend into it.
- **Carrying the hint in the mirrored `remote_session` row.** Would give every reader one place to look, but the mirror rebroadcasts to the app whenever the encoded payload changes, and the hint's `size` changes with every record the agent writes. The app would re-render the session list on every poll and every `events` line for a field it never shows.
- **The earlier-history header as a row in the table.** Would scroll with the content, but needs a new row type in the table renderer, and inserting or removing that row reflows the table on exactly the prepend-and-anchor path the design already treats as its riskiest. An overlay changes neither the row model nor the layout.
- **Background sync driven by the app.** Runs only while the app runs, puts a fleet-wide decision in the UI layer, and has every app instance poll independently. Per-event cost across a fleet belongs in the daemon.
