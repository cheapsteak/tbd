# Remote session transcript and composer

## Problem

A remote session's pane in TBD shows only its terminal. There is no transcript view and no way to send a message except by typing into the attached terminal or, when nothing is attached, through a single-line raw-keystroke footer. Local Claude sessions have both: a live transcript pane beside the terminal, and a composer in that pane that submits messages reliably.

The pieces that exist for remote sessions do not add up to either feature:

- The daemon's `remote.transcript` RPC runs the provider's `transcript` verb, re-downloads the whole conversation on every call, drops the cursor, and stores nothing. Only `tbd remote transcript` calls it; the app has no client for it and never checks the capability.
- The live transcript pane (`TableTranscriptPaneView`) is keyed on a local `Terminal` row and a `LocalWorktree`, so it cannot render a remote session at all.
- The contract's `send` delivers raw keystrokes. Reliable message submission into Claude Code needs the body as one bracketed paste followed by a separate Enter; an unbracketed write of 64 bytes or more with `\r` in the same write does not submit, and past roughly 1 KB a keystroke burst is coalesced into a paste that absorbs the Enter (the 64-byte threshold is measured in `docs/specs/2026-09-05-transcript-composer-design.md`, the ~1 KB coalescing in `docs/submit-reliability.md`). Locally the daemon owns that mechanism (`tmux paste-buffer -p` then `send-keys Enter`). Over raw `send` the caller would have to reproduce it without seeing the remote terminal's paste mode, across a transport it cannot observe, and with no evidence that the message landed.
- The contract gives a caller no signal when `transcript` answers `--since` from the beginning — a cursor the provider can no longer honor, or a conversation restarted by `/clear` or a resume — so an appending caller would duplicate records or splice two conversations together.

## Goals

- Show a remote session's transcript beside its terminal, live, using the existing transcript renderer.
- Send messages to a remote session from a composer in that transcript, with the same delivery guarantees the local composer has.
- Keep what is fetched, so reopening a transcript, relaunching the app, or restarting the daemon fetches only what is new. Some providers' transports are slow per call and cap output per call, so a full refetch of a long transcript takes many round trips.

## Non-goals

- New tabs, note tabs, or `⌘T` on remote sessions.
- A slash-command menu, image attachments, or waking an exited session from the remote composer.
- Transcripts for providers that do not declare `transcript.read`.

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

## Daemon

### `RemoteTranscriptSync`

A new actor under `Sources/TBDDaemon/Remote/` gives each `(provider, sessionID)` a serialized fetch lane:

- One `transcript read` runs per session at a time. A request arriving while one is in flight waits for it, plus at most one follow-up, so a burst of requests costs at most two fetches.
- It pages while the envelope says `more`, writing each page before fetching the next, so a slow first load fills the pane progressively. A sync stops after a fixed number of pages and reports that it is not caught up, so a provider that never clears `more` cannot hold the lane forever; the next sync resumes from the stored cursor.
- Delays and timeouts take an injected clock.

### Cache

Each session's transcript is cached under `~/tbd/remote-transcripts/<provider>/<sessionID>/`, through a new `TBDConstants` helper that honors `TBD_HOME` and escapes both components the way `retainedTranscriptPath` does. The directory holds two files:

- **`transcript.jsonl`** – the conversation.
- **`state.json`** – `{cursor, length, generation}`.

The two files are kept consistent by write order:

- **Append.** A page is appended to `transcript.jsonl` first. Then `state.json` is written atomically with the new cursor and the file's new length. On load, `transcript.jsonl` is truncated to the recorded `length`, so a crash between the two writes cannot leave records that the next fetch returns again.
- **Reset.** Three steps, in this order. First `state.json` is written atomically with no cursor, a `length` of 0, and `generation` incremented, so readers know to discard what they hold. Then the page is written to a temporary file and renamed over `transcript.jsonl`. Last, `state.json` is written again with the new cursor and length. A crash after the first step leaves a state that records nothing: load truncates `transcript.jsonl` to zero bytes, and the next sync fetches from the beginning, which is itself a reset. No crash point can pair a new file with an old cursor.

The cache sits outside the Claude projects store on purpose: `ClaudeSessionScanner` searches under project roots, so a TBD-owned root keeps remote conversations from being listed as local sessions. The daemon only writes this root and the app reads it directly, so no daemon read RPC needs to admit a second permitted transcript root.

### RPCs

