import Foundation
import TestSupport
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

@Suite("FableAvailabilityStore", .clockDriven)
struct FableAvailabilityStoreTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    }

    /// Counts probes, and the most that ran at once.
    final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [UUID] = []
        private var active = 0
        private(set) var maxActive = 0
        func begin(_ id: UUID) {
            lock.lock(); calls.append(id); active += 1; maxActive = max(maxActive, active); lock.unlock()
        }
        func end() { lock.lock(); active -= 1; lock.unlock() }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    }

    /// Holds every probe that reaches it until the test opens it, so the test
    /// decides when a probe finishes instead of racing a real-time sleep.
    actor ProbeGate {
        private var opened = false
        private var parked: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { parked.append($0) }
        }

        func open() {
            opened = true
            let waiting = parked
            parked = []
            for continuation in waiting { continuation.resume() }
        }
    }

    /// `ticks` times the store's `deadline` waits; the probe never sleeps on it.
    private func store(
        clock: Clock, meter: Meter, state: FableAvailability.State = .available,
        probeSeconds: Double = 0, gate: ProbeGate? = nil,
        ticks: EventDrivenTestClock = EventDrivenTestClock()
    ) -> FableAvailabilityStore {
        FableAvailabilityStore(
            probe: { id in
                meter.begin(id)
                if let gate { await gate.wait() }
                if probeSeconds > 0 { try? await Task.sleep(for: .seconds(probeSeconds)) }
                meter.end()
                return FableAvailability(state: state, checkedAt: clock.now, source: .probe)
            },
            now: { clock.now },
            clock: ticks)
    }

    @Test func neverProbedProfile_isProbedOnce_thenServedFromCacheWithinTTL() async {
        let clock = Clock(), meter = Meter()
        let s = store(clock: clock, meter: meter)
        let id = UUID()
        #expect(await s.current(id) == nil)
        let first = await s.refresh([id])
        #expect(first[id]?.state == .available)
        _ = await s.refresh([id])
        #expect(meter.callCount == 1)
    }

    @Test func ttlExpiry_perState() async {
        for (state, ttl) in [(FableAvailability.State.out, 1800.0), (.available, 21_600), (.unknown, 600)] {
            let clock = Clock(), meter = Meter()
            let s = store(clock: clock, meter: meter, state: state)
            let id = UUID()
            await s.refresh([id])
            clock.advance(ttl - 1)
            await s.refresh([id])
            #expect(meter.callCount == 1, "\(state) refetched early")
            clock.advance(2)
            await s.refresh([id])
            #expect(meter.callCount == 2, "\(state) not refetched after TTL")
        }
    }

    @Test func force_probesEvenWhenFresh() async {
        let clock = Clock(), meter = Meter()
        let s = store(clock: clock, meter: meter)
        let id = UUID()
        await s.refresh([id])
        await s.refresh([id], force: true)
        #expect(meter.callCount == 2)
    }

    /// A second ask while a probe is in flight joins it rather than starting
    /// another, even with `force`. The probe is held until the second ask has
    /// joined: that ask's deadline timer arms only after `refresh` has picked
    /// up the in-flight probe, so an armed sleeper proves the join.
    @Test func concurrentAsksForOneProfile_shareOneProbe() async throws {
        let clock = Clock(), meter = Meter(), gate = ProbeGate(), ticks = EventDrivenTestClock()
        let s = store(clock: clock, meter: meter, gate: gate, ticks: ticks)
        let id = UUID()
        let first = Task { await s.refresh([id], force: true) }
        try await boundedWait("the first ask's probe to start", observed: { "\(meter.callCount) probe calls" }) {
            meter.callCount == 1
        }
        let second = Task { await s.refresh([id], force: true, deadline: 60) }
        try await ticks.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        await gate.open()
        let a = await first.value
        let b = await second.value
        #expect(meter.callCount == 1)
        #expect(a[id]?.state == .available)
        #expect(b[id]?.state == .available)
    }

    @Test func neverMoreThanTwoProbesAtOnce() async {
        let clock = Clock(), meter = Meter()
        let s = store(clock: clock, meter: meter, probeSeconds: 0.1)
        let ids = (0..<6).map { _ in UUID() }
        let result = await s.refresh(ids)
        #expect(result.count == 6)
        #expect(meter.callCount == 6)
        #expect(meter.maxActive <= FableAvailabilityStore.maxConcurrentProbes)
    }

    /// The deadline ends the caller's wait, not the probe: the reading lands
    /// after the caller has gone. The test moves both the deadline (virtual
    /// time) and the probe's finish (the gate), so neither races the other.
    @Test func deadline_returnsWhatIsHeld_andLateProbeStillRecords() async throws {
        let clock = Clock(), meter = Meter(), gate = ProbeGate(), ticks = EventDrivenTestClock()
        let s = store(clock: clock, meter: meter, gate: gate, ticks: ticks)
        let id = UUID()
        let deadline: TimeInterval = 0.05
        let refreshing = Task { await s.refresh([id], deadline: deadline) }
        try await ticks.requireAdvanceWhenArmed(
            by: .seconds(deadline), timeout: TestDeadlines.saturatedPass)
        let early = await refreshing.value
        #expect(early[id] == nil)
        await gate.open()
        try await boundedWait("the late probe to record", observed: {
            let held = await s.current(id)
            return String(describing: held)
        }) {
            await s.current(id)?.state == .available
        }
    }

    @Test func sessionRecord_marksOut_andNothingProbesOnItsOwn() async {
        let clock = Clock(), meter = Meter()
        let s = store(clock: clock, meter: meter)
        let id = UUID()
        await s.record(FableAvailability(state: .out, checkedAt: clock.now, source: .session), for: id)
        #expect(await s.current(id)?.source == .session)
        #expect(await s.needsRefresh(id) == false)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(meter.callCount == 0)
    }

    /// A session reading that lands while a probe runs outranks that probe's
    /// result: the probe may have read the account before its credits ran
    /// out. The probe is held on the gate until the session reading is in, so
    /// the order is fixed rather than raced. A probe that begins afterwards
    /// replaces the session reading as usual.
    @Test func sessionRecordDuringAProbe_outranksThatProbesResult() async throws {
        let clock = Clock(), meter = Meter(), gate = ProbeGate()
        let s = store(clock: clock, meter: meter, state: .available, gate: gate)
        let id = UUID()
        let refreshing = Task { await s.refresh([id], force: true) }
        try await boundedWait("the probe to start", observed: { "\(meter.callCount) probe calls" }) {
            meter.callCount == 1
        }
        await s.record(FableAvailability(state: .out, checkedAt: clock.now, source: .session), for: id)
        await gate.open()
        let result = await refreshing.value
        #expect(result[id]?.state == .out)
        #expect(result[id]?.source == .session)
        let held = await s.current(id)
        #expect(held?.state == .out)
        #expect(held?.source == .session)

        let later = await s.refresh([id], force: true)
        #expect(meter.callCount == 2)
        #expect(later[id]?.state == .available)
        #expect(later[id]?.source == .probe)
    }

    /// The mirror case: a session reading recorded before a probe begins is
    /// replaced by that probe's result, so a recorded reading never freezes a
    /// profile.
    @Test func sessionRecordBeforeAProbe_isReplacedByThatProbesResult() async {
        let clock = Clock(), meter = Meter()
        let s = store(clock: clock, meter: meter, state: .available)
        let id = UUID()
        await s.record(FableAvailability(state: .out, checkedAt: clock.now, source: .session), for: id)
        let result = await s.refresh([id], force: true)
        #expect(meter.callCount == 1)
        #expect(result[id]?.state == .available)
        #expect(result[id]?.source == .probe)
        let held = await s.current(id)
        #expect(held?.source == .probe)
    }
}

/// A bounded wait (Tests/CLAUDE.md, assertion hygiene rule 5) that throws what
/// it observed, so a timeout reaches the CI summary's primary line.
private func boundedWait(
    _ what: String, observed: () async -> String, _ condition: () async -> Bool
) async throws {
    switch await pollUntilTrue(timeout: TestDeadlines.saturatedPass, condition) {
    case .satisfied:
        return
    case .cancelled:
        throw CancellationError()
    case .timedOut:
        throw BoundedWaitTimeout(
            what: what, observed: await observed(), deadline: TestDeadlines.saturatedPass)
    }
}
