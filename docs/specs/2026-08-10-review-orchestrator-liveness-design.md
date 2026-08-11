# Review orchestrator liveness: waiting without ending the turn — design

Status: **implemented**. Written 2026-08-10.

Brainstormed per `/tbd-brainstorming`; the four decisions in §2 were answered by a human.

Amends the fan-out pipeline described in
[`2026-08-03-pr-review-fanout-design.md`](2026-08-03-pr-review-fanout-design.md), whose
§6 named this failure's upgrade rungs before it occurred. Operational context for the
gate lives in [`docs/pr-review-gate.md`](../pr-review-gate.md).

---

## 1. Problem

The `claude-review` required check intermittently reports red with no verdict, because
the review session ends while its specialists are still running.

The orchestrator spawns two specialist subagents, then ends its turn to wait for their
completion notifications. Interactively a notification re-invokes the session. Headless —
which is how the gate runs — ending the turn ends the session, and no `findings-*.json`
reaches the workspace. `validate.py` finds nothing, and the gate fails closed.

Measured on PR #604: the review step exited **success** after 184 seconds having written
nothing, reporting `stop_reason: end_turn`, `is_error: false`, 35 turns, and the result
text *"Still running, no findings files yet. I have a monitor armed that will notify me
the moment both appear — continuing to hold rather than write a premature merge."* A
re-run of the same job on the same commit then succeeded in 13m57s and returned a real
REJECT verdict. The specialists need roughly ten minutes; the session gave them three.

What that measurement establishes is the empty workspace, not the route to it. Two
readings fit it: the specialists are killed when the process exits, or the action stops
consuming the CLI's output stream once the first result message arrives and so never
takes delivery of their work. A separate diagnosis of the same failure favors the second.
Nothing in this design turns on the answer — under either reading the specialists' output
is lost the moment the orchestrator ends its turn early, and holding that turn open until
the findings files exist is what removes the failure. A design that encoded one mechanism
would be wrong half the time; this one is indifferent to which is right.

Two independent defects produce this, and either alone is survivable.

**The prompt teaches turn-end as the waiting mechanism.** The fan-out step asserts that
Task results return immediately with launch acknowledgments and that each specialist's
completion "arrives later as an automated background-task notification", then instructs
the orchestrator to wait until it has received the notification for both. The only way to
receive one is to end the turn. The instruction *not to merge early* is correct and must
survive any fix: merging on launch acknowledgments yields a verdict from half a review.
What has to change is how the orchestrator waits.

**The Stop hook's give-up ceiling conflates two states.** The hook refuses to end the
session until `review-result.json` parses, but bounds itself to five nudges so a model
that will not comply still terminates. It cannot distinguish that model from one that
*cannot yet* comply because its specialists are still running. Because the budget counts
turns rather than elapsed time, and each nudge costs one short round trip, a hook meant
to prevent a premature end instead imposed a roughly three-minute deadline on a
fourteen-minute job. The bound released a session that was obeying its instructions.

Two properties make this worse than an ordinary intermittent failure. A stall is
indistinguishable from a rejected review at the check level — both are a red
`claude-review` — so the gate's own diagnostics do not say which occurred. And because a
re-run clears it, the pattern trains a maintainer to reflexively re-run a red required
check, which is corrosive to the gate's whole purpose.

The pipeline's liveness also rests on Task-tool scheduling semantics that the repository
neither pins nor controls: the workflow uses `anthropics/claude-code-action@v1`, a
floating tag, so a harness release can change how subagents are scheduled with no change
of ours. A fix that encodes the current scheduling behavior would inherit that exposure.

## 2. Decisions (human-answered brainstorm)

- **Scope** — **smallest change that removes the race**, keeping the single-session shape.
  Restructuring the fan-out into separate workflow jobs stays available but unbuilt; the
  interactive PTY driver is the named fallback if this fix fails to hold (§5).
