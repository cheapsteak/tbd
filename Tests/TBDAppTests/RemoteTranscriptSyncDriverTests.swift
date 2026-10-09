import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: virtual time only. The sync is an injected closure; no daemon.

/// `RemoteTranscriptSyncDriver`: the 3-second cadence while the pane is
/// visible and the app active, stopping when either goes away, the immediate
/// syncs a send or an agent-state change asks for, and the back-to-back syncs
/// of a load that is not caught up yet.
///
/// The clock is `EventDrivenTestClock`, so every positive assertion goes
/// through `syncs.next(timeout: TestDeadlines.saturatedPass)` and every negative one reads the recorder after an
/// explicit `settle()`.
@MainActor
@Suite("Remote transcript sync driver", .clockDriven, .serialized)
struct RemoteTranscriptSyncDriverTests {
    private static let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
    private static let interval = Duration.seconds(3)
    /// The loop is an unstructured main-actor task, so it arms only once it
    /// has had a turn on the main actor — see `EventDrivenTestClock.sleeperArmed`.
    private static let mainActorHop = TestDeadlines.saturatedPass

    /// A driver whose every sync records its ordinal and answers from
    /// `results`, so a test can script a reset, a failure, or a load that is
    /// not caught up. The default answer is caught up, so the driver waits the
    /// interval after every sync. A script must end caught up: these syncs
    /// never suspend, so an endless run of not-caught-up answers would hold
    /// the main actor.
    private static func makeDriver(
        clock: EventDrivenTestClock,
        syncs: FireRecorder<Int>,
        results: @escaping @MainActor (Int) throws -> RemoteTranscriptSyncResult = { _ in
            RemoteTranscriptSyncResult(path: "/cache/s1.jsonl", generation: 1, caughtUp: true)
        }
    ) -> RemoteTranscriptSyncDriver {
        var count = 0
        return RemoteTranscriptSyncDriver(
            selection: selection,
            sync: { selectionSeen in
                #expect(selectionSeen == selection)
                count += 1
                let ordinal = count
                defer { syncs.record(ordinal) }
                return try results(ordinal)
            },
            interval: interval,
            clock: clock)
    }

    private static func armed(_ clock: EventDrivenTestClock) async throws {
        try await clock.requireSleeperArmed(timeout: mainActorHop)
    }

    @Test("going active syncs at once, then every 3 seconds")
    func cadence() async throws {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let driver = Self.makeDriver(clock: clock, syncs: syncs)
        defer { driver.stop() }

        driver.setActive(true)
        #expect(await syncs.next(timeout: TestDeadlines.saturatedPass) == 1, "the first sync does not wait for a tick")

        // Short of the interval: nothing.
        try await Self.armed(clock)
        await clock.advance(by: .seconds(2))
        await settle()
        #expect(syncs.values == [1], "a sync before the 3 s tick means the cadence is too fast")

        // Crossing it: the second sync.
        await clock.advance(by: .seconds(1))
        #expect(await syncs.next(timeout: TestDeadlines.saturatedPass) == 2)

        try await Self.armed(clock)
        await clock.advance(by: Self.interval)
        #expect(await syncs.next(timeout: TestDeadlines.saturatedPass) == 3)
    }

