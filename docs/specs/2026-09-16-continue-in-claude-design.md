# Continue in Claude from Codex

**Status:** approved design
**Date:** 2026-09-16
**Authorship:** OpenAI Codex drafted this specification from the human-approved product decision and the repository's existing replacement machinery.

## Problem

A Codex terminal can hand a Claude session to Codex through Codex's native
`externalAgentConfig/import` API. Claude Code has no inverse API for importing a Codex
rollout. A user who needs to move the same work to Claude must open another terminal,
choose an account, and explain the work again.

The requested action is **Continue in Claude**. It replaces the Codex process in the
current terminal with a fresh Claude session under an account the user selects. Continue
means one captain: the worktree, tab, terminal row, and tmux window stay the same, and the
Codex and Claude processes never remain live together. A separate future action may offer
an explicit fork, but this action never creates a sibling terminal.

Because Claude cannot import the rollout, TBD gives it a deterministic continuation
packet as the initial user prompt. The packet is a bounded, mechanically selected view of
the Codex rollout, not a native resume and not a model-written summary. It points back to
the complete source rollout for details it omits.

## User experience

A Codex tab's context menu shows a **Continue in Claude** submenu when cached metadata
says the terminal is tmux-backed Codex and has a non-empty rollout path. The app cannot
establish filesystem readability; the daemon alone verifies that before acting. The
submenu contains:

- **Default (logged in)** — the ambient Claude login, represented by a nil profile ID.
- Every configured Claude profile — in the same order and with the same compact usage
  labels as the existing **Swap profile** and **Fork Session** menus.

The app enables the choices only when the transcript-derived presentation state is
positively `idle`. A presentation state of `working` or no presentation observation disables
them. A durable `waitingForUser` or `unknown` state also disables them; a stale durable
`working` value does not override a newer transcript-derived idle presentation. Disabled
choices explain that the current turn must finish first. The daemon performs its own stricter
activity checks and every other eligibility check; menu state is never authority.

After success, the active tab does not move. Its terminal keeps the same ID and window,
but its provider label, account chip, session identity, and transcript target change to
Claude. Failure before interruption leaves the Codex session untouched. An ordinary
failure after interruption reports that Continue failed only after Codex has been
restored; a transport outage that also blocks rollback leaves a durable pending source
recovery for startup reconciliation.

The v1 app surface is available only for tmux-backed Codex terminals. Holder-backed
terminals have no tmux window to replace, so the daemon refuses them without changing the
row or process. Holder replacement requires a transport-specific design and is outside
this change.

## Continuation packet

`CodexContinuationPacketBuilder` reads the rollout as newline-delimited JSON and produces
one UTF-8 string. It never calls a model and never writes a handoff file. Given the same
rollout bytes and git-status bytes, it produces the same packet bytes.

### Size and selection

The complete prompt is capped at **65,536 UTF-8 bytes**. The builder divides that budget
before parsing history:

- **16,384 bytes for the envelope** — provenance, source metadata, the immutable rollout
  pointer, current git status, safety guidance, authorship disclosure, and omission counts.
- **49,152 bytes for history** — user messages, assistant conclusions, and tool-call
  summaries.

The 64 KiB ceiling bounds the handoff's contribution to Claude's first prompt and keeps
packet construction predictable while retaining room for useful task context. TBD
reserves one quarter of that budget (16 KiB) for the envelope because provenance, safety
guidance, and the immutable pointer must not compete with optional transcript history. The
remaining three quarters (48 KiB) favor the conversation being continued. This fixed split
makes truncation deterministic and prevents history from crowding out the information
needed to understand and audit the handoff.

The envelope is mandatory. Source-controlled values such as IDs and paths are capped at
valid UTF-8 boundaries, and git status yields whole lines until the envelope budget is
full. If status does not fit, the envelope includes a count and an explicit truncation
marker. The pointer, source identity, git-status section, handoff warning, and authorship
statement always remain present.

