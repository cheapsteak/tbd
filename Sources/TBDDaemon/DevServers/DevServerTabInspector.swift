import Foundation
import TBDShared

enum DevServerTabStatus: Sendable, Equatable {
    /// The command is still the tab's live process. `expectedStart` anchors
    /// the pid against reuse when the row recorded one (holder). nil means
    /// the pid was read first-hand — a live tmux pane, the holder registry's
    /// adopted child — so a stop re-reads the tab and takes the start time
    /// at the kill.
    case running(pid: Int32, expectedStart: Date?)
    /// The tab's process is alive but nothing first-hand or recorded ties
    /// the pid to it: a holder session the registry has not adopted, whose
    /// row recorded no child start time. Reads as running; a stop refuses
    /// to signal it and reports so.
    case runningUnverifiable(pid: Int32)
    /// The command ended; `code` is nil when the transport could not say.
    case exited(code: Int32?)
    /// The tab's window or session no longer exists.
    case gone

    /// The pid of a running tab, verifiable or not.
    var runningPID: Int32? {
        switch self {
        case .running(let pid, _), .runningUnverifiable(let pid): return pid
        case .exited, .gone: return nil
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
/// for a session it has not adopted, the row's recorded child pid). The registry's
/// status is in memory only, so after a daemon restart an ended holder tab
/// reads `exited(code: nil)` here; the deriver then takes the code from the
/// server's saved last output (docs/specs/2026-10-11-dev-servers-design.md,
/// "Exited servers keep their last output").
struct ProductionDevServerTabInspector: DevServerTabInspecting {
    let tmux: TmuxManager
    let holderRegistry: HolderRegistry?
    let signaller: any ProcessSignaller

    func status(of terminal: Terminal, tmuxServer: String) async -> DevServerTabStatus {
        switch terminal.transport {
        case .tmux:
            switch await tmux.paneExitState(server: tmuxServer, paneID: terminal.tmuxPaneID) {
            case .running(let pid): return .running(pid: pid, expectedStart: nil)
            case .dead(let status): return .exited(code: status)
            case .gone: return .gone
            }
        case .holder:
            if let status = await holderRegistry?.lastKnownStatus(for: terminal.id) {
                switch status {
                case .alive: break
                case .exited(let code): return .exited(code: code)
                case .exitedStatusUnknown: return .exited(code: nil)
                }
            }
            // The registry's adopted child is first-hand: it came from the
            // hand-over that produced the session's reader.
            if let adopted = await holderRegistry?.adoptedProcess(for: terminal.id) {
                guard signaller.isAlive(adopted.childPID) else { return .exited(code: nil) }
                if adopted.childPID == terminal.childPID, let started = terminal.holderChildStartedAt {
                    return .running(pid: adopted.childPID, expectedStart: started)
                }
                return .running(pid: adopted.childPID, expectedStart: nil)
            }
            guard let pid = terminal.childPID, signaller.isAlive(pid) else { return .exited(code: nil) }
            guard let started = terminal.holderChildStartedAt else { return .runningUnverifiable(pid: pid) }
            return .running(pid: pid, expectedStart: started)
        }
    }
}
