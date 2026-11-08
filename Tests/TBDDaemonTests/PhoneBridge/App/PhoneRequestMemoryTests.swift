import Foundation
import Testing
import TestSupport

@testable import TBDDaemonLib

/// Counts runs of `work` per request name, so a test can prove a request ran
/// once, and stamps each run's reply with its run number, so a second run
/// would hand back different bytes.
private actor RunTally {
    private var counts: [String: Int] = [:]

    func record(_ name: String) -> Int {
        counts[name, default: 0] += 1
        return counts[name, default: 0]
    }

    func count(_ name: String) -> Int {
        counts[name, default: 0]
    }
}

/// Holds runs of `work` until the test opens it. Each waiter gets an
/// `AsyncStream` of its own, so any number of runs can wait at once, and a
/// waiter whose task is cancelled stops waiting.
private final class RunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [AsyncStream<Void>.Continuation] = []

    func wait() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let alreadyOpen = lock.withLock { () -> Bool in
            if !isOpen { waiters.append(continuation) }
            return isOpen
        }
        if alreadyOpen { return }
        for await _ in stream {}
    }

    func open() {
        let pending = lock.withLock { () -> [AsyncStream<Void>.Continuation] in
            isOpen = true
            let pending = waiters
            waiters = []
            return pending
        }
        for continuation in pending { continuation.finish() }
    }
}

/// A `work` closure that records its run under `name` and replies with
/// `"<name> run <n>"`. With a gate, it waits for the gate after recording, and
/// replies `"<name> cancelled"` when its task was cancelled meanwhile.
private func job(_ name: String, tally: RunTally, gate: RunGate? = nil) -> @Sendable () async -> Data {
    return {
        let run = await tally.record(name)
        if let gate {
            await gate.wait()
            if Task.isCancelled {
                _ = await tally.record("\(name) saw cancellation")
                return Data("\(name) cancelled".utf8)
            }
        }
        return Data("\(name) run \(run)".utf8)
    }
}

/// The refusal every test below the in-flight cap passes, so a call refused
/// by mistake shows up as these bytes.
private let capRefusal = Data("refused at the cap".utf8)

private extension PhoneRequestMemory {
    /// `reply(deviceID:requestID:refusal:work:)` with the shared refusal, for
    /// the tests that stay below the in-flight cap.
    func reply(deviceID: UUID, requestID: String,
               work: @escaping @Sendable () async -> Data) async -> (reply: Data, repeated: Bool) {
        await reply(deviceID: deviceID, requestID: requestID, refusal: { capRefusal }, work: work)
    }
}

/// Tier 1: an actor, a virtual clock and in-memory closures. Nothing touches
/// the disk or the network.
@Suite("Phone request memory", .clockDriven)
struct PhoneRequestMemoryTests {
    private let phone = UUID()

    @Test func aRepeatReturnsTheStoredReplyAndRunsOnce() async {
        let memory = PhoneRequestMemory(clock: EventDrivenTestClock())
        let tally = RunTally()

        let first = await memory.reply(deviceID: phone, requestID: "r1", work: job("send", tally: tally))
        let second = await memory.reply(deviceID: phone, requestID: "r1", work: job("send", tally: tally))

        #expect(first.reply == Data("send run 1".utf8))
        #expect(!first.repeated)
        #expect(first.reply == second.reply)
        #expect(second.repeated)
        #expect(await tally.count("send") == 1)
        await memory.forget(deviceID: phone)
    }

