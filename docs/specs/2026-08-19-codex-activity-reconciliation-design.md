# Codex Activity Reconciliation Design

## Purpose

TBD needs one reliable answer to a narrow presentation question: should a Codex terminal appear to be working, waiting for the user, or idle?

The persisted hook state is not sufficient on its own. Hooks can be delayed, omitted after interruption, or delivered after a session has moved to another rollout. Codex rollout transcripts contain task lifecycle events that more directly describe whether the current turn is open, but transcript evidence also has gaps: files can be incomplete, temporarily unreadable, very large, or contain copied history from a parent agent.

This design replaces the Codex sidebar's legacy working/idle interpretation with a reconciled presentation state. It is enabled for every Codex terminal. Claude and shell terminals retain their existing behavior.

The central safety policy is that false thinking is worse than false idle. Ambiguous evidence therefore resolves to idle rather than leaving an indefinite spinner.

## Goals

- Derive Codex working and idle presentation from rollout lifecycle events.
- Clear stale working indicators after interruption, restart, resumed sessions, and rewritten lifecycle identifiers.
- Preserve explicit user-attention states and immediate Ctrl+C feedback.
- Reject delayed activity hooks from an older Codex session.
- Handle root sessions and spawned subagents without treating copied parent history as nested active work.
- Keep terminal-list polling bounded and fair across a fleet.
- Preserve wire and database compatibility during upgrades.
- Leave Claude and shell activity semantics unchanged.

## Non-goals

- Inferring state from rendered terminal text or TUI glyphs.
- Reporting the internal progress of every nested tool or process inside a turn.
- Reconstructing lifecycle history older than the bounded transcript window when no current evidence exists.
- Changing Claude hooks, shell activity, hibernation policy, or notification policy.
- Introducing a general event-sourcing framework for terminal state.

## Product semantics

The Codex presentation state follows this precedence:

1. An explicit Ctrl+C interrupt presents idle immediately.
2. A current permission request presents waiting for the user.
3. Otherwise, complete transcript lifecycle evidence determines working or idle.
4. Missing, incomplete, unreadable, oversized, stale, or not-yet-caught-up transcript evidence presents idle.

Ctrl+C is an explicit user action and must not wait for Codex to append `turn_aborted`. A later valid event from the current session may supersede the interrupt. A permission request must remain visible even while the transcript contains an open task.

This path is enabled by default and has no feature flag. It replaces a known-unreliable Codex indicator, performs no destructive or autonomous action, and fails conservatively to idle. Maintaining two selectable interpretations would create competing answers to the same status question and preserve the failure mode this design removes.

## Authoritative signals

TBD uses two machine-readable sources:

- **Codex hook payloads** identify session boundaries, permission waits, user prompt submission, stops, and explicit TBD-originated interrupts.
- **Codex rollout JSONL** supplies task lifecycle events used for working and idle presentation.

Rendered terminal content is not an input. TBD does not parse prompts, status text, composer glyphs, or `tmux capture-pane` output.

## Components and data flow

### Hook overlay and CLI bridge