- **Where the waiting happens** — **the orchestrator's own turn.** Request foreground
  specialists so the tool result carries the findings, and repair the hook so it stops
  counting a legitimately waiting session against a budget meant for a refusing one.
  Rejected alternatives in §6.
- **On a stall** — **fail closed with a distinct diagnostic; a human re-runs.** No
  automatic retry, and no resume loop. An auto-retry doubles worst-case cost and, worse,
  makes a systematic regression look intermittent.
- **Deadlines** — **hook 25 minutes, job 45 minutes.** Roughly 1.8× the observed good
  run for the hook, with a generous outer bound on the job. The threshold errs toward
  paying for a slow review rather than killing a working one, because killing a working
  review reproduces the failure this design exists to remove. A wall-clock deadline is
  only reachable if holding costs wall clock, so each hold sleeps 30 seconds before it
  blocks; §3.2 gives the turn-budget arithmetic that fixes that number.

## 3. Design

### 3.1 The prompt states an invariant, not a mechanism

The fan-out and merge instructions stop describing how the harness schedules subagents.
That description is the version-drifting detail the floating action tag exposes, and the
orchestrator does not need it. Three instructions replace it:

- Spawn both specialists in one message, **requesting foreground execution**, so each
  tool result carries that specialist's output rather than an acknowledgment.
- **Never end the turn while either `findings-<name>.json` is missing.** A Task result
  that reads as a launch acknowledgment means the specialists are still running and the
  turn must continue — it is not permission to stop.
- Merge only once both files exist and parse.

Anchoring on **files on disk** rather than on notification delivery is what makes the
instruction hold whether the harness runs the specialists in the foreground or backgrounds
them anyway. The prohibition on merging early is unchanged in force; only its test
changes, from "a notification arrived" to "both files are on disk".

### 3.2 The Stop hook holds while work is pending and counts only refusal

`hooks/stop-hook.sh` recognizes four artifact states and adds a wall-clock deadline. On
its first invocation it stamps a start time beside its counter file.

- **An expected findings file is missing or unparseable inside 25 minutes** — sleep 30
  seconds, then block **without consuming the nudge budget**, with a reason that tells
  the orchestrator its specialists are still running and its turn must continue. An
  uncounted hold keeps the process alive, and the in-flight specialists with it.
- **Every expected findings file parses and `review-result.json` is missing or
  unparseable** — block and consume the budget with instructions to write the merge. The
  model has everything it needs and is not producing a readable result.
- **Every artifact parses but deterministic preflight rejects it** — run the base
  pipeline's `validate.py` with the same specialist glob and expected-specialist
  declaration used after the session, then block and consume the same budget with its
  exact schema, completeness, or disposition error. Correction instructions preserve
  every finding's ID, severity, and substance; unsupported unique elaboration moves into
  `body` rather than being dropped or replaced.
- **Every artifact passes deterministic preflight** — allow the session to end. The
  preflight runs in an isolated temporary directory, and its provisional `verdict.txt`
  is discarded. The post-session validator, re-restored from the pinned base SHA,
  remains authoritative.

Both counted states share the five-nudge ceiling. Past the 25-minute findings deadline,
the hook exits 0 and lets `validate.py` fail closed downstream. The deadline keeps the
uncounted hold from becoming unbounded.

**The hold sleeps, because a hold costs a turn.** Every hold is a block, and every block
costs one turn of the session's `--max-turns 100` budget — so the scarce resource is turns,
not seconds. PR #604 burned 35 turns in 184 seconds, about five seconds a turn, leaving
roughly 65. Holding at that rate spends those 65 turns in about five minutes of wall clock,
against specialists that need ten: the session would die of turn exhaustion long before a
25-minute deadline could be reached, in exactly the case the deadline exists for, and a
60-hold cap would never be approached either. Sleeping converts a turn into wall clock at
zero token cost, which is precisely the currency the hold is short of. At 30 seconds a
hold, the remaining turns cover a little over thirty minutes, so the 25-minute wall clock
becomes the binding bound as designed.

