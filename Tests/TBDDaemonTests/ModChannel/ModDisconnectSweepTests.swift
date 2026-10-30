import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 1 — `ModDisconnectSweep` clearing open prompts no mod is waiting on
/// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`, "Answering
/// prompts → Daemon: the store"). Liveness is per prompt: a prompt with no
/// wait attached, and none attached or released for more than 60 s, is
/// cleared whatever the terminal's poll is doing. One `TestDateSource` feeds
/// the channel, the store and the sweep, and every timer runs on an
/// `EventDrivenTestClock`, so passes are driven with `sweepOnce()` or by
/// advancing the sweep's clock.
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

        /// Starts a wait request on the prompt and returns once it is held.
        func attachWait(_ toolUseID: String = "toolu_1", token: UUID = UUID()) async -> Task<PendingPromptStore.WaitResult, Never> {
            let store = self.store
            let terminal = self.terminal
            let waiting = Task {
                await store.waitForAnswer(terminalID: terminal, toolUseID: toolUseID, token: token, hold: .seconds(25))
            }
            let attached = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
                await store.isWaiterAttached(terminalID: terminal, toolUseID: toolUseID)
            }
            #expect(attached != .timedOut, "the wait request never attached")
            return waiting
        }

        /// A wait request that attaches and then loses its connection, as the
        /// mod's hold cycle ends: the prompt is left with no wait attached.
        func waitAndLeave(_ toolUseID: String = "toolu_1") async {
            let token = UUID()
            let waiting = await attachWait(toolUseID, token: token)
            await store.waiterGone(token: token)
            #expect(await waiting.value == .pending)
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
            store: store,
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

    /// The terminal keeps polling the whole time, yet the prompt nobody waits
    /// on is cleared 60 s after its last wait ended: poll state is not read.
    @Test func sweepClearsAPromptWhoseWaitsStoppedWhileTheTerminalPolls() async {
        let h = makeHarness()
        await h.open()
        await h.waitAndLeave()

        for _ in 0..<3 {
            h.dates.advance(by: 20)
            await h.pollOnce()
        }
        #expect(await h.channel.isConnected(terminalID: h.terminal))
        // 60 s after the wait ended, not more: kept.
        await h.sweep.sweepOnce()
        #expect(await h.openIDs() == ["toolu_1"])
        #expect(await h.broadcasts.sets.isEmpty)

        h.dates.advance(by: 1)
        await h.pollOnce()
        #expect(await h.channel.isConnected(terminalID: h.terminal))
        await h.sweep.sweepOnce()
        #expect(await h.openIDs().isEmpty)
        #expect(await h.broadcasts.sets == [[h.terminal]])

        // Nothing left: a further pass broadcasts nothing.
        await h.sweep.sweepOnce()
        #expect(await h.broadcasts.sets.count == 1)
    }

    /// A held wait keeps its prompt however long it is held, and with no poll
    /// at all: a mod whose poll loop is down but whose dialog waits work
    /// keeps its cards.
    @Test func sweepKeepsAPromptWithAWaitAttached() async {
        let h = makeHarness()
        await h.open()
        let waiting = await h.attachWait()

        h.dates.advance(by: 300)
        #expect(await !h.channel.isConnected(terminalID: h.terminal))
        await h.sweep.sweepOnce()
        #expect(await h.openIDs() == ["toolu_1"])
        #expect(await h.broadcasts.sets.isEmpty)

        // A close ends the prompt and tells the held wait to stop.
        await h.store.closed(terminalID: h.terminal, toolUseID: "toolu_1")
        #expect(await waiting.value == .resolved)
    }

    /// Waits that come and go every 20 s keep the prompt; once they stop it
    /// goes 60 s after the last one ended.
    @Test func sweepKeepsAPromptWhoseLastWaitEndedUnderSixtySecondsAgo() async {
        let h = makeHarness()
        await h.open()
        for _ in 0..<10 {
            h.dates.advance(by: 20)
            await h.waitAndLeave()
            await h.sweep.sweepOnce()
        }
        #expect(await h.openIDs() == ["toolu_1"])

        h.dates.advance(by: 59)
        await h.sweep.sweepOnce()
        #expect(await h.openIDs() == ["toolu_1"])
        #expect(await h.broadcasts.sets.isEmpty)

        h.dates.advance(by: 2)
        await h.sweep.sweepOnce()
        #expect(await h.openIDs().isEmpty)
        #expect(await h.broadcasts.sets == [[h.terminal]])
    }

    /// A prompt opened before its first wait arrives is measured from its
    /// open, so a fresh prompt is not cleared before 60 s. A repeat open (the
    /// mod re-posting after a reconnect) restarts the measure.
    @Test func sweepSparesAFreshPromptForSixtySeconds() async {
        let h = makeHarness()
        await h.open("toolu_1")
        h.dates.advance(by: 40)
        await h.open("toolu_2")

        h.dates.advance(by: 21)
        await h.sweep.sweepOnce()
        // 61 s after the first open, 21 s after the second.
        #expect(await h.openIDs() == ["toolu_2"])
        #expect(await h.broadcasts.sets == [[h.terminal]])

        h.dates.advance(by: 30)
        await h.open("toolu_2")
        h.dates.advance(by: 59)
        await h.sweep.sweepOnce()
        #expect(await h.openIDs() == ["toolu_2"])

        h.dates.advance(by: 2)
        await h.sweep.sweepOnce()
        #expect(await h.openIDs().isEmpty)
        #expect(await h.broadcasts.sets == [[h.terminal], [h.terminal]])
    }

    /// Only the idle prompt's terminal is cleared.
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
        #expect(cleared != .timedOut, "the timed pass never cleared the idle prompt")
        await h.sweep.stop()
    }
}