The generated Codex hook overlay forwards hook JSON from standard input to TBD. `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, and `Stop` payloads include the Codex `session_id`; their `transcript_path` may be absent.

The CLI accepts a dedicated hook-payload mode rather than consuming standard input for ordinary commands. Input is bounded to 1 MiB and decoded into an optional, backward-compatible session identity on the terminal activity RPC. Payload reuse must preserve the same JSON for commands that perform more than one actuation.

Already-running installations may still send activity events without a session identity until their generated overlay is refreshed. Identity-free events remain accepted during this upgrade window. Events that do carry an identity are validated transactionally against the terminal's current Codex session before they mutate activity, attention state, ordering watermarks, or scheduled-resume state.

### SessionStart and durable boundaries

An accepted `SessionStart` establishes the current session identity and transcript path. Session identity has its own persisted observation order, separate from activity and attention timestamps. This prevents a delayed event from one rail from incorrectly ordering another rail.

For Codex, an accepted start also establishes a lifecycle boundary at the transcript's current end. Events before that boundary do not become current work after a same-path resume or daemon restart. The persisted SessionStart fact lets a new tracker reconstruct the boundary conservatively at the current end when actor memory is unavailable.

Rejected or stale SessionStart events do not change identity, transcript path, attention state, activity, or tracker boundaries. Equal-time competing starts are first-wins so completion order cannot roll identity backward.

### Transcript tracker

A daemon actor owns transcript baselines, incremental offsets, partial records, reducer state, and presentation observation ordering. Serial actor access gives observations a stable order without blocking on unrelated database state.

The tracker reads appended JSONL incrementally. Initial observation and truncation recovery inspect only a bounded tail. It preserves an unterminated fragment across reads, discards a record that grows beyond the record cap, and resumes at the next newline.

Fleet and worktree-scoped observations share a fair cyclic path order. Scoped polling cannot reset fleet progress or starve a deferred transcript. A terminal-list response revalidates terminal identity, transcript path, and session generation after the actor observation. If the transcript changed during the scan, the response returns the current identity with a newly ordered unknown presentation rather than stale activity from the old file.

### Lifecycle reducer

Only recognized lifecycle records inside `event_msg` envelopes affect activity.

The reducer tracks one current task because a Codex session has one active turn. A later `task_started` supersedes an unmatched earlier start. This is essential for resumed sessions and spawned agents: child rollout files can copy a parent lifecycle prefix, but that copied start is not concurrent child work.

A completion or abort closes the current task when:

- its `turn_id` matches the current start;
- its non-null `started_at` matches the current start; or
- it cannot be correlated because identity or start time is absent.

The last case deliberately clears to idle under the false-thinking safety policy. When a close carries a different, older `started_at`, it does not close a newer task. A start without a `turn_id` is ignored because it cannot establish useful identity.

The reducer does not maintain a task stack. Separate subagents have separate rollout files, and copied parent starts are historical prefixes. Restoring an older start after the child turn closes would manufacture active work that Codex does not report.

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

- An initial or truncation bootstrap reads at most 1 MiB of transcript content, plus the bounded boundary check.
- A terminal-list observation has a shared 1 MiB byte budget across Codex transcripts.
- Pending transcripts receive 64 KiB round-robin quanta.
- One observation performs at most 16 filesystem steps, including caught-up and unreadable paths that consume no content bytes.
- A single JSONL record is capped at 1 MiB. Oversized records are discarded through their newline.
- Partial, discarding, untouched, and not-yet-caught-up paths publish unknown rather than cached working.

Large backlogs converge over multiple polls. A continuously growing early path cannot consume every request because the cyclic cursor advances across requests and survives scoped polling and path removal.

Field measurements found lifecycle lines near 3 KiB at the 99th percentile and about 21 KiB at the observed maximum. The 1 MiB record cap leaves substantial margin while bounding memory and scan cost.

## Failure handling

- **Incomplete final record** — retain the bounded fragment, publish unknown, and retry after more bytes arrive.
- **Oversized record** — discard through the next newline, publish unknown while discarding, then resume normal parsing.
- **Unreadable file** — publish unknown and retry on a later observation.
- **Truncation or replacement** — rebuild from the bounded tail and do not reuse incompatible reducer evidence.
- **Backlog beyond the request budget** — preserve incremental progress and publish unknown until caught up.
- **Transcript identity changes during a scan** — discard the old-path result and publish an ordered unknown for the current identity.
- **Daemon restart after SessionStart** — reconstruct the boundary conservatively at the current end so an orphaned historical start cannot restore working.
- **Delayed old-session hook with identity** — reject it before any mutation.
- **Legacy hook without identity** — accept it for upgrade compatibility; subsequent session-bound hooks restore full protection.

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

New shared-model and RPC fields are optional so older JSON continues to decode. Database ordering fields are nullable so pre-migration rows retain an explicit unknown state and fall back to their existing semantic timestamps where required.

Session identity order is persisted independently from activity order. Presentation order is transient because it describes observations produced by the live transcript tracker rather than a durable user or hook fact.

Generated hook configuration is refreshed through the existing plugin installation path. Mixed-version clients remain usable because identity-free activity events are accepted and new wire fields are optional.

## Testing strategy

Reducer tests cover:

- matching and rewritten task identifiers;
- matching, older, and missing `started_at`;
- missing task identity;
- later-start supersession;
- copied parent prefix followed by a child start and close;
- completion and abort variants;
- malformed and unrelated JSONL records.

Tracker tests cover:

- initial tail bootstrap, truncation, and incremental reads;
- 64 KiB boundaries and unterminated fragments;
- oversized-record discard and recovery;
- unreadable-file recovery;
- per-request byte and step limits;
- fleet fairness, scoped polling, path removal, and reordering;
- SessionStart boundaries, daemon reconstruction, and same-path invalidation;
- transcript identity rollover during concurrent list calls.

Daemon and wire tests cover:

- current-session hook acceptance and stale-session rejection;
- legacy identity-free hook compatibility;
- atomic ordering of session, activity, and attention facts;
- equal-time precedence;
- Ctrl+C persistence and later supersession;
- bounded hook-payload parsing and JSON round trips;
- migration of nullable ordering fields.

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
- **A task stack** — copied parent history and orphaned starts would be restored after the current subagent task closes, creating false working.
- **A default-off flag** — the legacy path is the known failure and parallel modes would preserve conflicting interpretations. Conservative idle fallback bounds the replacement's risk.
- **Terminal screen scraping** — rendered TUI text is not a stable machine interface.

## Operational impact

The design adds no new durable external resource and requires no new reconciler. It reads existing rollout files, persists ordering metadata in the existing terminal record, and uses existing RPC and hook installation paths.

No automatic process control, input injection, deletion, or background actuation is introduced. The change affects only Codex activity observation and presentation.