The same arithmetic keeps the two bounds consistent: 60 holds of 30 seconds is 30 minutes
of sleep against a 25-minute deadline, so the deadline is always reached first and the hold
cap remains what it is meant to be — a backstop against a broken clock, not a second
deadline. The cap also sits below the turns the budget leaves, so neither bound asks for
turns the session does not have.

The sleep makes the hook's command timeout load-bearing, so `hooks/settings.json` declares
one explicitly at 60 seconds rather than relying on a default that a harness release could
move. It must stay strictly greater than the sleep: a hook killed mid-sleep emits no block,
and the session ends — the failure the hold exists to prevent.

The hook learns which files to expect from `REVIEW_SPECIALISTS`, a job-level environment
variable holding the comma-separated specialist set. The same variable supplies
`validate.py`'s `--expected-specialists`, so the set is declared once rather than
duplicated between a hook and a script that must agree about it.

The hook's fail-safe contract is unchanged and constrains every addition: it always exits
0. Malformed stdin, an absent `jq`, an unwritable state file — none may wedge the session,
because allowing a stop is never a gate bypass. `validate.py` fails closed downstream. Two
of those cases have a direction that must be chosen deliberately rather than inherited:

- **State that cannot be written releases the session.** Both bounds are made of persisted
  state, so if the start stamp or the hold counter cannot be written, elapsed time reads as
  zero on every invocation and the hold count never rises — a hook that kept blocking would
  block forever. Giving up costs a failed review that a human re-runs; the alternative
  costs a wedged runner.
- **Without `jq`, a present non-empty file counts as ready.** `jq` is probed once, and both
  the result check and the findings checks fall back to a plain non-empty-file test when it
  is absent. Reading a finished review as unfinished would tell the orchestrator its
  specialists are still running — a falsehood it can act on by re-spawning duplicates —
  and would hold the session for the whole deadline over a missing binary. Content that is
  present but malformed is caught by deterministic preflight when its infrastructure is
  available, and by post-session `validate.py` otherwise; both schema-validate and fail
  closed.
- **Unavailable preflight infrastructure releases the session.** If Python, the trusted
  base validator, or an isolated temporary working directory cannot be invoked, the hook
  stands aside instead of consuming five nudges on a failure the model cannot repair.
  Post-session validation still fails closed.

One mechanic carries forward from the fan-out spec's §6 and now covers three files: the
nudge counter, the start stamp, and the hold counter. Any future loop that invokes the
session more than once must reset all three between invocations. A counter sitting at its
ceiling silently disarms the nudge, a hold counter at its cap disarms the hold, and a stale
start stamp disarms the hold a second way by placing the deadline in the past.

### 3.3 A stall reports as a stall

`validate.py` already separates a lens that never ran from one whose file the schema
rejected, because those send an operator to different places. It gains a third class for
the signature this failure produces: **every** expected specialist absent **and**
`review-result.json` absent. That combination means the session produced nothing at all —
an infrastructure failure rather than a review — and the existing per-lens wording
misdiagnoses it, since its "orchestrator may have merged before all specialists completed"
parenthetical describes a merge that never happened.

All three classes still fail closed and write no verdict. Only the sentence differs, which
is the point: `validate.py` writes the diagnosis into the job log, so an operator looking
into a red check reads a line that names a stalled session as an infrastructure failure
rather than inferring it from an empty workspace. Whether any of that reaches a surface
above the log — a step annotation, a check summary — depends on what the surrounding
workflow step emits and on what GitHub renders; the scripts guarantee the log line and
nothing beyond it.

### 3.4 The job carries an outer timeout

The `claude-review` job declares `timeout-minutes: 45`. It carries no timeout today, so a
session that wedges rather than ends runs to GitHub's six-hour cap while the author waits
for a check that will never report.

