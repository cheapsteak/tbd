# Local agent session durability

## Summary

TBD treats Claude and Codex as peers while their processes run, but not after those processes
stop. A reboot parks Claude terminals for later resume and deletes Codex terminals. Session
History scans Claude's project store and omits Codex rollouts. Archiving records only Claude
sessions, so a mixed worktree cannot restore the tabs it had before archive.

This design gives every TBD-observed top-level local agent session a durable association with its
worktree. Reconciliation preserves identified Codex terminals after a reboot, Session History
lists and renders Codex rollouts, and archive and revive restore mixed Claude and Codex tabs. User
actions resume each agent through its native command. The existing `session_restore_enabled`
setting remains the only control for automatic process startup after a reboot.

## User story

When TBD has observed an agent session in one of my worktrees, I want that session to survive a
reboot or archive and appear in Session History, so I can resume the conversation without
remembering which agent produced it or reconstructing the tab myself.

## Current behavior

`WorktreeLifecycle.reconcileTerminals` asks `Terminal.claudeResumeDecision` whether a dead terminal
can resume. It parks an identified Claude terminal and deletes every other dead row. Codex already
reports its thread ID and rollout path through SessionStart, and `TerminalStore.applySessionStart`
stores them on the terminal row, but reconciliation deliberately classifies the row as
non-Claude-resumable and deletes it.

The command builder already emits `codex resume <thread-id>`. Dead-window recreation and
Continue-in-Claude rollback use that command, but the ordinary reboot path deletes the terminal
before a lazy wake can use it.

Session History has a separate Claude-only boundary. `session.list` resolves the worktree's
Claude project directory and calls `ClaudeSessionScanner`. `session.messages` accepts only files
under the Claude projects root and parses only Claude JSONL. The archive model likewise stores
`archivedClaudeSessions` and Claude spawn extras. These boundaries explain both symptoms: Codex
tabs disappear after reboot, and Codex rollouts never appear in Session History.

The restart-restoration design explicitly leaves out Codex because reconciliation deletes its
rows. This design replaces that limitation. It does not add a second restoration preference.

## Goals

- Preserve an identified Codex terminal when reboot or process loss makes its process
  unreachable.
- Resume a preserved Codex terminal lazily with its thread ID, model override, disabled features,
  environment, transport, and dedicated Codex home.
- Include Codex in the existing paced automatic restore pass when `session_restore_enabled` is on.
- List only top-level Codex sessions that TBD accepted through SessionStart for that worktree.
- Render Codex user messages, assistant messages, reasoning, tool calls, and tool results in the
  existing transcript timeline.
- Make active and archived Session History actions resume the selected session with the correct
  agent.
- Restore the resumable Claude and Codex tabs that were open when a worktree was archived, in
  their prior order.
- Preserve existing Claude behavior and decode archives written by older builds.

## Non-goals

- Import Codex rollouts solely because their recorded working directory matches a worktree.
- Recover a Codex tab whose terminal row was deleted before this design shipped.
- List Codex subagents or sessions that TBD never observed in a terminal.
- Continue an interrupted turn automatically. Every resumed agent waits for the user.
- Extend manual, idle, merge, or exit parking to Codex. This design parks Codex only when
  reconciliation proves that its process is unreachable.
- Copy, move, delete, or otherwise own Codex's rollout files.
- Add a new preference or feature flag.

## Durable model

### Session associations

Add a `local_agent_session` table. Each row represents one agent session as observed in one
worktree. A session resumed in a fresh worktree gains a second association; the original archived
worktree keeps its association and remains browseable.

Each row stores:

- `id` — a UUID primary key.
- `worktree_id` — the owning worktree, with cascade deletion when the worktree is forgotten.
- `terminal_id` — the last terminal that hosted the session. It is a nullable foreign key with
  `ON DELETE SET NULL`, because terminal deletion must not erase history.
- `agent_kind` — `claude` or `codex`.
- `session_id` — Claude's session ID or Codex's thread ID.
- `transcript_path` — the last accepted Claude transcript or Codex rollout path for this
  association.
- `codex_launch_options` — the terminal's encoded model override, disabled features, and dedicated
  home for Codex; NULL for Claude.
- `first_observed_at` and `last_observed_at` — timestamps from accepted SessionStart events.

The unique key is `(worktree_id, agent_kind, session_id)`. A later accepted SessionStart in the
same worktree updates the terminal, path, launch options, and last-observed time. An association
in another worktree remains independent, so fresh-branch resume cannot move history out of the
source archive.

