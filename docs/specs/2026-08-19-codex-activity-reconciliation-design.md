# Codex Activity Reconciliation Design

## Purpose

TBD needs one reliable answer to a narrow presentation question: should a Codex terminal appear to be working, waiting for the user, or idle?

The persisted hook state is not sufficient on its own. Hooks can be delayed, omitted after interruption, or delivered after a session has moved to another rollout. Codex rollout transcripts contain task lifecycle events that more directly describe whether the current turn is open, but transcript evidence also has gaps: files can be incomplete, temporarily unreadable, very large, or contain copied history from a parent agent.

This design replaces the Codex sidebar's legacy working/idle interpretation with a reconciled presentation state. It is enabled for every Codex terminal. Claude and shell terminals retain their existing behavior.

The central safety policy is that false thinking is worse than false idle. Ambiguous evidence therefore resolves to idle rather than leaving an indefinite spinner.

## Goals

- Derive Codex working and idle presentation from rollout lifecycle events.
- Clear stale working indicators after interruption, restart, resumed sessions, and rewritten lifecycle identifiers.
- Recover an open Codex turn after daemon state loss even when its start lies outside the transcript tail.
- Preserve explicit user-attention states and immediate Ctrl+C feedback.
- Reject delayed activity hooks from an older Codex process, including when a replacement reuses the same session ID.
- Handle root sessions and spawned subagents without treating copied parent history as nested active work.
- Keep terminal-list polling bounded and fair across a fleet.
- Preserve wire and database compatibility during upgrades.
- Leave Claude and shell activity semantics unchanged.

## Non-goals

- Inferring state from rendered terminal text or TUI glyphs.
- Reporting the internal progress of every nested tool or process inside a turn.
- Changing Claude or shell activity interpretation, user-visible hibernation
  policy, or notification policy. The shared replacement fence used by their
  existing process lifecycle is specified in
  [Terminal Process Incarnation Design](2026-08-29-terminal-process-incarnation-design.md).
- Introducing a general event-sourcing framework for terminal state.

## Product semantics

The Codex presentation state follows this precedence:

1. An explicit Ctrl+C interrupt presents idle immediately.
2. A current permission request presents waiting for the user.
3. Otherwise, complete transcript lifecycle evidence determines working or idle.
4. Missing, incomplete, unreadable, oversized, stale, or not-yet-caught-up transcript evidence presents idle.

Ctrl+C is an explicit user action and must not wait for Codex to append `turn_aborted`. A later valid event from the current session may supersede the interrupt. A permission request must remain visible even while the transcript contains an open task.

This path is the shipped default for every Codex terminal and has no feature flag. Although it wholesale replaces the Codex working/idle presentation signal, it is classified as a bug fix under the repository's rollout policy: it restores the existing indicator's intended meaning instead of adding an optional capability. It performs no destructive or autonomous action and fails conservatively to idle. The stale legacy interpretation is not a supported mode; maintaining two selectable interpretations would create competing answers to the same status question and preserve the failure mode this design removes.

## Required invariants

- A Codex terminal presents working only from complete lifecycle evidence associated with its current transcript identity and session generation.
- Unknown transcript evidence never reuses cached working evidence.
- A session-bound hook from an older Codex process changes no terminal fact and does not cancel current-process scheduled work, even when the replacement reuses the same session ID.
- Ctrl+C clears working immediately and remains authoritative until a valid later current-session event supersedes it.
- A current permission wait defeats transcript working.
- SessionStart applies identity and its eligible prompt/activity effects atomically; an event rejected by one ordering rail cannot partially roll identity backward.
- Session identity, ordering watermark, transcript path, and transcript boundary describe one accepted SessionStart and change atomically.
- Session identity, raw activity, attention state, and transcript presentation are ordered by the timestamps that describe those specific facts.
- Claude and shell terminals do not enter Codex reconciliation or acquire its ordering behavior.

## Authoritative signals

TBD uses two machine-readable sources:

- **Codex hook payloads** identify session boundaries, permission waits, user prompt submission, stops, and explicit TBD-originated interrupts.
- **Codex rollout JSONL** supplies task lifecycle events used for working and idle presentation.