    @Test func aRepeatWhileInFlightAwaitsTheFirst() async throws {
        let memory = PhoneRequestMemory(clock: EventDrivenTestClock())
        let tally = RunTally()
        let gate = RunGate()
        defer { gate.open() }
        let phone = self.phone

        let first = Task { await memory.reply(deviceID: phone, requestID: "r1", work: job("send", tally: tally, gate: gate)) }
        try await waitUntil("the first run to start") { await tally.count("send") == 1 }
        // Issued before the run is let go, and joined to it before the gate opens.
        let second = Task { await memory.reply(deviceID: phone, requestID: "r1", work: job("send", tally: tally, gate: gate)) }
        try await waitUntil("the repeat to join the run in flight") { await memory.waitingRepeats == 1 }
        gate.open()

        let a = await first.value
        let b = await second.value
        #expect(a.reply == Data("send run 1".utf8))
        #expect(!a.repeated)
        #expect(b.reply == a.reply)
        #expect(b.repeated)
        #expect(await tally.count("send") == 1)
        await memory.forget(deviceID: phone)
    }

    /// The first caller's task is cancelled while its run is going, as when a
    /// request's task is torn down mid-send. The run is the memory's, not the
    /// caller's: it goes on uncancelled, both callers get its reply, and the
    /// repeat runs nothing.
    @Test func aCancelledFirstCallerStillRunsOnceAndTheRepeatGetsItsReply() async throws {
        let memory = PhoneRequestMemory(clock: EventDrivenTestClock())
        let tally = RunTally()
        let gate = RunGate()
        defer { gate.open() }
        let phone = self.phone

        let first = Task { await memory.reply(deviceID: phone, requestID: "r1", work: job("send", tally: tally, gate: gate)) }
        try await waitUntil("the first run to start") { await tally.count("send") == 1 }
        first.cancel()
        let second = Task { await memory.reply(deviceID: phone, requestID: "r1", work: job("send", tally: tally, gate: gate)) }
        try await waitUntil("the repeat to join the run in flight") { await memory.waitingRepeats == 1 }
        gate.open()

        let a = await first.value
        let b = await second.value
        #expect(a.reply == Data("send run 1".utf8))
        #expect(!a.repeated)
        #expect(b.reply == a.reply)
        #expect(b.repeated)
        #expect(await tally.count("send") == 1)
        #expect(await tally.count("send saw cancellation") == 0)
        // Still remembered as done: a third call runs nothing either.
        let c = await memory.reply(deviceID: phone, requestID: "r1", work: job("send", tally: tally))
        #expect(c.reply == a.reply)
        #expect(c.repeated)
        #expect(await tally.count("send") == 1)
        await memory.forget(deviceID: phone)
    }

    @Test func theMemoryForgetsAfterTenMinutes() async throws {
        let clock = EventDrivenTestClock()
        let memory = PhoneRequestMemory(clock: clock)
        let tally = RunTally()

        _ = await memory.reply(deviceID: phone, requestID: "r1", work: job("send", tally: tally))
        let second = await memory.reply(deviceID: phone, requestID: "r1", work: job("send", tally: tally))
        #expect(second.repeated)

        // One second short of ten minutes, the reply is still kept.
        try await clock.requireAdvanceWhenArmed(by: .seconds(599))
        let atTheEdge = await memory.reply(deviceID: phone, requestID: "r1", work: job("send", tally: tally))
        #expect(atTheEdge.repeated)
        #expect(await tally.count("send") == 1)

        // The timer is still the one armed above, so a plain advance fires it.
        await clock.advance(by: .seconds(1))
        try await waitUntil("the entry to expire") { await !memory.remembers(deviceID: phone, requestID: "r1") }
        let third = await memory.reply(deviceID: phone, requestID: "r1", work: job("send", tally: tally))
        #expect(!third.repeated)
        #expect(third.reply == Data("send run 2".utf8))
        #expect(await tally.count("send") == 2)
        await memory.forget(deviceID: phone)
    }

