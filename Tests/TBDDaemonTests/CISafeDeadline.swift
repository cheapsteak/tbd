import Foundation
import TestSupport

/// Generous positive-wait poll deadline that only elapses on failure; sized
/// for loaded parallel CI (PR #379: cooperative-pool starvation stretched
/// sub-second async-drain deliveries past a 5 s poll). Passing runs still
/// complete in milliseconds.
///
/// ## This is a hang-catcher, not a timing budget
///
/// "Raise a timeout" reads as a cover-up, so state the case plainly. No test
/// that consumes this value asserts a timing property. They assert that
/// something eventually happens — the deadline exists only so an event that
/// never arrives fails with a named diagnostic instead of hanging the run. On
/// success it costs nothing: the poll returns as soon as the condition holds.
///
/// ## Sizing
///
/// Swift Testing runs the whole fast pass in one process with no concurrency
/// cap, so per-test scheduling latency scales with the pass's population, not
/// with the suite doing the waiting. A deadline inside that latency is a coin
/// flip, not a signal: in CI one suite was observed finishing green at
/// 45.8 s / 47.4 s and red at 47.9 s against a 30 s deadline, and the failures
/// burned the *full* 30 s, so the deadline was the binding constraint rather
/// than an incidental one.
///
/// The pass that binds this value is fast pass 2 (everything but the two
/// daemon targets, ~7200 tests). Its worst green maximum on record is 101.7 s,
/// with pass 2 as one step. Five other green runs as one step measured its
/// slowest test at 67.2–94.5 s (p90 55–79 s, p99 66–93 s), and runner noise
/// alone moves that tail by about twenty seconds. A tail within about 8 s of
/// the ~102 s split trigger (120 s less the ~18 s margin) is why pass 2 runs
/// as two steps, 2a and 2b, cut by main-thread time: on one green run their
/// slowest tests reported 41.0 s and 37.5 s (p99 40.9 s and 36.0 s).
///
/// Pass 1's figures are evidence, not the sizing input. Fast pass 1a's
/// slowest test reports 51.7–86.5 s on recent runs, 86.5 s on a slow runner,
/// and 1b's 22.5–38.5 s. On green runs where every in-memory database ran the
/// whole migration chain, 1a and 1b reported 111.7 s and 107.4 s. A reported
/// duration there also includes the time a test waits for its body to start,
/// which a wait inside the body never pays, so those figures bound a wait only
/// loosely.
///
/// So the sizing rule is applied to pass 2's tail: it clears the worst green
/// tail by about 18 s, because runner noise alone moves it by about twenty.
/// 120 s clears the 101.7 s on record by about 18 s, and the 94.5 s by about
/// 25 s, and the deadline still elapses only on a genuine hang. It is sized
/// against the record and is not re-derived from the split halves' tails.
/// Re-deriving it would also move the values coupled to it:
/// `TestGate.deadline`, `.fastPassBounded`, and the tier-3 suite limits summed
/// from chains of these waits (`Tests/CLAUDE.md`, "Population is the
/// scheduler").
///
/// ## The interaction with `.clockDriven` — read before changing either value
///
/// A `.clockDriven` suite that consumes this value races its time limit
/// against this deadline. `waitFor` is `@discardableResult` and does not throw
/// on timeout — it records an `Issue` and returns `false` — so a site written
/// `try await waitFor(…)` continues past a timeout, and chained waits are
/// real. A site written `try #require(await waitFor…)` aborts at the first.
///
/// The invariant is **not** "all N chained waits must fit inside the suite
/// limit". The operative invariant is: **the suite limit must afford the
/// first full deadline plus the rest of an ordinary test.** The first
/// timeout's `Issue.record` fires immediately and carries the named
/// diagnostic, so it always survives even if the limit later truncates the
/// test. Chains beyond the first belong to a test that is already failing;
/// truncating those is acceptable and deliberate.
///
/// Checked against `.clockDriven`'s 5-minute (300 s) limit:
/// - one `waitFor` (120 s) + one arming wait (45 s) = 165 s ✓
/// - two `waitFor` = 240 s ✓
/// - two arming waits = 90 s ✓ (preserves the "a test that waits twice must
///   afford both waits" property)
///
/// **If a chain of these waits starts tripping the limit, shorten the chain;
/// do not raise 300 s.** A longer limit only buys time for tests that are
/// already failing, while making every genuine wedge that much slower to
/// attribute.
///
/// ## Why not `@Suite(.serialized)`
///
/// It was considered and it is not the remedy here. `ArchivedWorktreeSearchTests`
/// "Archived search debounce" is *already* `.clockDriven, .serialized` and
/// still failed twice in CI, because the contention is process-global: every
/// target compiles into one process and Swift Testing parallelizes across all
/// of them, so serializing one suite does not reduce the number of runnable
/// tasks its waiter is queued behind. `Tests/CLAUDE.md` advises reaching for
/// `.serialized` before a longer timeout; that advice is about a suite starving
/// *itself* (its own tests megaYielding against each other) and does not cover
/// this case.
///
/// ## The value is shared; this is where its derivation lives
///
/// The number itself is `TestDeadlines.saturatedPass`
/// (`Tests/TestSupport/BoundedGateSupport.swift`), because
/// `Tests/TBDDaemonLiveTests` cannot import this symbol and waits there need
/// the same budget. Keeping one literal is what stops them from drifting apart
/// unnoticed; the reasoning above is what re-derives it, and it stays here.
/// Re-derive it together with `TestGate.deadline`, which must dominate it, and
/// with the clock's arming waits and `.clockDriven`.
///
/// `waitFor` and its `BoundedWaitTimeout` diagnostic live in
/// `Tests/TestSupport/BoundedGateSupport.swift`, beside the `TestDeadlines`
/// constant they default to, and arrive through `import TestSupport`.
let ciSafeDeadline: Duration = TestDeadlines.saturatedPass
