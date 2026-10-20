import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib

/// Tier 1 — `ModChannel`'s per-terminal outbox, held poll and liveness
/// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`, "Daemon to
/// mod: the poll" and "Liveness"). Every channel takes an
/// `EventDrivenTestClock`, so neither the 25 s hold nor the 60 s window fires
/// on wall time.
@Suite(.clockDriven)
struct ModChannelTests {

    private func attachPoll(
        _ channel: ModChannel, terminal: UUID, after: UInt64 = 0, token: UUID = UUID(),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Task<[ModChannel.Item], Never> {
        let poll = Task { await channel.poll(terminalID: terminal, after: after, token: token) }
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await channel.isPollAttached(terminalID: terminal)
        }
        if outcome == .timedOut {
            Issue.record("the poll never attached", sourceLocation: sourceLocation)
        }
        return poll
    }

    @Test func pollReturnsQueuedItemsAtOnce() async {
        let channel = ModChannel(clock: EventDrivenTestClock())
        let terminal = UUID()
        let first = await channel.enqueue(terminalID: terminal, kind: "message", body: #"{"n":1}"#) {}
        let second = await channel.enqueue(terminalID: terminal, kind: "message", body: #"{"n":2}"#) {}
        #expect(first == 1)
        #expect(second == 2)

        let items = await channel.poll(terminalID: terminal, after: 0, token: UUID())
        #expect(items == [
            ModChannel.Item(seq: 1, kind: "message", body: #"{"n":1}"#),
            ModChannel.Item(seq: 2, kind: "message", body: #"{"n":2}"#),
        ])
        #expect(await !channel.isPollAttached(terminalID: terminal))
    }

    @Test func pollHoldsThenReturnsEmptyAfterTwentyFiveSeconds() async throws {
        let clock = EventDrivenTestClock()
        let channel = ModChannel(clock: clock)
        let terminal = UUID()
        let poll = await attachPoll(channel, terminal: terminal)

        try await clock.requireAdvanceWhenArmed(by: .seconds(24))
        #expect(await channel.isPollAttached(terminalID: terminal))

        await clock.advance(by: .seconds(1))
        #expect(await poll.value == [])
        #expect(await !channel.isPollAttached(terminalID: terminal))
    }

    @Test func enqueueWakesWaitingPoll() async {
        let channel = ModChannel(clock: EventDrivenTestClock())
        let terminal = UUID()
        let other = UUID()
        let poll = await attachPoll(channel, terminal: terminal)

        // An item for another terminal leaves this poll held.
        await channel.enqueue(terminalID: other, kind: "message", body: "{}") {}
        #expect(await channel.isPollAttached(terminalID: terminal))

        await channel.enqueue(terminalID: terminal, kind: "message", body: #"{"text":"hi"}"#) {}
        #expect(await poll.value == [ModChannel.Item(seq: 1, kind: "message", body: #"{"text":"hi"}"#)])
    }

    @Test func afterConfirmsAndUnconfirmedAreResent() async {
        let channel = ModChannel(clock: EventDrivenTestClock())
        let terminal = UUID()
        for n in 1...3 {
            await channel.enqueue(terminalID: terminal, kind: "message", body: "{\"n\":\(n)}") {}
        }

        // A reply lost in flight: the same poll position gets everything again.
        #expect(await channel.poll(terminalID: terminal, after: 0, token: UUID()).map(\.seq) == [1, 2, 3])
        #expect(await channel.poll(terminalID: terminal, after: 0, token: UUID()).map(\.seq) == [1, 2, 3])
        // `after` confirms up to and including its number.
        #expect(await channel.poll(terminalID: terminal, after: 1, token: UUID()).map(\.seq) == [2, 3])

        // Everything confirmed: the poll holds.
        let token = UUID()
        let held = await attachPoll(channel, terminal: terminal, after: 3, token: token)
        await channel.pollGone(token: token)
        #expect(await held.value == [])

        // Numbering continues past confirmed items.
        let next = await channel.enqueue(terminalID: terminal, kind: "message", body: "{}") {}
        #expect(next == 4)
    }

    @Test func unconfirmedItemExpiresAfterSixtySecondsAndCallsOnExpired() async throws {
        let clock = EventDrivenTestClock()
        let channel = ModChannel(clock: clock)
        let terminal = UUID()
        let expired = FireRecorder<UInt64>()
        let seq = await channel.enqueue(terminalID: terminal, kind: "message", body: "{}") {
            expired.record(1)
        }
        #expect(seq == 1)

        try await clock.requireAdvanceWhenArmed(by: .seconds(59))
        #expect(expired.values.isEmpty)

        await clock.advance(by: .seconds(1))
        #expect(await expired.next() == 1)

        // Dropped: a poll now has nothing to send and holds.
        let token = UUID()
        let poll = await attachPoll(channel, terminal: terminal, token: token)
        await channel.pollGone(token: token)
        #expect(await poll.value == [])
        #expect(expired.values == [1])
    }

    @Test func isConnectedForThirtySecondsAfterPoll() async {
        let dates = TestDateSource()
        let channel = ModChannel(now: dates.provider, clock: EventDrivenTestClock())
        let terminal = UUID()
        #expect(await !channel.isConnected(terminalID: terminal))
        #expect(await channel.lastPollAt(terminalID: terminal) == nil)

        // Held: connected however long the hold lasts.
        let token = UUID()
        let held = await attachPoll(channel, terminal: terminal, token: token)
        let pollTime = dates.now
        #expect(await channel.lastPollAt(terminalID: terminal) == pollTime)
        dates.advance(by: 45)
        #expect(await channel.isConnected(terminalID: terminal))

        // Released: connected for 30 s after the poll arrived.
        dates.now = pollTime
        await channel.pollGone(token: token)
        _ = await held.value
        dates.advance(by: 29)
        #expect(await channel.isConnected(terminalID: terminal))
        dates.advance(by: 2)
        #expect(await !channel.isConnected(terminalID: terminal))
        #expect(await channel.lastPollAt(terminalID: terminal) == pollTime)
    }

    @Test func pollGoneReleasesWaiter() async {
        let channel = ModChannel(clock: EventDrivenTestClock())
        let terminal = UUID()
        let token = UUID()
        let poll = await attachPoll(channel, terminal: terminal, token: token)

        // Another request's token releases nothing.
        await channel.pollGone(token: UUID())
        #expect(await channel.isPollAttached(terminalID: terminal))

        await channel.pollGone(token: token)
        #expect(await poll.value == [])
        #expect(await !channel.isPollAttached(terminalID: terminal))
    }

    @Test func newerPollReleasesOlderOne() async {
        let channel = ModChannel(clock: EventDrivenTestClock())
        let terminal = UUID()
        let older = await attachPoll(channel, terminal: terminal)
        let newerToken = UUID()
        let newer = Task { await channel.poll(terminalID: terminal, after: 0, token: newerToken) }
        #expect(await older.value == [])

        await channel.enqueue(terminalID: terminal, kind: "message", body: "{}") {}
        #expect(await newer.value.map(\.seq) == [1])
    }
}
