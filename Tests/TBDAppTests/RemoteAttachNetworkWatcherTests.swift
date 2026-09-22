import Foundation
import Network
import Testing
@testable import TBDApp
import TestSupport

// Tier 1: virtual time only. No NWPathMonitor, no NSWorkspace, no wall clock.

/// The `now:` seam's backing store for the suite below. Lock-guarded and
/// declared at file scope — the seam is a `@Sendable` closure, which carries
/// no isolation of its own, so this must not be main-isolated.
private final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// `RemoteAttachNetworkWatcher`'s debounce (#884): how raw path and wake
/// events collapse into one `RemoteAttachNetworkChange`.
///
/// The watcher is driven through its `observePath`/`observeWake` seams rather
/// than through `start()`, so nothing here installs a real path monitor or a
/// workspace observer — the two things a test machine cannot control.
///
/// The clock is `EventDrivenTestClock`: its arming handshake is signalled from
/// inside the same critical section that registers the sleeper, so a saturated
/// process cannot starve the probe. Its `advance` does no yielding, so every
/// POSITIVE assertion goes through `fired.next()` and every negative one reads
/// the recorder after an explicit `settle()`.
@MainActor
@Suite("Remote attach network watcher", .clockDriven, .serialized)
struct RemoteAttachNetworkWatcherTests {
    private static let window = Duration.seconds(2)

    /// Hang guard for every wait here. The watcher's debounce task is an
    /// unstructured `Task { @MainActor }`, so it arms only once it has had a
    /// turn on the main actor — a process-wide queue, not one hop from the
    /// test body. That is the `timeout` note on
    /// `EventDrivenTestClock.sleeperArmed`.
    private static let mainActorHop = TestDeadlines.saturatedPass

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private static let pathA = RemoteAttachNetworkFingerprint(
        status: .satisfied, interfaceNames: ["en0"], gateways: ["192.0.2.1"])
    private static let pathB = RemoteAttachNetworkFingerprint(
        status: .satisfied, interfaceNames: ["en0", "utun4"], gateways: ["192.0.2.1"])
    private static let pathC = RemoteAttachNetworkFingerprint(
        status: .satisfied, interfaceNames: ["utun4", "en0"], gateways: ["192.0.2.1"])
    private static let pathDown = RemoteAttachNetworkFingerprint(
        status: .unsatisfied, interfaceNames: [], gateways: [])

    @MainActor
    private final class Harness {
        let clock: EventDrivenTestClock
        let now: TestNow
        let watcher: RemoteAttachNetworkWatcher
        let fired = FireRecorder<RemoteAttachNetworkChange>()

        init() {
            let clock = EventDrivenTestClock()
            let now = TestNow(RemoteAttachNetworkWatcherTests.epoch)
            self.clock = clock
            self.now = now
            self.watcher = RemoteAttachNetworkWatcher(
                debounce: RemoteAttachNetworkWatcherTests.window,
                now: { now.date },
                clock: clock
            )
            watcher.onChange = { [fired] change in fired.record(change) }
        }

        /// Moves the injected wall clock `seconds` past the epoch, so each raw
        /// event below carries an exact, asserted `at`.
        func setNow(plus seconds: TimeInterval) {
            now.date = RemoteAttachNetworkWatcherTests.epoch.addingTimeInterval(seconds)
        }
    }

    /// Reddens if the accumulator is dropped and each raw event fires its own
    /// change, or if `at`/`current` stop tracking the LATEST event of the
    /// burst rather than the first.
    @Test("a burst collapses into one change carrying the latest event")
    func aBurstCollapsesIntoOneChange() async throws {
        let h = Harness()
        h.watcher.observePath(Self.pathA)   // seed: emits nothing
        h.setNow(plus: 1)
        h.watcher.observePath(Self.pathB)
        h.setNow(plus: 2)
        h.watcher.observeWake()
        h.setNow(plus: 3)
        h.watcher.observePath(Self.pathC)

        try await h.clock.requireAdvanceWhenArmed(by: Self.window, timeout: Self.mainActorHop)
        let change = try #require(await h.fired.next(timeout: Self.mainActorHop))

        #expect(change.at == Self.epoch.addingTimeInterval(3))
        #expect(change.previous == Self.pathA, "previous is pinned at the first event of the burst")
        #expect(change.current == Self.pathC)
        #expect(change.triggers == [.path, .wake], "first-seen order, deduplicated")
        #expect(h.fired.values.count == 1)
    }

