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
    private(set) var terminated: [Int32] = []
    private(set) var killed: [Int32] = []
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
    func terminate(_ pid: Int32) { lock.withLock { terminated.append(pid); terminatedSet.insert(pid) } }
    func forceKill(_ pid: Int32) { lock.withLock { killed.append(pid); killedSet.insert(pid) } }
    func children(ofServerPID serverPID: Int32) -> [Int32] { lock.withLock { childrenByServer[serverPID] ?? [] } }
    func commandLine(_ pid: Int32) -> String? { lock.withLock { cmdlines[pid] } }
}