`TerminalStore.applySessionStart` writes the terminal identity and an eligible session association
in one database transaction. Rejected hook calls, stale process incarnations, foreign working
directories, and pending replacement processes write neither. This preserves the existing hook
identity and ordering rails.

Codex association also requires root-session provenance. The catalog classifier reads
`session_meta.payload.source`: an explicit subagent source is ineligible. When the rollout is not
yet readable, the terminal identity still commits but the association waits. The existing Codex
rollout reconciliation pass retries classification after the file appears and upserts the
association only after it can prove that the rollout is top-level. Absence of provenance is not
proof of a root session.

The migration seeds associations from surviving terminal rows that already contain an agent kind,
session ID, and transcript path. It cannot reconstruct deleted rows and does not scan either
agent's filesystem. New SessionStart events maintain the table thereafter.

### Terminal resume plans

Introduce `AgentSessionIdentity`, containing `agentKind` and `sessionID`, and an internal
`AgentResumePlan` derived from a terminal plus its durable launch metadata.

- A Claude plan contains the existing profile, spawn extras, and `claude --resume` inputs.
- A Codex plan contains the thread ID, launch options, environment overrides, and Codex-home
  preparation needed for `codex resume`.
- A shell or an agent terminal without a session ID has no plan.

The physical `claude_session_id` column remains in place for migration safety. New lifecycle code
treats it as the terminal's agent session ID and always combines it with `kind`; the ID alone never
proves that a terminal runs Claude. A later column-retirement change may rename the storage after
rollback compatibility no longer needs the current column.

### Archived tab snapshot

Add nullable `archived_agent_tabs` JSON to the worktree table, with no SQL default. The shared
`Worktree` model exposes it as an optional array. Each `ArchivedAgentTab` contains:

- `AgentSessionIdentity`.
- The previous terminal label and tab ordinal.
- Whether the terminal was primary.
- The Claude profile and spawn extras needed by Claude, when present.
- The Codex launch options and dedicated home needed by Codex, when present.

Archive writes this snapshot before it kills any agent or deletes any terminal row. It also keeps
writing the Claude projection to `archivedClaudeSessions` and `archivedClaudeSpawnExtras`, so a
rollback build can still revive Claude sessions. New code prefers `archivedAgentTabs`; an older
archive that lacks it synthesizes Claude entries from the existing fields.

Revive clears both representations only after the requested sessions start successfully. A
failed or pre-session-gated revive keeps the snapshot until its existing completion boundary.

## Reboot reconciliation

Reconciliation retains the existing tri-state ownership probes. An unknown tmux or holder answer
changes nothing. Once the daemon proves a nonparked terminal unreachable, it applies these
outcomes:

- A terminal with a Claude or Codex resume plan becomes parked with
  `HibernateReason.recovery`.
- A terminal without a resume plan is deleted as today.
- A row that was already parked remains untouched.

Parking a Codex terminal preserves its row, tab placement, session ID, rollout path, transport,
and launch options. It clears process-bound activity, pending input, process incarnation, and stale
holder PIDs. Reconciliation records the same hibernate actuation used for Claude. A database
failure leaves the row untouched for a later pass; failure never becomes evidence that the row is
disposable.

Codex remains ineligible for manual, automatic-idle, merge, and SessionEnd parking. Those paths
retain their Claude-specific gates. The provider-neutral resume decision applies only to recovery,
archive snapshots, explicit history actions, and wake.

## Wake and automatic restoration

`HibernationCoordinator.wake` accepts an `AgentResumePlan` instead of requiring
`claudeResumeDecision`. It retains the existing singleflight claim, start-admission check,
compare-and-set, condition check, and transport branches.

For Codex, wake:

1. Validates the recorded dedicated home when one exists; it never falls back to the shared home.
2. Resolves the Codex executable and ensures the selected profile plugin.
3. Builds `codex resume <thread-id>` with the stored model and disabled features.
4. Creates or replaces the tmux window or holder process through the current transport helper.
5. Rotates process incarnation state before launch and waits for the ordinary SessionStart path to
   attach the new rollout.
6. Clears the parked state only through the existing successful-wake commit.

Wake sends no prompt. A missing executable, invalid home, failed spawn, or lost compare-and-set
leaves the terminal parked and retryable. A missing rollout affects transcript display but does
not block resume; the thread ID is Codex's resume authority.

