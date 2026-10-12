import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// A process table in memory. Groups die when signalled with a signal they
/// are configured to die on; a dead group's processes vanish.
final class FakeDevServerSignalling: DevServerSignalling, @unchecked Sendable {
    struct Sent: Equatable { let pgid: Int32; let signal: Int32 }
    private let lock = NSLock()
    private var infos: [Int32: DevServerProcessInfo] = [:]
    private var groups: [Int32: Int32] = [:]
    private var dieOn: [Int32: Set<Int32>] = [:]
    private var sent: [Sent] = []
    private var sentAlone: [Sent] = []
    let own: Int32
    let ownPID: Int32

    init(own: Int32 = 4242, ownPID: Int32 = 4243) { self.own = own; self.ownPID = ownPID }

    func add(pid: Int32, pgid: Int32, start: Date, zombie: Bool = false, diesOn signals: Set<Int32> = [SIGTERM]) {
        lock.lock(); defer { lock.unlock() }
        infos[pid] = DevServerProcessInfo(startTime: start, isZombie: zombie)
        groups[pid] = pgid
        dieOn[pgid] = signals
    }

    /// Signals sent to whole groups (`kill(-pgid, …)`).
    var sentSignals: [Sent] { lock.lock(); defer { lock.unlock() }; return sent }
    /// Signals sent to single processes (`kill(pid, …)`); `pgid` holds the pid.
    var sentToProcesses: [Sent] { lock.lock(); defer { lock.unlock() }; return sentAlone }
    func isAlive(_ pid: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return infos[pid] != nil }

    func processInfo(_ pid: Int32) -> DevServerProcessInfo? { lock.lock(); defer { lock.unlock() }; return infos[pid] }
    func processGroup(of pid: Int32) -> Int32? { lock.lock(); defer { lock.unlock() }; return groups[pid] }
    func ownProcessGroup() -> Int32 { own }
    func ownProcessID() -> Int32 { ownPID }
    /// The pid dies alone when its group is configured to die on `signal`.
    func signalProcess(_ pid: Int32, _ signal: Int32) {
        lock.lock(); defer { lock.unlock() }
        sentAlone.append(Sent(pgid: pid, signal: signal))
        guard let group = groups[pid], dieOn[group]?.contains(signal) == true else { return }
        groups.removeValue(forKey: pid)
        infos.removeValue(forKey: pid)
    }
    func groupExists(_ pgid: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return groups.values.contains(pgid) }
    func signalGroup(_ pgid: Int32, _ signal: Int32) {
        lock.lock(); defer { lock.unlock() }
        sent.append(Sent(pgid: pgid, signal: signal))
        guard dieOn[pgid]?.contains(signal) == true else { return }
        for (pid, group) in groups where group == pgid {
            groups.removeValue(forKey: pid)
            infos.removeValue(forKey: pid)
        }
    }
}

final class FakeDevServerCommandRunner: DevServerCommandRunning, @unchecked Sendable {
    struct Run: Equatable { let command: String; let cwd: String; let environment: [String: String]; let timeout: Duration }
    private let lock = NSLock()
    private var outcomes: [String: DevServerCommandOutcome]
    private var recorded: [Run] = []

    init(outcomes: [String: DevServerCommandOutcome] = [:]) { self.outcomes = outcomes }

    var runs: [Run] { lock.lock(); defer { lock.unlock() }; return recorded }

    func run(_ command: String, cwd: String, environment: [String: String], timeout: Duration) async -> DevServerCommandOutcome {
        // `withLock`, not `lock()`: NSLock.lock() is unavailable from async contexts.
        lock.withLock {
            recorded.append(Run(command: command, cwd: cwd, environment: environment, timeout: timeout))
            return outcomes[command] ?? .exited(0)
        }
    }
}