History is normalized into semantic units in source order and grouped into turn bundles.
A new user message opens a boundary, while distinct `turn_context` turn IDs and task
lifecycle records preserve boundaries for rollout variants that do not repeat the user
record. Repeated context records for the same turn do not split a bundle. The first
complete user-task unit, when present, is the sole independently reserved unit so suffix
truncation cannot discard the task being continued. All remaining history is selected as
whole turn bundles from newest to oldest and restored to chronological order for
rendering. A bundle is either retained in full, omitted in full, or replaced by a typed
oversized-turn stub; the builder never emits only one side of a user/assistant turn because
the byte cap landed between its units. A first task larger than the history budget likewise
becomes a typed unit stub and remains available through the source pointer. The packet
reports omission counts for earlier and middle history, oversized history and JSONL records,
malformed records, and unsupported records. All byte decisions happen after redaction and
use valid UTF-8 boundaries.

The JSONL scanner reads fixed-size chunks and caps one input record at 1 MiB. At sixteen
times the total packet budget, this input limit leaves room to parse structured records
whose JSON overhead or redactable content exceeds what can ultimately be selected, while
still preventing one bulky record from forcing unbounded buffering. Raising the limit
would increase worst-case scanner memory without increasing packet capacity; lowering it
would discard potentially useful records sooner. The scanner discards an oversized or
unterminated record without accumulating the rest of that record in memory.

### Envelope

The envelope contains:

- A statement that TBD assembled the packet deterministically without a model call.
- A statement that the source conversation contains Codex-authored output and that this
  is a handoff, not a Claude-native resume.
- The standardized absolute path of the complete Codex rollout. TBD does not edit, move,
  or replace this file as part of Continue; after successful replacement no Codex process
  remains to append to it. Existing transcript-retention policy still applies.
- Allowlisted `session_meta` fields: source thread ID, rollout timestamp, working
  directory, Codex originator and version, and model/provider names when present. It does
  not copy instructions, environment maps, or unknown metadata fields.
- `git -C <worktree> status --short --branch --untracked-files=all`, invoked with a process
  argument array rather than a shell. A failed status command is a preparation failure.
- A direction to inspect the repository and the complete rollout before relying on an
  omitted detail.

### History records

`response_item` is the canonical source for conversation content:

- User-role message text becomes **User** units. These include the task and later user
  direction.
- Assistant-role output text becomes **Codex** units. Final-answer items are retained as
  conclusions; other visible assistant messages may be retained with their phase label.
- Function calls become **Tool call** units containing the tool name and only path-like
  arguments. Recognized keys include `path`, `paths`, `file`, `files`, `filename`,
  `directory`, `cwd`, `workdir`, `worktree`, and `target`, including nested occurrences.
- Function-call outputs, custom-tool outputs, reasoning items, encrypted reasoning,
  images, and binary payloads are omitted.

Some Codex versions emit visible messages only as `event_msg` records. The builder uses
`user_message` and `agent_message` as a fallback when no equivalent `response_item`
exists, deduplicated by role and normalized text. `turn_context` supplies boundaries but
contributes no environment or instruction payload. Unknown record types are counted and
ignored.

### Redaction

Every retained string passes through one redactor before sizing. Structured objects redact
values whose keys match secret-bearing names such as token, secret, password, credential,
authorization, API key, private key, cookie, or session cookie. Text redaction covers
credential assignments, bearer/basic authorization values, private-key blocks, URLs with
userinfo, and recognized service-token prefixes. A redaction marker replaces the value;
the marker never includes length or a recoverable fragment.

Tool arguments receive a second allowlist after redaction: path-like values survive, while
commands, prompts, request bodies, headers, and arbitrary argument text do not. Tool
results never enter the packet. These rules reduce accidental disclosure but do not claim
to recognize every secret a user might write in ordinary prose; the packet warns that its
source rollout is the complete authority.

## Preparation

All fallible work that can finish while Codex remains live happens before interruption:

1. Load the source row and require a tmux-backed Codex terminal with a session/thread ID,
   an absolute readable regular rollout file, and an active or main worktree whose directory
   exists.
2. Require the durable observed activity to be `idle` with an ordering watermark. Then read
   the rollout through the existing bounded `CodexTranscriptActivityTracker`, using the
   terminal's session generation and transcript boundary. Only an exact authoritative
   `.idle` result proceeds. A `working` or `waitingForUser` result, or no result because the
   observation became unavailable or remains behind its one-MiB budget, returns
   `terminalBusy`. The earlier fingerprint check rejects a rollout that is already missing
   or unreadable. The tracker does not publish an intermediate state, and Continue does not
   fall back to the cached row when the authoritative observation is unavailable. There is
   no force option.
