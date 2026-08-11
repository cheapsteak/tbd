# Review orchestrator liveness: waiting without ending the turn — design

Status: **proposed**. Written 2026-08-10.

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
which is how the gate runs — ending the turn ends the session, and the specialists die
with the process. No `findings-*.json` is written, `validate.py` finds nothing, and the
gate fails closed.

Measured on PR #604: the review step exited **success** after 184 seconds having written
nothing, reporting `stop_reason: end_turn`, `is_error: false`, 35 turns, and the result
text *"Still running, no findings files yet. I have a monitor armed that will notify me
the moment both appear — continuing to hold rather than write a premature merge."* A
re-run of the same job on the same commit then succeeded in 13m57s and returned a real
REJECT verdict. The specialists need roughly ten minutes; the session gave them three.

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
  review reproduces the failure this design exists to remove.

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

`hooks/stop-hook.sh` splits the single state it recognizes today into three, and adds a
wall-clock deadline. On its first invocation it stamps a start time beside its counter
file.

- **A findings file is missing, and the run is inside 25 minutes** — block **without
  consuming the nudge budget**, with a reason that tells the orchestrator its specialists
  are still running and its turn must continue. This is the repair: an uncounted hold
  keeps the process alive, and the in-flight specialists with it.
- **Every findings file is present and `review-result.json` is missing** — block and
  consume the budget, exactly as today, with today's reason. The model has everything it
  needs and is not writing the result. This is the state the five-nudge ceiling was
  designed for, and it keeps that ceiling.
- **Past 25 minutes** — exit 0 and let the session end. `validate.py` then fails closed.
  The deadline is what keeps an uncounted hold from becoming an unbounded one.

The hook learns which files to expect from `REVIEW_SPECIALISTS`, a job-level environment
variable holding the comma-separated specialist set. The same variable supplies
`validate.py`'s `--expected-specialists`, so the set is declared once rather than
duplicated between a hook and a script that must agree about it.

The hook's existing fail-safe contract is unchanged and constrains every addition: it
always exits 0. Malformed stdin, an absent `jq`, an unwritable counter or stamp file — none
may wedge the session, because allowing a stop is never a gate bypass. `validate.py` fails
closed downstream.

One mechanic carries forward from the fan-out spec's §6 and now covers a second file: a
stale counter sitting at the ceiling silently disarms the hook, so any future loop that
invokes the session more than once must reset both the counter and the start stamp between
invocations. A stale start stamp disarms the hold the same way, by placing the deadline in
the past.

### 3.3 A stall reports as a stall

`validate.py` already separates a lens that never ran from one whose file the schema
rejected, because those send an operator to different places. It gains a third class for
the signature this failure produces: **every** expected specialist absent **and**
`review-result.json` absent. That combination means the session produced nothing at all —
an infrastructure failure rather than a review — and the existing per-lens wording
misdiagnoses it, since its "orchestrator may have merged before all specialists completed"
parenthetical describes a merge that never happened.

All three classes still fail closed and write no verdict. Only the sentence differs, which
is the point: the operator reading a red check must be able to tell a stalled session from
a rejected diff without opening the job log.

### 3.4 The job carries an outer timeout

The `claude-review` job declares `timeout-minutes: 45`. It carries no timeout today, so a
session that wedges rather than ends runs to GitHub's six-hour cap while the author waits
for a check that will never report.

### 3.5 What this corrects in the fan-out spec

[`2026-08-03-pr-review-fanout-design.md`](2026-08-03-pr-review-fanout-design.md) §6
describes a resume-based retry loop as the first upgrade rung, resting on a premise
verified against the real CLI: that the process does not exit while background specialists
are pending, so their findings files land before the post-exit check runs. PR #604 refutes
that premise. Once the Stop hook stops blocking, the process exits with specialists in
flight and their files never land.

That passage is rewritten to state what is now known, so that whoever builds the next rung
does not design on a false premise. The correction also reorders the rungs: this design
occupies the "reviews die incomplete" slot the resume loop was reserved for, and the
interactive PTY driver moves up to the named fallback.

## 4. Testability and verification

The unit tests live beside the code they cover, in
`.github/workflows/claude-review-v2/tests/`, and run in the `Review scripts tests` CI job.

- **The hook's three states**, driven by a temporary workspace: a missing findings file
  inside the deadline blocks and leaves the counter untouched; a complete findings set with
  no result file blocks and increments the counter; a run past the deadline exits 0. The
  counter assertion is the discriminating one — a test that only checks "it blocked" passes
  against today's broken hook.
- **The fail-safe contract**, re-asserted against the new code paths: empty stdin, absent
  `REVIEW_SPECIALISTS`, and an unwritable stamp path each exit 0.
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
  findings files until they appear. The session holds no sleep affordance: `allowedTools`
  carries no `Bash(sleep:*)`, so the poll degrades to a tight loop of `Read` calls that
  burns the turn budget, and each iteration remains a turn that can end. It re-creates the
  failure with more steps.
- **A sleeping Stop hook** — keep background specialists and have the hook sleep and
  re-check, holding the process open without the model changing behavior. It works, but it
  couples the gate to hook-timeout semantics, spends runner minutes sleeping, and risks
  nudging the model into spawning duplicate specialists. The uncounted block in §3.2 buys
  the same liveness without a sleep.
- **Automatic retry of the review step** — recovers the observed case without a human, at
  double the worst-case cost and latency. Rejected mainly because it makes a systematic
  regression present as an intermittent one, which is how a required check quietly stops
  being trusted.
- **Building the resume rung now** — pre-decided in the fan-out spec, but its stated
  premise is what PR #604 falsified (§3.5), so it would need re-verification before it
  could be trusted, and it addresses a session that died with its turns exhausted rather
  than one that ended cleanly having done nothing.

## 7. Out of scope

- **A flag.** This changes a CI workflow rather than compiled daemon behavior; it adds no
  autonomous or destructive action, and the "large or risky new behavior ships behind a
  default-off flag" convention does not reach it.
- **Anything about the specialists' review content.** The lenses, their prompts, the
  severity vocabulary, and the verdict rule are untouched.
- **The stall diagnostic reaching the PR.** The distinct message lands in the job log and
  the step annotation. A stalled run posts no comment, and this design does not change
  that: the post step runs only behind a trustworthy verdict.
