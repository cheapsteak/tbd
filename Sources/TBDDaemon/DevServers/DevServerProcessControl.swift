import Darwin
import Foundation
import TBDShared

/// Injection seam over the kernel calls the stop kill makes, so the stop
/// rules are testable without signalling real processes.
protocol DevServerSignalling: Sendable {
    func processInfo(_ pid: Int32) -> DevServerProcessInfo?
    /// `getpgid(pid)`, nil when the pid is gone.
    func processGroup(of pid: Int32) -> Int32?
    /// The daemon's own group, which is never signalled.
    func ownProcessGroup() -> Int32
    /// The daemon's own pid, which is never signalled.
    func ownProcessID() -> Int32
    /// `kill(-pgid, signal)`.
    func signalGroup(_ pgid: Int32, _ signal: Int32)
    /// `kill(pid, signal)`.
    func signalProcess(_ pid: Int32, _ signal: Int32)
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

    func ownProcessID() -> Int32 { getpid() }

    func signalGroup(_ pgid: Int32, _ signal: Int32) {
        guard pgid > 1 else { return }
        _ = Foundation.kill(-pgid, signal)
    }

    func signalProcess(_ pid: Int32, _ signal: Int32) {
        guard pid > 1 else { return }
        _ = Foundation.kill(pid, signal)
    }

    /// Whether any member of the group is still running. A zombie does not
    /// count: `kill(-pgid, 0)` succeeds while a dead leader waits to be
    /// reaped, which would report a group that died on SIGKILL as a survivor.
    /// The group's members are read with `sysctl(KERN_PROC_PGRP)`; only when
    /// that read fails does the answer fall back to `kill(-pgid, 0)`.
    func groupExists(_ pgid: Int32) -> Bool {
        guard pgid > 1 else { return false }
        if let states = Self.memberStates(ofGroup: pgid) {
            return states.contains { $0 != DevServerProcessProbe.zombieState }
        }
        if Foundation.kill(-pgid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// `p_stat` of every process in group `pgid`; nil when the kernel read
    /// fails.
    static func memberStates(ofGroup pgid: Int32) -> [Int32]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        if size == 0 { return [] }
        // Headroom: the group can gain members between the two reads.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = procs.count * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return nil }
        return procs.prefix(size / stride).map { Int32($0.kp_proc.p_stat) }
    }
}

/// One process a stop should end.
struct DevServerKillTarget: Sendable, Equatable {
    /// What proves `pid` is still the process the stop means.
    enum Anchor: Sendable, Equatable {
        /// A start time recorded when the process was first seen (a running
        /// file, a holder row); the kernel's must lie within `tolerance`.
        case recorded(Date, tolerance: TimeInterval)
        /// The pid was read first-hand moments before the kill (a live tmux
        /// pane, the holder registry's adopted child): the kill reads the
        /// start time itself, at once, and every later check holds the
        /// process to it.
        case readAtKill
    }

    let pid: Int32
    let anchor: Anchor

    init(pid: Int32, anchor: Anchor) { self.pid = pid; self.anchor = anchor }

    init(pid: Int32, expectedStart: Date, tolerance: TimeInterval) {
        self.init(pid: pid, anchor: .recorded(expectedStart, tolerance: tolerance))
    }

    static func firstHand(pid: Int32) -> DevServerKillTarget { .init(pid: pid, anchor: .readAtKill) }
}

enum DevServerKillOutcome: Sendable, Equatable {
    /// The pid is gone, a zombie, or now names a different process.
    case notRunning
    /// The pid leads its own process group; the group was signalled.
    case terminated(pgid: Int32)
    case killed(pgid: Int32)
    case survived(pid: Int32, pgid: Int32)
    /// The pid does not lead its group (`pgid` is the group it is in); only
    /// the pid itself was signalled.
    case terminatedAlone(pid: Int32, pgid: Int32)
    case killedAlone(pid: Int32, pgid: Int32)
    case survivedAlone(pid: Int32, pgid: Int32)
    case refused(reason: String)
}

/// SIGTERM, then SIGKILL after `grace` (spec: 5 s). The whole process group
/// is signalled only when the pid leads it (`getpgid(pid) == pid`): a pid that
/// shares a group — `tbd server report --pid $!` from a shell without job
/// control shares that shell's, possibly an agent's — is signalled alone.
/// Never signals the daemon itself or its own group.
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

    /// How close two reads of one process's start time must be: the same
    /// kernel value read twice.
    private static let sameProcessTolerance: TimeInterval = 0.001

    /// Runs the whole SIGTERM → grace → SIGKILL sequence in a task of its
    /// own, which the caller's cancellation does not reach: a cancelled sleep
    /// throws at once, and a grace cut short would SIGKILL a server that was
    /// still shutting down cleanly.
    func kill(_ target: DevServerKillTarget) async -> DevServerKillOutcome {
        await Task { await self.killSequence(target) }.value
    }

    private func killSequence(_ target: DevServerKillTarget) async -> DevServerKillOutcome {
        guard target.pid > 1 else { return .refused(reason: "pid \(target.pid) is never signalled") }
        guard let info = signalling.processInfo(target.pid), !info.isZombie else { return .notRunning }
        if case .recorded(let expected, let tolerance) = target.anchor,
           abs(info.startTime.timeIntervalSince(expected)) > tolerance {
            return .notRunning
        }
        if target.pid == signalling.ownProcessID() {
            return .refused(reason: "pid \(target.pid) is TBD's own")
        }
        guard let pgid = signalling.processGroup(of: target.pid) else { return .notRunning }
        guard pgid == target.pid else {
            return await killAlone(pid: target.pid, pgid: pgid, started: info.startTime)
        }
        if pgid == signalling.ownProcessGroup() {
            return .refused(reason: "process group \(pgid) of pid \(target.pid) is TBD's own")
        }
        signalling.signalGroup(pgid, SIGTERM)
        guard await waitOut(until: { !signalling.groupExists(pgid) }) else { return .terminated(pgid: pgid) }
        signalling.signalGroup(pgid, SIGKILL)
        if postKillWait > .zero {
            try? await clock.sleep(for: postKillWait)
        }
        return signalling.groupExists(pgid) ? .survived(pid: target.pid, pgid: pgid) : .killed(pgid: pgid)
    }

    /// The pid alone, held to the start time read at the kill's first look so
    /// a pid reused during the grace is never signalled.
    private func killAlone(pid: Int32, pgid: Int32, started: Date) async -> DevServerKillOutcome {
        let alive: @Sendable () -> Bool = { [signalling] in
            guard let info = signalling.processInfo(pid), !info.isZombie else { return false }
            return abs(info.startTime.timeIntervalSince(started)) <= Self.sameProcessTolerance
        }
        signalling.signalProcess(pid, SIGTERM)
        guard await waitOut(until: { !alive() }) else { return .terminatedAlone(pid: pid, pgid: pgid) }
        signalling.signalProcess(pid, SIGKILL)
        if postKillWait > .zero {
            try? await clock.sleep(for: postKillWait)
        }
        return alive() ? .survivedAlone(pid: pid, pgid: pgid) : .killedAlone(pid: pid, pgid: pgid)
    }

    /// Polls `gone` through the grace. False when it came true (nothing left
    /// to SIGKILL), true when the grace ran out first.
    private func waitOut(until gone: () -> Bool) async -> Bool {
        var waited: Duration = .zero
        while !gone(), waited < grace {
            do { try await clock.sleep(for: pollInterval) } catch { break }
            waited += pollInterval
        }
        return !gone()
    }
}