3. Capture a continuation-specific source snapshot containing
   `TerminalReplacementSnapshot`; activity value, source, observation time, and ordering
   watermark; awaiting-input reason and observation time; and a rollout fingerprint
   consisting of path, file identity, size, and modification time. This separate type is
   required because `TerminalReplacementSnapshot` deliberately excludes activity facts.
4. Resolve the requested profile through `ModelProfileResolver`. Nil means the ambient
   login. An explicit missing or unreadable profile returns `profileMissing`.
5. Build the continuation packet and git-status section.
6. Allocate a fresh Claude session ID. Use `SystemPromptBuilder`,
   `ClaudeTrustSeeder`, `ClaudeHookOverlay`, `PluginDirWriter`,
   `ClaudeProfileConfigDirManager`, `EnvOverrideResolver`, and
   `ClaudeSpawnCommandBuilder` exactly as an ordinary fresh Claude terminal does. The
   packet is the builder's `initialPrompt`; Claude receives no Codex resume claim.
7. Prepare the source rollback command through `CodexLaunchPreparation`,
   `CodexSpawnCommandBuilder`, the source thread ID, the existing Codex home, and the
   ordinary Codex environment-routing path.

Trust seeding and existing profile-overlay writes may be idempotent during preparation,
but no terminal row, tmux window, source process, or rollout changes. Any error returns
while Codex is still running.

## Replacement transaction

The daemon performs replacement under the worktree's tmux-server lock. The lock is shared
with wake, recreation, profile replacement, and reconciliation.

### Final fence

Inside the lock, the handler reloads the row and accepts the prepared action only if:

- the complete source snapshot still matches;
- the row is still Codex, awake, and positively idle;
- the rollout fingerprint is unchanged;
- the recorded pane still belongs to the terminal and its window still exists; and
- no other replacement is pending.

A mismatch returns a stale-replacement or busy error before interruption. This second
check prevents a queued request from acting on a later session, profile, turn, or reused
tmux coordinate. Because preparation fingerprints the rollout before the authoritative
activity observation, the unchanged fingerprint also proves that no new rollout bytes have
invalidated that observation before this fence.

### Stage, launch, and commit

The transaction reuses `pendingSessionIncarnationID` as a launch fence and adds a small
`ContinueInClaudeReadinessCoordinator`. The actor is keyed by terminal ID plus process
incarnation and has remembered-ready semantics: a matching hook that arrives before the
waiter suspends is retained for that waiter, while timeout, finalization, rollback, and
terminal deletion clear the entry.

The ordered transition is:

1. A compare-and-set database write against the continuation-specific source snapshot
   assigns a new pending incarnation while leaving the row's Codex kind, label, thread ID,
   rollout path, profile, and active incarnation intact. Hooks from the old process become
   ineligible to mutate the row once replacement starts.
2. The daemon registers a readiness waiter keyed by terminal ID and pending incarnation.
3. Immediately before the first destructive act, `paneSendProbe` must report the exact
   row pane, the exact row window ID, and the pane's `@tbd_terminal_id` stamp equal to the
   source terminal ID. Missing or disagreeing identity refuses and rolls back the pending
   database token without touching the process. This path does not call
   `gracefullyInterruptPane`; the single `respawn-window -k` below is the first destructive
   act.
4. `tmux respawn-window -k` starts the prepared Claude command in the same window. tmux
   terminates Codex before it starts Claude, so no source and destination process coexist.
5. Claude's `SessionStart` hook supplies the pending incarnation, fresh session ID, and
   transcript path. Ordinary `applySessionStart` rejects rows with a pending incarnation,
   so the handler first recognizes an exact pending token and routes that event to
   `ContinueInClaudeReadinessCoordinator` without mutating the Codex row. No nil, active,
   stale, or mismatched token can satisfy readiness.
