import Foundation
import TBDShared

enum DevServerTabStatus: Sendable, Equatable {
    /// The command is still the tab's live process. `expectedStart` anchors
    /// the pid against reuse when the row recorded one (holder); tmux panes
    /// are read live and carry nil.
    case running(pid: Int32, expectedStart: Date?)
    /// The command ended; `code` is nil when the transport could not say.
    case exited(code: Int32?)
    /// The tab's window or session no longer exists.
    case gone
}

struct DevServerTabObservation: Sendable {
    let terminal: Terminal
    let status: DevServerTabStatus
}

protocol DevServerTabInspecting: Sendable {
    func status(of terminal: Terminal, tmuxServer: String) async -> DevServerTabStatus
}

/// tmux: `#{pane_dead}` / `#{pane_dead_status}`. Holder: the registry's last
/// known child status, else the recorded child pid's liveness. The registry's
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
            guard let pid = terminal.childPID, signaller.isAlive(pid) else { return .exited(code: nil) }
            return .running(pid: pid, expectedStart: terminal.holderChildStartedAt ?? terminal.createdAt)
        }
    }
}