    /// Retention counts from the reply, so an entry cannot expire while its
    /// run is going and let a repeat start a second run.
    @Test func anEntryInFlightNeverExpires() async throws {
        let clock = EventDrivenTestClock()
        let memory = PhoneRequestMemory(clock: clock)
        let tally = RunTally()
        let gate = RunGate()
        defer { gate.open() }
        let phone = self.phone

        let first = Task { await memory.reply(deviceID: phone, requestID: "r1", work: job("send", tally: tally, gate: gate)) }
        try await waitUntil("the first run to start") { await tally.count("send") == 1 }
        let armedInFlight = await watchForSleeper(on: clock)
        #expect(!armedInFlight)
        gate.open()
        _ = await first.value

        // The timer starts with the reply.
        try await clock.requireAdvanceWhenArmed(by: .seconds(600))
        try await waitUntil("the entry to expire") { await !memory.remembers(deviceID: phone, requestID: "r1") }
        await memory.forget(deviceID: phone)
    }

    @Test func theSameIDFromAnotherDeviceIsAnotherRequest() async {
        let memory = PhoneRequestMemory(clock: EventDrivenTestClock())
        let tally = RunTally()
        let other = UUID()

        let mine = await memory.reply(deviceID: phone, requestID: "r1", work: job("mine", tally: tally))
        let theirs = await memory.reply(deviceID: other, requestID: "r1", work: job("theirs", tally: tally))
        #expect(!mine.repeated)
        #expect(!theirs.repeated)
        #expect(mine.reply == Data("mine run 1".utf8))
        #expect(theirs.reply == Data("theirs run 1".utf8))

        // Each device's repeat gets its own reply back.
        let mineAgain = await memory.reply(deviceID: phone, requestID: "r1", work: job("mine", tally: tally))
        let theirsAgain = await memory.reply(deviceID: other, requestID: "r1", work: job("theirs", tally: tally))
        #expect(mineAgain.repeated && mineAgain.reply == mine.reply)
        #expect(theirsAgain.repeated && theirsAgain.reply == theirs.reply)
        #expect(await tally.count("mine") == 1)
        #expect(await tally.count("theirs") == 1)
        await memory.forget(deviceID: phone)
        await memory.forget(deviceID: other)
    }

    @Test func theOldestEntryIsEvictedPastTheLimit() async throws {
        let clock = EventDrivenTestClock()
        let memory = PhoneRequestMemory(perDeviceLimit: 2, clock: clock)
        let tally = RunTally()
        let gate = RunGate()
        defer { gate.open() }
        let phone = self.phone

        _ = await memory.reply(deviceID: phone, requestID: "a", work: job("a", tally: tally))
        _ = await memory.reply(deviceID: phone, requestID: "b", work: job("b", tally: tally))
        try await clock.requireSleepersArmed(count: 2)

        // C is held in flight, so it arms no timer of its own while we look.
        let c = Task { await memory.reply(deviceID: phone, requestID: "c", work: job("c", tally: tally, gate: gate)) }
        try await waitUntil("C's run to start") { await tally.count("c") == 1 }
        #expect(await !memory.remembers(deviceID: phone, requestID: "a"))
        #expect(await memory.remembers(deviceID: phone, requestID: "b"))
        #expect(await memory.remembers(deviceID: phone, requestID: "c"))
        // A's timer went with it; B's is the only one left.
        #expect(clock.sleeperCount == 1)
        gate.open()
        _ = await c.value

        let bAgain = await memory.reply(deviceID: phone, requestID: "b", work: job("b", tally: tally))
        #expect(bAgain.repeated)
        #expect(await tally.count("b") == 1)
        let aAgain = await memory.reply(deviceID: phone, requestID: "a", work: job("a", tally: tally))
        #expect(!aAgain.repeated)
        #expect(aAgain.reply == Data("a run 2".utf8))
        await memory.forget(deviceID: phone)
    }