6. A compare-and-set finalization promotes the pending incarnation and atomically changes
   the row to Claude: `kind` and label, selected profile ID, Claude session ID and
   transcript path, activity provenance, and cleared Codex boundary and stale prompt
   state. The terminal ID, worktree ID, tmux window ID, tab, pin, creation time, and desk
   role remain unchanged.
7. The daemon broadcasts a new `terminalReplaced` state delta carrying the complete
   updated `Terminal`, then returns that terminal. `terminalCreated` cannot represent this
   event: app reducers deduplicate an already-known terminal ID and would retain stale
   provider, transcript, and profile fields.

Readiness uses `SessionStart`, never terminal screen text. The waiter has an injected
`Clock<Duration>` and a 15-second default deadline. Holding the server lock through
readiness and finalization serializes the full provider transition against other in-place
replacement paths. Fifteen seconds gives process launch and hook delivery a finite window
while bounding how long the destructive transaction can hold that lock with the row still
pending. A shorter deadline leaves less tolerance for launch scheduling; a longer or
unbounded wait delays rollback and other same-server replacements. Silence never counts
as readiness: the deadline requires an exact incarnation-keyed `SessionStart`; on timeout,
the daemon begins rollback instead of adopting the process.

### Rollback

Any tmux launch error, readiness timeout, malformed readiness event, or finalization error
after interruption takes the rollback path while the same server lock is held:

1. Retract the pending destination waiter.
2. Compare-and-set the still-Codex row to a fresh rollback pending incarnation while
   preserving the captured thread and rollout. Delayed hooks from both dead processes are
   stale.
3. Respawn `codex resume <source-thread-id>` in the same window with the original Codex
   home, env overrides, rollout identity, and rollback incarnation.
4. Route the exact rollback token through the same remembered-ready coordinator. On
   readiness, promote that token, clear pending state, and retain the Codex identity. Only
   then return a Continue error saying that Codex was restored.

Rollback never changes provider or transcript identity to Claude. If the tmux server or
window disappears during rollback, recovery uses the existing inert-window staging path,
persists the recreated coordinates before launch, and then starts Codex. Cleanup must not
kill a freshly created window when tmux reuses the stale source ID: kill the stale or
bootstrap window only when its ID differs from the new window's ID. This same guard is
applied to the hibernation wake path from commit `30b324d5` so Continue cannot reintroduce
the window-ID-reuse race.

The RPC does not report success until Claude readiness and row finalization agree. It does
not report an ordinary replacement failure until source readiness and the rolled-back row
agree. If rollback respawn or readiness fails, the row remains durably pending with its
original Codex thread and rollout; it never claims Claude.

Startup recovery has two ordered owners. Before the socket binds,
`Daemon.performStartupReconciliation` runs the ordinary `WorktreeLifecycle` ownership pass.
That pass preserves every nonparked Codex row with a pending incarnation, even when its
recorded window is missing or reassigned; it neither disposes of the row nor launches a
replacement. After the RPC socket starts accepting the `SessionStart` hook,
`RPCRouter.reconcilePendingContinueInClaude` treats each preserved row as **restore Codex**,
never as permission to infer or finalize Claude. The same pass runs again with orphan
maintenance so a transport failure remains retryable.

Under the worktree server lock, the Continue-specific pass rebuilds the ordinary
`codex resume <source-thread-id>` command and rotates to a new pending recovery incarnation.
If the recorded pane is live and carries the exact terminal stamp, that pane is the ownership
fact; the pass adopts its actual window coordinate before respawning Codex. An unstamped or
foreign live pane fails closed and leaves recovery pending. A missing or dead pane uses the
inert-window recreation path. Exact Codex `SessionStart` readiness promotes the recovery
token and clears pending state. A failed recovery keeps the Codex row pending for the next
post-socket pass instead of clearing the fence or adopting whatever process occupies the
coordinate. This rule makes the source identity and recovery intent survive a daemon crash
or repeated transport failure. No failure path reports or persists a live provider identity
it did not observe.

## RPC, CLI, and app contracts

`Sources/TBDShared/RPCProtocol.swift` adds:

```swift
public static let terminalContinueInClaude = "terminal.continueInClaude"

public struct TerminalContinueInClaudeParams: Codable, Sendable {
    public let sourceTerminalID: UUID
    public let profileID: UUID?
    public let cols: Int?
    public let rows: Int?
}
```