- **`remote.transcriptSync {provider, sessionID}`** returns `{path, generation, caughtUp}`. The app calls it; the daemon runs no timers of its own for transcripts. It is refused unless `remote_transcript_enabled` is on and the provider declares `transcript.read`.
- **`remote.sendMessage {provider, sessionID, text}`** invokes `send <id> --submit` with `text` on stdin and a 30-second timeout. It is refused:
  - unless both `remote_transcript_enabled` and `transcript_composer_enabled` are on — the daemon checks the flags itself, so a direct RPC call cannot send input the hidden composer would not;
  - unless the provider declares `send-submit`;
  - when the provider's snapshot is stale, as `remote.send` is;
  - while the mirrored `agent_state` is `waiting_input`, because the agent is blocked on a prompt and an Enter would choose its highlighted option — the refusal says to answer the prompt in the terminal;
  - when the session has exited.

  Sends to one session are serialized, and each is recorded in the actuation log, as `remote.send` is.

  The result has three outcomes, not two. **Sent** is exit 0. **Not sent** is a non-zero exit with the provider's error object. **Unknown** is a call that ended without an exit status: the 30-second timeout fired or the provider process died, and the provider may already have pressed Enter. The daemon never retries a send, and reports unknown as its own outcome rather than as a failure.

The existing `remote.transcript` RPC and `tbd remote transcript` keep their full-fetch behavior and invoke `transcript read`. `remote.retain`, `remote.import`, `remote.recall`, and `remote.delete`'s retain path check the namespaced capabilities and invoke the namespaced verbs.

### Flag

`remote_transcript_enabled` is a new `config` column with no SQL default, resolved as `remote_transcript_enabled ?? Config.remoteTranscriptEnabledDefault`, which is `false`. It gates `remote.transcriptSync`, the pane, and the composer. The composer also requires the existing `transcript_composer_enabled`, so remote and local composers are switched together. Graduation flips `Config.remoteTranscriptEnabledDefault`.

### Reclaiming the cache

The cache directory is a new kind of durable resource, and `OrphanGC` reclaims it in a new leg under `gcEnabled`:

- A session directory is reclaimed when TBD no longer tracks its `(provider, sessionID)` and nothing has been written to it within `gcGraceSeconds`, the grace window every other leg uses. A session is tracked while a `remote_session` row for it has `dismissed = 0` or a `worktree` row for it has a status other than `archived`. Row absence alone would not do: dismissing sets `dismissed = 1` and keeps the row, and archiving keeps the worktree row, so a sweep that waited for rows to disappear would never reclaim a dismissed or archived session's cache. A session un-dismissed or unarchived after its cache was reclaimed simply refetches. The window keeps a sync that raced a dismiss from losing its file mid-write.
- A successful `remote.delete` and `remote.dismiss` remove the session's directory immediately. The sweep is the guarantee; the eager removal is only prompt cleanup.

The leg needs no soak flag of its own, unlike the retained-transcripts leg beside it, which ships behind `gc_retained_transcripts_enabled`. That leg deletes database rows and unlinks transcripts that may be the only copy left once the provider's own copy expires, so a wrong decision there loses data. This leg deletes no rows, and everything it removes is a copy of what the provider still serves: a directory is eligible only after TBD has stopped tracking the session altogether, and if the session reappears, the next sync rebuilds its cache from the provider. The worst a wrong reclaim can cost is one refetch. The default-off rule exists for behavior that can destroy state someone needs, and a derived cache of an untracked session is not that state. An install that never enabled `remote_transcript_enabled` has no such directories, so the leg finds nothing.

## App

### Opening the transcript

Remote sessions get a **Transcript** toggle in the window toolbar beside Reconnect and Stop, shown only when the provider declares `transcript.read` and `remote_transcript_enabled` is on.

Whether the transcript is open is one preference shared by every remote session, stored in `UserDefaults` under `remoteTranscriptOpen`. Unset reads as open, so the first remote session a user views shows its transcript. Closing it with the toggle stores `false`, and every remote session then opens without it until the toggle stores `true` again.

### Layout

`RemoteSessionDetailView`'s content area becomes a horizontal split:

- **Left** – what the pane shows today: the attached terminal, the detached prompt, or the log fallback. `RemoteAttachPager` stays mounted whether or not the split is open, because unmounting it drops every live attach connection. Both halves are on screen together, so no hidden terminal is left receiving input.
- **Right** – `RemoteTranscriptPaneView`, built the way Session History's transcript view is: `TableTranscriptView` and `TranscriptPresentation` with a `TranscriptCardContext` whose `terminalID` is nil.

The pane tails the cache file with the existing `TranscriptSource`, keyed in `sessionTranscripts` as `remote:<provider>/<sessionID>`. When `generation` changes it drops its items and reads the file from the start. "Show full output" looks the record up in the cache file on the app side. Links to file paths are suppressed, because those paths name files on another machine.

### Refreshing

While the pane is visible and the app is active, the app calls `remote.transcriptSync` every 3 seconds, and stops when the pane is hidden or the app is inactive. It also syncs at once after a successful send and whenever the session's `agent_state` changes. Until a sync reports `caughtUp`, the pane shows that it is still loading while records appear page by page. The cadence takes an injected clock.

### Composer

The remote pane reuses `MessageComposerView` and its send coordinator. A composer target type, `terminal(…)` or `remote(selection)`, replaces the terminal UUID as the key for drafts and focus.

