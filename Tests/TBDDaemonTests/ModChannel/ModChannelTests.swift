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

    /// A channel created at the epoch numbers from a base of 0, so its first
    /// item is seq 1 and the tests can name sequence numbers literally.
    static let epoch: @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }

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
        let channel = ModChannel(now: Self.epoch, clock: EventDrivenTestClock())
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
        let channel = ModChannel(now: Self.epoch, clock: clock)
        let terminal = UUID()
        let poll = await attachPoll(channel, terminal: terminal)

        try await clock.requireAdvanceWhenArmed(by: .seconds(24))
        #expect(await channel.isPollAttached(terminalID: terminal))

        await clock.advance(by: .seconds(1))
        #expect(await poll.value == [])
        #expect(await !channel.isPollAttached(terminalID: terminal))
    }

    @Test func enqueueWakesWaitingPoll() async {
        let channel = ModChannel(now: Self.epoch, clock: EventDrivenTestClock())
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
        let channel = ModChannel(now: Self.epoch, clock: EventDrivenTestClock())
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
        let channel = ModChannel(now: Self.epoch, clock: clock)
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
        let channel = ModChannel(now: Self.epoch, clock: EventDrivenTestClock())
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

    /// The server cancels a poll whose connection closed. Cancelling the
    /// awaiting task releases the held poll with `[]`, and a later item is
    /// still delivered to the next poll.
    @Test func pollReleasedWhenTaskCancelled() async {
        let channel = ModChannel(now: Self.epoch, clock: EventDrivenTestClock())
        let terminal = UUID()
        let poll = await attachPoll(channel, terminal: terminal)

        poll.cancel()

        #expect(await poll.value == [])
        #expect(await !channel.isPollAttached(terminalID: terminal))
        await channel.enqueue(terminalID: terminal, kind: "message", body: "{}") {}
        #expect(await channel.poll(terminalID: terminal, after: 0, token: UUID()).map(\.seq) == [1])
    }

    /// A poll cancelled before it reaches the channel — its connection closed
    /// while it was still authenticating — returns `[]` without ever being
    /// held, so no continuation is left parked.
    @Test func pollCancelledBeforeHoldingIsNeverHeld() async {
        let channel = ModChannel(now: Self.epoch, clock: EventDrivenTestClock())
        let terminal = UUID()
        let poll = Task { () -> [ModChannel.Item] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await channel.poll(terminalID: terminal, after: 0, token: UUID())
        }

        #expect(await poll.value == [])
        #expect(await !channel.isPollAttached(terminalID: terminal))
        #expect(await channel.lastPollAt(terminalID: terminal) != nil, "the poll did reach the channel")
    }

    @Test func newerPollReleasesOlderOne() async {
        let channel = ModChannel(now: Self.epoch, clock: EventDrivenTestClock())
        let terminal = UUID()
        let older = await attachPoll(channel, terminal: terminal)
        let newerToken = UUID()
        let newer = Task { await channel.poll(terminalID: terminal, after: 0, token: newerToken) }
        #expect(await older.value == [])

        await channel.enqueue(terminalID: terminal, kind: "message", body: "{}") {}
        #expect(await newer.value.map(\.seq) == [1])
    }

    /// A daemon restart must not reset numbering: a mod still polling with
    /// `after` from the previous daemon life would otherwise confirm, and
    /// silently drop, the new life's first items.
    @Test func sequenceNumbersKeepRisingAcrossRestart() async {
        let terminal = UUID()
        let bootTime = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ModChannel(now: { bootTime }, clock: EventDrivenTestClock())
        var lastSeq: UInt64 = 0
        for _ in 0..<3 {
            lastSeq = await previous.enqueue(terminalID: terminal, kind: "message", body: "{}") {}
        }
        #expect(await previous.poll(terminalID: terminal, after: 0, token: UUID()).last?.seq == lastSeq)

        // The next daemon life starts one second later.
        let restarted = ModChannel(
            now: { bootTime.addingTimeInterval(1) }, clock: EventDrivenTestClock())
        let fresh = await restarted.enqueue(terminalID: terminal, kind: "message", body: #"{"n":1}"#) {}
        #expect(fresh > lastSeq)

        // The mod reconnects still carrying the old life's `after`.
        let items = await restarted.poll(terminalID: terminal, after: lastSeq, token: UUID())
        #expect(items == [ModChannel.Item(seq: fresh, kind: "message", body: #"{"n":1}"#)])
    }
}
