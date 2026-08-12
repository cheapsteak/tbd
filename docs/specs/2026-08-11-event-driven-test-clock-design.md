# Event-driven test clock — design

## The problem

Clock-driven tier-1 suites drive virtual time so their assertions are exact and
independent of how loaded the machine is. `TestClock` (swift-clocks) delivers
most of that, but it makes those suites load-**tolerant** rather than
load-**independent**, and the intolerance is structural rather than a matter of
tuning. Both halves of the test↔clock handshake are the reason.

- **Arming is polled, and every probe costs a yield storm.** The only way to
  observe "a sleeper is registered" on a `TestClock` is `checkSuspension()`,
  which opens with `Task.megaYield()` — 20 serially-awaited background-QoS
  detached tasks per probe. `waitForSuspension`
  (`Tests/TestSupport/ClockTestSupport.swift`) polls it against a 45 s deadline.
  Under process-global saturation macOS starves background QoS, so the code
  under test cannot reach its `sleep` inside the guard, and the guard itself
  floods the pool with more of exactly the work that is starving.
- **Asserting straight after `advance` is safe only by accident.**
  `TestClock.advance(to:)` megaYields after finishing a sleeper's continuation,
  and that is the only thing which usually lets the resumed task run its
  post-sleep code before `advance` returns. It is a scheduling accident, not a
  guarantee — and it stops holding under precisely the load that matters.

The field evidence: in a full-suite soak on a loaded development box (2 of 3
runs, failing at ~131 s and ~228 s), `AppearanceDebounceTests` and
`SearchQueryDebouncerTests` reported `Issue recorded` at the
`advanceWhenSuspended` call site, followed by an empty fired-values array. No
logic assertion failed — the arming handshake did.

Every suite-local remedy is already measured and refuted (`Tests/CLAUDE.md`,
"Population is the scheduler"): both suites already carry `.serialized` and
failed anyway, since the contention is process-global; `TASK_MEGA_YIELD_COUNT=1`
measured as noise; blanket retry is banned in every tier. `ClockTestSupport`
names the real fix and defers it — "a megaYield-free virtual clock replacing
`TestClock` … a shared-contract change". This is that change.

## Goal

Make both directions of the handshake **event-driven**: no polling, no yield
storms, no wall-clock guard on any healthy path.

- **Arming** — the clock signals when a sleeper registers; the test parks on a
  continuation instead of probing.
- **Firing** — the test observes the effect through an awaitable recorder
  instead of reading state synchronously after `advance` returns.

The property to hold: under arbitrary load a green test gets slower, never red.
Diagnostics-only timeouts remain, because a timer that genuinely never arms must
fail with a named message rather than park until the suite time limit, and they
are reached only on runs that are already failing.

## Design

Both types live in `Tests/TestSupport/EventDrivenTestClock.swift` and are
`public`, since `TestSupport` is imported across test targets.

### `EventDrivenTestClock`

A `final class` conforming to `Clock` with `Duration == Swift.Duration` and its
own offset-based `Instant`, so it satisfies the production
`clock: any Clock<Duration>` seam with no change to any production type. State
is one `NSLock`-guarded group: current virtual `now`, the suspension ledger, and
the ledger of parked arming waiters — the same storage shape as `TestClock` plus
the waiter ledger that makes arming observable.

- **`sleep(until:tolerance:)`** opens with `try Task.checkCancellation()`,
  mirroring `TestClock`. A task cancelled before it ever ran must not register a
  sleeper and must throw rather than return normally: cancel-and-replace
  debouncers depend on it, since a burst of keystrokes cancels tasks that have
  never started and a sleep returning *successfully* in one of them fires a
  superseded value. It is also the only enforcement on the already-elapsed
  deadline path, which returns without consulting cancellation at all. A
  deadline at or before `now` returns immediately, registering nothing and
  signalling nobody. Otherwise the suspension is appended to the ledger under
  the lock, parked arming waiters are collected in the same critical section,
  and they are resumed after the lock is released.
- **Signal-after-append is the whole correctness story.** There is no window in
  which a waiter proceeds while the sleeper it was told about is unregistered.
  That ordering is also why this is a clock and not a wrapper: `TestClock`
  registers inside its own lock, where nothing outside can interpose, so any
  wrapper's signal necessarily precedes the registration it claims to announce.
- **Cancellation while suspended** removes the entry under the lock and resumes
  the continuation throwing `CancellationError`, matching `TestClock`. The
  handler and the continuation body can run in either order, so they share a
  per-sleep box that records whether the sleeper has settled and whether
  cancellation arrived before the continuation was installed; whoever gets the
  lock first owns the outcome, and the sleeper is resumed exactly once.
- **`sleeperArmed(timeout:sourceLocation:)`** returns immediately when a sleeper
  is registered and otherwise parks a continuation that the next registration
  resumes. The timeout is a hang guard only: it races a single real
  `Task.sleep` that never fires on a healthy path, and on expiry it deregisters
  the waiter — so a later signal cannot resume a dead continuation — then
  records an `Issue` carrying observed state. 45 s carries over from
  `waitForSuspension` so that existing tallies of chained waits against
  `.clockDriven`'s 240 s limit stay valid.
- **`advanceWhenArmed(by:)`** is `sleeperArmed()` followed by `advance(by:)` —
  the drop-in replacement for `advanceWhenSuspended(by:)`.
- **`advance(by:)` / `advance(to:)`** step `now` through each due deadline in
  order and resume those sleepers outside the lock. **No megaYield and no
  yields at all.** The consequence is documented on the method and is the one
  thing a migrating test must internalize: `advance` returning means the
  continuations were resumed, *not* that the resumed tasks have run their
  post-sleep code. Positive assertions pair with `FireRecorder.next()`.
