import Darwin
import Foundation
import TBDShared

/// Injection seam over the kernel calls the group kill makes, so the stop
/// rules are testable without signalling real processes.
protocol DevServerSignalling: Sendable {
    func processInfo(_ pid: Int32) -> DevServerProcessInfo?
    /// `getpgid(pid)`, nil when the pid is gone.
    func processGroup(of pid: Int32) -> Int32?
    /// The daemon's own group, which is never signalled.
    func ownProcessGroup() -> Int32
    /// `kill(-pgid, signal)`.
    func signalGroup(_ pgid: Int32, _ signal: Int32)
    /// Whether any process is still in the group (`kill(-pgid, 0)`).
    func groupExists(_ pgid: Int32) -> Bool
}

struct ProductionDevServerSignalling: DevServerSignalling {
    func processInfo(_ pid: Int32) -> DevServerProcessInfo? { DevServerProcessProbe.kernelInfo(pid: pid) }

    func processGroup(of pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        let group = getpgid(pid)
        return group < 0 ? nil : group
    }

    func ownProcessGroup() -> Int32 { getpgrp() }

    func signalGroup(_ pgid: Int32, _ signal: Int32) {
        guard pgid > 1 else { return }
        _ = Foundation.kill(-pgid, signal)
    }

    func groupExists(_ pgid: Int32) -> Bool {
        guard pgid > 1 else { return false }
        if Foundation.kill(-pgid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// One process whose group a stop should end.
struct DevServerKillTarget: Sendable, Equatable {
    let pid: Int32
    /// The start time `pid` must still have; nil when the caller read the pid
    /// moments ago from a source that cannot be stale (a live tmux pane).
    let expectedStart: Date?
    let tolerance: TimeInterval
}

enum DevServerKillOutcome: Sendable, Equatable {
    /// The pid is gone, a zombie, or now names a different process.
    case notRunning
    case terminated(pgid: Int32)
    case killed(pgid: Int32)
    case survived(pid: Int32, pgid: Int32)
    case refused(pgid: Int32, reason: String)
}

/// SIGTERM to the process group, then SIGKILL after `grace` (spec: 5 s).
/// Refuses groups 0 and 1 and the daemon's own group.
struct DevServerGroupKiller: Sendable {
    let signalling: any DevServerSignalling
    let grace: Duration
    let pollInterval: Duration
    let postKillWait: Duration
    let clock: any Clock<Duration>

    init(
        signalling: any DevServerSignalling = ProductionDevServerSignalling(),
        grace: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(250),
        postKillWait: Duration = .seconds(1),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.signalling = signalling
        self.grace = grace
        self.pollInterval = pollInterval
        self.postKillWait = postKillWait
        self.clock = clock
    }

    func kill(_ target: DevServerKillTarget) async -> DevServerKillOutcome {
        guard let info = signalling.processInfo(target.pid), !info.isZombie else { return .notRunning }
        if let expected = target.expectedStart,
           abs(info.startTime.timeIntervalSince(expected)) > target.tolerance {
            return .notRunning
        }
        guard let pgid = signalling.processGroup(of: target.pid) else { return .notRunning }
        if pgid <= 1 {
            return .refused(pgid: pgid, reason: "process group \(pgid) of pid \(target.pid) is never signalled")
        }
        if pgid == signalling.ownProcessGroup() {
            return .refused(pgid: pgid, reason: "process group \(pgid) of pid \(target.pid) is TBD's own")
        }
        signalling.signalGroup(pgid, SIGTERM)
        var waited: Duration = .zero
        while signalling.groupExists(pgid), waited < grace {
            do { try await clock.sleep(for: pollInterval) } catch { break }
            waited += pollInterval
        }
        guard signalling.groupExists(pgid) else { return .terminated(pgid: pgid) }
        signalling.signalGroup(pgid, SIGKILL)
        if postKillWait > .zero {
            try? await clock.sleep(for: postKillWait)
        }
        return signalling.groupExists(pgid) ? .survived(pid: target.pid, pgid: pgid) : .killed(pgid: pgid)
    }
}