    /// An entry in flight is never evicted, however far past the limit the
    /// device goes: evicting it would let a repeat start a second run while
    /// the first is still going. The limit takes finished entries instead:
    /// with A filling the limit of 1, B and C are each evicted as they finish.
    @Test func anEntryInFlightIsNeverEvicted() async throws {
        let memory = PhoneRequestMemory(perDeviceLimit: 1, clock: EventDrivenTestClock())
        let tally = RunTally()
        let gate = RunGate()
        defer { gate.open() }
        let phone = self.phone

        let a = Task { await memory.reply(deviceID: phone, requestID: "a", work: job("a", tally: tally, gate: gate)) }
        try await waitUntil("A's run to start") { await tally.count("a") == 1 }
        _ = await memory.reply(deviceID: phone, requestID: "b", work: job("b", tally: tally))
        _ = await memory.reply(deviceID: phone, requestID: "c", work: job("c", tally: tally))
        #expect(await memory.remembers(deviceID: phone, requestID: "a"))
        #expect(await !memory.remembers(deviceID: phone, requestID: "b"))
        #expect(await !memory.remembers(deviceID: phone, requestID: "c"))

        let aAgain = Task { await memory.reply(deviceID: phone, requestID: "a", work: job("a", tally: tally, gate: gate)) }
        try await waitUntil("the repeat to join A's run") { await memory.waitingRepeats == 1 }
        gate.open()
        let first = await a.value
        let repeated = await aAgain.value
        #expect(!first.repeated)
        #expect(repeated.repeated)
        #expect(repeated.reply == first.reply)
        #expect(await tally.count("a") == 1)
        await memory.forget(deviceID: phone)
    }

    /// `forget` is for a revoked phone: it cancels the device's timers and its
    /// runs in flight, and leaves every other device alone.
    @Test func forgetCancelsTheDevicesRunsAndTimers() async throws {
        let clock = EventDrivenTestClock()
        let memory = PhoneRequestMemory(clock: clock)
        let tally = RunTally()
        let gate = RunGate()
        defer { gate.open() }
        let phone = self.phone
        let other = UUID()

        _ = await memory.reply(deviceID: phone, requestID: "done", work: job("done", tally: tally))
        _ = await memory.reply(deviceID: other, requestID: "done", work: job("other", tally: tally))
        try await clock.requireSleepersArmed(count: 2)
        let inFlight = Task {
            await memory.reply(deviceID: phone, requestID: "flight", work: job("flight", tally: tally, gate: gate))
        }
        try await waitUntil("the run in flight to start") { await tally.count("flight") == 1 }

        await memory.forget(deviceID: phone)
        // Cancelling a sleeping timer takes it off the clock at once.
        #expect(clock.sleeperCount == 1)
        // Waited for before the run's value, so a forget that cancels nothing
        // fails here instead of hanging on the gate.
        try await waitUntil("the run in flight to see its cancellation") {
            await tally.count("flight saw cancellation") == 1
        }
        let cancelled = await inFlight.value
        #expect(cancelled.reply == Data("flight cancelled".utf8))
        #expect(!cancelled.repeated)
        #expect(await tally.count("flight saw cancellation") == 1)
        // The cancelled run's reply was not stored after the forget.
        #expect(await !memory.remembers(deviceID: phone, requestID: "flight"))
        #expect(await !memory.remembers(deviceID: phone, requestID: "done"))
        #expect(await memory.remembers(deviceID: other, requestID: "done"))

        // The forgotten device's request IDs are new again.
        let again = await memory.reply(deviceID: phone, requestID: "done", work: job("done", tally: tally))
        #expect(!again.repeated)
        #expect(await tally.count("done") == 2)
        await memory.forget(deviceID: phone)
        await memory.forget(deviceID: other)
    }

