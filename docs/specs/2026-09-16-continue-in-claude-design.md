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

The app disables the choices while the source reports `working` or
`waitingForUser` and explains that the current turn must finish first. The daemon repeats
the activity check and every other eligibility check; menu state is never authority.

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

The envelope is mandatory. Source-controlled values such as IDs and paths are capped at
valid UTF-8 boundaries, and git status yields whole lines until the envelope budget is
full. If status does not fit, the envelope includes a count and an explicit truncation
marker. The pointer, source identity, git-status section, handoff warning, and authorship
statement always remain present.

History is normalized into semantic units in source order. The first complete user-task
unit, when present, receives space first so suffix truncation cannot discard the task being
continued. The builder then walks the remaining units from newest to oldest, retains every
whole unit that fits, deduplicates the initial task if it already falls in that suffix, and
restores chronological order for rendering. It never cuts a serialized unit mid-record. A
single unit larger than the history budget becomes a typed omission stub and remains
available through the source pointer. The packet says how many middle, earlier, oversized,
malformed, and unsupported records it omitted. All byte decisions happen after redaction
and use valid UTF-8 boundaries.

The JSONL scanner reads fixed-size chunks and caps one input record at 1 MiB. It discards
an oversized or unterminated record without accumulating the rest of that record in
memory. Thus both packet size and parser working memory remain bounded even when a tool
result writes a very large line.

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
2. Require a positively idle source. `working` and `waitingForUser` return
   `terminalBusy`; unknown activity fails closed because it cannot prove the turn finished.
   There is no force option.
3. Capture a continuation-specific source snapshot containing
   `TerminalReplacementSnapshot`, activity value, source, observation time and ordering
   watermark, and a rollout fingerprint consisting of path, file identity, size, and
   modification time. This separate type is required because `TerminalReplacementSnapshot`
   deliberately excludes activity facts.
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
tmux coordinate.

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
replacement paths.

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

Startup reconciliation treats every pending Codex-to-Claude row as **restore Codex**, never
as permission to infer or finalize Claude. Under the same server lock it rebuilds the
ordinary `codex resume <source-thread-id>` command, replaces any destination, inert, dead,
or missing pane using the verified/recreated-window path, and supplies a new pending
recovery incarnation. Exact Codex `SessionStart` readiness promotes that token and clears
pending state. A failed recovery keeps the Codex row pending for the next reconciliation
pass instead of clearing the fence or adopting whatever process happens to occupy the
coordinate. This rule makes the source identity and recovery intent survive a daemon crash
or repeated transport failure. No failure path reports or persists a live provider
identity it did not observe.

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

- Stable input and git status produce byte-for-byte identical output.
- The packet never exceeds 65,536 bytes and always ends on a valid UTF-8 boundary.
- The mandatory envelope survives maximal metadata and git-status input.
- Selection reserves the initial user task, retains the newest complete units in
  chronological order without duplicating that task, and reports every omitted category.
- Oversized and unterminated JSONL records respect the 1 MiB record cap.
- User messages and assistant conclusions render; response/event duplicates render once.
- Tool calls retain names and path-like arguments; tool outputs, commands, reasoning,
  encrypted content, and binary data do not render.
- Structured and text secrets are replaced, including authorization headers, credential
  assignments, private keys, credentialed URLs, and recognized token prefixes.
- Malformed or content-free rollouts fail preparation without changing a terminal.

### Daemon and transaction tests

- Wrong provider, missing/unreadable rollout, missing worktree, missing profile,
  holder transport, parked source, and non-idle or unknown activity all refuse before
  interruption.
- Explicit and ambient profiles use the existing config-dir, secret, routing, env-override,
  trust, settings-overlay, plugin, fallback-model, and usage-label paths.
- A final snapshot, activity, rollout-fingerprint, pane-ownership, or incarnation mismatch
  refuses the queued operation.
- The final destructive fence requires one `paneSendProbe` result with the exact pane,
  window, and terminal-ID stamp; no graceful interrupt runs before it.
- Success retains exactly one terminal row, terminal ID, worktree, tab, and tmux window;
  it leaves one live Claude process and no live Codex process.
- The Claude spawn receives a fresh session ID and the packet as its initial prompt.
- A preparation failure leaves the original Codex process, row, rollout, and incarnation
  untouched.
- A Claude spawn failure, readiness timeout, or finalization failure restores the original
  Codex thread and rollout under a fresh incarnation before returning an error.
- Readiness remembers an exact-token event that beats waiter registration, rejects every
  mismatched token, and never mutates a pending Codex row through `applySessionStart`.
- A daemon crash at every staged boundary and a failed rollback respawn leave a durable
  pending Codex row that startup reconciliation restores; reconciliation never adopts the
  destination Claude process.
- Delayed source or failed-destination hooks cannot mutate the finalized or rolled-back row.
- Concurrent Continue, wake, recreate, and profile-swap requests serialize through the
  server lock and only one can pass the snapshot fence.
- Server restart and tmux window-ID reuse never kill the newly staged replacement or
  bootstrap window. The two cleanup inequalities and regression test from commit
  `30b324d5` land with this work: neither the stale source ID nor bootstrap ID is killed
  when it equals the freshly created replacement ID.

### Client tests

- RPC params and the returned `Terminal` round-trip through JSON.
- CLI parsing covers required `--terminal`, profile name/UUID, ambient omission, and JSON
  output.
- The app menu appears only when cached metadata says tmux-backed Codex with a rollout
  path, uses the existing profile labels and usage summaries, and disables action during
  an in-flight turn. Readability remains a daemon check.
- Success updates the existing tab; failure creates no tab and surfaces the daemon error.

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
- Readiness entries are in-memory and bounded by their injected-clock deadlines; durable
  pending row state, not an in-memory waiter, drives recovery after daemon restart.

No new reconciler is required. `WorktreeLifecycle+Reconcile` must recognize the durable
pending provider replacement and restore the source Codex process by the exact rule above;
that extends the existing terminal/window reconciler rather than creating a new resource
owner.

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
