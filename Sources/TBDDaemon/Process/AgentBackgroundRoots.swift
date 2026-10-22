import Foundation
import TBDShared

/// Names the process each live agent tab runs from, for `AgentBackgroundController`.
///
/// A root is the top of the tab's own tree: the job a holder forked for a holder
/// tab, the pane's process for a tmux tab. Never the holder and never the tmux
/// server, which carry the terminal's input and output. Parked tabs name no
/// process and are skipped.
struct AgentBackgroundRoots: Sendable {
    let database: TBDDatabase
    let tmux: TmuxManager
    let priority: any ProcessPriority

    func resolve() async -> [pid_t] {
        guard let terminals = try? await database.terminals.list() else { return [] }
        var roots: [pid_t] = []
        for terminal in terminals {
            // A row with no recorded kind predates kinds and is Claude's, the
            // same reading `isClaudeTab` gives it everywhere else.
            guard terminal.isCodexTerminal || terminal.isClaudeTab, !terminal.isParked
            else { continue }
            let root: pid_t?
            switch terminal.transport {
            case .holder:
                root = holderJob(of: terminal)
            default:
                root = await panePID(of: terminal)
            }
            if let root, root > 1, !roots.contains(root) { roots.append(root) }
        }
        return roots
    }

    /// The recorded job, trusted only while it is still its holder's child and
    /// started near the row's anchor: the same test `HolderDescentIndex` applies,
    /// because a recorded pid alone may have been reissued.
    private func holderJob(of terminal: Terminal) -> pid_t? {
        guard let holder = terminal.holderPID, holder > 1,
              let job = terminal.childPID, job > 1,
              priority.startTimeMicros(of: holder) != nil,
              priority.parentPID(of: job) == holder,
              let startedMicros = priority.startTimeMicros(of: job)
        else { return nil }
        let started = Date(timeIntervalSince1970: TimeInterval(startedMicros) / 1_000_000)
        let anchor = HolderChildIdentity.anchor(of: terminal)
        guard abs(started.timeIntervalSince(anchor)) <= HolderChildIdentity.startWindow else { return nil }
        return job
    }

    private func panePID(of terminal: Terminal) async -> pid_t? {
        guard let worktree = (try? await database.worktrees.getLocal(id: terminal.worktreeID)) ?? nil,
              let text = try? await tmux.panePID(server: worktree.tmuxServer, paneID: terminal.tmuxPaneID)
        else { return nil }
        return pid_t(text)
    }
}