The two windows are measured from different origins, and the 25 sits inside the 45 only
because of what separates them. The job's clock starts when the runner picks the job up;
the hook's starts at the session's **first stop attempt**, which is after checkout,
unshallow, token mint, `prepare.py`, and the session's own work up to that point. Twenty
minutes of headroom covers that preamble comfortably today. The job timeout is the outer
backstop for everything the hook cannot see — including a session that wedges without ever
attempting to stop, where the hook's window never starts at all — so nothing depends on the
two clocks agreeing. If the preamble ever grows past that headroom, the symptom is a job
killed at 45 minutes with the hook still holding, which the job log shows plainly; the fix
is to widen the outer bound, not to add machinery for aligning the origins.

### 3.5 What the resume rung may rest on

[`2026-08-03-pr-review-fanout-design.md`](2026-08-03-pr-review-fanout-design.md) §6 keeps a
resume-based retry loop among its upgrade rungs. The tempting premise for such a loop is
that a headless process stays alive while background specialists are pending, so their
findings files are on disk for the next invocation to collect. PR #604 does not support it:
the review step returned success after 184 seconds with both specialists still working, and
the workspace held no `findings-*.json` afterwards. A resume into that state has nothing to
collect.

The rung stays available on a narrower premise. A resume must read the disk and re-fan-out
whatever is missing, never treat a prior invocation's in-flight specialists as work it can
wait on. That is also why the rung sits behind this design rather than ahead of it: holding
the orchestrator's own turn open removes the die-incomplete case at its source, while a loop
that restarts the fan-out pays for a second review to arrive at the same place. The
interactive PTY driver is the fallback beyond both, because a session that wedges rather
than ends is unreachable from between invocations.

## 4. Testability and verification

The unit tests live beside the code they cover, in
`.github/workflows/claude-review-v2/tests/`, and run in the `Review scripts tests` CI job.

- **The hook's four artifact states**, driven by a temporary workspace: a missing or
  unparseable findings file inside the deadline blocks and leaves the counter untouched;
  a complete findings set with a missing or unparseable result blocks and increments the
  counter; parseable artifacts rejected by deterministic preflight block with its exact
  error and increment the same counter; valid complete artifacts allow the stop without
  leaving a workspace `verdict.txt`. Repeated counted failures release after five blocks.
  The counter assertion is the discriminating one — a test that only checks "it blocked"
  passes against a hook that conflates these states.
- **The sleep and the bounds it interacts with.** A pending hold takes at least its
  configured sleep before emitting the block; a run past the deadline, and one at the hold
  cap, each return promptly and release, proving both bounds are tested before the sleep
  rather than after it. The unit tests drive the duration to zero through an environment
  variable so the suite stays fast, so two further assertions pin what the tests cannot
  exercise: that the shipped default is 30 seconds with no configuration, and that
  `settings.json` declares a hook timeout strictly greater than it.
- **The fail-safe contract**, in a form that can fail. Exit code 0 alone is not an
  assertion here — every path of the script exits 0, so a test that checks only that passes
  against a hook that holds forever. Empty stdin and an absent `REVIEW_SPECIALISTS` are
  asserted on behavior, and the unwritable-state case loops invocations until it observes
  an actual release, the same shape as the broken-clock case.
- **The `jq`-absent fallbacks**, run against a `PATH` carrying every other hook
  dependency: valid complete artifacts end the session, schema-invalid artifacts receive
  exact validator feedback through the counted correction nudge, a complete findings set
  with no result receives the merge nudge, a missing findings file still holds, and an
  empty result file does not count as written.
- **Unavailable preflight infrastructure**, covering a missing Python runtime or trusted
  validator, a validator that cannot execute normally, and a temporary directory that
  cannot be created. Each releases with exit code 0 and leaves the nudge counter untouched.
- **`validate.py`'s new class**, and the two existing ones, so the third does not swallow
  them.