- **`hasSleeper` / `sleeperCount`** are synchronous snapshots, for the negative
  assertion "the code under test armed no timer at all" and for waiting until
  several sleepers are registered before advancing.

### `FireRecorder<Value: Sendable>`

A lock-guarded buffer plus at most one parked consumer, replacing the
hand-rolled `Box { var values: [String] }` that these suites asserted against
immediately after `advance`.

- **`record(_:)`** is synchronous and callable from any context, because the
  code under test calls it from a non-async callback. It resumes a parked
  consumer if there is one.
- **`next(timeout:sourceLocation:)`** returns the next value not yet handed out,
  awaiting it if it has not arrived, and returns `nil` after recording a
  diagnostic on timeout. Returning an optional rather than continuing silently
  means a test asserting on the result compares against `nil` *after* the real
  diagnostic was recorded, never instead of it.
- **`values`** is a full-history snapshot, never drained by `next()`, for order
  and collapse assertions and for negative assertions. Negative assertions here
  stay **one-sided**: a pathologically late fire can make one false-*pass*,
  never false-fail. That is unchanged from the hand-rolled boxes, and it is
  exactly why the positive half of every test goes through `next()`.

Both diagnostics are thrown-`Error` shapes passed to `Issue.record`, since only
that form puts the message on the primary failure line where a CI summary shows
it (`Tests/CLAUDE.md` assertion-hygiene rule 4), and both report observed state
rather than restating the expectation.

### First consumers

`AppearanceDebounceTests` and `SearchQueryDebouncerTests` migrate wholesale —
they are small, each shares one harness, and a mixed-clock suite would be harder
to read than either pure form. The pattern per positive test is: schedule the
work, `await clock.advanceWhenArmed(by:)`, `let value = await fired.next()`,
assert on that value and on `fired.values`. Boundary and cancellation tests keep
their exact-virtual-time structure. `CancelOnResumeClock`, the delegating
wrapper that reproduces cancellation landing after a sleep resumes, ports
unchanged onto the new base clock.

Two consequences worth naming, because they are the cost side of the trade:

- **Negative assertions need an explicit settle.** Where a megaYielding
  `advance` used to supply incidental scheduling turns, these suites now hand
  the main actor back for a few short real sleeps before reading `values`. Same
  one-sidedness as before, made explicit and bounded rather than inherited from
  a library's internals.
- **One negative got weaker on purpose.** `dropFirstAndRemoveDuplicates` proved
  "the subscriber-time replay armed no timer" by asserting that
  `checkSuspension()` did *not* throw. Its replacement settles briefly and then
  asserts `hasSleeper == false`. The timer a missing `dropFirst()` would arm
  needs a scheduling turn to appear and the settle gives it several, but this is
  a weaker proof than the original and, like every negative here, can only ever
  false-pass.

### Self-tests

The clock's own properties are invisible in normal use — a clock that silently
stopped signalling would look identical to a working one until some unrelated
suite began timing out at 45 s. `Tests/TBDDaemonTests/EventDrivenTestClockSelfTests.swift`
covers them, alongside `FlakyQuarantineSelfTests`, which lives there for the
same reason: a waiter parked before any sleep is released by the later
registration; `sleeperArmed` takes the fast path when a sleeper already exists;
a pre-cancelled task's sleep neither registers nor signals; a cancelled task's
sleep throws even when the deadline has already elapsed; cancelling a suspended
sleeper removes its ledger entry and throws; `advance` fires in deadline order
and moves `now` exactly; one advance past several deadlines fires each sleeper
once; both hang guards reach their diagnostic when driven at a tiny timeout, and
deregister the stranded waiter afterwards.

## Non-goals

- **Migrating the other clock-driven suites.** `FileWatcherTests`,
  `GatedIntervalSleepTests`, `DaywatchRunnerTests`, `PaneRepairCoordinatorTests`
  and the rest stay on `TestClock` and move on field evidence, one at a time —
  the Built/Enabled ratchet applied to test infrastructure.
- **Removing `TestClock`, `advanceWhenSuspended` or `waitForSuspension`.** They
  remain correct for their existing consumers, and their documented derivation
  against `.clockDriven`'s limit stays load-bearing.
- **Touching the production clock seam.** `clock: any Clock<Duration>` as the
  last defaulted initializer parameter is unchanged; the new type simply
  conforms to it.

## Rejected alternatives

- **Raise the 45 s arming guard.** It does not converge — at a load average in
  the hundreds no finite number holds. It also violates the rule that
  `ciSafeDeadline`, `waitForSuspension` and `.clockDriven` are derived together,
  and it taxes every genuinely wedged test with a longer wait before the failure
  is attributed.
- **Wrap `TestClock` in a signalling decorator.** Unsound. Registration happens
  inside `TestClock`'s own lock, so a wrapper can only signal before or after
  that critical section, never within it. Signalling before leaves a window in
  which the waiter advances past an unregistered sleeper — which moves `now`
  with nothing to fire, so the sleep that lands afterwards is scheduled against
  the new `now` and never fires. That is the permanent-desync hang, not a red
  test.
- **`TASK_MEGA_YIELD_COUNT=1`.** Measured across interleaved runs with
  population held constant: p90 26.5 s / 31.2 s → 26.0 s / 29.4 s, p99 26.6 s →
  27.0 s. Noise. The megaYield is a real but secondary contributor; the dominant
  term is the number of runnable tasks in the process.
- **`.serialized` on the affected suites.** Already applied to both, and both
  still failed. It narrows a suite that starves *itself*; it cannot shrink the
  process-global queue its waiter sits behind.
- **Blanket retry.** Banned in every tier: a retry nobody named hides a
  regression, because a test that started failing when someone broke the code is
  indistinguishable from one that was always flaky.