The startup restore pass changes its selection from Claude resumability to agent resumability. Its
timestamp window, recovery reason, worktree-status check, newest-transcript ordering, batches of
three, ten-second gap, cancellation, and admission brake remain unchanged. With
`session_restore_enabled` off, Claude and Codex stay parked until the user opens them. With it on,
the pass wakes both kinds and every agent waits at an empty composer.

## Archive and revive

Archive resolves the current tab order and builds the mixed-agent snapshot before teardown. A
failure to persist the snapshot aborts archive before any process dies or terminal row disappears.
A terminal without a session ID is non-resumable and does not enter the snapshot; archive proceeds
as it does for an unidentified Claude terminal today.

Whole-worktree Revive recreates every entry in snapshot order. The former primary stays first. A
user-selected history session becomes primary, followed by the remaining snapshot entries in
their prior relative order. Entries that remain only in the session catalog are browseable but do
not reopen unless the user selects one.

Original-branch revive starts Claude with its existing resume path and Codex with
`codex resume <thread-id>`. Fresh-branch revive carries only the selected conversation. For Codex,
the new worktree resumes the selected thread and SessionStart creates a new worktree association;
the archived association remains intact.

The pre-session hook gates all primary agents as it does today. Prepared Codex launch data crosses
the wait, preventing a second resolution after checkout mutation. Setup hooks remain parallel and
agent-neutral.

## Session History

### Listing

Extend `SessionSummary` with an optional `agentKind` that decodes an absent value as Claude.
`session.list` merges:

- Claude summaries from `ClaudeSessionScanner`, including older sessions that predate the catalog.
- Codex summaries from `local_agent_session` for the requested worktree.

The daemon deduplicates entries by `(agentKind, sessionID)` and sorts them by most recent activity.
The Codex summary parser reads bounded rollout metadata to find the first and latest user message
and the latest timestamp. Missing or unreadable files remain in the list with an unavailable
state; absence does not erase the association.

The app marks Codex rows with a Codex badge. Existing Claude rows and Closed Terminals keep their
current presentation.

### Reading

Add `CodexTranscriptParser`, which maps rollout records into `TranscriptItem`:

- User and assistant content becomes the existing conversation rows.
- Reasoning becomes the existing thinking presentation.
- Tool calls and results become activity rows, with the same correlation and truncation rules the
  renderer uses for Claude.
- Unknown record types are ignored.
- A malformed line is skipped without discarding later records.

The parser owns Codex format interpretation; the shared table renderer remains agent-neutral.
Fixtures cover current Codex records and keep proprietary or machine-specific content out of the
public repository.

For Claude, `session.messages` retains its current projects-root allowlist. For Codex, it accepts a
worktree and `AgentSessionIdentity`, resolves the path from `local_agent_session`, and requires the
standardized path to remain under the recorded Codex home. The app cannot authorize an arbitrary
file by sending its path. A worktree mismatch, missing association, path escape, or non-regular
file returns a refusal. A cataloged but missing file returns the unavailable state shown by the
history pane.

### Actions

Add a provider-aware session-resume RPC that takes a worktree and `AgentSessionIdentity`. Active
worktrees open a new agent tab through the normal spawn path. Archived actions pass the same
identity into original-branch or fresh-branch revive. Existing RPC fields that name only a Claude
session remain decodable during app-daemon upgrades and translate to `agentKind = claude`.

- Active Claude history runs the existing Claude resume flow.
- Active Codex history runs `codex resume <thread-id>` with cataloged launch options.
- Archived original-branch history promotes the selected session to primary and restores the
  remaining archived snapshot.
- Archived fresh-branch history creates a new worktree with only the selected session.

All actions pass through start admission and write the same actuation records as equivalent
terminal and worktree starts.

## Failure handling

- An eligible SessionStart catalog write fails atomically with its terminal identity write. A
  Codex rollout whose provenance is not readable yet updates terminal identity but creates no
  association until rollout reconciliation proves it top-level.
- Reconciliation destroys no row after an unreadable ownership probe or failed park transaction.
- Archive destroys no process after a failed snapshot write.
- Wake leaves a failed Codex resume parked with its identity and options intact.
- A missing rollout leaves history metadata and resume available; only transcript content is
  unavailable.
- A delayed old-process hook cannot attach to a replacement because the existing incarnation and
  pending-incarnation checks remain authoritative.
- A catalog row outlives terminal deletion but not worktree deletion. TBD never deletes the rollout
  it references; Codex owns that file.

## Compatibility

The database migration, GRDB records, and shared Codable models land in one commit. New fields are
optional. The migration adds no SQL defaults.

