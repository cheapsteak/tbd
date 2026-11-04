import Foundation
import Testing
@testable import TBDApp
import TestSupport

// Tier 1: virtual time only. The poller sleeps on an `EventDrivenTestClock`,
// and its host is a fake that records each load, so nothing reads git.

/// `ChangesListPoller` (side panel toggle pills spec, "The Changes pill"): it
/// polls the worktree on screen at once when TBD becomes active or another
/// worktree comes on screen, then once per interval after each poll's loads
/// finish. It loads no list its host holds fresh, never starts a second load
/// of a list one of its own loads is still reading, and polls nothing while
/// TBD is inactive.
@Suite("Changes list poller", .clockDriven)
@MainActor
struct ChangesListPollerTests {
    private static let interval = Duration.seconds(10)

    /// A host whose worktrees on screen are `onScreen`, whose lists all need
    /// reading except those in `fresh`, recording each load in `loads`, and
    /// holding each load in flight while `holdsLoads` is set.
    @MainActor
    private final class Host: ChangesListPollerHost {
        var onScreen: Set<UUID>
        var fresh: Set<UUID> = []
        var holdsLoads = false
        let loads = FireRecorder<UUID>()
        private var held: [CheckedContinuation<Void, Never>] = []

        init(onScreen: Set<UUID>) {
            self.onScreen = onScreen
        }

        var changesPollWorktreeIDs: Set<UUID> { onScreen }

        func changesPollNeedsLoad(worktreeID: UUID) -> Bool {
            !fresh.contains(worktreeID)
        }

        func changesPollLoad(worktreeID: UUID) async {
            loads.record(worktreeID)
            guard holdsLoads else { return }
            await withCheckedContinuation { held.append($0) }
        }

        /// Lets every held load finish, and the ones after them run through.
        func releaseLoads() {
            holdsLoads = false
            let waiting = held
            held = []
            for load in waiting {
                load.resume()
            }
        }
    }

    /// A poller on its own test clock, polling `host` every `interval`.
    private static func poller(host: Host) -> (poller: ChangesListPoller, clock: EventDrivenTestClock) {
        let clock = EventDrivenTestClock()
        let poller = ChangesListPoller(interval: interval, clock: clock)
        poller.host = host
        return (poller, clock)
    }

    @Test("nothing polls while TBD is inactive, even as the worktree on screen changes")
    func inactivePollsNothing() {
        let worktreeID = UUID()
        let host = Host(onScreen: [worktreeID])
        let (poller, clock) = Self.poller(host: host)

        poller.worktreesOnScreenChanged()

        let polling = poller.isPolling
        let loads = host.loads.values
        let sleeping = clock.hasSleeper
        #expect(!polling)
        #expect(loads.isEmpty)
        #expect(!sleeping)
    }

    @Test("becoming active loads the worktree on screen at once, then once per interval")
    func activationLoadsThenOncePerInterval() async throws {
        let worktreeID = UUID()
        let host = Host(onScreen: [worktreeID])
        let (poller, clock) = Self.poller(host: host)
        defer { poller.appResignedActive() }

        poller.appBecameActive()

        // The poll sleeps only once its loads have finished, so an armed
        // sleeper means the activation's poll is done.
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        let afterActivation = host.loads.values
        #expect(afterActivation == [worktreeID])

        await clock.advance(by: Self.interval)
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        let afterOneInterval = host.loads.values
        #expect(afterOneInterval == [worktreeID, worktreeID], "one load per poll")
    }

    @Test("a poll loads no list its host holds fresh, and loads it once it is not")
    func freshListIsNotLoaded() async throws {
        let worktreeID = UUID()
        let host = Host(onScreen: [worktreeID])
        host.fresh = [worktreeID]
        let (poller, clock) = Self.poller(host: host)
        defer { poller.appResignedActive() }

        poller.appBecameActive()
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        let whileFresh = host.loads.values
        #expect(whileFresh.isEmpty)

        host.fresh = []
        await clock.advance(by: Self.interval)
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        let onceOld = host.loads.values
        #expect(onceOld == [worktreeID])
    }

    @Test("resigning active stops the polling, and nothing polls until TBD is active again")
    func resigningStopsPolling() async throws {
        let worktreeID = UUID()
        let host = Host(onScreen: [worktreeID])
        let (poller, clock) = Self.poller(host: host)
        defer { poller.appResignedActive() }

        poller.appBecameActive()
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)

        poller.appResignedActive()
        let pollingAfterResign = poller.isPolling
        let sleepingAfterResign = clock.hasSleeper
        #expect(!pollingAfterResign)
        #expect(!sleepingAfterResign, "the poll's sleep ends with it")

        // Another worktree on screen polls nothing while TBD is inactive.
        poller.worktreesOnScreenChanged()
        let pollingAfterChange = poller.isPolling
        #expect(!pollingAfterChange)
        await clock.advance(by: Self.interval)
        let loads = host.loads.values
        #expect(loads == [worktreeID], "only the activation's load")
    }

    @Test("a poll starts no second load of a list one of its loads is still reading")
    func noSecondLoadWhileOneIsInFlight() async throws {
        let worktreeID = UUID()
        let host = Host(onScreen: [worktreeID])
        host.holdsLoads = true
        let (poller, clock) = Self.poller(host: host)
        defer { poller.appResignedActive() }
        let loads = host.loads

        poller.appBecameActive()
        let first = await loads.next(timeout: TestDeadlines.saturatedPass)
        _ = try #require(first, "precondition: the activation's load is in flight")

        // A new poll while that load is held finds the list still being read,
        // starts nothing, and sleeps; so does the poll an interval later.
        poller.worktreesOnScreenChanged()
        try await clock.requireAdvanceWhenArmed(by: Self.interval, timeout: TestDeadlines.saturatedPass)
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        let whileHeld = loads.values
        #expect(whileHeld == [worktreeID])

        // Once it finishes, a later poll reads the list again.
        host.releaseLoads()
        try await clock.advanceUntil(
            "the list loads again", by: Self.interval, timeout: TestDeadlines.saturatedPass, maxSteps: 3
        ) {
            loads.values.count == 2
        }
        let afterRelease = loads.values
        #expect(afterRelease == [worktreeID, worktreeID])
    }

    @Test("another worktree on screen is loaded at once, without waiting out the interval")
    func worktreeOnScreenLoadsAtOnce() async throws {
        let first = UUID()
        let second = UUID()
        let host = Host(onScreen: [first])
        let (poller, clock) = Self.poller(host: host)
        defer { poller.appResignedActive() }

        poller.appBecameActive()
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)

        host.onScreen = [second]
        poller.worktreesOnScreenChanged()
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        let loads = host.loads.values
        #expect(loads == [first, second])
    }
}