- **`timeout-minutes` and the `REVIEW_SPECIALISTS` wiring**, as structural assertions in
  `test_workflow_structure.py` — including that the value reaching `--expected-specialists`
  and the value reaching the hook come from the same declaration.

**The gate cannot test itself.** The workflow restores
`.github/workflows/claude-review-v2/` from the base branch before the session and again
after it, so this change does not affect its own PR's review, and a green check on that PR
proves nothing about it. The hook's live behavior is therefore proven before merge with a
throwaway `on: push` workflow that runs the real session against a small diff and asserts
that the session outlives its specialists. Unit tests establish that the hook's logic is
right; only a live run establishes that an uncounted block actually holds the process open.

A second consequence is worth stating because it looks like a failure: this fix reaches the
gate only after it merges. A PR blocked by the bug is recovered by an admin merge, not by
re-running the check — though a re-run may also clear it, since the failure is a race.

## 5. If this does not hold

The residual risk is precise. The prompt asks the harness for foreground specialists, and
the hook holds the process open if it gets background ones instead; both legs depend on
harness behavior that a floating action tag can change. If reviews stall again, the next
rung is the **interactive PTY driver** named in the fan-out spec's §6 — a driver that runs
the session under a pseudo-terminal and can nudge or steer it mid-flight, reaching wedged
sessions that a between-invocation loop cannot. That machinery was descoped from the
original fan-out design as heavier than this repository's PRs need; a second stall class
would be the evidence that reverses that judgment.

The intermediate option, unbuilt and available, is to move the fan-out into the workflow:
each specialist its own job, the orchestrator running afterwards over files that already
exist. That removes the race by construction rather than by instruction, at the cost of
repeating the trust, checkout, and restore sequence per job.

## 6. Rejected alternatives

- **A bounded poll loop in the prompt** — instruct the orchestrator to poll for both
  findings files until they appear. The model has no sleep affordance of its own —
  `allowedTools` carries no `Bash(sleep:*)`, and the hook's sleep (§3.2) is the harness
  waiting between turns, not something the orchestrator can invoke — so the poll degrades
  to a tight loop of `Read` calls that burns the turn budget, and each iteration remains a
  turn that can end. It re-creates the failure with more steps.
- **Raising `--max-turns` instead of sleeping** — buy the hold its wall clock by giving the
  session more turns rather than by spending fewer. Every hold is a real model round trip,
  so the cost scales with the budget, and the number that would have to be guessed is the
  product of two unknowns: how long a review takes and how fast the harness turns holds
  over. The sleep fixes the seconds-per-hold directly, which is why 60 holds and 25 minutes
  can be stated as a single arithmetic rather than as a hope about pacing. The budget stays
  where the fan-out spec set it, sized for review work rather than for waiting.
- **Automatic retry of the review step** — recovers the observed case without a human, at
  double the worst-case cost and latency. Rejected mainly because it makes a systematic
  regression present as an intermittent one, which is how a required check quietly stops
  being trusted.
- **Building the resume rung now** — available in the fan-out spec, but the premise that
  makes it cheap is the one PR #604's empty workspace does not support (§3.5), so a resume
  would have to re-run the fan-out rather than collect it. It also addresses a session that
  died with its turns exhausted rather than one that ended cleanly having done nothing.

## 7. Out of scope

- **A flag.** This changes a CI workflow rather than compiled daemon behavior; it adds no
  autonomous or destructive action, and the "large or risky new behavior ships behind a
  default-off flag" convention does not reach it.
- **Anything about the specialists' review content.** The lenses, their prompts, the
  severity vocabulary, and the verdict rule are untouched.
- **The stall diagnostic reaching the PR.** The distinct message is written to the job
  log, where an operator investigating the red check reads it. A stalled run posts no
  comment, and this design does not change that: the post step runs only behind a
  trustworthy verdict.
