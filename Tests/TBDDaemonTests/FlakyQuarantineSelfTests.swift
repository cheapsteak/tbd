import Foundation
import TestSupport
import Testing

/// Proof that `.flaky(issue:)` actually re-runs a failing body.
///
/// Tier 1 — pure in-process counters, no sleeps, no filesystem, no subprocesses.
///
/// A retry mechanism that silently never retried would look exactly like a
/// working one: every test would pass, the metrics file would fill with
/// `passedFirstTry`, and the first real flake would go red anyway. These two
/// fixtures are the only thing standing between that and us.
@Suite("Flaky quarantine self-tests")
struct FlakyQuarantineSelfTests {
    private static let passCounter = RunCounter()
    private static let failCounter = RunCounter()

    /// **This is not a flaky test.** It is the mechanism's self-test: the body
    /// fails by design on its first run in a process and passes on every
    /// subsequent one, so the suite is permanently green *if and only if*
    /// `.flaky` re-ran it. If quarantine ever stops working, this goes red.
    ///
    /// Issue #499 is a permanently-open **fixture anchor**, not a flake report —
    /// nothing is wrong with this test, and closing the issue would only make
    /// the nightly audit nag about a test that is doing its job. Slice G's
    /// quarantine audit excludes exactly
    /// `TBDDaemonTests.FlakyQuarantineSelfTests/retriesUntilPass()` by ID for
    /// the same reason.
    @Test(.flaky(issue: 499))
    func retriesUntilPass() {
        let run = Self.passCounter.next()
        #expect(
            run > 1,
            """
            self-test fixture: run \(run) fails by design. Seeing this as a *visible* \
            failure means .flaky(issue:) did not re-run the body.
            """
        )
    }

    /// Proof of the *exactly three attempts* half: this body always fails, so
    /// the run must go red with a visible failure naming attempt 3 — attempts 1
    /// and 2 suppressed as known issues, attempt 3 surfaced.
    ///
    /// Gated off by default because a permanently-red test cannot live in CI.
    /// Keeping it here rather than deleting it costs a PR nothing and keeps the
    /// proof re-runnable on demand:
    ///
    /// ```
    /// TBD_FLAKY_SELFTEST_FAILURE=1 swift test --filter FlakyQuarantineSelfTests
    /// ```
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TBD_FLAKY_SELFTEST_FAILURE"] == "1"),
        .flaky(issue: 499)
    )
    func alwaysFails() {
        let attempt = Self.failCounter.next()
        Issue.record("self-test fixture: attempt \(attempt) of \(FlakyTrait.maxAttempts) — fails by design")
    }
}

/// Lock-guarded run counter. Static because `.flaky` re-instantiates the suite
/// type per attempt — stored properties would reset and the fixture would fail
/// forever.
private final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
