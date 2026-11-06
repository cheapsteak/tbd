# Restore running sessions after a restart

A reboot kills every agent process on the machine. When TBD starts again it parks each Claude
session, and the session stays parked until somebody opens it. A user with many sessions comes
back to a fleet that has stopped, and has to visit each tab to bring it back.

This design adds one setting, off by default. When it is on, the daemon restarts the Claude
sessions that a startup found dead, a few at a time, and leaves alone the sessions that were
already asleep. Each session reloads its conversation and waits at the prompt. TBD types nothing
into it.

## How a restart works today

The startup reconcile pass finds each terminal whose process is gone. A row with a Claude session
to resume is parked with `HibernateReason.recovery`, keeping its session id. Shell and Codex tabs
have no Claude session to resume, so their rows are deleted. Rows that were already parked are
skipped, so a session hibernated before the reboot keeps its own reason: `manual`, `auto`, `merged`
or `exited`.

Nothing then restarts the parked rows. They wake one at a time as the user reaches them: opening a
worktree wakes its visible tab, switching tabs wakes that tab, and clicking a parked pane wakes it.
The sidebar row menu's "Wake all parked" wakes one worktree's sessions, three at a time.

This laziness is deliberate. An earlier build recreated every terminal at once after a reboot. On a
machine with more than 20 sessions that started more than 20 `claude --resume` processes
together, at 0.5 to 1.5 GB each, and exhausted memory (issue #284).

Field measurement from one real reboot on a 48 GB development machine:

- The daemon parked at least 28 sessions in 3.4 seconds, starting 82 seconds after boot.
- 25 older `recovery` rows were still parked beside them, the oldest from August, left by earlier
  restarts and never opened.
- All 28 rows had a transcript path.
- All 28 rows read `activityState = idle`, with `activityStateObservedAt` equal to the moment of
  the park, because parking overwrites both.
- At a later moment on the same machine, 18 `claude` processes held 6.6 GB in total: 0.37 GB on
  average, 0.79 GB at most.

## Behavior

With the setting on, each daemon startup runs one restore pass after startup has finished.

### Which sessions

A row is selected when all of these hold:

- `hibernateReason` is `recovery`.
- `hibernatedAt` is at or after the moment this daemon process began its startup reconcile.
- Its worktree's status is `active` or `main`.
- `claudeResumeDecision` says it can resume.

The time limit is what separates this restart from older ones. Without it, the 25 stale rows above
would come back too, some of them after months. The limit needs no new column: the daemon captures
the time before step 8d and passes it to the pass.

The pass is not tied to a reboot as such. Logout, power loss and a killed holder fleet all leave
the same evidence, and the user wants the same outcome from each. A routine daemon restart restores
nothing, because holder and tmux sessions survive it and so nothing is parked.

### Order

Newest first, by the modification time of the row's transcript file. A row whose file cannot be
read goes last. The activity columns cannot supply this order, because parking overwrites them.

### Pacing

The pass wakes three sessions together, waits for those three wake calls to return, then waits
`sessionRestoreBatchGap`, 10 seconds, before the next three. The batch size matches the
"Wake all parked" action.

The gap is required. A wake returns once the process has started, not once Claude has loaded its
transcript, so batches with no gap would start 28 sessions within seconds and repeat #284. With
the gap, 28 sessions take about 90 seconds.

Both numbers are hypotheses, named as constants, and the soak tests them. The gap sleeps on the
router's injected clock. The total memory is not the concern, because the machine held these
sessions before it restarted. The concern is the burst of starts.

### The switch stops a running pass

The pass reads the flag again before each batch. Turning the setting off during a pass stops it
after the current batch. This is the operator's brake if a restart goes badly.

### Each wake is an ordinary wake

The pass calls `handleTerminalWake`, the handler behind the `terminal.wake` RPC, with the actor
`.daemon(rail: ActuationRail.sessionRestore)`. So each wake gets what any wake gets: one actuation
record, the start-admission check, the session-mod draft path, the row's state broadcast to the
app, and the same outcome classification. No new spawn path exists, for tmux rows or holder rows.

The pass omits `cols` and `rows`, so a session starts at its default size and resizes when a pane
attaches. It omits `prompt`, so nothing is typed.

The pass runs in a detached task as the last step of `Daemon.start()`, after the socket and every
listener are up, and nothing waits for it. Mock mode skips it, as it skips every background rail.

The user may open a worktree during a pass. The wake's own singleflight settles that race: one of
the two calls gets `.inFlight`, or the later one gets `.notHibernated`, and the pass counts it as
skipped.

### Start admission

The restore rail is checked by the start-admission gate
([`2026-10-21-agent-start-admission-design.md`](2026-10-21-agent-start-admission-design.md)).
Daemon actors are otherwise exempt, because their rails were out of scope for that gate. This rail
is the case the gate exists for: a program starting many agents with no gesture. A user who has
written an admission command has already said when the machine is too full, and TBD should not
override that at login. `StartAdmissionActorRule` gains one exception, by rail name, and every
other daemon rail stays exempt. With the admission flag off or no command file, the check does
nothing.

A hold ends the pass when its batch finishes. The held row records its reason, and its parked pane
shows it through the existing "Automatic wake held" line. The rest stay parked with no further
command run. Opening any of them still wakes it, because app wakes are not checked.

### Failure

A session that cannot wake stays parked and the pass moves on: a missing worktree directory, a
missing account profile, a failed spawn. The pass does not retry, shows no alert, and does not fall
back to the default profile. The parked pane is the same one the user sees today.

If the daemon restarts during a pass, the rows it has not reached keep their earlier `hibernatedAt`.
The next startup does not select them, so they wait for the user. Every failure here ends in
today's behavior, never in a tight loop.

The pass ends with one `.notice` log line in the `session-restore` category, giving the counts
selected, woken, skipped, failed and held. A pass that selected nothing logs nothing.

## The setting

The column is `session_restore_enabled`, added by a `.sql` migration with no SQL default, so NULL
keeps meaning "nobody chose". The default lives in `Config.sessionRestoreDefault`, which is `false`,
and `ConfigRecord.toModel()` resolves it. The plumbing follows `queued_prompt_enabled`: the
`Config` model, the daemon capabilities the app reads, a `config.setSessionRestore` RPC, an
`AppState` setter, and a toggle.

The toggle sits in Settings under "Session Hibernation":

- **Label** – "Restart running sessions after a reboot"
- **Caption** – "When TBD starts, Claude sessions that were running come back, a few at a time.
  Hibernated sessions stay asleep."

## How it works with other features

- **Idle sweep.** A restored session gets a full idle window, because the sweep's idle clock is held
  in memory and a wake clears it. A session nobody touches parks again with reason `auto` after
  `hibernateIdleMinutes`. That is the intended outcome, not a conflict.
- **Composer drafts and limit resume.** These act on a woken session as they do today.
- **A second restart during a pass.** Sessions that were woken are running, so the next startup
  parks and restores them. Sessions the first pass never reached are not selected. If a machine
  keeps crashing, each cycle needs a login and a TBD launch, and the pacing leaves time to turn the
  setting off. This design adds no compiled crash-loop breaker.

## What this leaves out

- **Shell and Codex tabs.** Reconcile deletes these rows, so nothing remains to restore. Keeping
  them is a separate design.
- **Continuing work.** A session that was mid-task reloads and waits. Typing "continue" could repeat
  a tool call that was already partly done, and only the user knows whether that is safe.
- **Starting TBD.** The pass runs when TBD starts. Nothing here adds TBD to the login items, and
  until TBD starts, sessions stay parked.

## Placement

Run through [`docs/theory-placement.md`](../theory-placement.md):

- **Whether to restore** is a theory two reasonable users answer differently, so it is the user's
  choice through a toggle, not a compiled answer.
- **Which sessions** is a fact the daemon already holds: the parks this startup made.
- **When the machine is too full** stays the user's own, through the admission command. TBD
  compiles no memory threshold.
- **The batch size and the gap** are tunable numbers, and they guard the daemon's own start
  boundary. They stay compiled as named constants because no consumer has asked to change them.
  A user with a real policy has the admission command.

The pass creates no new kind of durable resource. It starts sessions through the existing wake
path, which `AgentReaper` and `WorktreeLifecycle+Reconcile` already cover.

## Rejected alternatives

- **Recreate terminals inside reconcile.** This is the path #284 removed. It runs before the socket
  binds, so it would also delay startup.
- **An app-side pass.** The app can only infer new parks from timestamps, races the daemon's startup,
  and does not run when only the daemon restarts. The daemon holds the facts.
- **A user-land hook such as `~/tbd/hooks/after-restart`.** It is the most flexible, but it does
  nothing until the user writes a script, and the common wish is a plain on or off. The facts and
  the `tbd terminal wake` actuation remain open to anyone who wants a custom policy.
- **Selecting by boot time.** Comparing `hibernatedAt` with `kern.boottime` would also catch rows a
  mid-run reconcile parked hours later, and wake them at an unrelated daemon restart. The startup
  time asks the question that matters: did this startup park it?
- **A marker column for "parked by this startup".** The timestamp and reason already answer it.
- **Waking only sessions that were busy.** Parking overwrites the activity columns, so the fact is
  gone by the time the pass runs. Preserving it would add state to serve a narrower feature than
  the one wanted.
- **Waiting for each session to report ready.** It would pace to the machine's real speed, but it
  makes the pass depend on one more signal from every session and needs a timeout anyway. A fixed
  gap is simpler, and the soak will show whether it is enough.
- **Capping the number of sessions restored.** The machine ran all of them before the restart, and
  a cap would leave an arbitrary set parked. The pacing addresses the burst, and the cap would not.

## Testing

Flag branches, through the production pass:

- Flag off or NULL: a startup that parks sessions wakes none.
- Flag on: the same startup wakes them.
- A pre-migration row reads NULL, and an explicit `false` survives a change to the default constant.

Selection, each with a row that must be left out:

- A `recovery` row parked before the startup time.
- A row parked with each of `manual`, `auto`, `merged` and `exited`.
- A row in an `archived`, `creating` or `failed` worktree.
- A row that cannot resume.

Pass behavior, on a test clock:

- Batches are three, and the next batch starts only after the gap.
- Order follows transcript modification time, with an unreadable file last.
- Turning the flag off between batches stops the pass.
- A failed wake leaves the row parked and the pass continues.
- A hold records its reason on the row, ends the pass after its batch, and no later batch runs the
  command.
- `.inFlight` and `.notHibernated` count as skipped.
- Each wake's actuation row names the `session-restore` rail.

The admission rule gets its own test: the restore rail is checked, and other daemon rails and the
app actor are not.

A unit test cannot reproduce a reboot, so the soak carries the live check.

## Flag and rollout

- **Flag** – `session_restore_enabled`, default off, `Config.sessionRestoreDefault`.
- **Enable for the soak** – Settings → Session Hibernation.
- **What the soak watches** – across real reboots: the `session-restore` log line, whether the
  machine stays responsive during the pass, and memory pressure for those 90 seconds.
- **Graduation** – the toggle stays after the soak, because on or off is a real preference and
  restarting sessions costs memory at login. Graduation can only mean changing
  `Config.sessionRestoreDefault`, a one-line change that reaches everyone who never chose and keeps
  every explicit choice. Flip it only if several reboots show no memory or responsiveness problem.
