# Tests

## Shared-box hazards

Reproducing a flake means inducing load, and this box runs several agent
worktrees at once. Every entry below was paid for during the test-hardening
program. They are one family, not four anecdotes — the next variant will be a
fifth way to kill or mismeasure something you did not mean to.

### The kill hazards

**One rule covers all of them: kill by captured PID or by your own process
tree (`pkill -P $$`). Never by name pattern, never by process group.**

- **`kill $(jobs -p)`** — job control is OFF in the non-interactive tool shell,
  so `jobs -p` returns nothing, `kill` reaps nothing, and every backgrounded
  `&` child orphans to launchd and runs forever. (Once leaked 22 `yes`
  processes at ~850% CPU for a week.)
- **`trap 'kill 0' EXIT`** — signals the whole process group, which includes
  your own tool shell. This file used to recommend it; it does not any more.
  It cost this program a stress run, and two slices had it in their plans.
- **`pkill -f <pattern>`** — matches **across worktrees**. Every worktree
  builds identically-named bundles, so `pkill -f TBDPackageTests` kills a
  sibling agent's test run. Cost: ~70 minutes of someone else's work.
- **Orphaned subagent subtrees** — stopping a parent *orphans* its children
  rather than killing them, and the orphans keep obeying the rules that were
  in force when they were spawned. An agent audited its own load, stopped the
  subagent it knew about, verified `pgrep` was clean, and still contaminated
  the box.

That last one generalizes into three habits worth more than the rule itself:

1. When a coordination rule lands, enumerate what is actually **running** —
   processes, not your mental model of your agents.
2. A stop is not a guarantee the subtree is gone. **Re-check after stopping.**
3. Judge by **capability, not current behaviour**. An idle child that can fire
   a build is a load generator that happens to be between jobs — `pgrep` came
   back clean only because the children were momentarily between builds.

For a long-lived helper, prefer the Bash tool's `run_in_background` option,
which the harness tracks and reaps. The `jobs -p` shape is also blocked
mechanically at PreToolUse time by the `background-jobs` rule in
`.claude/hooks/guardrails`.

### The same class, without a signal: the machine lying in your vocabulary

A shared box also breaks builds in ways that read as broken code.

- **Disk at 100%** surfaces as `generate-dSYM command failed` and `link
  command failed` — errors that look exactly like a bad diff. **If a build or
  link dies strangely, check `df` before debugging the diff.**
- **Load average in the hundreds** turns clock-driven suites red on their
  arming handshake, and CI-contention reds look like real assertion failures.

Same family as the kill hazards and as the instrument-calibration failures
below: the machine failing in the vocabulary of your own code. When your slice
merges and you stand down, delete your own `.build` — and reclaim only your
own, never a sibling's, because a rebuild costs them ~2 minutes and silently
invalidates any measurement they are midway through.

## Test tiers

Three tiers, defined by what a test may touch: tier 1 (deterministic,
in-process state only — no real sleeps, subprocesses, tmux, network, or
`~/tbd`), tier 2 (in-process integration — real concurrency, real filesystem,
real git subprocesses, deadlines only via bounded waits), tier 3
(live-external — real tmux server, real `ps`, spawned processes, the replay
firehose). Full taxonomy: `docs/specs/2026-07-24-test-hardening-design.md` §3.

Tier 3 suites live in `Tests/TBDDaemonLiveTests/`. A suite belongs there if
and only if its runtime depends on an external process it does not fully
control: it spawns a real tmux server, shells out to `ps`, spawns a child
racing a deadline, or drives the replay firehose. CI runs that target
serially on an otherwise-idle machine, in a separate step from the fast
parallel pass.

That step passes `--no-parallel` explicitly. Omitting `--parallel` is **not**
equivalent: SwiftPM's `--parallel` governs XCTest's process-level sharding,
while Swift Testing parallelizes suites in-process regardless. Measured here,
the difference is all 17 live suites starting simultaneously versus running
one at a time.

The failure asymmetry is the thing reviewers get wrong: leaving a heavy suite
in the parallel pass is merely the status quo, but moving a fast
deterministic suite into the serial pass taxes every PR forever. When in
doubt, leave it in the parallel pass.

## Population is the scheduler, and it is a moving target

