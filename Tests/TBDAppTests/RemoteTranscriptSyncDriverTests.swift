import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: virtual time only. The sync is an injected closure; no daemon.

/// `RemoteTranscriptSyncDriver`: the 3-second cadence while the pane is
/// visible and the app active, stopping when either goes away, and the
/// immediate syncs a send or an agent-state change asks for.
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
    /// `results` (repeating the last one), so a test can script a reset or a
    /// failure.
    private static func makeDriver(
        clock: EventDrivenTestClock,
        syncs: FireRecorder<Int>,
        results: @escaping @MainActor (Int) throws -> RemoteTranscriptSyncResult = { n in
            RemoteTranscriptSyncResult(path: "/cache/s1.jsonl", generation: 1, caughtUp: n > 1)
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
                path: "/cache/s1.jsonl", generation: n == 1 ? 1 : 2, caughtUp: n > 1)
        }
        defer { driver.stop() }
        #expect(driver.snapshot == RemoteTranscriptSyncSnapshot())

        driver.setActive(true)
        _ = await syncs.next(timeout: TestDeadlines.saturatedPass)
        try await Self.armed(clock)
        #expect(driver.snapshot == RemoteTranscriptSyncSnapshot(
            path: "/cache/s1.jsonl", generation: 1, caughtUp: false, refreshToken: 1))

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
}
