import Foundation
import Testing
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// A process table the controller can lower and restore without touching a real
/// process. Priority 20 is normal, 4 is background, as the kernel reports them.
final class FakeProcessPriority: ProcessPriority, @unchecked Sendable {
    struct Proc {
        var parent: pid_t
        var startMicros: Int64
        var priority: Int32 = 20
    }

    private let lock = NSLock()
    private var table: [pid_t: Proc] = [:]
    private var lowered: [pid_t] = []
    private var restored: [pid_t] = []
    private var beforeLowering: (@Sendable (pid_t) -> Void)?

    /// Runs just before each lower, so a test can look at what is on disk then.
    func onLower(_ body: @escaping @Sendable (pid_t) -> Void) {
        lock.withLock { beforeLowering = body }
    }

    func add(_ pid: pid_t, parent: pid_t, start: Int64 = 1_000, priority: Int32 = 20) {
        lock.withLock { table[pid] = Proc(parent: parent, startMicros: start, priority: priority) }
    }

    /// The process exits.
    func remove(_ pid: pid_t) { lock.withLock { table[pid] = nil } }

    /// The pid is reissued to a different process, at normal priority.
    func recycle(_ pid: pid_t, start: Int64) {
        lock.withLock { table[pid]?.startMicros = start; table[pid]?.priority = 20 }
    }

    func priority(of pid: pid_t) -> Int32? { lock.withLock { table[pid]?.priority } }
    var loweredPIDs: [pid_t] { lock.withLock { lowered } }
    var restoredPIDs: [pid_t] { lock.withLock { restored } }

    func basePriority(of pid: pid_t) -> Int32? { lock.withLock { table[pid]?.priority } }

    func lowerToBackground(_ pid: pid_t) -> Bool {
        lock.withLock { beforeLowering }?(pid)
        return lock.withLock {
            guard table[pid] != nil else { return false }
            table[pid]?.priority = 4
            lowered.append(pid)
            return true
        }
    }

    func restore(_ pid: pid_t) -> Bool {
        lock.withLock {
            guard table[pid] != nil else { return false }
            table[pid]?.priority = 20
            restored.append(pid)
            return true
        }
    }

    func startTimeMicros(of pid: pid_t) -> Int64? { lock.withLock { table[pid]?.startMicros } }
    func parentPID(of pid: pid_t) -> pid_t? { lock.withLock { table[pid]?.parent } }

    func subtree(of root: pid_t) -> [pid_t] {
        lock.withLock {
            guard table[root] != nil else { return [] }
            var result = [root]
            var index = 0
            while index < result.count {
                let current = result[index]
                result.append(contentsOf: table.filter { $0.value.parent == current }.keys.sorted())
                index += 1
            }
            return result
        }
    }
}

