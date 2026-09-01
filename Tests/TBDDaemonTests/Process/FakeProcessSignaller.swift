import Foundation
@testable import TBDDaemonLib

/// Records signal intent and answers liveness from a scriptable table.
final class FakeProcessSignaller: ProcessSignaller, @unchecked Sendable {
    struct Behavior {
        var aliveInitially = true
        var aliveAfterTerminate = true
        var aliveAfterKill = false
    }

    private let lock = NSLock()
    var childrenByServer: [Int32: [Int32]] = [:]
    var cmdlines: [Int32: String] = [:]
    var behaviors: [Int32: Behavior] = [:]
    /// Scriptable `ps -o stat=` result per pid; a missing entry means the
    /// pid reports no stat (as if gone) — mirrors `ProcessSignaller.stat`.
    var stats: [Int32: String] = [:]
    /// Scriptable process start time per pid. A missing entry means the start
    /// time could not be read — which every identity check must read as "not
    /// the same process", so leaving it unset is how a test states that case.
    var startTimes: [Int32: Date] = [:]
    private(set) var terminated: [Int32] = []
    private(set) var killed: [Int32] = []
    /// Only the pid-exact variants, recorded separately so a caller that must
    /// never widen its target to a process group can assert which door it went
    /// through. Both still fall through to `terminated`/`killed`, so callers
    /// that do not care keep asserting on those.
    private(set) var terminatedProcessOnly: [Int32] = []
    private(set) var killedProcessOnly: [Int32] = []
    private var terminatedSet: Set<Int32> = []
    private var killedSet: Set<Int32> = []

    func isAlive(_ pid: Int32) -> Bool {
        lock.withLock {
            let b = behaviors[pid] ?? Behavior()
            if killedSet.contains(pid) { return b.aliveAfterKill }
            if terminatedSet.contains(pid) { return b.aliveAfterTerminate }
            return b.aliveInitially
        }
    }
    /// Fired after a SIGTERM is recorded, so a test can mutate the scripted
    /// process table mid-reap — the only way to state "this pid was freed and
    /// handed to somebody else inside the grace window".
    var onTerminate: (@Sendable (Int32) -> Void)?

    func terminate(_ pid: Int32) {
        lock.withLock { terminated.append(pid); terminatedSet.insert(pid) }
        onTerminate?(pid)
    }
    func forceKill(_ pid: Int32) { lock.withLock { killed.append(pid); killedSet.insert(pid) } }
    func children(ofServerPID serverPID: Int32) -> [Int32] { lock.withLock { childrenByServer[serverPID] ?? [] } }
    func commandLine(_ pid: Int32) -> String? { lock.withLock { cmdlines[pid] } }
    func stat(_ pid: Int32) -> String? { lock.withLock { stats[pid] } }
    func startTime(_ pid: Int32) -> Date? { lock.withLock { startTimes[pid] } }

    func terminateProcessOnly(_ pid: Int32) {
        lock.withLock { terminatedProcessOnly.append(pid) }
        terminate(pid)
    }

    func forceKillProcessOnly(_ pid: Int32) {
        lock.withLock { killedProcessOnly.append(pid) }
        forceKill(pid)
    }
}

final class FakeTmuxQuerier: TmuxProcessQuerying, @unchecked Sendable {
    var serverPIDs: [String: Int32] = [:]
    var panePIDs: [String: Set<Int32>] = [:]
    func serverPID(server: String) async -> Int32? { serverPIDs[server] }
    func livePanePIDs(server: String) async -> Set<Int32> { panePIDs[server] ?? [] }
}
