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