The result is the updated `Terminal`, not a new-terminal wrapper. A second request after a
successful continuation finds a Claude row, returns `terminalWrongProvider`, and spawns
nothing. Other machine-readable failures reuse or add these codes:

- `terminalBusy` — the source is working, waiting, or lacks a trustworthy idle fact.
- `profileMissing` — an explicit profile no longer resolves.
- `terminalSessionGone` — the row's source window or pane identity is gone.
- `terminalWrongProvider` — the source is not Codex, including an already-continued row.

The CLI command is:

```text
tbd terminal continue-in-claude --terminal <uuid> [--profile <name-or-uuid>] [--json]
```

It reuses the existing exact-name, unique case-insensitive-name, or UUID profile resolver.
Omitting `--profile` selects **Default (logged in)**. Plain output reports the unchanged
terminal ID and selected account; `--json` prints the returned `Terminal`.

`DaemonClient.continueInClaude`, `AppState.continueInClaude`, and the tab menu call the
same RPC. `StateDelta.terminalReplaced` carries the full terminal and atomically replaces
the cached row. The app preserves the selected tab and layout. Errors appear through the
existing alert path.

## Testing

### Packet tests

- Identical rollout and git-status input produces identical attributed output. The fixture
  also proves allowlisted metadata, user and Codex text, the immutable rollout pointer, and
  the authorship and handoff warnings appear while unknown metadata does not.
- A long multibyte history stays within 65,536 UTF-8 bytes, retains the initial task and the
  newest turns in chronological order, and reports omitted middle history.
- A cap-edge fixture retains both sides of the newest user/Codex turn and omits both sides of
  the displaced middle turn; no partial turn bundle appears.
- Maximal metadata and git status keep the envelope within 16,384 bytes and preserve the
  pointer, status heading and omission marker, safety direction, and authorship disclosure.
- Oversized and unterminated JSONL records are counted without hiding valid content,
  and an oversized initial user unit becomes a typed stub.
- A canonical `response_item` replaces its equivalent `event_msg` fallback without
  duplication, while distinct fallback content remains visible.
- Tool-call output proves that only the tool name and path-like arguments survive. The same
  fixture excludes command, prompt, header, arbitrary secret argument, tool-result, and
  reasoning content and exercises credential assignments, authorization values, private
  keys, credentialed URLs, service-token prefixes, and git-status redaction.
- A content-free rollout and a failed git-status command fail packet preparation.

### Daemon and transaction tests

- The readiness coordinator remembers an exact-token event and rejects a mismatched token.
- Store tests prove that staging preserves Codex identity, successful finalization changes
  the same row to Claude, rollback rotates the token without publishing Claude, and an
  activity change makes the continuation compare-and-set fail without mutation.
- The successful RPC test keeps one row and the same terminal, pane, and window IDs; records
  one `respawn-window`, no `send-keys`, and a full `terminalReplaced` delta; and leaves the
  row named Codex until the exact destination readiness hook arrives.
- An unstamped pane and a throwing ownership probe both retract the staged fence without a
  respawn. Persisted `working`, wrong-provider, unreadable-rollout, and missing-profile
  fixtures also refuse before respawn and preserve the tested source rows.
- A rollout `task_started` record overrides a stale persisted idle fact. A scan that remains
  behind its bounded observation budget also refuses with `terminalBusy`; neither case
  stages a pending incarnation or respawns the window.
- Destination launch failure and destination-readiness timeout restore the source Codex
  thread and rollout under a rotated token. A delayed destination hook cannot mutate the
  restored row. Repeated respawn failure leaves a durable pending Codex recovery candidate.
- Continue recovery restores a staged pending row to Codex, adopts the actual window of a
  live exact-stamped pane, and refuses an unstamped live pane without creating or respawning
  another window. The ordinary startup ownership test separately proves that pre-bind
  `WorktreeLifecycle` reconciliation preserves a nonparked pending Codex row for that
  post-bind pass.
