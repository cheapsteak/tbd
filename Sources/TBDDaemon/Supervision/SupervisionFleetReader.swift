import Foundation
import TBDShared

/// One agent inside the perimeter, as the roster snapshot records it.
///
/// The perimeter is the fleet table: a session TBD did not spawn is invisible
/// to it, and the record reports that boundary honestly rather than implying
/// coverage it does not have (design §6).
public struct SupervisionFleetAgent: Sendable, Equatable {
    public let worktree: UUID
    public let terminal: UUID
    public let repo: UUID
    /// What TBD launched in this terminal — `claude`, `codex`, or `unknown` for
    /// a row whose kind was never recorded.
    public let spawnSource: String
    /// The agent's transcript, or nil when TBD does not know it.
    public let transcriptPath: String?

    public init(worktree: UUID, terminal: UUID, repo: UUID,
                spawnSource: String, transcriptPath: String?) {
        self.worktree = worktree
        self.terminal = terminal
        self.repo = repo
        self.spawnSource = spawnSource
        self.transcriptPath = transcriptPath
    }

    /// The value `spawnSource` takes for a terminal whose kind was never
    /// recorded. Named rather than spelled inline so the roster and its tests
    /// agree on the one string.
    public static let unknownSpawnSource = "unknown"
}

/// The only fleet facts supervision reads.
///
/// Deliberately two methods and two value types wide. Supervision needs the
/// repo list to resolve topology and a roster of agents to snapshot when a
/// project turns on; everything else about a session — its activity state, its
/// work facts, its counters — belongs to the readout that a later slice builds,
/// and pulling any of it through here now would couple coverage to a surface
/// that is still moving.
public protocol SupervisionFleetReading: Sendable {
    /// Every registered repo, as project resolution sees it.
    ///
    /// All of them, including hidden and `.missing` ones: a repo an operator
    /// hid from the sidebar is still a repo, and resolving it away would make
    /// its project silently vanish from the topology rather than appear turned
    /// off — the third state this design refuses.
    func repos() async throws -> [SupervisionRepo]

    /// The agents whose worktrees belong to any of `repoIDs`, for a roster
    /// snapshot. Order is not part of the contract; the caller sorts.
    func agents(inRepos repoIDs: Set<UUID>) async throws -> [SupervisionFleetAgent]
}

/// The production reader, over TBD's own database.
public struct DatabaseSupervisionFleetReader: SupervisionFleetReading {
    private let db: TBDDatabase

    public init(db: TBDDatabase) {
        self.db = db
    }

    public func repos() async throws -> [SupervisionRepo] {
        try await db.repos.list().map(SupervisionRepo.init)
    }

    /// Archived worktrees are excluded — an archived worktree's sessions are
    /// gone, so listing them would put agents on the roster that no longer
    /// exist. A terminal explicitly recorded as a shell is excluded because a
    /// shell is not an agent; one whose kind was never recorded is **kept**,
    /// with `spawnSource` reading `unknown`. Dropping it would make the record
    /// claim it was not there, and "what was under watch" is exactly the
    /// question this snapshot answers.
    public func agents(inRepos repoIDs: Set<UUID>) async throws -> [SupervisionFleetAgent] {
        var agents: [SupervisionFleetAgent] = []
        for repoID in repoIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let worktrees = try await db.worktrees.list(repoID: repoID, excludeArchived: true)
            for worktree in worktrees {
                for terminal in try await db.terminals.list(worktreeID: worktree.id) {
                    guard terminal.kind != .shell else { continue }
                    agents.append(SupervisionFleetAgent(
                        worktree: worktree.id,
                        terminal: terminal.id,
                        repo: repoID,
                        spawnSource: terminal.kind?.rawValue
                            ?? SupervisionFleetAgent.unknownSpawnSource,
                        transcriptPath: terminal.transcriptPath))
                }
            }
        }
        return agents
    }
}
