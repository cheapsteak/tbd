import Clocks
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1 for the cadence — virtual time only, never a real sleep — and tier 2
/// for the bytes it writes.
///
/// The path is injected, so nothing here can reach `~/tbd/supervision`.
@Suite("Supervision heartbeat", .clockDriven)
struct SupervisionHeartbeatTests {

    /// The reason a snapshot could not be composed, so a test can assert the
    /// heartbeat skips rather than publishes.
    private struct Unreadable: Error {}

    /// Counts ticks and hands back whatever the test wants published.
    ///
    /// Holding `nil` means **the next call throws**, not that it publishes
    /// nothing: the production seam has exactly one way to say "no snapshot",
    /// and this stub speaks it rather than inventing a second.
    private final class Snapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SupervisionStatusFile?
        private var callCount = 0

        init(_ value: SupervisionStatusFile?) { self.value = value }

        func set(_ value: SupervisionStatusFile?) { lock.withLock { self.value = value } }

        var calls: Int { lock.withLock { callCount } }

        var provider: @Sendable () async throws -> SupervisionStatusFile {
            { [self] in
                let value = lock.withLock { () -> SupervisionStatusFile? in
                    callCount += 1
                    return self.value
                }
                guard let value else { throw Unreadable() }
                return value
            }
        }
    }

    /// A snapshot source whose **first** call parks until the test releases it,
    /// so one `applyBrake` can be held inside its edge write while another runs
    /// to completion.
    ///
    /// Lock-guarded rather than an actor, deliberately: an actor that parked
    /// inside its own isolated method would still be holding itself, so the
    /// second call could not get in and the test would deadlock instead of
    /// interleaving. The lock is only ever held across bookkeeping, never
    /// across the suspension.
    private final class ParkingSnapshots: @unchecked Sendable {
        private let lock = NSLock()
        private let value: SupervisionStatusFile
        private var callCount = 0
        private var sawFirstCall = false
        private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
        private var isReleased = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        init(_ value: SupervisionStatusFile) { self.value = value }

        var calls: Int { lock.withLock { callCount } }

        var provider: @Sendable () async throws -> SupervisionStatusFile {
            { [self] in
                let shouldPark = lock.withLock { () -> Bool in
                    callCount += 1
                    guard !sawFirstCall else { return false }
                    sawFirstCall = true
                    return true
                }
                guard shouldPark else { return value }

                let arrivals = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    defer { firstCallWaiters = [] }
                    return firstCallWaiters
                }
                for waiter in arrivals { waiter.resume() }

                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let alreadyReleased = lock.withLock { () -> Bool in
                        guard !isReleased else { return true }
                        releaseWaiters.append(continuation)
                        return false
                    }
                    if alreadyReleased { continuation.resume() }
                }
                return value
            }
        }

        func waitForFirstCall() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyArrived = lock.withLock { () -> Bool in
                    guard !sawFirstCall else { return true }
                    firstCallWaiters.append(continuation)
                    return false
                }
                if alreadyArrived { continuation.resume() }
            }
        }

        func release() {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isReleased = true
                defer { releaseWaiters = [] }
                return releaseWaiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    private static func path() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-heartbeat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("status.json").path
    }

    private static func statusFile(
        brake: SupervisionBrakeState, at seconds: TimeInterval = 1_700_000_000,
        projects: [SupervisionStatusFileProject] = []
    ) -> SupervisionStatusFile {
        SupervisionStatusFile(
            writtenAt: SupervisionInstant(Date(timeIntervalSince1970: seconds)),
            brake: brake, projects: projects)
    }

    private func read(_ path: String) throws -> SupervisionStatusFile? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try JSONDecoder().decode(SupervisionStatusFile.self, from: data)
    }

    @Test("The first tick is immediate, then one per interval")
    func writesImmediatelyThenOnCadence() async throws {
        let path = try Self.path()
        let snapshots = Snapshots(Self.statusFile(brake: .released))
        let clock = TestClock()
        let heartbeat = SupervisionHeartbeat(
            path: path, snapshot: snapshots.provider,
            interval: SupervisionHeartbeat.defaultInterval, clock: clock)

        await heartbeat.applyBrake(released: true)
        // The first advance proves the loop reached its sleep, which it can
        // only do after the immediate tick. The second waits for the sleep that
        // follows the *second* tick — so its returning is the evidence that a
        // tick happened per elapsed interval, not merely once at start.
        await clock.advanceWhenSuspended(by: SupervisionHeartbeat.defaultInterval)
        await clock.advanceWhenSuspended(by: SupervisionHeartbeat.defaultInterval)
        await heartbeat.stop()

        #expect(snapshots.calls >= 2, "one immediate write plus one per interval elapsed")
        #expect(try read(path)?.brake == .released)
    }

    @Test("The file exists before a single interval has elapsed")
    func firstTickPrecedesTheFirstInterval() async throws {
        let path = try Self.path()
        let snapshots = Snapshots(Self.statusFile(brake: .released))
        let clock = TestClock()
        let heartbeat = SupervisionHeartbeat(
            path: path, snapshot: snapshots.provider,
            interval: SupervisionHeartbeat.defaultInterval, clock: clock)

        await heartbeat.applyBrake(released: true)
        // Parking on the clock is the loop's first act after its immediate
        // write, so a registered sleeper with no file on disk would mean the
        // daemon published nothing for a whole interval after boot.
        await clock.waitForSuspension()
        #expect(FileManager.default.fileExists(atPath: path))
        await heartbeat.stop()
    }

    @Test("Stopping ends the cadence")
    func stopEndsTheCadence() async throws {
        let path = try Self.path()
        let snapshots = Snapshots(Self.statusFile(brake: .released))
        let clock = TestClock()
        let heartbeat = SupervisionHeartbeat(
            path: path, snapshot: snapshots.provider,
            interval: SupervisionHeartbeat.defaultInterval, clock: clock)

        await heartbeat.applyBrake(released: true)
        await clock.advanceWhenSuspended(by: SupervisionHeartbeat.defaultInterval)
        // `stop()` returns only once the loop has unwound, so what follows is
        // an assertion about a settled state rather than a race.
        await heartbeat.stop()
        let afterStop = snapshots.calls

        await clock.advance(by: SupervisionHeartbeat.defaultInterval * 5)
        #expect(snapshots.calls == afterStop)
        #expect(try read(path) != nil, "the last tick's file is left exactly as it was")
    }

    @Test("An engaged brake publishes the edge and arms no timer")
    func engagedBrakePublishesOnceAndArmsNoTimer() async throws {
        let path = try Self.path()
        let snapshots = Snapshots(Self.statusFile(brake: .engaged))
        let clock = TestClock()
        let heartbeat = SupervisionHeartbeat(
            path: path, snapshot: snapshots.provider,
            interval: SupervisionHeartbeat.defaultInterval, clock: clock)

        await heartbeat.applyBrake(released: false)
        #expect(snapshots.calls == 1, "the edge is published even while braked")
        #expect(try read(path)?.brake == .engaged)

        // Nothing is registered on the clock, so this advance moves virtual
        // time past five intervals and releases nobody. A braked daemon runs no
        // background loop at all — the brake is the switch.
        await clock.advance(by: SupervisionHeartbeat.defaultInterval * 5)
        for _ in 0..<20 { await Task.yield() }
        #expect(snapshots.calls == 1)
        await heartbeat.stop()
    }

    @Test("Releasing the brake arms the timer; engaging it publishes and disarms")
    func brakeEdgesArmAndDisarmTheTimer() async throws {
        let path = try Self.path()
        let snapshots = Snapshots(Self.statusFile(brake: .released))
        let clock = TestClock()
        let heartbeat = SupervisionHeartbeat(
            path: path, snapshot: snapshots.provider,
            interval: SupervisionHeartbeat.defaultInterval, clock: clock)

        await heartbeat.applyBrake(released: true)
        // Each advance waits for a registered sleeper first, so returning at
        // all is the evidence the timer is armed and re-arming.
        await clock.advanceWhenSuspended(by: SupervisionHeartbeat.defaultInterval)
        await clock.advanceWhenSuspended(by: SupervisionHeartbeat.defaultInterval)
        #expect(snapshots.calls >= 2, "the timer runs while the brake is released")

        snapshots.set(Self.statusFile(brake: .engaged))
        await heartbeat.applyBrake(released: false)
        #expect(try read(path)?.brake == .engaged, "the engaging edge is published")

        // `applyBrake` awaits the loop's unwind before returning, so no tick
        // can still be in flight and this count is settled.
        let afterEngaging = snapshots.calls
        await clock.advance(by: SupervisionHeartbeat.defaultInterval * 5)
        for _ in 0..<20 { await Task.yield() }
        #expect(snapshots.calls == afterEngaging, "and the timer is disarmed behind it")
    }

    @Test("Overlapping brake edges leave the timer matching the edge that landed last")
    func overlappingBrakeEdgesSettleOnTheLastOne() async throws {
        let path = try Self.path()
        let snapshots = ParkingSnapshots(Self.statusFile(brake: .released))
        let heartbeat = SupervisionHeartbeat(
            path: path, snapshot: snapshots.provider,
            interval: SupervisionHeartbeat.defaultInterval, clock: TestClock())

        // The releasing edge parks inside its own write, which releases the
        // actor — exactly the window in which a second edge can run start to
        // finish. Without the intent re-check, the parked call would resume and
        // arm a timer the engaging edge had just decided against.
        let releasing = Task { await heartbeat.applyBrake(released: true) }
        await snapshots.waitForFirstCall()

        // Deterministic, and this is why: the engaging edge does not depend on
        // the parked one, so it can be awaited to completion before the park is
        // released. No yields, no polling, no timing — unlike its sibling at
        // the store layer, where the guard's whole purpose is that the second
        // caller *cannot* proceed and so cannot be awaited.
        let engaging = Task { await heartbeat.applyBrake(released: false) }
        await engaging.value

        snapshots.release()
        await releasing.value

        #expect(await heartbeat.isTimerArmed == false, """
            the engaging edge landed last, so no timer may be running — an armed \
            one here is a loop ticking under a brake the operator pulled
            """)
        #expect(snapshots.calls == 2, "both edges published; neither was skipped")
    }

    @Test("The heartbeat publishes an engaged brake — observability is never withheld")
    func writesWhileTheBrakeIsEngaged() async throws {
        let path = try Self.path()
        let snapshots = Snapshots(Self.statusFile(
            brake: .engaged,
            projects: [SupervisionStatusFileProject(
                name: "acme-web", on: true, mode: "autonomous", lastSweepContactAt: nil)]))
        let heartbeat = SupervisionHeartbeat(
            path: path, snapshot: snapshots.provider, clock: TestClock())

        await heartbeat.tick()

        let published = try #require(try read(path))
        #expect(published.brake == .engaged)
        #expect(published.projects.first?.on == true,
                "the mark is published beside the brake that suppresses it")
    }

    @Test("A never-contacted project publishes an explicit null, not a missing key")
    func neverContactedPublishesNull() async throws {
        let path = try Self.path()
        let snapshots = Snapshots(Self.statusFile(
            brake: .released,
            projects: [SupervisionStatusFileProject(
                name: "acme-web", on: true, mode: "attended", lastSweepContactAt: nil)]))
        let heartbeat = SupervisionHeartbeat(
            path: path, snapshot: snapshots.provider, clock: TestClock())

        await heartbeat.tick()

        let data = try #require(FileManager.default.contents(atPath: path))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let projects = try #require(object["projects"] as? [[String: Any]])
        #expect(projects.first?["lastSweepContactAt"] is NSNull)
    }

    @Test("A tick that cannot read the state writes nothing and lets the file go stale")
    func unreadableStateSkipsTheWrite() async throws {
        let path = try Self.path()
        let snapshots = Snapshots(Self.statusFile(brake: .released, at: 1_700_000_000))
        let heartbeat = SupervisionHeartbeat(
            path: path, snapshot: snapshots.provider, clock: TestClock())

        await heartbeat.tick()
        // `#require` is the right form here and must stay: a tick with a
        // readable snapshot was supposed to write, so absence is a real
        // failure. Capturing this as an optional instead would let a heartbeat
        // that never wrote at all pass vacuously on `nil == nil`. The opposite
        // reasoning applies where absence is a legitimate state — see
        // `SupervisionStoreTests.fileBytes`.
        let first = try #require(FileManager.default.contents(atPath: path))

        snapshots.set(nil)
        await heartbeat.tick()

        #expect(FileManager.default.contents(atPath: path) == first,
                "staleness is the signal the watchdog reads; a half-truth is not")
    }

    @Test("Each tick republishes, so the file's content changes and not only its mtime")
    func everyTickRestampsWrittenAt() async throws {
        let path = try Self.path()
        let snapshots = Snapshots(Self.statusFile(brake: .released, at: 1_700_000_000))
        let heartbeat = SupervisionHeartbeat(
            path: path, snapshot: snapshots.provider, clock: TestClock())

        await heartbeat.tick()
        let first = try #require(try read(path))

        snapshots.set(Self.statusFile(brake: .released, at: 1_700_000_060))
        await heartbeat.tick()
        let second = try #require(try read(path))

        #expect(first.writtenAt != second.writtenAt)
    }

    @Test("The published cadence sits an order of magnitude under the watchdog's rule")
    func cadenceLeavesRoomForLostTicks() {
        // The watchdog raises when a file claiming coverage has not changed in
        // about ten minutes. A shipped cadence that did not leave several
        // missed ticks of headroom would page on ordinary jitter, and a page
        // nobody trusts is a page nobody reads.
        #expect(SupervisionHeartbeat.defaultInterval <= .seconds(120))
    }
}