    @Test("each sync publishes path, generation and caughtUp, and bumps the refresh token")
    func snapshotFollowsEachSync() async throws {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let driver = Self.makeDriver(clock: clock, syncs: syncs) { n in
            RemoteTranscriptSyncResult(
                path: "/cache/s1.jsonl", generation: n == 1 ? 1 : 2, caughtUp: true)
        }
        defer { driver.stop() }
        #expect(driver.snapshot == RemoteTranscriptSyncSnapshot())

        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        #expect(driver.snapshot == RemoteTranscriptSyncSnapshot(
            path: "/cache/s1.jsonl", generation: 1, caughtUp: true, refreshToken: 1))

        await clock.advance(by: Self.interval)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        #expect(driver.snapshot == RemoteTranscriptSyncSnapshot(
            path: "/cache/s1.jsonl", generation: 2, caughtUp: true, refreshToken: 2))
    }

    @Test("a failed sync keeps the last snapshot, reports the error, and a success clears it")
    func failureKeepsSnapshot() async throws {
        struct Refused: Error, LocalizedError {
            var errorDescription: String? { "not implemented" }
        }
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let driver = Self.makeDriver(clock: clock, syncs: syncs) { n in
            if n == 2 { throw Refused() }
            return RemoteTranscriptSyncResult(path: "/p", generation: 1, caughtUp: true)
        }
        defer { driver.stop() }

        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        await clock.advance(by: Self.interval)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        #expect(driver.snapshot.path == "/p")
        #expect(driver.snapshot.refreshToken == 1, "a failed sync read nothing new")
        #expect(driver.snapshot.error == "not implemented")

        await clock.advance(by: Self.interval)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        #expect(driver.snapshot.error == nil)
        #expect(driver.snapshot.refreshToken == 2)
    }

    @Test("a cancelled sync is not reported as a failure")
    func cancellationIsNotAFailure() async throws {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let driver = Self.makeDriver(clock: clock, syncs: syncs) { n in
            if n == 1 { throw CancellationError() }
            return RemoteTranscriptSyncResult(path: "/p", generation: 1, caughtUp: true)
        }
        defer { driver.stop() }

        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        #expect(driver.snapshot == RemoteTranscriptSyncSnapshot(), "a cancelled call says nothing about the daemon")

        await clock.advance(by: Self.interval)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        #expect(driver.snapshot.refreshToken == 1)
    }

    @Test("going inactive stops the cadence; going active again syncs at once")
    func stopsWhenInactive() async throws {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let driver = Self.makeDriver(clock: clock, syncs: syncs)
        defer { driver.stop() }

        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)

        driver.setActive(false)
        await settle()
        await clock.advance(by: .seconds(30))
        await settle()
        #expect(syncs.values == [1], "a hidden pane or an inactive app must not sync")

        driver.setActive(true)
        #expect(await syncs.next(timeout: TestDeadlines.saturatedPass) == 2)
    }

    @Test("syncNow runs a sync without waiting for the tick, and restarts the cadence")
    func syncNowIsImmediate() async throws {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let driver = Self.makeDriver(clock: clock, syncs: syncs)
        defer { driver.stop() }

        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)

        driver.syncNow()
        #expect(await syncs.next(timeout: TestDeadlines.saturatedPass) == 2, "no virtual time passed, so only the trigger can explain it")

        try await Self.armed(clock)
        await clock.advance(by: Self.interval)
        #expect(await syncs.next(timeout: TestDeadlines.saturatedPass) == 3)
    }

    @Test("syncNow while inactive does nothing")
    func syncNowWhileInactive() async {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let driver = Self.makeDriver(clock: clock, syncs: syncs)
        defer { driver.stop() }

        driver.syncNow()
        await settle()
        #expect(syncs.values.isEmpty)
    }

    @Test("an agent-state change syncs at once; the first sighting and a repeat do not")
    func agentStateChangeTriggers() async throws {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let driver = Self.makeDriver(clock: clock, syncs: syncs)
        defer { driver.stop() }
        let working = RemoteTranscriptSyncDriver.AgentStateMark(state: .working, at: "t1")
        let idle = RemoteTranscriptSyncDriver.AgentStateMark(state: .idle, at: "t2")

        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)

        driver.noteAgentState(working)
        await settle()
        #expect(syncs.values == [1], "the first sighting only records")

        driver.noteAgentState(idle)
        #expect(await syncs.next(timeout: TestDeadlines.saturatedPass) == 2)

        try await Self.armed(clock)
        driver.noteAgentState(idle)
        await settle()
        #expect(syncs.values == [1, 2], "an unchanged state must not trigger")

        // The same state at a later time is a change: the agent went
        // somewhere and came back between two reads.
        driver.noteAgentState(.init(state: .idle, at: "t3"))
        #expect(await syncs.next(timeout: TestDeadlines.saturatedPass) == 3)
    }

    // MARK: - Catching up

    /// Lets a sync closure built before the driver read the driver's snapshot
    /// when the sync starts.
    @MainActor
    private final class DriverRef {
        weak var driver: RemoteTranscriptSyncDriver?
    }

    /// What one sync saw as it started: its ordinal and the refresh token the
    /// syncs before it had published.
    private struct SyncStart: Equatable, Sendable {
        let ordinal: Int
        let tokenSeen: Int
    }

    /// A driver whose syncs record their start, park on `gate`, then answer
    /// `caughtUp(ordinal)`.
    private static func makeGatedDriver(
        clock: EventDrivenTestClock,
        starts: FireRecorder<SyncStart>,
        gate: RemoteTranscriptSyncGate,
        caughtUp: @escaping @MainActor (Int) -> Bool
    ) -> RemoteTranscriptSyncDriver {
        let ref = DriverRef()
        var count = 0
        let driver = RemoteTranscriptSyncDriver(
            selection: selection,
            sync: { _ in
                count += 1
                let ordinal = count
                starts.record(SyncStart(
                    ordinal: ordinal, tokenSeen: ref.driver?.snapshot.refreshToken ?? -1))
                await gate.wait()
                return RemoteTranscriptSyncResult(
                    path: "/cache/s1.jsonl", generation: 1, caughtUp: caughtUp(ordinal))
            },
            interval: interval,
            clock: clock)
        ref.driver = driver
        return driver
    }

    @Test("a sync that is not caught up is followed at once after publishing; caught up, the cadence resumes")
    func catchUpSyncsBackToBack() async throws {
        let clock = EventDrivenTestClock()
        let starts = FireRecorder<SyncStart>()
        let gate = RemoteTranscriptSyncGate()
        let driver = Self.makeGatedDriver(clock: clock, starts: starts, gate: gate) { $0 >= 3 }
        defer {
            driver.stop()
            gate.open()
        }

        driver.setActive(true)
        #expect(await starts.next(timeout: TestDeadlines.saturatedPass) == SyncStart(ordinal: 1, tokenSeen: 0))
        gate.releaseOne()
        // No virtual time passes: only the catch-up rule explains sync 2, and
        // it starts after sync 1's page was published.
        #expect(await starts.next(timeout: TestDeadlines.saturatedPass) == SyncStart(ordinal: 2, tokenSeen: 1),
                "a load that is not caught up must re-sync at once, after publishing its page")
        #expect(driver.snapshot.caughtUp == false)
        gate.releaseOne()
        #expect(await starts.next(timeout: TestDeadlines.saturatedPass) == SyncStart(ordinal: 3, tokenSeen: 2))
        gate.releaseOne()

        // Sync 3 caught up: back to the cadence.
        try await Self.armed(clock)
        #expect(driver.snapshot == RemoteTranscriptSyncSnapshot(
            path: "/cache/s1.jsonl", generation: 1, caughtUp: true, refreshToken: 3))
        await clock.advance(by: .seconds(2))
        await settle()
        #expect(starts.values.map(\.ordinal) == [1, 2, 3], "a caught-up sync must wait the interval")
        await clock.advance(by: .seconds(1))
        #expect(await starts.next(timeout: TestDeadlines.saturatedPass)?.ordinal == 4)
    }

    @Test("going inactive mid-catch-up starts no further sync, but the one in flight still publishes")
    func inactiveStopsCatchUp() async throws {
        let clock = EventDrivenTestClock()
        let starts = FireRecorder<SyncStart>()
        let gate = RemoteTranscriptSyncGate()
        let driver = Self.makeGatedDriver(clock: clock, starts: starts, gate: gate) { _ in false }
        defer {
            driver.stop()
            gate.open()
        }

        driver.setActive(true)
        #expect(await starts.next(timeout: TestDeadlines.saturatedPass)?.ordinal == 1)
        gate.releaseOne()
        #expect(await starts.next(timeout: TestDeadlines.saturatedPass)?.ordinal == 2)

        // Hidden while sync 2 is in flight; then let it answer.
        driver.setActive(false)
        gate.releaseOne()
        let published = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { driver.snapshot.refreshToken == 2 }
        }
        #expect(published == .satisfied,
                "the sync in flight when the pane hid fetched data already persisted; it must still publish")
        #expect(driver.snapshot.caughtUp == false)
        await settle()
        await clock.advance(by: .seconds(30))
        await settle()
        #expect(starts.values.map(\.ordinal) == [1, 2], "a hidden pane must not start another sync")

        driver.setActive(true)
        #expect(await starts.next(timeout: TestDeadlines.saturatedPass) == SyncStart(ordinal: 3, tokenSeen: 2))
    }

    @Test("a sync that finishes after going inactive publishes its result")
    func inFlightSyncPublishesAfterInactive() async throws {
        let clock = EventDrivenTestClock()
        let starts = FireRecorder<SyncStart>()
        let gate = RemoteTranscriptSyncGate()
        let driver = Self.makeGatedDriver(clock: clock, starts: starts, gate: gate) { _ in true }
        defer {
            driver.stop()
            gate.open()
        }

        driver.setActive(true)
        #expect(await starts.next(timeout: TestDeadlines.saturatedPass)?.ordinal == 1)
        driver.setActive(false)
        gate.releaseOne()
        let published = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { driver.snapshot.refreshToken == 1 }
        }
        #expect(published == .satisfied)
        #expect(driver.snapshot == RemoteTranscriptSyncSnapshot(
            path: "/cache/s1.jsonl", generation: 1, caughtUp: true, refreshToken: 1))
    }

    /// Going inactive does not wait for the sync in flight, so going active
    /// again starts a second sync while the first is still out. When the
    /// newer one publishes first, the older one's late answer must not move
    /// the snapshot backwards.
    @Test("an older sync finishing after a newer one has published is dropped")
    func olderResultNeverOverwritesNewer() async throws {
        let clock = EventDrivenTestClock()
        let starts = FireRecorder<Int>()
        let olderGate = RemoteTranscriptSyncGate()
        let newerGate = RemoteTranscriptSyncGate()
        var count = 0
        let driver = RemoteTranscriptSyncDriver(
            selection: Self.selection,
            sync: { _ in
                count += 1
                let ordinal = count
                starts.record(ordinal)
                await (ordinal == 1 ? olderGate : newerGate).wait()
                return RemoteTranscriptSyncResult(
                    path: "/cache/s1.jsonl", generation: ordinal, caughtUp: true)
            },
            interval: Self.interval,
            clock: clock)
        defer {
            driver.stop()
            olderGate.open()
            newerGate.open()
        }

        driver.setActive(true)
        #expect(await starts.next(timeout: TestDeadlines.saturatedPass) == 1)
        driver.setActive(false)
        driver.setActive(true)
        #expect(await starts.next(timeout: TestDeadlines.saturatedPass) == 2,
                "going active again starts a sync while the first is still in flight")

        newerGate.releaseOne()
        try await Self.armed(clock)
        #expect(driver.snapshot == RemoteTranscriptSyncSnapshot(
            path: "/cache/s1.jsonl", generation: 2, caughtUp: true, refreshToken: 1))

        olderGate.releaseOne()
        await settle()
        #expect(driver.snapshot == RemoteTranscriptSyncSnapshot(
            path: "/cache/s1.jsonl", generation: 2, caughtUp: true, refreshToken: 1),
                "the older sync's late answer replaced the newer one")
    }

    @Test("a sync that finishes after stop() publishes nothing")
    func inFlightSyncAfterStopIsDropped() async throws {
        let clock = EventDrivenTestClock()
        let starts = FireRecorder<SyncStart>()
        let gate = RemoteTranscriptSyncGate()
        let driver = Self.makeGatedDriver(clock: clock, starts: starts, gate: gate) { _ in true }
        defer { gate.open() }

        driver.setActive(true)
        #expect(await starts.next(timeout: TestDeadlines.saturatedPass)?.ordinal == 1)
        driver.stop()
        gate.releaseOne()
        await settle()
        await clock.advance(by: .seconds(30))
        await settle()
        #expect(driver.snapshot == RemoteTranscriptSyncSnapshot(),
                "a retired driver's pane is gone or shows another session")
        #expect(starts.values.map(\.ordinal) == [1])
    }

    @Test("the initial snapshot is what the driver shows before any sync publishes")
    func initialSnapshotSeedsThePane() async throws {
        let clock = EventDrivenTestClock()
        let starts = FireRecorder<SyncStart>()
        let gate = RemoteTranscriptSyncGate()
        let seed = RemoteTranscriptSyncSnapshot(path: "/cache/s1.jsonl", generation: 4, caughtUp: false)
        let ref = DriverRef()
        let driver = RemoteTranscriptSyncDriver(
            selection: Self.selection,
            sync: { _ in
                starts.record(SyncStart(ordinal: 1, tokenSeen: ref.driver?.snapshot.refreshToken ?? -1))
                await gate.wait()
                return RemoteTranscriptSyncResult(path: "/cache/s1.jsonl", generation: 4, caughtUp: true)
            },
            initialSnapshot: seed,
            interval: Self.interval,
            clock: clock)
        ref.driver = driver
        defer {
            driver.stop()
            gate.open()
        }
        #expect(driver.snapshot == seed)

        driver.setActive(true)
        _ = await starts.next(timeout: TestDeadlines.saturatedPass)
        #expect(driver.snapshot == seed, "the seed stands while the first sync is still running")
    }

    @Test("a failed sync waits the interval even while the load is not caught up")
    func failureMidCatchUpWaits() async throws {
        struct Refused: Error {}
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        // 1 not caught up, 2 fails, 3 not caught up, 4 onward caught up.
        let driver = Self.makeDriver(clock: clock, syncs: syncs) { n in
            if n == 2 { throw Refused() }
            return RemoteTranscriptSyncResult(path: "/p", generation: 1, caughtUp: n >= 4)
        }
        defer { driver.stop() }

        driver.setActive(true)
        #expect(await syncs.next(timeout: TestDeadlines.saturatedPass) == 1)
        #expect(await syncs.next(timeout: TestDeadlines.saturatedPass) == 2, "not caught up: the next sync is immediate")
        try await Self.armed(clock)
        await settle()
        #expect(syncs.values == [1, 2], "a failure must not be retried without waiting")

        await clock.advance(by: Self.interval)
        #expect(await syncs.next(timeout: TestDeadlines.saturatedPass) == 3)
        // Sync 3 succeeded without catching up, so sync 4 follows at once.
        #expect(await syncs.next(timeout: TestDeadlines.saturatedPass) == 4)
    }
}