Swift Testing runs every non-serialized test in **one process with no
concurrency cap**, and all targets compile into that process. So per-test
scheduling latency scales with the *total* population, not with the suite you
are looking at. Mined CI runs put p50 per-test reported duration at ~1/3 of
total wall time on green runs as well as red — a trivial test "takes" 16–29 s
because it is mostly suspended waiting for a turn. Population went 3013 → 4536
in three weeks. Two consequences, both load-bearing.

**The fast pass is two sequential steps in one job.** `test.yml` runs
`--filter '^TBDDaemonTests\.'` then
`--skip '^(TBDDaemonTests|TBDDaemonLiveTests)\.'`, sharing one build.
Halving the in-flight population halves the tail: measured under induced load
with arms interleaved, means over 5 iterations, p90 26.4 s → 14.6 s and p50
8.8 s → 7.6 s, for **+26 s** of wall time (56 s → 82 s — the second invocation
re-pays SPM's no-op build check and process startup). Quote that figure, not the
+6 s a single iteration showed; it did not survive the other four. This is not
the "sharding across runners" that
`docs/specs/2026-07-24-test-hardening-design.md` §1 rejected and §2 lists as a
non-goal — that was about extra *jobs* paying the 5-concurrent-macOS-job cap and
a second ~2 min build. **Step 2 is a complement, not an enumeration, and that
is deliberate.** Two `--filter` lists would have reintroduced the hazard the
spec's §3 names when it calls the target boundary "compiler-enforced, cannot
silently zero-match like a `--filter` regex": `swift test --filter` exits GREEN
on zero matches, so a new `TBDFooTests` named in neither list would run in
**neither** pass with nothing going red — and the floors could not catch that,
because adding a target reduces no existing step's count. Written as a
complement, step 2 absorbs any new target automatically, and the three passes
partition the package by construction. The per-step floors have a narrower job:
catching a target that *is* named in one of these regexes collapsing or being
renamed, where the regex would zero-match or over-skip its way to a green run
of nothing. Keep them updated.

**Wall-clock handshake deadlines are hang-catchers sized against the population
of the day.** `ciSafeDeadline` (`Tests/TBDDaemonTests/ControlModeTestSupport.swift`)
and `waitForSuspension`'s `timeout` / `.clockDriven`'s limit
(`Tests/TestSupport/ClockTestSupport.swift`) bound a hang; they assert nothing
and cost passing runs nothing. They are the first things to re-derive when the
population moves materially — that is what turned the `ControlModeInputHealth`,
`ControlModeInputRouter` and "Archived search debounce" reds into a ~42% red
rate on `main` with **zero** logic assertions failing.

**Derive the three together, and know the invariant.** They are currently
`ciSafeDeadline` 90 s, `waitForSuspension` 45 s, `.clockDriven`
`.timeLimit(.minutes(4))` = 240 s. The suite limit and the two wait deadlines
race each other for real: `AttachRPCOrchestrationTests` and
`PaneRepairCoordinatorTests` are both `.clockDriven` **and** consume
`ciSafeDeadline`, across 48 `waitFor` call sites. Every one of those sites is
unguarded — `waitFor` is `@discardableResult` and non-throwing on timeout, so
the test continues and chained waits are real (the `try` covers only the inner
`Task.sleep`).

The rule is **not** "all N chained waits must fit inside the suite limit". That
was never satisfiable — the deepest chain is 6 waits in one
`PaneRepairCoordinator` test, and 6 × 30 s already blew the old one-minute
limit. The rule is:

> The suite limit must afford the **first** full deadline plus the rest of an
> ordinary test. The first timeout's `Issue.record` fires immediately and
> carries the named diagnostic, so it always survives even if the limit later
> truncates the test. Chains beyond the first belong to a test that is already
> failing; truncating those is acceptable and deliberate.

Checked against 240 s: one `waitFor` + one `waitForSuspension` = 135 s ✓; two
`waitFor` = 180 s ✓; two `waitForSuspension` = 90 s ✓ (this is the "a test that
waits twice must afford both waits" property the old pairing was reasoned
from).

**Past that pair the margin is thin — 240 s is not roomy, and the real numbers
are worth knowing before someone reaches for a raise.**
**Count `advanceWhenSuspended` as a `waitForSuspension`** — it opens with one
(`await waitForSuspension(...)`, then `advance`), so it pays the full 45 s
guard. Grepping only for the literal `waitForSuspension(` undercounts every
chain below, which is exactly the miscount a PR #547 reviewer made.

On that basis: `GatedIntervalSleepTests.returnsAfterExpectedPollCount`
(3 `advanceWhenSuspended` + 2 `waitForSuspension`) and
`DaywatchRunnerTests.testSubsequentTicksAtInterval` (2 + 3) each pay **5**
guards, i.e. 225 s of the 240 s ceiling. And counting `waitFor` at 90 s plus
each clock wait at 45 s, **9 of the 13** `PaneRepairCoordinatorTests` have a
worst case above 240 s — not just the 6-deep chain (540 s) usually cited. Every one of those is still consistent with
the invariant, because only an already-failing test walks a full chain of
timeouts and the first diagnostic is already recorded by then.

**The remedy if they start tripping is to shorten the chain, not to raise the
limit again.** "Keep advance chains short — single digits" below is already the
rule, and a 5-deep chain sits at its edge; inject pacing values and cross the
threshold in 2–3 advances. Raising 240 s buys room only for tests that are
already failing, and taxes every genuinely wedged test with a longer wait
before it gets attributed.

**All three are sized for the fast parallel pass, so tier 3 opts out.** The
quiet pass (`--no-parallel`, idle machine) never sees the saturation that forced
`.clockDriven` up, and a tier-3 suite whose time limit is its *regression
detector* rather than a hang guard is actively harmed by the raise — it disarms
a mutation-verified proof with nothing going red. Those pin their own
`.timeLimit(.minutes(1))`: `SubprocessTimeoutStarvationTests` (a `sleep 90`
child must outlive the limit), `GitManagerTimeoutTests` and
`SubprocessTimeoutTests` (a regressed EOF-waiting drain must outlive it). Don't
"tidy" them back to `.clockDriven`; the residual — that 45 s makes two chained
`waitForSuspension`s exceed 60 s — is acceptable only because none of those
suites chains two and a healthy handshake there returns in milliseconds.

Three remedies are already refuted; don't re-litigate them.

- **Per-suite `.serialized`.** "Archived search debounce" is already
  `.clockDriven, .serialized` and still failed twice in CI. The contention is
  process-global, so serializing one suite does not shrink the queue its waiter
  sits behind. (The advice under "Clock and date seams" still holds for its own
  case — a suite starving *itself*.)
- **`TASK_MEGA_YIELD_COUNT=1`.** Measured across interleaved runs: p90
  26.5/31.2 → 26.0/29.4, p99 26.6 → 27.0. Noise. Real but secondary
  contributor; resolves the open question in issue #496.
- **Blanket retry.** Banned in every tier — see "Quarantine" below.

**The measurement method is the transferable part.** Arms must be
**interleaved, not batched**, with population held constant. An earlier attempt
at this same comparison ran each arm as a block and was invalidated by
uncontrolled load drift from sibling agents on the shared box — the arms
measured different machines, not different configurations.

New tests should state their tier. Tier-1 tests put no real sleep in the
*behaviour under test* — the code under test is driven entirely by virtual
time. The scheduling handshake that observes it may still sleep; see "Clock and
date seams" below for why that is not a tier violation.

## Quarantine — `.flaky(issue:)`

There is no blanket retry policy, in any tier, and there will not be one:
a retry that nobody named hides a regression, because a test that started
failing 40% of the time when someone broke the code is indistinguishable from
one that was always 40% flaky. A tier-2 test that genuinely needs a retry gets
named quarantine instead.

```swift
@Test(.flaky(issue: 512))
func attachRacesSupersession() async { … }
```

The body re-runs up to 3 times total; the first two failures are suppressed as
known issues and the third is surfaced normally, with its real source location.
**The issue number is required — that is the entire honesty mechanism**, and it
is what lets the nightly audit flag a `.flaky` whose issue is closed, or one
that passed first-try all week, for removal. Anonymous quarantine is a
permanent blind spot.

Rules:

- **Tier 2 only.** A red tier-1 test is a bug, full stop. Tier 3 already has
  its own serial target. Never quarantine either.
- **Open the issue first**, and put the diagnosis in it. Quarantine is a
  deadline, not a resting place.
- The trait is `TestTrait` only, never `SuiteTrait` — a quarantined *suite*
  would let one annotation silence twenty tests.
- **Do not quarantine a test that reports failures from an escaping `Task`.**
  Suppression is scoped to the task tree, and it breaks in both directions
  there. Full detail is in the trait's doc comment,
  `Tests/TestSupport/FlakyTestSupport.swift`.

Every execution of a `.flaky` test — including clean first-try passes, which
are what prove a flake is fixed — appends one JSONL record to
`$TBD_RETRY_METRICS_PATH` (set at the job level in CI, unset locally, where the
trait does no work). Keys: `schema`, `testID`, `issue`, `attempts`, `outcome`
(`passedFirstTry` | `passedOnRetry` | `failed`), `file`, `line`. **That schema
is a consumed API** — the nightly quarantine audit reads it, so adding a key is
fine and changing or removing one means bumping `schema`.

One record in that ledger is *not* a flake report:
`TBDDaemonTests.FlakyQuarantineSelfTests/retriesUntilPass()` is the mechanism's
own self-test, which fails once and passes on retry by design on every run so
that a quarantine mechanism that silently stopped retrying cannot look
identical to a working one. Its issue (#499) is a permanently-open fixture
anchor. **The audit must exclude that exact test ID and no other.**

The same file's `alwaysFails()` fixture shares issue #499 and is deliberately
**not** excluded. It is gated off by `TBD_FLAKY_SELFTEST_FAILURE` and nothing in
CI sets that, so it should contribute no records at all — if `failed` records
for it ever appear in the ledger, the gate has leaked into CI, and the audit
should **report that** rather than filter it away. An exclusion list that grew
to cover it would turn a broken gate into silence.

## Assertion hygiene

Four rules. Each traces to a real flake — provenance kept so the rule sticks.

1. **Assert contracts, not incidents.** Prefer membership (`contains`) over
   `.last` or positional/ordering assertions unless ordering is the
   documented contract. (The paste-failure flake: `delete-buffer` and the
   follow-up keystroke are order-independent effects, so pinning `.last`
   pinned an incident.)
2. **No wall-clock freshness windows.** Bracket with `[before, after]`
   captured around the call, or inject the date. (`resolve_success_bumpsLastUsedAt`
   blew a 5-second window by 0.11 s under CI load.)
3. **No bare `Task.sleep(for:)` as a synchronization primitive in tests.**
   Tier 1 advances a test clock; tiers 2–3 use bounded polling with a
   deadline (`waitFor` style). In `Sources/` this is now mechanical — the
   `no_raw_task_sleep` SwiftLint rule rejects any unsuppressed `Task.sleep`.
   In `Tests/` it stays a review rule: the lint rule deliberately does not
   cover test code, where tier-2/3 bounded polling is legitimate. See
   "Clock and date seams" below for the seam the rule pushes you toward.
4. **Timeout errors must report observed state, not just expected — and the
   report has to survive into the CI summary.** Two halves; the second is the
   one you satisfy accidentally-wrong.

   *Observed, not expected.* `fileBytesMismatch(expected: 6150, actual: 6150)`
   re-read the file *after* the deadline and therefore lied about what it saw;
   `fileBytesUnmatched(expected:observed:correctPrefix:)` is the corrected
   shape.

   *Reaching the summary.* Only `Issue.record(_: some Error)` puts your text on
   the **primary** failure line. Both `#expect(cond, "message")` and
   `Issue.record(String)` demote the message to a trailing `↳` line that **CI
   summaries drop** — measured with a render probe, not assumed. So the
   thrown-`Error` shape this rule already cites is **load-bearing, not
   incidental**: the error is what carries the diagnostic to the place you will
   read it. The failure that established this arrived in CI as bare
   `condition(value → 0)` and `condition(value → 2)`, distinguishable only by
   column number, from two `#expect` calls whose message strings were perfect.
   Verified rendering of the corrected shape:

   ```
   Caught error: FileWatcher: exactly one FD closed (baseline 0) — observed 1
   after polling up to 25.0 seconds
   ```

   Scope: this applies to **timeout and bounded-wait diagnostics**, where the
   expression (`condition(value → 0)`) is uninformative by construction and the
   message *is* the whole finding. It is not a ban on `#expect(cond, "…")` for
   ordinary assertions whose expression already describes itself. There is no
   lint rule for it, deliberately — nothing can mechanically tell a timeout
   diagnostic from an ordinary assertion, and a rule that fired on both would
   be one people disable.

   Consequence for tooling: anything that reads a **CI summary** to extract
   diagnostics will not find them in the `#expect` form. (Readers of the full
   tee'd log are unaffected — the `↳` line is present there.)

Full rationale: `docs/specs/2026-07-24-test-hardening-design.md` §6.

## Clock and date seams

Governing rule: **`Duration` is behavior, `Date` is data.** The two seams are
not interchangeable — picking the wrong one is how a test ends up measuring
elapsed wall time on a loaded runner instead of asserting behavior.

### Behavior — delays, debounces, timers, polling intervals, timeouts

```swift
init(..., clock: any Clock<Duration> = ContinuousClock())
```

Last initializer parameter, named `clock`, defaulted so no call site changes
and the migration is behavior-preserving by construction. **Existential, not
generic**, and not named `scheduler`: these subsystems are actors carrying
`Sendable` conformances, and a generic parameter would infect their types.

Tests pass `TestClock` and drive time with `advanceWhenSuspended(by:)`, which
buys exact virtual timings instead of tolerance windows.

**Where the real sleeps went — the distinction to keep straight.** "No real
sleeps" applies to the *behaviour under test*: it never waits on wall time, so
its assertions are exact and load-independent. It does **not** mean the process
never sleeps. `advanceWhenSuspended` has to observe that the code under test
has actually reached its `sleep`, and that is real task scheduling, not virtual
time — so it polls with a real `Task.sleep` against a deadline (bounded
polling, rule 3 above). Spinning `Task.yield()` there instead does not
converge: it keeps the waiter runnable and re-queues it behind the very task it
is waiting for, and raising the budget makes it worse, not better.

Consequence to design around: clock-driven suites are load-**tolerant**, not
load-**independent**. `TestClock.advance(to:)` calls `Task.megaYield()` twice
per advance inside swift-clocks — 20 background-QoS tasks each — so a large
population of clock-driven tests running in parallel floods the pool with
exactly the low-priority work each one is waiting on, and they starve each
other. If a clock-driven suite fails on the arming handshake, reach for
`@Suite(.serialized)` before reaching for a longer timeout: it narrows that one
suite rather than the target, and measured on the appearance suite it was both
reliable *and* faster.

That advice covers a suite starving **itself**. It does not cover
process-global saturation, where a suite starves on the other 4000 tests — see
"Population is the scheduler" above, where an already-`.serialized` suite still
flaked and the remedy was population, not suite ordering.

**Keep advance chains short — single digits.** If crossing a threshold would
take many production-sized intervals, **inject the pacing values** (that is
what the interval init parameters are for) and cross it in 2–3 advances rather
than 100.

Measured: 100 tight `advanceWhenSuspended` iterations, accumulating a 5 s
threshold out of 50 ms production intervals, passed in **0.626 s unloaded and
hung past 10 minutes under 12 spinners**. The helper was behaving exactly as
specified — it is non-throwing by design, so under load, if the code under test
does not re-park within its yield budget, it records an `Issue` and *continues*;
`advance` then moves `now` with no sleeper registered, and the sleep that
arrives afterwards is scheduled against the new `now` and never fires.
Permanent desync. The defect is emergent, not a helper bug: one advance has a
small miss probability, one hundred makes it near-certain. That is a property
of the *usage*, which is why it is a written rule rather than a helper fix.

**The counter-rule, because following the above naively degrades coverage.**
Shortening a chain silently buys a weaker assertion — and it degrades
invisibly, because the test still passes. One migrated test named for having
"no deadline" ended up running 4 iterations totalling 150 ms virtual and never
reaching the 5 s threshold its own docstring claimed. Whenever you shorten a
chain, check that the test still crosses the thresholds its name and docstring
claim; if it does not, inject pacing sized to span them within the same 3–5
advance budget. Short chain *and* strong claim — you do not have to trade them.

**The failure signature is the part to internalize:** this did not present as a
red test. It presented as a **hang**, and in the stress log as a silently
truncated iteration with no `Test run with N tests` summary line — which a
naive `rc == 0` check counts as a pass. It was caught only because the harness
asserted the executed test count per iteration. **A truncated log or a missing
summary line is a failure, not a pass.** Any harness, corpus runner, or stress
loop must treat "no summary" as red.

**The existential pins `Duration`, not `Instant`** — so it can express delays
but not deadlines:

| Compiles | Does **not** compile (`#ExistentialMemberAccess`) |
|---|---|
| `try await clock.sleep(for: .seconds(1))` | `clock.sleep(until:tolerance:)` |
| `clock.now`, storage in an `actor` | `instant.duration(to:)` |

Write timeout-shaped code duration-relative, as a task-group race:

```swift
group.addTask { try await work() }
group.addTask { try await clock.sleep(for: limit); return nil }
let first = try await group.next()
group.cancelAll()
```

This is also the better *test* shape: "time out after X" is directly
advanceable on a `TestClock`, while "sleep until instant Y" invites `Instant`
arithmetic that drifts back toward wall-clock reasoning. If you hit a case
that genuinely needs `Instant` math, raise it rather than switching the
subsystem to a generic clock parameter.

### Data — timestamps that get persisted or compared

Two shapes, also not interchangeable:

- **One-shot stamp** (`lastUsedAt`, hibernation stamps): a defaulted method
  parameter, `func touchLastUsed(at date: Date = Date())`. Tests pass a
  literal. No clock object needed to stamp a row.
- **Repeated "what time is it now" reads**: `now: @Sendable () -> Date` on the
  type. Tests back it with `TestDateSource`.

### Shared test helpers — `Tests/TestSupport/ClockTestSupport.swift`

Don't roll your own test clock wrapper, advance helper, `.timeLimit` default,
or date box. This file is the whole shared surface:

- `@Suite(.clockDriven)` — a four-minute time limit (Swift Testing expresses
  limits in whole minutes, so that is the dial). A hang-catcher, not a perf
  budget; sized against the wall-clock waits a clock-driven test can sit on in
  the **fast parallel pass** — see "Population is the scheduler" above for the
  triple, its invariant, and the three tier-3 live suites that pin their own
  `.timeLimit` instead because their limit is a regression detector.
- `await clock.advanceWhenSuspended(by:)` — the one you want by default.
- `await clock.waitForSuspension()` — the same wait without advancing.
- `TestDateSource` — a lock-guarded box behind the `now: @Sendable () -> Date`
  seam. Deliberately a class with a lock rather than an actor, because that
  seam is a *synchronous* `() -> Date`.

**The failure mode to design against:** a tier-1 test awaiting a `TestClock`
sleep that nobody advances hangs forever. Two mitigations, use both —
`.clockDriven` on the suite bounds the hang, and `advanceWhenSuspended` turns
"the code under test never armed its timer" from an infinite hang into a named
failure. Convention: **put the advance immediately next to the assertion it
unblocks**, not in a setup block far away.

**`.clockDriven` is not a reliable backstop on its own** — known limitation,
measured: a desynced advance chain hung past 10 minutes with the trait applied
and the then one-minute limit never fired (the hung work most likely sits in a
detached task the time limit cannot cancel). It usually works and is worth
keeping. Do not make it your *only* hang guard: stress harnesses, corpus
runners and fuzzers need an outer timeout of their own.

One caution on those two helpers: they record an `Issue` and continue rather
than throwing, which is safe *only* because neither returns a value. A
non-throwing waiter that does return something — `ControlModeTestSupport.waitFor`
(PR #415) — also keeps going after recording, so anything you index out of its
result must be `#require`-guarded or the test crashes instead of failing
cleanly. Don't generalize "non-throwing" into "no `#require` needed".

**And the crash is the *good* case.** The nastier one is that execution
continues far enough to produce a second, plausible-looking assertion failure
that misattributes the cause. A real instance: a waiter timed out having
collected one event instead of two, the discarded `false` return let the test
carry on, and the visible failure was `[42] == [42, 42]` — which reads as a
generation-numbering bug and sends the reader to the wrong line entirely. A
crash announces itself; this does not. **The tell was the duration**: 62 s for
what should have been a fast assertion failure, i.e. two bounded waits timing
out back to back against the 30 s `ciSafeDeadline` of the day (90 s now, so the
same signature is ~180 s). When an assertion failure took far longer than an
assertion failure should, suspect a swallowed waiter before you believe the
message.

`PollerClock` is **not** this seam and must not be copied as a template — see
its doc comment. Full rationale:
`docs/specs/2026-07-24-test-hardening-design.md` §5.
