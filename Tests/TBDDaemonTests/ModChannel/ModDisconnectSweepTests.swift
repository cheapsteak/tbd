import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 1 — `ModDisconnectSweep` clearing the prompts of terminals whose mod
/// stopped polling (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`,
/// "Answering prompts → Clearing"). One `TestDateSource` feeds the channel, the
/// store and the sweep, and every timer runs on an `EventDrivenTestClock`, so
/// passes are driven with `sweepOnce()` or by advancing the sweep's clock.
@Suite(.clockDriven)
struct ModDisconnectSweepTests {

    private actor BroadcastLog {
        private(set) var sets: [Set<UUID>] = []
        func record(_ set: Set<UUID>) { sets.append(set) }
    }

    private struct Harness {
        let dates: TestDateSource
        let channel: ModChannel
        let store: PendingPromptStore
        let sweep: ModDisconnectSweep
        let sweepClock: EventDrivenTestClock
        let broadcasts: BroadcastLog
        let terminal = UUID()

        func open(_ toolUseID: String = "toolu_1") async {
            await store.open(
                terminalID: terminal, sessionID: "s1", toolUseID: toolUseID, toolName: "Bash",
                toolInputJSON: #"{"command":"ls"}"#, suggestionsJSON: nil)
        }

        func openIDs() async -> [String] {
            await store.prompts(forTerminal: terminal).map(\.id)
        }

        /// One poll that returns at once (an item is waiting), stamping
        /// `lastPollAt` with the current date.
        func pollOnce() async {
            let seq = await channel.enqueue(terminalID: terminal, kind: "message", body: "{}") {}
            _ = await channel.poll(terminalID: terminal, after: seq - 1, token: UUID())
        }
    }

    private func makeHarness() -> Harness {
        let dates = TestDateSource()
        let clock = EventDrivenTestClock()
        let sweepClock = EventDrivenTestClock()
        let channel = ModChannel(now: dates.provider, clock: clock)
        let store = PendingPromptStore(now: dates.provider, clock: clock)
        let broadcasts = BroadcastLog()
        let sweep = ModDisconnectSweep(
            channel: channel, store: store,
            broadcast: { await broadcasts.record($0) },
            now: dates.provider, clock: sweepClock)
        return Harness(
            dates: dates, channel: channel, store: store, sweep: sweep,
            sweepClock: sweepClock, broadcasts: broadcasts)
    }

    @Test func defaultsMatchTheSpec() {
        #expect(ModDisconnectSweep.defaultInterval == .seconds(15))
        #expect(ModDisconnectSweep.defaultThreshold == .seconds(60))
    }

    @Test func sweepClearsPromptsAfterSixtySecondsWithoutPoll() async {
        let h = makeHarness()
        await h.pollOnce()
        await h.open()

        // Past the 30 s liveness window but inside the 60 s threshold: kept.
        h.dates.advance(by: 59)
        #expect(await !h.channel.isConnected(terminalID: h.terminal))
        await h.sweep.sweepOnce()
        #expect(await h.openIDs() == ["toolu_1"])
        #expect(await h.broadcasts.sets.isEmpty)

        h.dates.advance(by: 2)
        await h.sweep.sweepOnce()
        #expect(await h.openIDs().isEmpty)
        #expect(await h.broadcasts.sets == [[h.terminal]])

        // Nothing left: a further pass broadcasts nothing.
        await h.sweep.sweepOnce()
        #expect(await h.broadcasts.sets.count == 1)
    }

    /// The clearing ends a held wait request like any other resolution, so
    /// the mod is told to stop waiting.
    @Test func sweepReleasesAHeldWaitAsResolved() async {
        let h = makeHarness()
        await h.pollOnce()
        await h.open()
        let store = h.store
        let terminal = h.terminal
        let waiting = Task {
            await store.waitForAnswer(terminalID: terminal, toolUseID: "toolu_1", token: UUID(), hold: .seconds(25))
        }
        let attached = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await store.isWaiterAttached(terminalID: terminal, toolUseID: "toolu_1")
        }
        #expect(attached != .timedOut)

        h.dates.advance(by: 61)
        await h.sweep.sweepOnce()
        #expect(await waiting.value == .resolved)
    }

    @Test func sweepKeepsPromptsWhilePolling() async {
        let h = makeHarness()
        await h.open()
        let channel = h.channel
        let terminal = h.terminal
        let token = UUID()
        let held = Task { await channel.poll(terminalID: terminal, after: 0, token: token) }
        let attached = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await channel.isPollAttached(terminalID: terminal)
        }
        #expect(attached != .timedOut)

        // A held poll is connected however old its arrival.
        h.dates.advance(by: 300)
        await h.sweep.sweepOnce()
        #expect(await h.openIDs() == ["toolu_1"])

        await channel.pollGone(token: token)
        _ = await held.value

        // Polls every few seconds keep it connected too.
        for _ in 0..<10 {
            h.dates.advance(by: 20)
            await h.pollOnce()
            await h.sweep.sweepOnce()
        }
        #expect(await h.openIDs() == ["toolu_1"])
        #expect(await h.broadcasts.sets.isEmpty)
    }

    /// A terminal that never polled this daemon run is measured from its
    /// newest prompt's `createdAt`, so a prompt opened just now is not swept
    /// before its mod has had the full 60 s to start polling.
    @Test func sweepUsesCreatedAtWhenNeverPolled() async {
        let h = makeHarness()
        await h.open("toolu_1")
        h.dates.advance(by: 100)
        await h.open("toolu_2")
        #expect(await h.channel.lastPollAt(terminalID: h.terminal) == nil)

        // 150 s after the first prompt, 50 s after the newest: kept.
        h.dates.advance(by: 50)
        await h.sweep.sweepOnce()
        #expect(await h.openIDs() == ["toolu_1", "toolu_2"])

        h.dates.advance(by: 11)
        await h.sweep.sweepOnce()
        #expect(await h.openIDs().isEmpty)
        #expect(await h.broadcasts.sets == [[h.terminal]])
    }

    /// Only the quiet terminal is cleared.
    @Test func sweepLeavesOtherTerminalsAlone() async {
        let h = makeHarness()
        let other = UUID()
        await h.open()
        h.dates.advance(by: 61)
        await h.store.open(
            terminalID: other, sessionID: "s2", toolUseID: "toolu_9", toolName: "Bash",
            toolInputJSON: #"{"command":"pwd"}"#, suggestionsJSON: nil)

        await h.sweep.sweepOnce()
        #expect(await h.openIDs().isEmpty)
        #expect(await h.store.prompts(forTerminal: other).map(\.id) == ["toolu_9"])
        #expect(await h.broadcasts.sets == [[h.terminal]])
    }

    /// `start()` runs a pass every 15 s on its clock; `stop()` ends the loop.
    @Test func startSweepsEveryFifteenSeconds() async throws {
        let h = makeHarness()
        await h.open()
        h.dates.advance(by: 61)
        await h.sweep.start()
        try await h.sweepClock.requireAdvanceWhenArmed(by: .seconds(15))
        let store = h.store
        let terminal = h.terminal
        let cleared = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await store.prompts(forTerminal: terminal).isEmpty
        }
        #expect(cleared != .timedOut, "the timed pass never cleared the quiet terminal")
        await h.sweep.stop()
    }
}
