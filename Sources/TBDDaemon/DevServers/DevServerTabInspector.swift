import Foundation
import TBDShared

enum DevServerTabStatus: Sendable, Equatable {
    /// The command is still the tab's live process. `expectedStart` anchors
    /// the pid against reuse: a holder job always carries the start time its
    /// row recorded. nil means the pid was read first-hand from a live tmux
    /// pane, so a stop re-reads the tab and takes the start time at the kill.
    case running(pid: Int32, expectedStart: Date?)
    /// The tab's process is alive but no recorded start time ties the pid
    /// to it: a holder job whose row recorded none for that pid, adopted by
    /// the registry or not. Liveness alone cannot tell it from a reused pid.
    /// Reads as running; a stop — gesture or archive — refuses to signal it
    /// and reports so, and closing the tab ends the job.
    case runningUnverifiable(pid: Int32)
    /// The command ended; `code` is nil when the transport could not say.
    /// `pid` is the process that ended, when the transport still reports it
    /// (a tmux dead pane); it tells a respawned tab's runs apart.
    case exited(code: Int32?, pid: Int32? = nil)
    /// The tab's window or session no longer exists.
    case gone
    /// The transport could not be asked — a tmux query that timed out or
    /// failed without saying the pane is gone. The command may still be
    /// running: the server reads *Unknown*, a start refuses rather than
    /// open a second tab, and a stop refuses rather than report success.
    case unknown(reason: String)

    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// The pid of a running tab, verifiable or not.
    var runningPID: Int32? {
        switch self {
        case .running(let pid, _), .runningUnverifiable(let pid): return pid
        case .exited, .gone, .unknown: return nil
        }
    }
}

struct DevServerTabObservation: Sendable {
    let terminal: Terminal
    let status: DevServerTabStatus
}

protocol DevServerTabInspecting: Sendable {
    func status(of terminal: Terminal, tmuxServer: String) async -> DevServerTabStatus
}

/// tmux: `#{pane_dead}` / `#{pane_dead_status}`. Holder: the registry's last
/// known child status, else the liveness of the registry's adopted child (or,
/// for a session it has not adopted, the row's recorded child pid). A pid the
/// row recorded a start time for counts as alive only while the kernel's start
/// time for it still matches, so a reused pid reads ended. The registry's
/// status is in memory only, so after a daemon restart an ended holder tab
/// reads `exited(code: nil)` here; the deriver then takes the code from the
/// server's saved last output (docs/specs/2026-10-11-dev-servers-design.md,
/// "Exited servers keep their last output").
struct ProductionDevServerTabInspector: DevServerTabInspecting {
    let tmux: TmuxManager
    let holderRegistry: HolderRegistry?
    let signaller: any ProcessSignaller
    /// Reads the kernel's start time for a pid checked against the row's.
    var probe: DevServerProcessProbe = .live

    func status(of terminal: Terminal, tmuxServer: String) async -> DevServerTabStatus {
        switch terminal.transport {
        case .tmux:
            switch await tmux.paneExitState(server: tmuxServer, paneID: terminal.tmuxPaneID) {
            case .running(let pid): return .running(pid: pid, expectedStart: nil)
            case .dead(let status, let pid): return .exited(code: status, pid: pid)
            case .gone: return .gone
            case .unknown(let reason): return .unknown(reason: reason)
            }
        case .holder:
            if let status = await holderRegistry?.lastKnownStatus(for: terminal.id) {
                switch status {
                case .alive: break
                case .exited(let code): return .exited(code: code)
                case .exitedStatusUnknown: return .exited(code: nil)
                }
            }
            // The registry's adopted child came from the hand-over that
            // produced the session's reader, but the registry keeps no start
            // time for it: only the row's recorded one anchors the pid
            // against reuse, so without it the job is never signalled.
            if let adopted = await holderRegistry?.adoptedProcess(for: terminal.id) {
                guard signaller.isAlive(adopted.childPID) else { return .exited(code: nil) }
                if adopted.childPID == terminal.childPID, let started = terminal.holderChildStartedAt {
                    guard isSameProcess(adopted.childPID, startedAt: started) else { return .exited(code: nil) }
                    return .running(pid: adopted.childPID, expectedStart: started)
                }
                return .runningUnverifiable(pid: adopted.childPID)
            }
            guard let pid = terminal.childPID, signaller.isAlive(pid) else { return .exited(code: nil) }
            guard let started = terminal.holderChildStartedAt else { return .runningUnverifiable(pid: pid) }
            guard isSameProcess(pid, startedAt: started) else { return .exited(code: nil) }
            return .running(pid: pid, expectedStart: started)
        }
    }

    /// Whether `pid` is still the process the row recorded: alive, not a
    /// zombie, and started within the same window a stop's kill allows.
    private func isSameProcess(_ pid: Int32, startedAt recorded: Date) -> Bool {
        guard let info = probe.info(pid), !info.isZombie else { return false }
        return abs(info.startTime.timeIntervalSince(recorded)) <= AgentReaper.defaultHolderIdentityWindow
    }
}