An old app ignores the added summary field and continues to use Claude-only actions. A new app
talking to an old daemon decodes the absent field as Claude and receives no Codex summaries.
Existing archives without `archivedAgentTabs` revive through synthesized Claude entries. New
archives retain the old Claude projection for rollback.

The feature needs no historical filesystem import. Surviving terminal rows seed the catalog;
sessions whose rows were already deleted remain available through Codex's own history but cannot
be attributed to a TBD worktree safely.

## Placement

The session ID, agent kind, transcript path, tab order, and launch options are facts TBD already
observes at process boundaries. Recording them belongs in the daemon because user-land cannot
atomically join hook identity, terminal incarnation, and archive teardown.

Resume is transport mechanism. The user chooses when to resume by opening a tab or selecting a
history action. Automatic restoration remains a theory owned by the existing
`session_restore_enabled` preference and start-admission command. This design adds no compiled
answer to whether agents should restart automatically.

Codex rollout parsing also belongs in the daemon. It protects the file boundary, normalizes one
provider format into the shared transcript model, and prevents every UI consumer from interpreting
the same records independently.

## Testing

### Durable records

- Accepted Claude and Codex SessionStart events upsert the correct worktree association.
- An eligible terminal update and association update commit or roll back together.
- Stale incarnation, pending replacement, foreign working directory, missing-ID, and explicit
  subagent events add no association. An unreadable Codex rollout remains uncataloged until the
  rollout reconciliation pass can classify its provenance.
- Migration seeds surviving identified terminals and imports no filesystem-only history.
- The same Codex thread in two worktrees keeps two associations.

### Reconciliation and wake

- A positively dead identified Codex row parks on tmux and holder transports.
- An unidentified Codex row and a shell row are reclaimed.
- Unknown ownership leaves every row unchanged.
- Codex recovery parking clears process-bound facts and holder PIDs while preserving launch data.
- Wake emits the recorded thread ID, model, disabled features, environment, and home.
- Missing executable, invalid home, spawn failure, and compare-and-set loss leave the row parked.
- Manual and idle hibernation continue to refuse Codex.

### Startup restore

- With `session_restore_enabled` off, newly recovery-parked Claude and Codex rows stay parked.
- With it on, both kinds enter the same ordered batches.
- Existing pacing, cancellation, condition recheck, and admission-hold tests cover mixed batches.
- No restore path sends a prompt or continues a turn.

### Archive and revive

- Archive records mixed tabs, prior order, primary identity, and provider-specific launch data.
- A failed snapshot write leaves agents and terminal rows running.
- Whole-worktree Revive restores all resumable snapshot entries in order.
- Selecting a Claude or Codex history entry promotes it without changing the relative order of the
  rest.
- Fresh-branch Codex revive creates a new association and retains the archived association.
- An archive with only legacy `archivedClaudeSessions` still revives.

### Session History

- Lists merge Claude scanner results and cataloged Codex results, deduplicate, and sort.
- Codex rows show their agent kind and unavailable state.
- Rollout fixtures cover messages, reasoning, tool calls, tool results, malformed lines, unknown
  records, and body truncation.
- Transcript reads accept a matching catalog path and refuse arbitrary paths, worktree mismatches,
  uncataloged rollouts, and paths outside the recorded home.
- Active, archived-original, and archived-fresh actions dispatch to the selected agent.

Run daemon and shared tests with `scripts/test.sh`, then compile with `scripts/swift-safe build`.

## Rejected alternatives

### Codex-specific parallel fields

Adding `archivedCodexSessions` and special-casing each lifecycle path would make the first diff
smaller. It would duplicate reconciliation, wake, archive, revive, history, and RPC decisions while
leaving Claude-named abstractions in charge of agent-neutral behavior. A provider-neutral identity
and snapshot give each decision one implementation.

### Filesystem discovery by working directory

Scanning Codex rollouts for a matching `cwd` would show older history without a migration. It would
also include sessions TBD never hosted, lose launch metadata and tab order, and misattribute
sessions after checkout moves. Accepted SessionStart is the reliable ownership boundary.

### Read-only Codex history

Showing rollouts without Resume and Revive would fix discovery but leave the primary recovery task
outside TBD. The durable record already contains the native thread ID and launch data, so the
history action should use them.

### A second restoration flag

An additional Codex durability flag would make transcript visibility and non-destructive row
preservation optional. Those are correctness properties. The existing default-off
`session_restore_enabled` setting already controls the autonomous and resource-intensive act:
starting agents after reboot.
