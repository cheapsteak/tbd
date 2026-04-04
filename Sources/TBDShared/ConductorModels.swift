import Foundation

public struct Conductor: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var repos: [String]             // repo IDs or ["*"]
    public var worktrees: [String]?        // worktree name patterns, nil = all
    public var terminalLabels: [String]?   // terminal labels to monitor, nil = all
    public var heartbeatIntervalMinutes: Int
    public var terminalID: UUID?           // FK to terminal (conductor's own terminal)
    public var worktreeID: UUID?           // FK to synthetic worktree
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        repos: [String] = ["*"],
        worktrees: [String]? = nil,
        terminalLabels: [String]? = nil,
        heartbeatIntervalMinutes: Int = 10,
        terminalID: UUID? = nil,
        worktreeID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.repos = repos
        self.worktrees = worktrees
        self.terminalLabels = terminalLabels
        self.heartbeatIntervalMinutes = heartbeatIntervalMinutes
        self.terminalID = terminalID
        self.worktreeID = worktreeID
        self.createdAt = createdAt
    }
}