- The hibernation window-ID-reuse regression proves that wake does not kill a newly created
  window when tmux reuses the stale window ID. Continue's missing-pane recovery uses the
  same two stale/bootstrap ID inequality guards; the Continue-specific recovery tests cover
  its exact-stamped live-pane and fail-closed ambiguous-pane branches.

### Client tests

- CLI parsing requires named `--terminal`, accepts ambient omission, profile name or UUID,
  and `--json`, and plain output reports the unchanged terminal ID and account label.
- Menu policy tests cover visibility for tmux-backed Codex rows with non-empty rollout
  paths, transcript-derived idle/working state, missing presentation state, durable waiting
  and unknown states, and the busy caption. Readability remains a daemon check.
- `terminalReplaced` replaces the cached row without moving the selected tab or layout,
  does not append an unknown terminal, preserves a custom tab label while clearing a
  generated provider label, and fences an overlapping pre-replacement list snapshot while
  still admitting a later rollback snapshot.

Run focused packet, router, store, CLI, and app tests, then
`scripts/swift-safe build` and the full `scripts/test.sh` suite.

## Feature flag

This change adds no flag or config column. Continue is an explicit user gesture, and its
process replacement uses the existing same-window replacement actuator already exercised
by profile swap, wake, and recreation. It adds no background timer, background policy, or
autonomous kill path. Its safety boundary is stricter than the existing actuator:
idle-only entry, complete preflight, snapshot and pane fencing, machine readiness, and
mandatory rollback.
A default-off switch would duplicate those gates, add a migration, and leave the risky
operation unchanged once enabled.

## Durable resources and reconciliation

Continue creates no new kind of durable resource:

- It creates no packet file, mapping table, terminal row, tab, steady-state tmux window,
  ref, worktree, or background job. Transport recovery calls the existing window-recreation
  path rather than adding a new creation mechanism.
- The source rollout is an existing Codex resource and stays under existing transcript
  retention. The destination Claude transcript is the ordinary transcript of the process
  already covered by terminal reconciliation and transcript retention.
- The selected profile's config directory, trust entry, hook overlay, and plugin directory
  use existing writers and existing `OrphanGC` coverage.
- The process remains attached to the existing terminal row and window, so
  `WorktreeLifecycle+Reconcile` and `AgentReaper` retain their current ownership model.
  The ordinary pre-bind ownership pass preserves pending nonparked Codex rows; it does not
  try to launch a process before hooks can reach the daemon.
- Readiness entries are in-memory and bounded by their injected-clock deadlines; durable
  pending row state, not an in-memory waiter, drives recovery after daemon restart.

No new durable resource owner is required. The post-socket
`RPCRouter.reconcilePendingContinueInClaude` recovery pass consumes the pending state that
the ordinary lifecycle reconciler preserves and repairs the existing terminal row/window
ownership. It runs at startup and with existing orphan maintenance; it does not introduce a
new timer or a new kind of resource.

## Tradeoffs and rejected alternatives

- **Model-written summary** — rejected because it spends credits, varies between runs, and
  turns a provider switch into an inference task.
- **Full rollout as the prompt** — rejected because rollouts contain bulky tool results,
  secrets, and unbounded history. The immutable pointer preserves the complete record.
- **Sibling Claude tab** — rejected because it leaves two captains live in one worktree.
  If added later, it must be named **Fork into Claude** and make duplicate-live behavior
  explicit.
- **Pretend resume** — rejected because Claude session IDs cannot address Codex rollouts.
  The packet states that it is a handoff.
- **Persist a packet file or source-to-destination mapping** — rejected because the packet
  is needed once, the source pointer suffices, and another durable artifact would need
  lifecycle and orphan policy.
- **Change the row before launch without a pending fence** — rejected because a failed
  spawn would leave the row naming Claude while Codex or no agent was running.
- **Change the row only after an unfenced launch** — rejected because Claude's
  `SessionStart` can race the write and attach to the Codex identity. The pending
  incarnation makes readiness observable without publishing the destination early.
- **Force while working** — rejected for v1. A bounded deterministic packet cannot make
  killing an in-flight turn safe.

## Not built

No Claude import API, model summarizer, full tool-result replay, packet file, mapping table,
sibling tab, force option, holder-transport replacement, feature flag, config migration,
new background timer, or new reconciler.
