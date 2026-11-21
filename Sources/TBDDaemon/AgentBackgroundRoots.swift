import Foundation
import TBDShared

/// Names the process each live agent tab runs from, for `AgentBackgroundController`.
///
/// A root is the top of the tab's own tree: the job a holder forked. Never the
/// holder, which carries the terminal's input and output. Parked tabs name no
/// process and are skipped, and so are tabs still on the tmux transport, which
/// TBD runs no tmux command to read.
struct AgentBackgroundRoots: Sendable {
    let database: TBDDatabase
    let priority: any ProcessPriority

    func resolve() async -> [pid_t] {
        guard let terminals = try? await database.terminals.list() else { return [] }
        var roots: [pid_t] = []
        for terminal in terminals {
            // A row with no recorded kind predates kinds and is Claude's, the
            // same reading `isClaudeTab` gives it everywhere else.
            guard terminal.isCodexTerminal || terminal.isClaudeTab, !terminal.isParked
            else { continue }
            guard terminal.transport == .holder else { continue }
            if let root = holderJob(of: terminal), root > 1, !roots.contains(root) {
                roots.append(root)
            }
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
}
