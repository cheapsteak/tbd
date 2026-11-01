import Foundation
import Testing
import TestProcessDefaults
import TestSupport

/// The test host's main run loop guard (`Tests/TestProcessDefaults/MainRunLoopGuard.m`).
///
/// Swift runs the test bundle's async `main` by calling `CFRunLoopRun()` and
/// then `exit(0)`, so a stop of the main run loop at its outermost level ended
/// the whole run with status 0 and no summary: the deaths CI names
/// `fast-pass-app-a ran no tests` or `fast-pass-app-b ran no tests`. Without
/// the guard this test is that death, every run: the stop lands while the
/// process has no other way to survive it, and the pass reports no tests.
/// With it, the run loop is resumed and the count moves.
@Suite("Test host main run loop guard")
struct MainRunLoopGuardTests {
    @Test func stoppingTheMainRunLoopDoesNotEndTheRun() async {
        let before = await MainActor.run { TBDTestHostMainRunLoopResumeCount() }
        // Each read runs as a main-queue job, which the outermost activation
        // runs, so a stop from it lands there. A stop a nested pump happens to
        // absorb ends only that pump, and the next read stops again.
        let budget = TestDeadlines.saturatedPass
        let outcome = await pollUntilTrue(timeout: budget, pollInterval: .milliseconds(20)) { @Sendable in
            await MainActor.run {
                if TBDTestHostMainRunLoopResumeCount() > before { return true }
                TBDTestHostExpectMainRunLoopStop()
                CFRunLoopStop(CFRunLoopGetMain())
                return false
            }
        }
        #expect(outcome == .satisfied, "The guard never resumed the stopped main run loop")
    }
}
