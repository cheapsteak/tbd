# Retire the polling test clock

Clock-driven tests use one clock, `EventDrivenTestClock`. swift-clocks'
`TestClock` stays only in the files that test it. A SwiftLint rule keeps it out
of everything else.

Related: [`2026-08-11-event-driven-test-clock-design.md`](2026-08-11-event-driven-test-clock-design.md)
(the clock itself), [`2026-10-07-flake-autofix-design.md`](2026-10-07-flake-autofix-design.md)
(the ledger whose records are the evidence here), and `Tests/CLAUDE.md`,
"Clock and date seams" and "The event-driven alternative".

## 1. Why

`TestClock.advanceWhenSuspended` finds out that the code under test has reached
its `sleep` by polling `checkSuspension()`. Each poll is a `megaYield`: twenty
serially awaited background-QoS tasks. In a saturated parallel pass, those
probes compete with the sleeper they are waiting for, and the 45 s arming guard
fires although the logic under test is correct. `EventDrivenTestClock` signals
arming from inside the critical section that registers the sleeper, so the wait
is a continuation, not a poll.

Field evidence from the flake ledger, gathered over its first week of records:

- **Share of failures.** 529 of the 850 recorded failures (62%) carry the
  TestClock arming-guard message. The next largest group, Swift Testing's
  `.timeLimit` (150), is mostly the same starvation seen one level up.
- **Spread.** Of the 32 test files that still use `TestClock`, 21 already have
  at least one test that hit the guard.
- **Fixes.** Every flake-fixer PR so far that touched a clock-driven test made
  the same move to `EventDrivenTestClock`.
- **Inflow.** New uses keep arriving. In one month, seven feature PRs added
  17 `advanceWhenSuspended` calls, because the guidance allowed either clock
  for new tests.

The ledger's counts lean on the nightly stress loop, which loads the machine on
purpose, so they overstate how often each test flakes on an ordinary CI run.
They do not overstate which shape flakes: the per-PR records point the same way.

Migrating suite by suite on field evidence made every one of those suites earn
its migration by failing first. With most of the remaining files already
failing, that costs more than migrating the rest outright.

## 2. The rule

- `EventDrivenTestClock` is the clock for any test that drives an injected
  `any Clock<Duration>` through sleeps.
- Tests use the strict forms: `requireAdvanceWhenArmed(by:timeout:)`,
  `requireSleeperArmed`, and the helpers in §4. A missed arming throws a named
  `NoSleeperArmed` and ends the test with one clear failure. Tests that use
  them are declared `throws`.
- `@MainActor` code under test passes `timeout: TestDeadlines.saturatedPass`,
  as `Tests/CLAUDE.md` already requires.
- `ImmediateClock` remains allowed. It never waits for arming.
- `TestClock` remains only in `Tests/TBDDaemonTests/ClockTestSupportTests.swift`
  and `Tests/TestSupport/ClockTestSupport.swift`, which test it.

`Tests/CLAUDE.md` states this rule as the default. Its passages that offer
either clock for a new test, that defer migration to field evidence, and that
open "Tests pass `TestClock` and drive time with `advanceWhenSuspended(by:)`"
are rewritten to describe the event-driven clock. The list of suites migrated
one at a time is reduced to the worked examples a reader needs. The 2026-08-11
spec is edited to match, stating the current design rather than recording the
change.

## 3. Lint rule

A SwiftLint custom rule, `no_polling_test_clock`, in `.swiftlint.yml`:

- **Matches** construction of `TestClock` and calls to `advanceWhenSuspended`,
  `waitForSuspension` and `checkSuspension`, in `Tests/`.
- **Excludes** the two files named in §2.
- **Runs** in the `lint` CI job and the pre-push hook, next to
  `no_raw_task_sleep`, under `swiftlint --strict`.

The rule lands before any migration. Every existing match gets a suppression
on the line above it:

```swift
// swiftlint:disable:next no_polling_test_clock - legacy, #<tracking issue>
```

A tracking issue lists each file still carrying suppressions. Migration PRs
delete suppressions as they convert lines. When none remain, the issue closes.
From then on, the rule's exclusions are only the two files in §2.

A new suppression of this rule draws the same review scrutiny as a new
`no_raw_task_sleep` suppression.

## 4. Helpers

Two additions to `EventDrivenTestClock`, each covered in
`EventDrivenTestClockSelfTests`:

- **`advanceUntil(_ condition:, by step:, timeout:) async throws -> Bool`.**
  It repeats `requireAdvanceWhenArmed(by: step)` until `condition()` holds or
  the timeout passes. Every step waits for an armed sleeper, so it never
  advances blind. It replaces the six `advanceUntil` calls on the old clock and
  `PeerLinkSupervisorTests`' private `advanceVirtualTime` and `stopDriven`.