For a remote target:

- **Visibility** – shown only when the provider declares `send-submit` and both flags are on.
- **Disabled states** – "Session has exited" when it has; "Waiting on a prompt — answer it in the terminal" while `agent_state` is `waiting_input`.
- **Omissions** – no slash-command menu, since the completion inventory comes from a local terminal (a typed `/command` is still sent as text); no image attachments, since staged images are local paths the remote machine cannot read; no wake path for an exited session.
- **Submission** – submit calls `remote.sendMessage`. The text stays in the composer until the call succeeds, and success triggers a sync. Not sent shows the composer's failure banner. Unknown shows a distinct banner — "May have been sent — check the transcript before sending again" — triggers a sync so the transcript can answer the question, and keeps the text without offering a one-keystroke resend: the user must edit the text or confirm before it can be sent again. Neither outcome resubmits automatically.

The attached terminal and the composer are independent writers to the same session. Text left unsent in the agent's own input box is prefixed to the composer's message. This is the limitation the local composer already accepts.

The existing send footer is unchanged: it still appears only when no terminal is live.

## Testing

Each gate is tested on both branches.

- **Envelope parsing** – `cursor` alone, with `reset`, with `more`; no envelope (a reset that is caught up); `more` without a cursor; a malformed envelope.
- **Sync actor**, against the mock provider invoker and an injected clock:
  - append and cursor round-trip;
  - reset rewrites the file and increments `generation`;
  - paging continues while `more`, stops at the page cap without being caught up, and persists each page;
  - concurrent requests coalesce;
  - a `transcript.jsonl` longer than `state.json`'s `length` is truncated on load;
  - paths follow `TBD_HOME`.
- **RPC gates**:
  - `remote.transcriptSync` refused with the flag off or without `transcript.read`;
  - `remote.sendMessage` refused with either flag off, without `send-submit`, on a stale snapshot, while `waiting_input`, and after exit;
  - on success it invokes `send <id> --submit` with the text on stdin, and concurrent sends to one session are serialized;
  - a provider that times out or dies yields the unknown outcome, never a failure and never a retry; the composer's unknown banner requires an edit or confirmation before resending.
- **Namespace cutover** – read, retain, import, recall, and `delete --retain` require the namespaced capabilities and invoke the namespaced verbs; a provider declaring the bare `transcript` is refused by `remote.transcriptSync` and offered no transcript pane, and one declaring only `retain` is offered neither retain nor `--retain`.
- **OrphanGC leg** – keeps a directory whose session has an undismissed `remote_session` row or an unarchived `worktree` row, keeps one written within `gcGraceSeconds`, reclaims one outside the window whose only rows are dismissed or archived, reclaims one with no rows at all, and does nothing with `gcEnabled` off.
- **App gates** – toolbar toggle visibility against the capability and flag; the open preference unset, closed, and reopened, on an isolated `UserDefaults(suiteName:)`; composer state hidden, running, exited, and blocked.
- **Config column** – a pre-migration row reads NULL and follows the default constant; an explicit `false` survives a change to it.

## Rollout

- Everything ships behind `remote_transcript_enabled`, default off; the composer also needs `transcript_composer_enabled`. The soak enables both against a provider that implements `transcript.read` and `send-submit`.
- The namespace rename is a hard cutover in TBD. A provider that has not adopted the namespaced spellings loses, until it does, every transcript operation it declares under a bare spelling — `transcript` (read), `retain`, `import`, and `recall` alike. Every other capability keeps working. No provider shipped the bare `transcript` or `import`, so in practice an un-updated provider loses retain and recall.
- Provider implementations of `transcript read` (with paging and `reset`), `send --submit`, and the renamed verbs are tracked with each provider.

## Rejected alternatives

- **Composing bracketed paste over raw `send`.** Needs no contract change, but puts one TUI's paste timing in the caller across a transport it cannot observe, depends on the provider's keystroke path passing escape bytes through intact, and yields no delivery evidence.
- **A separate `prompt` verb.** Equivalent to `send --submit`, but gives a second name to what TBD calls sending everywhere else.
- **Deduplicating records by `uuid` instead of a `reset` flag.** Handles a replay of the same conversation but not a switch to a new one, and some record types carry no `uuid`.
- **Holding transcripts only in app memory.** No files and no reclaimer, but every launch and every eviction refetches the whole conversation, which is the slowest path on a transport that pages.
- **Pushing transcript records on `events`.** Lowest latency, but it is a per-session stream shape the remote design has already declined; cursor polling comes first, and the evidence that would reopen this is a sync cadence users find too slow.
- **A per-session open state for the transcript.** Hiding the transcript is a standing preference about how a user views remote sessions, not a fact about one session, and a per-session state would make every newly viewed session ignore it.
- **A new contract major for the rename.** Makes an un-updated provider unusable instead of degrading two of its verbs; see the namespace section.