Rendered terminal content is not an input. TBD does not parse prompts, status text, composer glyphs, or `tmux capture-pane` output.

## Components and data flow

### Hook overlay and CLI bridge

The generated Codex hook overlay forwards hook JSON from standard input to TBD. `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, and `Stop` payloads include the Codex `session_id`; their `transcript_path` may be absent.

The CLI accepts a dedicated hook-payload mode rather than consuming standard input for ordinary commands. Input is bounded to 1 MiB and decoded into an optional, backward-compatible session identity on the terminal activity RPC. The CLI also forwards the process-incarnation token that TBD plants in the spawned process environment. Payload reuse must preserve the same JSON for commands that perform more than one actuation.

Legacy terminals whose durable process-incarnation token is `NULL` accept activity events without a token, preserving compatibility with processes launched before TBD managed replacements. Once a row carries a managed token, every process-bound activity event must report that exact token; a missing or mismatched token is stale even when its session ID matches the current Codex session. A staged replacement token temporarily makes both the outgoing and not-yet-launched processes ineligible to write hook facts. The daemon validates these identities transactionally before mutating activity, attention state, ordering watermarks, or scheduled-resume state. Explicit app-originated interrupts are user actions rather than process-bound hook observations and remain accepted without either identity. The shared token lifecycle, including hibernate and wake recovery, is defined in [Terminal Process Incarnation Design](2026-08-29-terminal-process-incarnation-design.md).

### SessionStart and durable boundaries

An accepted `SessionStart` establishes the current session identity, transcript path, session-order watermark, and durable transcript boundary. The boundary is a byte offset: lifecycle records before it belong to an earlier process or session, and records at or after it are eligible evidence for the accepted session. Session identity has its own persisted observation order, separate from activity and attention timestamps. This prevents a delayed event from one rail from incorrectly ordering another rail.

The first accepted Codex start attaches the terminal to its initial rollout; there is no earlier terminal session to fence. The database classifies that attachment inside the same transaction that accepts the start. It is initial only when the stored row has no session identity, transcript path, session-order watermark, or transcript boundary. An initial attachment stores boundary `0`, even when the transcript does not exist yet, so lifecycle records written before the hook arrived remain eligible. A partial legacy or damaged row with any history field is a later attachment and fences conservatively.

Every later accepted Codex start, including a same-path resume, records the effective transcript's current EOF as its boundary. If the effective path is absent or unreadable, the start records `NULL`. The database persists this choice atomically with the accepted identity, path, and session-order watermark. Rejected or stale starts change none of those facts. Equal-time competing starts are first-wins so completion order cannot roll identity backward.

Any path that clears or replaces Codex session identity without accepting an ordered `SessionStart` also clears the durable boundary. This rule prevents a new process from inheriting an offset chosen for a dead identity. A permission fact observed at the same time as, or after, SessionStart survives it; only a strictly older permission fact is retracted.

A recreated Codex window is a deliberate fresh-process boundary, not a partial-history row. TBD first creates an inert replacement pane, then atomically stores its new tmux coordinates, clears the dead process's session identity, transcript path, session-order watermark, transcript boundary, attention, and activity facts, and retains the tab's Codex label and kind. Only after that write commits does TBD respawn the pane with Codex, so the replacement process cannot send SessionStart against the dead process's history. Its first SessionStart is an initial attachment and may adopt lifecycle records it wrote before its hook arrived. Until that start arrives, session-bound activity hooks from the dead process mismatch the cleared identity and change nothing.

Failure before the durable reset leaves the old row unchanged and removes any inert replacement pane on a best-effort basis; the normal worktree and tmux reconciler reclaims the unmatched pane if cleanup fails. Failure while launching Codex after the reset leaves the row cleared and retryable and also removes the inert pane on a best-effort basis. If that cleanup fails, the row still names the replacement window, so the same reconciler continues to own it rather than leaving an untracked resource.

Session-order watermarks use numeric epoch storage so distinct starts within one millisecond remain distinct; the decoder also accepts legacy datetime text rows. Tracker targets carry the identity, effective path, watermark, and boundary read back from the updated database row, so the live handler and later terminal-list reload identify the same durable generation. A later generation defeats an older delayed tracker operation.

A `NULL` boundary means TBD cannot identify a safe historical starting point. The tracker captures the transcript's current EOF once for that target, uses it as an in-memory fence, and waits for later lifecycle evidence. This applies to pre-migration terminals and later attachments whose transcript was unavailable when SessionStart arrived. The database retains `NULL` until a later accepted SessionStart supplies a new boundary; tracker recovery never guesses or backfills one.

### Transcript tracker

A daemon actor owns transcript targets, recovery cursors, incremental offsets, partial records, reducer state, and presentation observation ordering. Serial actor access gives observations a stable order without blocking on unrelated database state.

Each target includes the terminal's current session identity, effective transcript path, session generation, and durable boundary. For a known-boundary cold recovery, the tracker captures the transcript's current EOF as a fixed target, then searches complete eligible JSONL records backward from that target under the shared byte, step, and round-robin budgets. It publishes authoritative unknown, which presents as idle, throughout recovery.

The reverse search stops at the first of three exact anchors. A close that omits either `turn_id` or `started_at` is an unconditional idle synchronizer and seeds idle immediately. The newest valid `task_started` supplies a byte offset; from that offset, the tracker replays only the start-to-frozen-EOF suffix forward through the ordinary lifecycle reducer. If the durable boundary is reached without a valid start, any close evidence seeds idle and no lifecycle evidence yields `nil`. A start-anchored recovery remains unknown until the bounded forward suffix replay reaches the target with no incomplete or discarding record. Ordinary incremental reads then resume at the effective recovery EOF.

The two phases keep recovery memory bounded without weakening close correlation. Reverse search retains framing for at most one capped record and a `sawClose` bit; it does not retain a set of identifiers or timestamps from fully identified closes. Exact correlation of those closes against the newest start happens during the forward suffix replay through the existing reducer. The fixed target also prevents a continuously growing transcript from keeping recovery perpetually behind. Bytes appended after capture wait for ordinary incremental polls once recovery reaches that target.

If the captured EOF falls inside a JSONL record, cold recovery remains unknown until the first later newline completes that record. That newline becomes the effective recovery EOF; later records returned in the same filesystem read are not included and are read again by ordinary incremental processing. Recovery does not chase later appends while waiting for the captured record to finish.

The tracker preserves an unterminated fragment across incremental reads, discards a record that grows beyond the record cap, and resumes at the next newline. An initial attachment whose file truncates restarts exact recovery from boundary `0` against the replacement file's frozen EOF. If a later attachment's file shrinks below its boundary, the tracker fences at the new EOF in memory and waits for new lifecycle evidence; it does not reinterpret pre-boundary history or replace the durable boundary.

Fleet and worktree-scoped observations share a fair cyclic path order. Scoped polling cannot reset fleet progress or starve a deferred transcript. A terminal-list response revalidates terminal identity, transcript path, session generation, and durable boundary after the actor observation. If any target fact changed during the scan, the response returns the current identity with a newly ordered unknown presentation rather than stale activity from the old file.

### Lifecycle reducer

Only recognized lifecycle records inside `event_msg` envelopes affect activity.

The reducer tracks one current task because a Codex session has one active turn. A later `task_started` supersedes an unmatched earlier start. This is essential for resumed sessions and spawned agents: child rollout files can copy a parent lifecycle prefix, but that copied start is not concurrent child work.

A completion or abort closes the current task when:

- its `turn_id` matches the current start;
- its non-null `started_at` matches the current start; or
- the close record omits `turn_id`; or
- the close record omits `started_at` and its `turn_id` does not match.

The uncorrelated cases deliberately clear to idle under the false-thinking safety policy. This means a mismatched close without `started_at` can clear a different, genuinely open successor. That known false-idle risk is preferable to allowing the observed rewritten-close shape to leave working latched indefinitely. When a close carries a different, older `started_at`, it does not close a newer task. A start without a `turn_id` is ignored because it cannot establish useful identity.

The reducer does not maintain a task stack. `session_meta` and `thread_spawn` describe rollout provenance, not nested task lifecycle inside one file, so they do not change reducer state. Separate subagents have separate rollout files, and a child file can contain copied parent lifecycle records as a historical prefix. A newer child `task_started` supersedes that copied prefix. Restoring an older parent start after the child turn closes would manufacture active work that Codex does not report.

### Terminal-list presentation

The daemon exposes transcript-derived presentation activity separately from persisted raw hook activity. A complete observation carries its own timestamp. An authoritative unknown observation is also timestamped so it can clear an older working presentation without being mistaken for missing legacy metadata.

Raw activity, session identity, and transcript presentation are ordered independently. Their timestamps describe different facts and cannot safely substitute for one another.

### App reconciliation

The app merges terminal snapshots and pushed deltas using three independent rails:

- session identity and transcript-path order;
- persisted raw activity and its event-order watermark;
- response-derived presentation activity and its observation watermark.

This separation prevents an overlapping older `terminal.list` response from rolling back a newer SessionStart, permission state, interrupt, or transcript completion. Identity changes clear presentation evidence from the old transcript. Same-identity SessionStart boundaries also fence presentation observations derived from a pre-boundary activity generation.

Hidden ordering watermarks are cleared when terminals are removed and reseeded when terminal observations are replaced. Legacy payloads without the new optional fields retain compatible arrival-order behavior.

These reconciliation rules apply only to Codex terminals. Claude and shell snapshots, deltas, and interrupts continue to use their established raw activity semantics.

### Sidebar rendering

The sidebar renders Codex state using the product precedence:

- explicit terminal interrupt: idle;
- waiting for user: attention state;
- transcript working: working animation;
- all other cases: idle.

Raw generic idle hooks do not defeat a valid open transcript. Raw generic working hooks do not create a Codex spinner without transcript evidence.

## Bounded I/O and fairness

Terminal-list polling must not decode unbounded transcript history or perform unbounded zero-byte filesystem work.

- Reverse search and forward suffix replay read fixed-size chunks and retain their phase and cursor across requests; no request scans the whole backlog.
- A terminal-list observation has a shared 1 MiB byte budget across Codex transcripts.
- Pending transcripts receive 64 KiB round-robin quanta.
- One observation performs at most 16 filesystem steps, including caught-up and unreadable paths that consume no content bytes.
- A single JSONL record is capped at 1 MiB. Oversized records are discarded through their newline.
- Bytes returned while completing a captured partial record count against the request budget even when bytes after its first newline are deferred to incremental processing.
- Reverse-searching, suffix-replaying, partial, discarding, untouched, and not-yet-caught-up paths publish unknown rather than cached working.

Large backlogs converge over multiple polls, regardless of how far the relevant lifecycle event lies from EOF or how large its forward suffix is. Reverse recovery stores no per-close collection, so the number of fully identified closes does not increase retained correlation state. A continuously growing early path cannot consume every request because the cyclic cursor advances across requests and survives scoped polling and path removal.

Field measurements found lifecycle lines near 3 KiB at the 99th percentile and about 21 KiB at the observed maximum. The 1 MiB record cap leaves substantial margin while bounding memory and scan cost.

## Failure handling

- **Incomplete incremental final record** — retain the bounded fragment, publish unknown, and retry after more bytes arrive.
- **Captured partial EOF record** — publish unknown until its first later newline, make only that completed record part of recovery, charge every byte returned by the read, and leave later records for incremental processing.
- **Oversized record** — discard through the next newline, publish unknown while discarding, then resume normal parsing.
- **Unreadable file** — publish unknown and retry on a later observation.
- **Initial-attachment truncation or replacement** — discard incompatible reducer evidence and restart reverse recovery from boundary `0` against the replacement's frozen EOF.
- **Later-attachment shrink below the boundary** — fence at the new EOF in memory, publish unknown, and wait for later lifecycle evidence.
- **Shrink during cold recovery** — discard both recovery phases and restart under the target's original known-boundary policy against the replacement file.
- **Backlog beyond the request budget** — preserve reverse-search or forward-suffix progress and publish unknown until exact.
- **Target changes during a scan** — discard the old result when identity, path, generation, or boundary revalidation fails, then publish an ordered unknown for the current target.
- **Initial task precedes SessionStart** — recover from durable boundary `0`, so already-written lifecycle evidence remains eligible.
- **Terminal list races tracker attachment** — bind both operations to the complete persisted target; same-generation work with a different boundary cannot publish.
- **Initial rollout is temporarily unavailable** — retain boundary `0` without positive evidence, then recover from zero when the file appears.
- **Daemon restart with a known boundary** — capture a fixed EOF, search backward for an anchor, replay only an anchored forward suffix when needed, and publish unknown until exact.
- **Daemon restart with a `NULL` boundary** — fence at the current EOF in memory and wait for new evidence rather than guessing at historical eligibility.
- **Delayed old-process hook with identity** — reject it before any mutation, including when its session ID matches a replacement process.
- **Legacy hook without process identity** — accept it only while the durable row also has no process-incarnation token; a managed row requires an exact token match.

These cases intentionally favor temporary idle over stale working.

## Evidence informing the reducer

Aggregate rollout analysis established the following public-safe characteristics:

- In 1,003 recent rollouts, 150 closes rewrote the task identifier while retaining the start timestamp: 127 exec sessions, 18 subagent sessions, and 5 CLI sessions.
- Across more than 43,000 lifecycle records, 64 rewritten-identifier completions omitted `started_at` while a task was open. Strict identifier matching would leave those sessions working indefinitely.
- The audited Codex 0.147 lifecycle records all supplied `turn_id`, but the decoder remains tolerant of missing identity for future or partial schemas.
- Codex creates spawned agents as distinct sessions and rollout files with one active task per session. Forked rollouts can copy parent lifecycle history.
- Across 2,640 examined rollouts, 2,096 apparent overlapping starts were observed, predominantly copied into spawned-agent histories. No case later closed both the older and newer start. A stack reducer would therefore resurrect copied or orphaned work after the current child task completed.

The design uses aggregate counts and schema behavior only. No rollout content or organization-specific context belongs in the repository.

## Persistence and compatibility

The `terminal` table gains `codexTranscriptBoundaryOffset INTEGER` with no SQL default. Its GRDB record and shared `Terminal` model expose the value as `Int64?`. The shared model decodes the field with `decodeIfPresent`, so older JSON remains valid. Pre-migration rows read `NULL`, not `0`; `NULL` preserves the distinction between a known initial boundary and an unknown safe boundary.

The migration file, GRDB record, and shared model change together. The Swift migration escape hatch also omits a default if it must add the missing column. Existing RPC payloads remain compatible because the new field is optional.

Session identity order and the transcript boundary are persisted independently from activity order but atomically with each other. Presentation order, recovery cursors, captured recovery EOFs, and reducer state remain transient because they describe observations produced by the live transcript tracker rather than durable user or hook facts.

Generated hook configuration is refreshed through the existing plugin installation path. The new wire field is optional, so mixed-version payloads still decode. Identity-free activity remains usable for legacy nil-token rows, while managed replacement rows reject clients that cannot prove the current process incarnation.

## Testing strategy

Reducer tests cover:

- matching and rewritten task identifiers;
- matching, older, and missing `started_at`;
- missing task identity;
- later-start supersession;
- `session_meta`/`thread_spawn` plus a copied parent prefix followed by a child start and close;
- completion and abort variants;
- malformed and unrelated JSONL records.

Tracker tests cover:

- a fresh tracker finding a valid start more than one request budget from EOF while every intermediate reverse-search and forward-replay observation remains unknown;
- exact agreement between reverse-anchored recovery and ordinary forward reducer semantics for working starts, matching closes, reliable mismatches, unconditional closes, malformed records, and missing lifecycle evidence;
- stopping reverse search at an unconditional close, at the newest valid start, or at the durable boundary without scanning ineligible older history;
- exact reliable-close correlation during bounded forward suffix replay without retaining per-close keys during reverse search;
- positive-boundary and crossing-record exclusion;
- a captured partial EOF record waiting for its first later newline without chasing later records, including full filesystem-read budget accounting;
- fixed-EOF recovery when the transcript grows during either phase, followed by ordinary incremental reads;
- initial-attachment recovery from zero after truncation, shrink during reverse recovery, and later-attachment in-memory fencing after shrink below the boundary;
- 64 KiB boundaries, malformed records, and unterminated fragments;
- oversized-record discard in both reverse and forward processing;
- unreadable-file recovery;
- per-request byte and step limits;
- round-robin fairness across simultaneous reverse searches and forward suffix replays, scoped polling, path removal, and reordering;
- target changes during suspended observation, including identity, path, generation, and boundary changes.

Daemon and wire tests cover:

- migration of pre-existing rows to a `NULL` boundary and model round trips for `0`, positive offsets, and `NULL`;
- backward-compatible shared-model decoding when the boundary field is absent;
- initial attachment storing `0`, including when the transcript is not yet readable;
- later attachment storing the effective transcript EOF or `NULL` when the file is unavailable;
- atomic first-attachment classification, including partial-history rows, concurrent starts, sub-millisecond ordering, and legacy datetime rows;
- stale and retried SessionStart events leaving the accepted boundary unchanged;
- identity-clearing and identity-replacement paths clearing the boundary;
- current-process hook acceptance and stale-process rejection when session IDs differ or are reused;
- legacy identity-free hook compatibility on nil-token rows and rejection on managed-token rows;
- atomic ordering of session, activity, and attention facts;
- equal-time precedence;
- Ctrl+C persistence and later supersession;
- bounded hook-payload parsing and JSON round trips;
- a terminal-list integration path that loads a database-backed terminal into a fresh tracker and recovers activity after daemon-state loss.

App and sidebar tests cover:

- Ctrl+C and permission precedence;
- transcript working and authoritative unknown;
- reversed snapshot and delta delivery;
- same-path and changed-path SessionStart fences;
- hidden-watermark monotonicity and cleanup;
- Claude and shell regression behavior.

Verification includes focused suites for each layer, `scripts/swift-safe build`, strict SwiftLint, and the fenced full `scripts/test.sh` suite for daemon or shared changes.

## Alternatives rejected

- **Hooks alone** — hooks do not reliably close every interrupted or resumed turn and can arrive after session rollover.
- **Transcript alone** — it cannot provide immediate Ctrl+C feedback or preserve a permission prompt over an open task.
- **Bounded tail recovery** — an open turn whose start lies before the tail window remains falsely idle after tracker state is lost.
- **Persisting the reducer checkpoint** — storing the cursor and open-task state would require frequent database writes and crash-consistency rules, and a stale checkpoint could restore false working.
- **One-pass backward close correlation** — exact membership checks for arbitrary fully identified close records require retaining an unbounded set of identifiers or timestamps. The bounded two-phase scan instead uses constant reverse-search state and delegates exact correlation to a forward replay of only the anchored suffix.
- **A task stack** — copied parent history and orphaned starts would be restored after the current subagent task closes, creating false working.
- **A default-off flag** — the legacy path is the known failure and parallel modes would preserve conflicting interpretations. Conservative idle fallback bounds the replacement's risk.
- **Terminal screen scraping** — rendered TUI text is not a stable machine interface.

## Operational impact

The design adds no new durable external resource and requires no new reconciler. It reads existing rollout files, persists ordering metadata and the transcript boundary in the existing terminal record, and uses existing RPC and hook installation paths.

Codex reconciliation introduces no automatic process control, input injection,
deletion, or background actuation. It changes only Codex activity observation
and presentation. The shared incarnation fence hardens the existing terminal
replacement, hibernate, and wake paths described in
[Terminal Process Incarnation Design](2026-08-29-terminal-process-incarnation-design.md);
it does not expand when those paths actuate.
