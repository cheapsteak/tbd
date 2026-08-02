import Foundation
import TBDShared

/// A deterministic, read-only projection of TBD's existing remote-session
/// mirror for one provider. The provider's reachability never rewrites these
/// counts: terminal liveness and agent activity remain independent axes.
struct RemoteProviderDeskSummary: Equatable {
    struct TerminalCounts: Equatable {
        var starting = 0
        var running = 0
        var exited = 0
        var gone = 0
        var unknown = 0
    }

    struct AgentCounts: Equatable {
        var working = 0
        var waitingInput = 0
        var idle = 0
        var exited = 0
        var unknown = 0
    }

    let sessions: [RemoteSessionInfo]
    let terminal: TerminalCounts
    let agent: AgentCounts
    let latestMirrorUpdate: Date?

    var total: Int { sessions.count }

    /// "just now" / "2h ago" — the same freshness vocabulary every other
    /// staleness surface in the app already speaks
    /// (`ProfileUsagePresentation.ageText`, `RemoteSessionRowView.stalenessCaption`),
    /// rather than SwiftUI's `Text(_, style: .relative)`, which renders a
    /// bare magnitude with no direction ("Latest mirror update 2 minutes").
    /// `ageText`'s "just now" is already a complete phrase, so it never
    /// takes the trailing "ago".
    nonisolated static func agePhrase(since date: Date, now: Date = Date()) -> String {
        let age = ProfileUsagePresentation.ageText(since: date, now: now)
        return age == "just now" ? age : "\(age) ago"
    }

    /// What the desk is allowed to claim about freshness.
    ///
    /// `RemoteProviderStatus.lastSuccessfulSnapshotAt` is the provider-wide
    /// fact — the last COMPLETE inventory the mirror accepted — so it is the
    /// honest answer whenever the daemon has one, and it is what the sidebar
    /// caption and the session detail pane already quote. Per-row `lastSeen`
    /// is only a lower bound derived from whichever rows happened to appear:
    /// it cannot tell a successful EMPTY snapshot from no snapshot at all,
    /// and a provider whose rows all stopped being reported would keep
    /// quoting an age that no longer describes any inventory.
    ///
    /// The row-derived value stays as a labelled fallback (an older daemon
    /// sends no snapshot timestamp), but it is never called an inventory.
    nonisolated static func freshnessLabel(
        lastSuccessfulSnapshotAt: Date?,
        latestMirrorUpdate: Date?,
        now: Date = Date()
    ) -> String {
        if let snapshot = lastSuccessfulSnapshotAt {
            return "Inventory as of \(agePhrase(since: snapshot, now: now))"
        }
        if let latest = latestMirrorUpdate {
            return "Latest mirror update \(agePhrase(since: latest, now: now))"
        }
        return "No successful inventory yet"
    }

    init(provider: String, sessions allSessions: [RemoteSessionInfo]) {
        sessions = allSessions
            .filter { $0.provider == provider && !$0.dismissed }
            .sorted {
                if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
                return $0.payload.id.localizedStandardCompare($1.payload.id) == .orderedAscending
            }

        var terminal = TerminalCounts()
        var agent = AgentCounts()

        for session in sessions {
            if session.gone {
                terminal.gone += 1
            } else {
                switch session.payload.state {
                case .starting: terminal.starting += 1
                case .running: terminal.running += 1
                case .exited: terminal.exited += 1
                case .unknown: terminal.unknown += 1
                }
            }

            switch session.payload.agentState {
            case .working: agent.working += 1
            case .waitingInput: agent.waitingInput += 1
            case .idle: agent.idle += 1
            case .exited: agent.exited += 1
            case .unknown: agent.unknown += 1
            }
        }

        self.terminal = terminal
        self.agent = agent
        latestMirrorUpdate = sessions.first?.lastSeen
    }
}