    /// Reddens if the debounce stops being cancel-and-replace: a leading-edge
    /// or non-restarting window would fire at the original deadline, one
    /// second early.
    @Test("a raw event inside the window restarts it")
    func aRawEventInsideTheWindowRestartsIt() async throws {
        let h = Harness()
        h.watcher.observePath(Self.pathA)
        h.setNow(plus: 1)
        h.watcher.observePath(Self.pathB)

        try await h.clock.requireAdvanceWhenArmed(by: .seconds(1), timeout: Self.mainActorHop)
        await settle()
        #expect(h.fired.values.isEmpty, "half a window in — nothing may fire yet")

        h.setNow(plus: 2)
        h.watcher.observeWake()
        try await h.clock.requireAdvanceWhenArmed(by: .seconds(1), timeout: Self.mainActorHop)
        await settle()
        #expect(h.fired.values.isEmpty, "one second since the restart — the window restarted, so not yet")

        await h.clock.advance(by: .seconds(1))
        let change = try #require(await h.fired.next(timeout: Self.mainActorHop))
        #expect(change.at == Self.epoch.addingTimeInterval(2))
        #expect(h.fired.values.count == 1)
    }

    /// Sleep kills TCP connections without moving the path, so the wake source
    /// has to emit on its own. Reddens if `observeWake` starts routing through
    /// the detector, which would suppress it as "unchanged".
    @Test("a wake alone emits, with the path unchanged since the seed")
    func aWakeAloneEmits() async throws {
        let h = Harness()
        h.watcher.observePath(Self.pathA)
        h.setNow(plus: 5)
        h.watcher.observeWake()

        try await h.clock.requireAdvanceWhenArmed(by: Self.window, timeout: Self.mainActorHop)
        let change = try #require(await h.fired.next(timeout: Self.mainActorHop))

        #expect(change.triggers == [.wake])
        #expect(change.previous == Self.pathA)
        #expect(change.current == Self.pathA)
        #expect(change.at == Self.epoch.addingTimeInterval(5))
    }

    /// Reddens if the watcher schedules on every update instead of only on the
    /// detector's verdict: an unsatisfied path must arm no timer at all, so
    /// the machine never spawns an attach onto a network that is not there.
    /// `watchForSleeper` watches rather than samples, so the negative keeps
    /// discriminating under load.
    @Test("an unsatisfied path update schedules nothing")
    func anUnsatisfiedPathSchedulesNothing() async {
        let h = Harness()
        h.watcher.observePath(Self.pathA)
        h.setNow(plus: 1)
        h.watcher.observePath(Self.pathDown)

        #expect(await watchForSleeper(on: h.clock) == false, "no debounce timer may arm")
        #expect(h.fired.values.isEmpty)
    }

    /// Reddens if `stop()` stops cancelling the pending task: the watcher
    /// would go on firing into an `onChange` whose owner has torn it down.
    @Test("stop cancels a pending fire")
    func stopCancelsAPendingFire() async {
        let h = Harness()
        h.watcher.observePath(Self.pathA)
        h.setNow(plus: 1)
        h.watcher.observePath(Self.pathB)
        await h.clock.sleeperArmed(timeout: Self.mainActorHop)

        h.watcher.stop()
        await h.clock.advance(by: Self.window)
        await settle()

        #expect(h.fired.values.isEmpty)
    }

    /// Reddens if `stop()` leaves the detector holding the fingerprint from
    /// before the gap: the first update after a later `start()` would be
    /// compared against it and emit a change for a path nobody watched move.
    /// Driven through `observePath` alone — a real `start()` would install an
    /// `NWPathMonitor`, which a test machine cannot control.
    @Test("stop reseeds the detector, so the next update emits nothing")
    func stopReseedsTheDetector() async {
        let h = Harness()
        h.watcher.observePath(Self.pathA)

        h.watcher.stop()
        h.setNow(plus: 1)
        h.watcher.observePath(Self.pathB)

        #expect(await watchForSleeper(on: h.clock) == false, "the first update after stop is a seed")
        #expect(h.fired.values.isEmpty)
    }
}
