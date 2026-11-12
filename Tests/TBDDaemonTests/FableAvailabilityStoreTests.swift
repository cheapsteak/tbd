import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

@Suite("FableAvailabilityStore")
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

    private func store(
        clock: Clock, meter: Meter, state: FableAvailability.State = .available,
        probeSeconds: Double = 0
    ) -> FableAvailabilityStore {
        FableAvailabilityStore(
            probe: { id in
                meter.begin(id)
                if probeSeconds > 0 { try? await Task.sleep(for: .seconds(probeSeconds)) }
                meter.end()
                return FableAvailability(state: state, checkedAt: clock.now, source: .probe)
            },
            now: { clock.now })
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

    @Test func concurrentAsksForOneProfile_shareOneProbe() async {
        let clock = Clock(), meter = Meter()
        let s = store(clock: clock, meter: meter, probeSeconds: 0.2)
        let id = UUID()
        async let a = s.refresh([id], force: true)
        async let b = s.refresh([id], force: true)
        _ = await (a, b)
        #expect(meter.callCount == 1)
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

    @Test func deadline_returnsWhatIsHeld_andLateProbeStillRecords() async {
        let clock = Clock(), meter = Meter()
        let s = store(clock: clock, meter: meter, probeSeconds: 0.5)
        let id = UUID()
        let early = await s.refresh([id], deadline: 0.05)
        #expect(early[id] == nil)
        try? await Task.sleep(for: .seconds(1))
        #expect(await s.current(id)?.state == .available)
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
}
