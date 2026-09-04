import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Tier 1. `UpdateChecker` — the fact the daemon publishes about a newer
/// `main`, and the one act it takes about it
/// (`docs/specs/2026-09-04-automatic-version-updates-design.md` §5).
///
/// Every collaborator is an injected closure, so the mode table, the relation
/// table and the launch decision are all exercised without a network, a git
/// remote or a subprocess. The clock only appears in the two tests that are
/// about the loop; everything else drives `runOnce()` directly, which keeps the
/// advance chains at one step.
@Suite("UpdateChecker", .clockDriven)
struct UpdateCheckerTests {

    private static let ours = "1111111111111111111111111111111111111111"
    private static let latest = "2222222222222222222222222222222222222222"
    private static let newerStill = "3333333333333333333333333333333333333333"
    private static let worktree = "/w"

    /// Counts every external effect, so a test can assert what did NOT happen
    /// as precisely as what did — which is the whole content of the `off` mode.
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _remoteResolutions = 0
        private var _headReads = 0
        private var _launches: [String] = []

        var remoteResolutions: Int { lock.withLock { _remoteResolutions } }
        var headReads: Int { lock.withLock { _headReads } }
        var launches: [String] { lock.withLock { _launches } }

        func noteRemoteResolution() { lock.withLock { _remoteResolutions += 1 } }
        func noteHeadRead() { lock.withLock { _headReads += 1 } }
        func noteLaunch(_ worktree: String) { lock.withLock { _launches.append(worktree) } }
    }

    /// A mutable box for the values a test wants to change between ticks: the
    /// mode (to prove a change is honored at the next tick) and the remote's
    /// head (to prove `auto` launches once per commit, not once per tick).
    private final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var _mode: UpdateMode
        private var _head: String?
        private var _launchSucceeds = true

        init(mode: UpdateMode, head: String?) {
            _mode = mode
            _head = head
        }

        var mode: UpdateMode {
            get { lock.withLock { _mode } }
            set { lock.withLock { _mode = newValue } }
        }
        var head: String? {
            get { lock.withLock { _head } }
            set { lock.withLock { _head = newValue } }
        }
        var launchSucceeds: Bool {
            get { lock.withLock { _launchSucceeds } }
            set { lock.withLock { _launchSucceeds = newValue } }
        }
    }

    private func makeChecker(
        fixture: Fixture,
        spy: Spy,
        ourCommit: String? = UpdateCheckerTests.ours,
        sourceWorktree: String? = UpdateCheckerTests.worktree,
        remoteURL: String? = "git@github.com:acme/tbd.git",
        ancestry: Bool? = true,
        behindBy: Int? = nil,
        interval: Duration = .seconds(3600),
        clock: any Clock<Duration> = ContinuousClock()
    ) -> UpdateChecker {
        UpdateChecker(
            ourCommit: ourCommit,
            sourceWorktree: sourceWorktree,
            readMode: { fixture.mode },
            resolveRemote: { _ in
                spy.noteRemoteResolution()
                return remoteURL
            },
            remoteHead: { _, _ in
                spy.noteHeadRead()
                return fixture.head
            },
            isAncestor: { _, _, _ in ancestry },
            behindCount: { _, _, _ in behindBy },
            launch: { worktree in
                spy.noteLaunch(worktree)
                return fixture.launchSucceeds
            },
            interval: interval,
            now: { Date(timeIntervalSince1970: 1_780_000_000) },
            clock: clock)
    }

    // MARK: - off does nothing at all

    /// The shipped default. Not "checks and discards" — no network call is made
    /// and no status is published, which is what makes the default free.
    @Test func offRunsNothing() async {
        let spy = Spy()
        let checker = makeChecker(
            fixture: Fixture(mode: .off, head: Self.latest), spy: spy)
        await checker.runOnce()
        #expect(spy.headReads == 0)
        #expect(spy.remoteResolutions == 0)
        #expect(spy.launches.isEmpty)
        #expect(await checker.currentStatus() == nil)
    }

    // MARK: - check observes and never launches

    @Test func checkObservesAndPublishesTheRelation() async {
        let spy = Spy()
        let checker = makeChecker(
            fixture: Fixture(mode: .check, head: Self.latest), spy: spy, behindBy: 7)
        await checker.runOnce()
        let status = await checker.currentStatus()
        #expect(status?.latestCommit == Self.latest)
        #expect(status?.relation == .behind)
        #expect(status?.behindBy == 7)
        #expect(status?.remote == "git@github.com:acme/tbd.git")
        #expect(status?.observedAt == Date(timeIntervalSince1970: 1_780_000_000))
    }

    /// The branch that separates the two live modes. `check` sees exactly what
    /// `auto` sees and does nothing about it.
    @Test func checkNeverLaunches() async {
        let spy = Spy()
        let checker = makeChecker(
            fixture: Fixture(mode: .check, head: Self.latest), spy: spy)
        await checker.runOnce()
        await checker.runOnce()
        #expect(spy.headReads == 2)
        #expect(spy.launches.isEmpty, "check mode must observe only")
    }

    @Test func upToDateIsReportedRatherThanSuppressed() async {
        let spy = Spy()
        let checker = makeChecker(
            fixture: Fixture(mode: .check, head: Self.ours), spy: spy)
        await checker.runOnce()
        #expect(await checker.currentStatus()?.relation == .upToDate)
        #expect(spy.launches.isEmpty)
    }

    // MARK: - auto launches once per commit

    @Test func autoLaunchesWhenBehind() async {
        let spy = Spy()
        let checker = makeChecker(
            fixture: Fixture(mode: .auto, head: Self.latest), spy: spy)
        await checker.runOnce()
        #expect(spy.launches == [Self.worktree])
    }

    /// The memory that stops a checker from starting an update an hour, and
    /// then another, while the first is still building.
    @Test func autoLaunchesOncePerCommitAndAgainWhenMainMoves() async {
        let spy = Spy()
        let fixture = Fixture(mode: .auto, head: Self.latest)
        let checker = makeChecker(fixture: fixture, spy: spy)

        await checker.runOnce()
        await checker.runOnce()
        await checker.runOnce()
        #expect(spy.launches == [Self.worktree], "the same commit must be attempted once")

        fixture.head = Self.newerStill
        await checker.runOnce()
        #expect(spy.launches.count == 2, "a new commit is a new attempt")
    }

    /// A launch that failed is still an attempt. Retrying it every hour would
    /// spawn a process an hour against a script that cannot run.
    @Test func aFailedLaunchIsNotRetriedUntilMainMoves() async {
        let spy = Spy()
        let fixture = Fixture(mode: .auto, head: Self.latest)
        fixture.launchSucceeds = false
        let checker = makeChecker(fixture: fixture, spy: spy)

        await checker.runOnce()
        await checker.runOnce()
        #expect(spy.launches.count == 1)

        fixture.head = Self.newerStill
        await checker.runOnce()
        #expect(spy.launches.count == 2)
    }

    /// `auto` acts on `behind` and on nothing else — a build ahead of `main`
    /// must never be replaced by one that would throw its commits away.
    @Test func autoDoesNotLaunchWhenNotBehind() async {
        let spy = Spy()
        let checker = makeChecker(
            fixture: Fixture(mode: .auto, head: Self.latest), spy: spy, ancestry: false)
        await checker.runOnce()
        #expect(await checker.currentStatus()?.relation == .upToDate)
        #expect(spy.launches.isEmpty)
    }

    // MARK: - The mode is read per tick

    @Test func aModeChangeIsHonoredAtTheNextTickWithNoRestart() async {
        let spy = Spy()
        let fixture = Fixture(mode: .off, head: Self.latest)
        let checker = makeChecker(fixture: fixture, spy: spy)

        await checker.runOnce()
        #expect(spy.headReads == 0)

        fixture.mode = .check
        await checker.runOnce()
        #expect(spy.headReads == 1)
        #expect(spy.launches.isEmpty)

        fixture.mode = .auto
        await checker.runOnce()
        #expect(spy.launches == [Self.worktree])

        fixture.mode = .off
        fixture.head = Self.newerStill
        await checker.runOnce()
        #expect(spy.headReads == 2, "off stops the work again, without a restart")
    }

    // MARK: - checkNow ignores the mode for the question, not for the act

    /// Somebody who just asked has made the gesture the flag exists to require.
    @Test func checkNowObservesEvenInOffMode() async {
        let spy = Spy()
        let checker = makeChecker(
            fixture: Fixture(mode: .off, head: Self.latest), spy: spy)
        let status = await checker.checkNow()
        #expect(status.latestCommit == Self.latest)
        #expect(status.relation == .behind)
        #expect(spy.launches.isEmpty, "asking what the remote is at is not asking for an install")
    }

    @Test func checkNowInAutoModeStillLaunches() async {
        let spy = Spy()
        let checker = makeChecker(
            fixture: Fixture(mode: .auto, head: Self.latest), spy: spy)
        _ = await checker.checkNow()
        #expect(spy.launches == [Self.worktree])
    }

    // MARK: - Degenerate inputs idle rather than guess

    @Test func noSourceWorktreeMeansNoWorkAndNoStatus() async {
        let spy = Spy()
        let checker = makeChecker(
            fixture: Fixture(mode: .auto, head: Self.latest), spy: spy, sourceWorktree: nil)
        await checker.runOnce()
        #expect(spy.remoteResolutions == 0)
        #expect(await checker.currentStatus() == nil)
    }

    @Test func noRemoteMeansNoStatus() async {
        let spy = Spy()
        let checker = makeChecker(
            fixture: Fixture(mode: .check, head: Self.latest), spy: spy, remoteURL: nil)
        await checker.runOnce()
        #expect(spy.headReads == 0)
        #expect(await checker.currentStatus() == nil)
    }

    /// The remote resolution is cached: an hourly `git remote get-url` for an
    /// answer that changes when somebody edits `.git/config` is not worth a
    /// subprocess.
    @Test func theRemoteIsResolvedOnce() async {
        let spy = Spy()
        let checker = makeChecker(
            fixture: Fixture(mode: .check, head: Self.latest), spy: spy)
        await checker.runOnce()
        await checker.runOnce()
        #expect(spy.remoteResolutions == 1)
        #expect(spy.headReads == 2)
    }

    /// A remote that did not answer is a fact about the network. The previous
    /// observation is better than replacing it with `unknown`.
    @Test func aFailedReadKeepsTheLastObservation() async {
        let spy = Spy()
        let fixture = Fixture(mode: .check, head: Self.latest)
        let checker = makeChecker(fixture: fixture, spy: spy)
        await checker.runOnce()
        #expect(await checker.currentStatus()?.latestCommit == Self.latest)

        fixture.head = nil
        await checker.runOnce()
        #expect(await checker.currentStatus()?.latestCommit == Self.latest)
    }

    /// A daemon that cannot say what it was built from cannot say whether it is
    /// behind. It still publishes the commit it saw, so `tbd version` can show
    /// a latest even when it cannot show a verdict.
    @Test func noBuildIdentityMeansUnknownRatherThanBehind() async {
        let spy = Spy()
        let checker = makeChecker(
            fixture: Fixture(mode: .auto, head: Self.latest), spy: spy, ourCommit: nil)
        await checker.runOnce()
        #expect(await checker.currentStatus()?.relation == .unknown)
        #expect(spy.launches.isEmpty)
    }

    // MARK: - The loop

    /// The loop ticks immediately, so a restarted daemon has something to say
    /// about updates before the first interval elapses.
    @Test func startTicksImmediately() async throws {
        let spy = Spy()
        let clock = EventDrivenTestClock()
        let checker = makeChecker(
            fixture: Fixture(mode: .check, head: Self.latest),
            spy: spy, interval: .seconds(3600), clock: clock)
        await checker.start()
        // The first tick runs before the first sleep is armed, so waiting for
        // the arming is waiting for the tick to have completed.
        try await clock.requireSleeperArmed()
        #expect(spy.headReads == 1)
        await checker.stop()
    }

    /// And again every interval. One advance, per the short-chain rule.
    @Test func theLoopTicksAgainAfterTheInterval() async throws {
        let spy = Spy()
        let clock = EventDrivenTestClock()
        let checker = makeChecker(
            fixture: Fixture(mode: .check, head: Self.latest),
            spy: spy, interval: .seconds(3600), clock: clock)
        await checker.start()
        try await clock.requireAdvanceWhenArmed(by: .seconds(3600))
        // The re-arm after the second tick is the observable that says the
        // tick ran to completion.
        try await clock.requireSleeperArmed()
        #expect(spy.headReads == 2)
        await checker.stop()
    }

    @Test func stopIsIdempotentAndStartDoesNotDoubleTheLoop() async throws {
        let spy = Spy()
        let clock = EventDrivenTestClock()
        let checker = makeChecker(
            fixture: Fixture(mode: .check, head: Self.latest),
            spy: spy, interval: .seconds(3600), clock: clock)
        await checker.start()
        await checker.start()
        try await clock.requireSleeperArmed()
        #expect(clock.sleeperCount == 1, "a second start must not run a second loop")
        await checker.stop()
        await checker.stop()
    }

    // MARK: - Interval resolution

    @Test func intervalDefaultsToAnHourAndTheEnvOverrides() {
        #expect(UpdateChecker.interval(from: [:]) == .seconds(3600))
        #expect(UpdateChecker.interval(from: ["TBD_UPDATE_CHECK_INTERVAL": "90"])
            == .seconds(90))
        // Unusable values fall back rather than spinning or crashing.
        for bad in ["", "   ", "soon", "0", "-5"] {
            #expect(
                UpdateChecker.interval(from: ["TBD_UPDATE_CHECK_INTERVAL": bad])
                    == .seconds(3600),
                "'\(bad)' must fall back to the default interval")
        }
    }
}