/// Holds each remote transcript sync until the test releases it, so a test can
/// look at a driver while a sync is in flight. A release that arrives before
/// its sync parks is banked, and `open()` lets everything through for
/// teardown. Shared by the driver and session suites.
@MainActor
final class RemoteTranscriptSyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var banked = 0
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        if banked > 0 {
            banked -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseOne() {
        if waiters.isEmpty {
            banked += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

// MARK: - Earlier history

/// `RemoteTranscriptSyncDriver.loadEarlier(trigger:)` and `noteNearTop(_:)`:
/// one `remote.transcriptLoadEarlier` in flight at a time, only while the
/// daemon reports `hasEarlier`; a failure waits for the next entry into the
/// top zone or the header's button; `head` never moves backwards within a
/// generation; a newer generation resets the earlier-history state.
extension RemoteTranscriptSyncDriverTests {
    private struct Refused: Error, LocalizedError {
        var errorDescription: String? { "nope" }
    }

    /// The cache a pane mounts over: generation 1, head 0, more above.
    private static func seed(hasEarlier: Bool = true) -> RemoteTranscriptSyncSnapshot {
        var seed = RemoteTranscriptSyncSnapshot(path: "/cache/s1.jsonl", generation: 1, caughtUp: false)
        seed.hasEarlier = hasEarlier
        return seed
    }

    private static func page(
        generation: Int = 1, head: Int, reachedStart: Bool = false, expired: Bool = false
    ) -> RemoteTranscriptLoadEarlierResult {
        RemoteTranscriptLoadEarlierResult(
            generation: generation, head: head, reachedStart: reachedStart, expired: expired)
    }

    /// A driver whose loads record their ordinal and answer from `load`, and
    /// whose syncs answer from `sync` (caught up, generation 1, head 0, more
    /// above, by default).
    private static func makeLoadingDriver(
        clock: EventDrivenTestClock,
        seed: RemoteTranscriptSyncSnapshot = RemoteTranscriptSyncDriverTests.seed(),
        syncs: FireRecorder<Int> = FireRecorder<Int>(),
        loads: FireRecorder<Int>,
        sync: @escaping @MainActor (Int) throws -> RemoteTranscriptSyncResult = { _ in
            RemoteTranscriptSyncResult(
                path: "/cache/s1.jsonl", generation: 1, caughtUp: true, head: 0, hasEarlier: true)
        },
        load: @escaping @MainActor (Int) async throws -> RemoteTranscriptLoadEarlierResult
    ) -> RemoteTranscriptSyncDriver {
        var syncCount = 0
        var loadCount = 0
        return RemoteTranscriptSyncDriver(
            selection: selection,
            sync: { _ in
                syncCount += 1
                let ordinal = syncCount
                defer { syncs.record(ordinal) }
                return try sync(ordinal)
            },
            loadEarlier: { selectionSeen in
                #expect(selectionSeen == selection)
                loadCount += 1
                let ordinal = loadCount
                loads.record(ordinal)
                return try await load(ordinal)
            },
            initialSnapshot: seed,
            interval: interval,
            clock: clock)
    }

    private static func until(
        _ driver: RemoteTranscriptSyncDriver,
        _ condition: @escaping @MainActor (RemoteTranscriptSyncSnapshot) -> Bool
    ) async -> PollOutcome {
        await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { condition(driver.snapshot) }
        }
    }

    @Test("a sync publishes head and hasEarlier")
    func syncPublishesHeadAndHasEarlier() async throws {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let driver = Self.makeDriver(clock: clock, syncs: syncs) { _ in
            RemoteTranscriptSyncResult(
                path: "/cache/s1.jsonl", generation: 1, caughtUp: true, head: 2, hasEarlier: true)
        }
        defer { driver.stop() }

        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        #expect(driver.snapshot.head == 2)
        #expect(driver.snapshot.hasEarlier)
        #expect(driver.snapshot.earlier == .idle)
    }

    @Test("near the top with hasEarlier loads once")
    func oneLoadInFlight() async throws {
        let clock = EventDrivenTestClock()
        let loads = FireRecorder<Int>()
        let gate = RemoteTranscriptSyncGate()
        let driver = Self.makeLoadingDriver(clock: clock, loads: loads) { _ in
            await gate.wait()
            return Self.page(head: 1)
        }
        defer {
            driver.stop()
            gate.open()
        }

        driver.noteNearTop(true)
        #expect(driver.snapshot.earlier == .loading)
        #expect(await loads.next(timeout: TestDeadlines.saturatedPass) == 1)

        driver.loadEarlier(trigger: .nearTop)
        driver.loadEarlier(trigger: .button)
        driver.noteNearTop(false)
        driver.noteNearTop(true)
        await settle()
        #expect(loads.values == [1], "a second call while one is in flight")
        #expect(driver.snapshot.earlier == .loading)

        // Out of the zone, so the success below does not chain a second load.
        driver.noteNearTop(false)
        gate.releaseOne()
        #expect(await Self.until(driver) { $0.head == 1 } == .satisfied)
        #expect(loads.values == [1])
    }

    @Test("no load without hasEarlier")
    func noLoadWithoutHasEarlier() async {
        let clock = EventDrivenTestClock()
        let loads = FireRecorder<Int>()
        let driver = Self.makeLoadingDriver(
            clock: clock, seed: Self.seed(hasEarlier: false), loads: loads
        ) { _ in Self.page(head: 1) }
        defer { driver.stop() }

        driver.noteNearTop(true)
        driver.loadEarlier(trigger: .nearTop)
        driver.loadEarlier(trigger: .button)
        await settle()
        #expect(loads.values.isEmpty)
        #expect(driver.snapshot.earlier == .idle)
    }

    @Test("a successful load publishes the new head and bumps the refresh token")
    func successfulLoadPublishes() async {
        let clock = EventDrivenTestClock()
        let loads = FireRecorder<Int>()
        let driver = Self.makeLoadingDriver(clock: clock, loads: loads) { _ in Self.page(head: 1) }
        defer { driver.stop() }
        let tokenBefore = driver.snapshot.refreshToken

        driver.loadEarlier(trigger: .nearTop)
        #expect(await Self.until(driver) { $0.head == 1 } == .satisfied)
        #expect(driver.snapshot.earlier == .idle)
        #expect(driver.snapshot.hasEarlier)
        #expect(driver.snapshot.generation == 1)
        #expect(driver.snapshot.refreshToken == tokenBefore + 1)
    }

    @Test("reachedStart and expired end the history")
    func reachedStartAndExpired() async {
        let clock = EventDrivenTestClock()
        let loads = FireRecorder<Int>()
        let start = Self.makeLoadingDriver(clock: clock, loads: loads) { _ in
            Self.page(head: 1, reachedStart: true)
        }
        defer { start.stop() }
        start.loadEarlier(trigger: .nearTop)
        #expect(await Self.until(start) { $0.earlier == .reachedStart } == .satisfied)
        #expect(start.snapshot.hasEarlier == false)

        let expiredLoads = FireRecorder<Int>()
        let expired = Self.makeLoadingDriver(clock: clock, loads: expiredLoads) { _ in
            Self.page(head: 0, reachedStart: true, expired: true)
        }
        defer { expired.stop() }
        expired.loadEarlier(trigger: .nearTop)
        #expect(await Self.until(expired) { $0.earlier == .expired } == .satisfied)
        #expect(expired.snapshot.hasEarlier == false)

        // Neither asks again.
        start.loadEarlier(trigger: .button)
        expired.loadEarlier(trigger: .button)
        await settle()
        #expect(loads.values == [1])
        #expect(expiredLoads.values == [1])
    }

    @Test("a failed load waits for the next scroll, or the button")
    func failureWaitsForTheNextScroll() async throws {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let loads = FireRecorder<Int>()
        // Loads 1 and 2 fail; 3 succeeds.
        let driver = Self.makeLoadingDriver(clock: clock, syncs: syncs, loads: loads) { n in
            if n < 3 { throw Refused() }
            return Self.page(head: 1)
        }
        defer { driver.stop() }

        driver.noteNearTop(true)
        // Consume load 1 here: `next()` hands out the oldest unreturned value,
        // so leaving it buffered would make the retry assertions below read
        // 1 and 2 instead of 2 and 3.
        #expect(await loads.next(timeout: TestDeadlines.saturatedPass) == 1)
        #expect(await Self.until(driver) { $0.earlier == .failed("nope") } == .satisfied)

        // A sync while still near the top is not a retry.
        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        driver.noteNearTop(true)
        await settle()
        #expect(loads.values == [1], "a failure was retried without a new scroll into the zone")
        #expect(driver.snapshot.earlier == .failed("nope"))

        // Leaving the zone and coming back is the next scroll.
        driver.noteNearTop(false)
        driver.noteNearTop(true)
        #expect(await loads.next(timeout: TestDeadlines.saturatedPass) == 2)
        #expect(await Self.until(driver) { $0.earlier == .failed("nope") } == .satisfied)

        // The header's button retries too. Scrolled away first, so the success
        // that follows does not chain another load.
        driver.noteNearTop(false)
        driver.loadEarlier(trigger: .button)
        #expect(await loads.next(timeout: TestDeadlines.saturatedPass) == 3)
        #expect(await Self.until(driver) { $0.head == 1 } == .satisfied)
        #expect(driver.snapshot.earlier == .idle)
    }

    @Test("head never moves backwards within a generation")
    func headNeverMovesBackwards() async throws {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let loads = FireRecorder<Int>()
        // The sync read the cache before the prepend: head 0.
        let driver = Self.makeLoadingDriver(clock: clock, syncs: syncs, loads: loads) { _ in
            Self.page(head: 1)
        }
        defer { driver.stop() }

        driver.loadEarlier(trigger: .nearTop)
        #expect(await Self.until(driver) { $0.head == 1 } == .satisfied)

        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        #expect(driver.snapshot.head == 1, "a sync's stale head moved the pane backwards")
        #expect(driver.snapshot.caughtUp, "the rest of the sync still publishes")
    }

    @Test("a sync cannot revive hasEarlier once a load reached the start")
    func syncCannotReviveHasEarlier() async throws {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let loads = FireRecorder<Int>()
        let driver = Self.makeLoadingDriver(clock: clock, syncs: syncs, loads: loads) { _ in
            Self.page(head: 0, reachedStart: true)
        }
        defer { driver.stop() }

        driver.loadEarlier(trigger: .nearTop)
        #expect(await Self.until(driver) { $0.earlier == .reachedStart } == .satisfied)

        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        #expect(driver.snapshot.hasEarlier == false)
        #expect(driver.snapshot.earlier == .reachedStart)
    }

    @Test("a newer generation from a sync resets the earlier state")
    func newerGenerationResets() async throws {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let loads = FireRecorder<Int>()
        let driver = Self.makeLoadingDriver(
            clock: clock, syncs: syncs, loads: loads,
            sync: { _ in
                RemoteTranscriptSyncResult(
                    path: "/cache/s1.jsonl", generation: 2, caughtUp: true, head: 5, hasEarlier: true)
            },
            load: { _ in Self.page(head: 1, reachedStart: true) })
        defer { driver.stop() }

        driver.loadEarlier(trigger: .nearTop)
        #expect(await Self.until(driver) { $0.earlier == .reachedStart } == .satisfied)

        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        #expect(driver.snapshot.generation == 2)
        #expect(driver.snapshot.head == 5)
        #expect(driver.snapshot.hasEarlier)
        #expect(driver.snapshot.earlier == .idle)
    }

    @Test("a load answered under another generation is treated as that reset")
    func loadUnderAnotherGenerationIsAReset() async {
        let clock = EventDrivenTestClock()
        let loads = FireRecorder<Int>()
        let driver = Self.makeLoadingDriver(clock: clock, loads: loads) { _ in
            Self.page(generation: 2, head: 3)
        }
        defer { driver.stop() }
        let tokenBefore = driver.snapshot.refreshToken

        driver.loadEarlier(trigger: .nearTop)
        #expect(await Self.until(driver) { $0.generation == 2 } == .satisfied)
        #expect(driver.snapshot.head == 3)
        #expect(driver.snapshot.hasEarlier == false, "only the next sync can say what the new cache holds")
        #expect(driver.snapshot.earlier == .idle)
        #expect(driver.snapshot.refreshToken == tokenBefore + 1)
    }

    @Test("a sync published while the table is near the top loads earlier history")
    func syncNearTopLoads() async throws {
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        let loads = FireRecorder<Int>()
        let driver = Self.makeLoadingDriver(
            clock: clock, seed: Self.seed(hasEarlier: false), syncs: syncs, loads: loads
        ) { _ in Self.page(head: 1, reachedStart: true) }
        defer { driver.stop() }

        // The table is already at the top before anything says there is more.
        driver.noteNearTop(true)
        await settle()
        #expect(loads.values.isEmpty)

        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        #expect(await loads.next(timeout: TestDeadlines.saturatedPass) == 1,
                "hasEarlier arriving with the table at the top must start a load")
    }

    @Test("a successful load that leaves the table near the top chains to the next until the start")
    func successNearTopChainsUntilReachedStart() async {
        let clock = EventDrivenTestClock()
        let loads = FireRecorder<Int>()
        // Each page lands without moving the table out of the zone (a page of
        // tool activity folding into the top group); the third reaches the
        // start. No sync runs: the driver is never made active, so only the
        // completions themselves can start the next load.
        let driver = Self.makeLoadingDriver(clock: clock, loads: loads) { n in
            Self.page(head: n, reachedStart: n == 3)
        }
        defer { driver.stop() }

        driver.noteNearTop(true)
        #expect(await Self.until(driver) { $0.earlier == .reachedStart } == .satisfied,
                "paging stalled near the top after load(s) \(loads.values)")
        #expect(loads.values == [1, 2, 3])
        #expect(driver.snapshot.head == 3)
        #expect(driver.snapshot.hasEarlier == false)
    }

    @Test("a successful load after the table left the zone does not chain")
    func successAwayFromTopDoesNotChain() async {
        let clock = EventDrivenTestClock()
        let loads = FireRecorder<Int>()
        let gate = RemoteTranscriptSyncGate()
        let driver = Self.makeLoadingDriver(clock: clock, loads: loads) { _ in
            await gate.wait()
            return Self.page(head: 1)
        }
        defer {
            driver.stop()
            gate.open()
        }

        driver.noteNearTop(true)
        #expect(await loads.next(timeout: TestDeadlines.saturatedPass) == 1)
        // The prepend pushed the reader's rows down out of the zone.
        driver.noteNearTop(false)
        gate.releaseOne()
        #expect(await Self.until(driver) { $0.head == 1 } == .satisfied)
        await settle()
        #expect(loads.values == [1])
        #expect(driver.snapshot.earlier == .idle)

        // Scrolling back up into the zone is the next entry, and it loads.
        driver.noteNearTop(true)
        #expect(await loads.next(timeout: TestDeadlines.saturatedPass) == 2)
    }

    @Test("a failed load near the top does not chain")
    func failureNearTopDoesNotChain() async {
        let clock = EventDrivenTestClock()
        let loads = FireRecorder<Int>()
        // Load 1 succeeds and chains; load 2 fails, and nothing follows it.
        let driver = Self.makeLoadingDriver(clock: clock, loads: loads) { n in
            if n >= 2 { throw Refused() }
            return Self.page(head: n)
        }
        defer { driver.stop() }

        driver.noteNearTop(true)
        #expect(await Self.until(driver) { $0.earlier == .failed("nope") } == .satisfied)
        await settle()
        #expect(loads.values == [1, 2], "a failure was retried without a new scroll into the zone")
        #expect(driver.snapshot.head == 1)
    }

    @Test("a load result after stop publishes nothing")
    func loadAfterStopIsDropped() async {
        let clock = EventDrivenTestClock()
        let loads = FireRecorder<Int>()
        let gate = RemoteTranscriptSyncGate()
        let driver = Self.makeLoadingDriver(clock: clock, loads: loads) { _ in
            await gate.wait()
            return Self.page(head: 1)
        }
        defer { gate.open() }

        driver.loadEarlier(trigger: .nearTop)
        #expect(await loads.next(timeout: TestDeadlines.saturatedPass) == 1)
        let held = driver.snapshot
        driver.stop()
        gate.releaseOne()
        await settle()
        #expect(driver.snapshot == held, "a retired driver's pane is gone or shows another session")

        driver.loadEarlier(trigger: .button)
        await settle()
        #expect(loads.values == [1], "a retired driver must not load")
    }
}
