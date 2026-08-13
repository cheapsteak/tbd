# Poller-suite clock migration, and a strict arming wait

## What this is for

Two clock-driven suites test **poller loops** — code that wakes on an interval, does
work, and immediately sleeps again. `GatedIntervalSleepTests.returnsAfterExpectedPollCount`
and `DaywatchRunnerTests.testSubsequentTicksAtInterval` each spend five wall-clock
handshake guards, 225 seconds against the 240-second `.clockDriven` limit. Neither
test is failing today. Both are one scheduling excursion away from tripping that
limit, and a tripped time limit reports "wedged" with no attribution rather than a
named failure.

`EventDrivenTestClock` (`docs/specs/2026-08-11-event-driven-test-clock-design.md`)
removed the polled arming handshake for the debounce suites. This applies it to the
poller shape, and adds the one piece pollers need that debouncers did not: a wait
that **throws** rather than recording an issue and continuing.

## Why a poller needs a throwing wait

`sleeperArmed` and `advanceWhenArmed` are non-throwing: a timeout records an issue at
the caller's location and execution continues. That is right for a single-shot
debounce test, where the next statement is an assertion that will fail informatively.

It is wrong for a chain. A poller test is a sequence of *arm → advance → re-arm*
steps, and each step's correctness depends on the previous one having landed. When a
non-throwing wait times out mid-chain, `advance` moves virtual time with no sleeper
registered; the sleep that arrives afterwards is scheduled against the new `now` and
never fires. Every later step then runs against a desynced clock, and the failure
surfaces as a hang rather than as the missed arming that caused it. `Tests/CLAUDE.md`
records the measurement: a hundred-step chain on the predecessor clock passed in
0.63 seconds unloaded and hung past ten minutes under load.

A throwing wait ends the test at the first missed arming, with the diagnostic naming
that step. Nothing afterwards runs against a desynced clock, and the worst-case cost
of a failing chain becomes one guard rather than one per step.

## Design

### The strict pair

Two additions to `EventDrivenTestClock`, mirroring Swift Testing's `#expect` / `#require`
split — soft asks, strict requires:

- **`requireSleeperArmed(timeout:sourceLocation:) async throws`** — the throwing twin
  of `sleeperArmed`. Identical wait; on timeout it throws instead of recording.
- **`requireAdvanceWhenArmed(by:sourceLocation:) async throws`** — `requireSleeperArmed`
  followed by `advance(by:)`.

Both throw the existing `NoSleeperArmed` value that the non-throwing pair records, so
one diagnostic serves both delivery mechanisms and a reader sees the same message
whether it arrived via `Issue.record` or a thrown error. Cancellation keeps the
established treatment: the wait ends without a diagnostic, because attribution belongs
to whatever cancelled the test.

The non-throwing pair stays, unchanged, for its existing callers. New clock-driven
tests should prefer the strict form; the soft form is documented as the legacy shape
rather than removed, because a soft wait followed immediately by an assertion is still
a sound pattern and its callers are settled.

### The two migrations

Both suites already follow the poller idiom by hand: `advanceWhenSuspended(by:)`
followed by an explicit `waitForSuspension()` to catch the re-park. That maps directly
onto `requireAdvanceWhenArmed(by:)` followed by `requireSleeperArmed()`.

`DaywatchRunnerTests` additionally uses a plain `advance(by:)` for its
"one millisecond short of the interval" step, which is sound only because a sleeper is
already registered at that point. That property must survive the migration: the step
stays a plain `advance`, and the arming it depends on is established by the preceding
strict wait.

### Assert the observable, not the clock

`GatedIntervalSleepTests` asserts that its gated sleep *returned* by calling
`checkSuspension()` and expecting no error — and depends on that call's internal
`megaYield` to give the resumed task a turn before the flag is read.
`EventDrivenTestClock.hasSleeper` is a synchronous snapshot with no such nudge, so a
mechanical port would read the flag before the resumed task has run: it would pass for
the wrong reason, or fail spuriously under load.

The replacement is not a weaker negative. The test already holds the positive fact —
the probe records `markReturned()`, and the waiter task can be joined. Asserting on
that is stronger than any clock-state inference and removes the timing dependency
entirely.

This is the migration's actual goal. The clock swap is the mechanism; replacing
clock-state inference with the observable the test already has is the point, and it is
the same correction applied across the flake cluster these suites belong to: assert the
event, not a proxy for it.

### The chain-length rule

`Tests/CLAUDE.md` requires advance chains to stay in single digits. That rule is
retained and gains the mechanism it was missing: the failure it guards against is
record-and-continue desync, which strict `EventDrivenTestClock` chains do not share,
because a miss throws at the first bad step.

The rule is **not** lifted for strict callers. Both suites migrated here already sit
within it, so lifting buys this work nothing, and the majority of clock-driven suites
still use the predecessor helpers where the warning holds in full. Stating the
mechanism lets a future reader with an actual need make that case on evidence.

## Rejected alternatives

- **Make the existing waits throw.** Cleanest end state, and it would retire two shapes
  in favour of one. It also edits suites that are green and settled — including the two
  debounce suites whose whole value right now is that they stopped flaking — to buy
  nothing they need.
- **A `strict:` parameter instead of separate methods.** Swift cannot overload on
  throwing-ness, so this would force every caller to `try` regardless of the flag,
  which is worse than two names.
- **Raise the `.clockDriven` limit so five guards fit comfortably.** Buys headroom only
  for tests that are already failing, taxes every genuinely wedged test with a longer
  wait before attribution, and leaves the desync mechanism untouched.
- **Shorten the chains instead of migrating.** The documented counter-rule applies: a
  shortened chain silently buys a weaker assertion, and one test migrated that way ran
  150 milliseconds of virtual time against a docstring claiming a five-second
  threshold.

## Verification

- Each migrated test still crosses the threshold its name and docstring claim. A
  shortened or reordered chain that no longer reaches its stated threshold is a
  regression even while green.
- A mutation that stops the poller re-arming makes the strict wait throw promptly with
  its named diagnostic, rather than hanging to the suite time limit.
- A mutation to each production behaviour under test still reddens the suite, so the
  migration does not buy stability by weakening what the tests detect.
- Both suites hold under a loop with machine load induced, since load is the failure
  condition these guards exist for.