    /// A device at the in-flight cap gets the caller's refusal for a new
    /// request ID: nothing runs and nothing is stored. A repeat of an ID in
    /// flight still joins its run, another device is not held back, and a
    /// finished run frees a place.
    @Test func aNewRequestAtTheInFlightCapIsRefused() async throws {
        let memory = PhoneRequestMemory(inFlightLimit: 2, clock: EventDrivenTestClock())
        let tally = RunTally()
        let gate = RunGate()
        defer { gate.open() }
        let phone = self.phone
        let other = UUID()
        let refusal = Data("too many".utf8)

        let a = Task { await memory.reply(deviceID: phone, requestID: "a", work: job("a", tally: tally, gate: gate)) }
        let b = Task { await memory.reply(deviceID: phone, requestID: "b", work: job("b", tally: tally, gate: gate)) }
        try await waitUntil("A's and B's runs to start") {
            let started = [await tally.count("a"), await tally.count("b")]
            return started == [1, 1]
        }

        let c = await memory.reply(deviceID: phone, requestID: "c", refusal: { refusal }, work: job("c", tally: tally))
        #expect(c.reply == refusal)
        #expect(!c.repeated)
        #expect(await tally.count("c") == 0)
        #expect(await !memory.remembers(deviceID: phone, requestID: "c"))

        let theirs = await memory.reply(deviceID: other, requestID: "c", refusal: { refusal }, work: job("theirs", tally: tally))
        #expect(theirs.reply == Data("theirs run 1".utf8))

        let aAgain = Task {
            await memory.reply(deviceID: phone, requestID: "a", refusal: { refusal }, work: job("a", tally: tally, gate: gate))
        }
        try await waitUntil("the repeat to join A's run") { await memory.waitingRepeats == 1 }
        gate.open()
        let first = await a.value
        let repeated = await aAgain.value
        _ = await b.value
        #expect(repeated.repeated)
        #expect(repeated.reply == first.reply)
        #expect(await tally.count("a") == 1)

        let cAgain = await memory.reply(deviceID: phone, requestID: "c", refusal: { refusal }, work: job("c", tally: tally))
        #expect(!cAgain.repeated)
        #expect(cAgain.reply == Data("c run 1".utf8))
        await memory.forget(deviceID: phone)
        await memory.forget(deviceID: other)
    }

    /// Runs in flight can take a device past `perDeviceLimit`, since none of
    /// them can be evicted. As they finish, the oldest finished entries go
    /// until the device is back at the limit.
    @Test func finishingRunsShrinkADeviceBackToTheLimit() async throws {
        let memory = PhoneRequestMemory(perDeviceLimit: 1, inFlightLimit: 3, clock: EventDrivenTestClock())
        let tally = RunTally()
        let gateA = RunGate()
        defer { gateA.open() }
        let gateB = RunGate()
        defer { gateB.open() }
        let gateC = RunGate()
        defer { gateC.open() }
        let phone = self.phone

        let a = Task { await memory.reply(deviceID: phone, requestID: "a", work: job("a", tally: tally, gate: gateA)) }
        let b = Task { await memory.reply(deviceID: phone, requestID: "b", work: job("b", tally: tally, gate: gateB)) }
        let c = Task { await memory.reply(deviceID: phone, requestID: "c", work: job("c", tally: tally, gate: gateC)) }
        try await waitUntil("all three runs to start") {
            let started = [await tally.count("a"), await tally.count("b"), await tally.count("c")]
            return started == [1, 1, 1]
        }
        #expect(await memory.remembers(deviceID: phone, requestID: "a"))
        #expect(await memory.remembers(deviceID: phone, requestID: "b"))
        #expect(await memory.remembers(deviceID: phone, requestID: "c"))

        // Each caller's value arrives after its run's entry is stored.
        gateA.open()
        _ = await a.value
        #expect(await !memory.remembers(deviceID: phone, requestID: "a"))
        gateB.open()
        _ = await b.value
        #expect(await !memory.remembers(deviceID: phone, requestID: "b"))
        gateC.open()
        _ = await c.value
        #expect(await memory.remembers(deviceID: phone, requestID: "c"))
        let cAgain = await memory.reply(deviceID: phone, requestID: "c", work: job("c", tally: tally))
        #expect(cAgain.repeated)
        #expect(await tally.count("c") == 1)
        await memory.forget(deviceID: phone)
    }
}