- **`requireSleepersArmed(count:timeout:) async throws`.** It waits until at
  least `count` sleepers are registered. Registration signals it, as it does
  `requireSleeperArmed`. It serves tests that arm several sleepers at once:
  the provisional-row retire timers, queued-prompt delivery, and PeerLink. Go's
  `clockwork.FakeClock.BlockUntil(n)` is the same idea.

## 5. Migration

Agent-authored PRs, each reviewed by a human:

1. **Lint rule and policy.** §2's documentation changes, §3's rule with its
   suppressions, and the tracking issue.
2. **Helpers.** §4, with self-tests.
3. **Mechanical swap.** About 75 calls where the swap keeps the same waits:
   the construction becomes `EventDrivenTestClock()`; `advanceWhenSuspended(by:)`
   becomes `requireAdvanceWhenArmed(by:)`; `waitForSuspension()` becomes
   `requireSleeperArmed()`; the test gains `throws`; `import Clocks` goes where
   unused; the suppression goes. A script does the edit; review reads every
   hunk.
4. **Rework batch.** About 50 calls that need more than a swap:
   - **Negative assertions.** Checks that something did not happen right after
     an advance, or `Task.yield` loops, move to `settle()` or
     `watchForSleeper(on:upTo:)`.
   - **Immediate positive reads.** Checks that relied on swift-clocks yielding
     inside `advance` move to `FireRecorder`, a join, or a bounded poll.
   - **Several sleepers.** Tests with several sleepers at once use
     `requireSleepersArmed(count:)`.
   - **Shared fixtures.** Fixtures that hold a `TestClock`, such as
     `ModelProxySupervisorTests`' `SupervisorFixture`, change type.
5. **PeerLink.** `Tests/TBDDaemonLiveTests/PeerLinkSupervisorTests.swift` on
   its own: its private time-driving helpers are rebuilt on §4. Whether the
   suite can leave tier 3 once it no longer polls is decided in that PR, on CI
   evidence.

### Proof each PR carries

- **Mechanical swaps (PR 3).** A green CI run and review. The swap keeps each
  wait at the same point, so what each test checks is unchanged.
- **Reworked tests and every negative assertion (PRs 4 and 5).** The PR
  description records, per test, a deliberate break that turns it red on CI:
  removing the sleep, firing the timer early, or skipping the action. Then the
  break is reverted. A negative assertion that passes vacuously is the specific
  failure this guards against.

No migration PR raises a deadline, adds a retry, or adds `.flaky`.

## 6. Out of scope

- **A tests specialist in the PR-review fan-out.** It gets its own spec once
  this rule has removed the dominant shape and the ledger shows what remains.
- **Production code.** Unchanged, apart from injecting a clock where a test
  needs one, as the clock-seam rule already requires.
- **`ImmediateClock` users.** Unchanged.

## 7. Risks

- **Vacuous checks.** A reworked negative assertion can pass without testing
  anything. The deliberate-break proof in §5 covers it.
- **Slow arming on the main actor.** `@MainActor` arming is slow under load.
  The strict forms take `TestDeadlines.saturatedPass`, as §2 says.
- **Feature PRs in flight.** Once the rule lands, they must use the new clock.
  That is the point of landing it first.

No feature flag: only tests, lint configuration and documentation change. No
durable resource is created, so no reconciler is involved.

## 8. Rejected alternatives

- **`withMainSerialExecutor` (swift-concurrency-extras).** It makes `Task.yield`
  reach suspension points predictably by running tasks serially on the main
  thread. But it installs a process-wide hook, and every target here runs in
  one process with suites in parallel. It would change scheduling for every
  other suite.
- **Banning only the polling calls.** That would keep `TestClock` with a plain
  `advance(by:)`. `advance` itself calls `megaYield` twice, so the starvation
  source stays, and authors still choose between two clocks.
- **Migrating before adding the rule.** It gives a clean end state with no
  suppressions, but new polling calls keep arriving during the migration.
- **Keeping migration on field evidence.** Each remaining suite would have to
  fail first. Most already have.
- **Non-throwing waits for mechanical swaps.** `advanceWhenArmed` records a
  miss and carries on, so one starvation shows as a cascade of follow-on
  failures. The strict form ends the test at the cause.
- **Having the flake-fixer do the burn-down nightly.** That would take about a
  month at one file a night, with weak-evidence noise on each PR, while
  directed PRs finish in days.