/// A date the test moves.
final class MovableDate: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var date: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@Suite("AgentBackgroundController")
struct AgentBackgroundControllerTests {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func statePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-agent-background-\(UUID().uuidString).json").path
    }

    private func makeController(
        _ fake: FakeProcessPriority, roots: [pid_t], path: String, date: MovableDate,
        clock: any Clock<Duration> = ContinuousClock(),
        onRoots: @escaping @Sendable () -> Void = {}
    ) -> AgentBackgroundController {
        AgentBackgroundController(
            priority: fake, roots: { onRoots(); return roots }, statePath: path,
            now: { date.date }, clock: clock)
    }

    /// holder 50 (never a root) > job 100 > shell 101 > build 102, plus a second tab 200 > 201.
    private func makeTable() -> FakeProcessPriority {
        let fake = FakeProcessPriority()
        fake.add(50, parent: 1)
        fake.add(100, parent: 50, start: 2_000)
        fake.add(101, parent: 100, start: 2_100)
        fake.add(102, parent: 101, start: 2_200)
        fake.add(200, parent: 50, start: 3_000)
        fake.add(201, parent: 200, start: 3_100)
        return fake
    }

    @Test func lowersEveryProcessBelowTheRootsAndNeverTheParent() async throws {
        let fake = makeTable()
        let controller = makeController(
            fake, roots: [100, 200], path: statePath(), date: MovableDate(epoch))

        let result = try await controller.on(for: .seconds(600))

        #expect(result.active)
        #expect(result.loweredCount == 5)
        #expect(Set(fake.loweredPIDs) == [100, 101, 102, 200, 201])
        #expect(fake.priority(of: 50) == 20, "the holder carries input and output and stays put")
        #expect(result.leaseEndsAt == epoch.addingTimeInterval(600))
    }

    @Test func aProcessAlreadyInTheBackgroundIsNeitherLoweredNorRestored() async throws {
        let fake = makeTable()
        fake.add(101, parent: 100, start: 2_100, priority: 4)
        let controller = makeController(
            fake, roots: [100], path: statePath(), date: MovableDate(epoch))

        let result = try await controller.on(for: .seconds(600))
        #expect(result.loweredCount == 2)
        #expect(!fake.loweredPIDs.contains(101))

        await controller.off()
        #expect(!fake.restoredPIDs.contains(101))
        #expect(fake.priority(of: 101) == 4, "someone else's choice survives the restore")
        #expect(Set(fake.restoredPIDs) == [100, 102])
    }

    @Test func aSweepLowersWhatAppearedSinceTheLast() async throws {
        let fake = makeTable()
        let controller = makeController(
            fake, roots: [100], path: statePath(), date: MovableDate(epoch))
        try await controller.on(for: .seconds(600))

        fake.add(103, parent: 100, start: 2_300)
        await controller.sweep()

        #expect(fake.priority(of: 103) == 4)
        #expect(await controller.status().loweredCount == 4)
        #expect(fake.loweredPIDs.filter { $0 == 100 }.count == 1, "no process is lowered twice")
    }

    @Test func restoreSkipsARecycledPidAndAVanishedOne() async throws {
        let fake = makeTable()
        let controller = makeController(
            fake, roots: [100], path: statePath(), date: MovableDate(epoch))
        try await controller.on(for: .seconds(600))

        fake.recycle(101, start: 9_999)
        fake.remove(102)
        await controller.off()

        #expect(fake.restoredPIDs == [100])
        #expect(fake.priority(of: 101) == 20)
    }

    @Test func leaseExpiryRestoresAndDeletesTheFile() async throws {
        let fake = makeTable()
        let path = statePath()
        let date = MovableDate(epoch)
        let controller = makeController(fake, roots: [100], path: path, date: date)
        try await controller.on(for: .seconds(600))
        #expect(FileManager.default.fileExists(atPath: path))

        date.advance(by: 599)
        await controller.sweep()
        #expect(await controller.status().active)

        date.advance(by: 1)
        await controller.sweep()

        #expect(Set(fake.restoredPIDs) == [100, 101, 102])
        #expect(await controller.status() == AgentsBackgroundResult(active: false))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func offRestoresNowAndDeletesTheFile() async throws {
        let fake = makeTable()
        let path = statePath()
        let controller = makeController(fake, roots: [100], path: path, date: MovableDate(epoch))
        try await controller.on(for: .seconds(600))

        let result = await controller.off()

        #expect(!result.active)
        #expect(Set(fake.restoredPIDs) == [100, 101, 102])
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func renewingExtendsTheLeaseAndKeepsTheRecord() async throws {
        let fake = makeTable()
        let date = MovableDate(epoch)
        let controller = makeController(fake, roots: [100], path: statePath(), date: date)
        try await controller.on(for: .seconds(600))

        date.advance(by: 300)
        let renewed = try await controller.on(for: .seconds(600))

        #expect(renewed.leaseEndsAt == epoch.addingTimeInterval(900))
        #expect(renewed.loweredCount == 3)
        date.advance(by: 599)
        await controller.sweep()
        #expect(await controller.status().active, "the old end passed and the lease held")
        #expect(fake.restoredPIDs.isEmpty)
    }

    @Test func aLeaseOverTwoHoursOrNotPositiveIsRefused() async {
        let controller = makeController(
            makeTable(), roots: [100], path: statePath(), date: MovableDate(epoch))

        await #expect(throws: AgentBackgroundError.durationTooLong(maximumSeconds: 7200)) {
            try await controller.on(for: .seconds(7201))
        }
        await #expect(throws: AgentBackgroundError.durationNotPositive) {
            try await controller.on(for: .seconds(0))
        }
        #expect(await controller.status().active == false)
        // Exactly two hours is allowed.
        #expect((try? await controller.on(for: .seconds(7200)))?.active == true)
    }

    @Test func aSweepWithoutALeaseDoesNothing() async {
        let fake = makeTable()
        let controller = makeController(
            fake, roots: [100], path: statePath(), date: MovableDate(epoch))

        await controller.sweep()

        #expect(fake.loweredPIDs.isEmpty)
    }

    // MARK: - Restart

    @Test func aRestartAfterTheLeaseEndedRestoresAndDeletesTheFile() async throws {
        let fake = makeTable()
        let path = statePath()
        let date = MovableDate(epoch)
        let first = makeController(fake, roots: [100], path: path, date: date)
        try await first.on(for: .seconds(600))

        // The daemon goes away; a new one starts after the lease ended.
        date.advance(by: 700)
        let second = makeController(fake, roots: [100], path: path, date: date)
        await second.recoverOnStart()

        #expect(Set(fake.restoredPIDs) == [100, 101, 102])
        #expect(await second.status().active == false)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aRestartDuringTheLeaseKeepsItAndKeepsSweeping() async throws {
        let fake = makeTable()
        let path = statePath()
        let date = MovableDate(epoch)
        let first = makeController(fake, roots: [100], path: path, date: date)
        try await first.on(for: .seconds(600))

        date.advance(by: 100)
        let second = makeController(fake, roots: [100], path: path, date: date)
        await second.recoverOnStart()

        let status = await second.status()
        #expect(status.active)
        #expect(status.loweredCount == 3)
        #expect(status.leaseEndsAt == epoch.addingTimeInterval(600))
        #expect(fake.restoredPIDs.isEmpty)

        fake.add(103, parent: 100, start: 2_300)
        await second.sweep()
        #expect(fake.priority(of: 103) == 4)
        await second.off()
        #expect(Set(fake.restoredPIDs) == [100, 101, 102, 103])
    }

    @Test func aRestartRestoresOnlyProcessesThatAreStillTheSame() async throws {
        let fake = makeTable()
        let path = statePath()
        let date = MovableDate(epoch)
        let first = makeController(fake, roots: [100], path: path, date: date)
        try await first.on(for: .seconds(600))

        fake.recycle(102, start: 8_888)
        date.advance(by: 700)
        let second = makeController(fake, roots: [100], path: path, date: date)
        await second.recoverOnStart()

        #expect(Set(fake.restoredPIDs) == [100, 101])
        #expect(fake.priority(of: 102) == 20)
    }

    @Test func aDaemonThatDiesWhileLoweringLeavesARecordTheNextOneRestores() async throws {
        let fake = makeTable()
        let path = statePath()
        let leftBehind = statePath()
        let date = MovableDate(epoch)
        // The file as it stood just before 102 was lowered: what a daemon that
        // died at that moment would leave.
        fake.onLower { pid in
            if pid == 102 { try? FileManager.default.copyItem(atPath: path, toPath: leftBehind) }
        }
        try await makeController(fake, roots: [100], path: path, date: date).on(for: .seconds(600))

        date.advance(by: 700)
        let next = makeController(fake, roots: [100], path: leftBehind, date: date)
        await next.recoverOnStart()

        #expect(Set(fake.restoredPIDs) == [100, 101, 102])
    }

    @Test func aRecordThatCannotBeWrittenLowersNothing() async throws {
        let fake = makeTable()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-no-such-directory-\(UUID().uuidString)")
            .appendingPathComponent("agent-background.json").path
        let controller = makeController(fake, roots: [100], path: path, date: MovableDate(epoch))

        let result = try await controller.on(for: .seconds(600))

        #expect(fake.loweredPIDs.isEmpty)
        #expect(result.loweredCount == 0)
    }

    @Test func aCorruptFileRestoresNothingAndIsDeleted() async throws {
        let fake = makeTable()
        let path = statePath()
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: path))
        let controller = makeController(fake, roots: [100], path: path, date: MovableDate(epoch))

        await controller.recoverOnStart()

        #expect(fake.restoredPIDs.isEmpty)
        #expect(await controller.status().active == false)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func noFileMeansNothingToRecover() async {
        let controller = makeController(
            makeTable(), roots: [100], path: statePath(), date: MovableDate(epoch))
        await controller.recoverOnStart()
        #expect(await controller.status().active == false)
    }

    // MARK: - The loop

    @Test func theLoopSweepsEverySixtySecondsOnTheInjectedClock() async throws {
        let fake = makeTable()
        let clock = EventDrivenTestClock()
        let swept = FireRecorder<Void>()
        let controller = makeController(
            fake, roots: [100], path: statePath(), date: MovableDate(epoch), clock: clock,
            onRoots: { swept.record(()) })
        await controller.start()
        try await controller.on(for: .seconds(3600))
        _ = await swept.next()  // the sweep `on` runs itself

        fake.add(103, parent: 100, start: 2_300)
        try await clock.requireAdvanceWhenArmed(by: .seconds(60))
        _ = await swept.next()

        #expect(fake.priority(of: 103) == 4)
        await controller.stop()
    }
}
