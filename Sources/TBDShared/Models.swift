import Foundation

public struct Repo: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var path: String
    public var remoteURL: String?
    public var displayName: String
    public var defaultBranch: String
    public var createdAt: Date

    public init(id: UUID = UUID(), path: String, remoteURL: String? = nil,
                displayName: String, defaultBranch: String = "main", createdAt: Date = Date()) {
        self.id = id
        self.path = path
        self.remoteURL = remoteURL
        self.displayName = displayName
        self.defaultBranch = defaultBranch
        self.createdAt = createdAt
    }
}

public enum WorktreeStatus: String, Codable, Sendable {
    case active, archived, main, creating
}

public struct Worktree: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var repoID: UUID
    public var name: String
    public var displayName: String
    public var branch: String
    public var path: String
    public var status: WorktreeStatus
    public var hasConflicts: Bool = false
    public var createdAt: Date
    public var archivedAt: Date?
    public var tmuxServer: String
    public var archivedClaudeSessions: [String]?

    public init(id: UUID = UUID(), repoID: UUID, name: String, displayName: String,
                branch: String, path: String, status: WorktreeStatus = .active,
                hasConflicts: Bool = false,
                createdAt: Date = Date(), archivedAt: Date? = nil, tmuxServer: String,
                archivedClaudeSessions: [String]? = nil) {
        self.id = id
        self.repoID = repoID
        self.name = name
        self.displayName = displayName
        self.branch = branch
        self.path = path
        self.status = status
        self.hasConflicts = hasConflicts
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.tmuxServer = tmuxServer
        self.archivedClaudeSessions = archivedClaudeSessions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        repoID = try c.decode(UUID.self, forKey: .repoID)
        name = try c.decode(String.self, forKey: .name)
        displayName = try c.decode(String.self, forKey: .displayName)
        branch = try c.decode(String.self, forKey: .branch)
        path = try c.decode(String.self, forKey: .path)
        status = try c.decode(WorktreeStatus.self, forKey: .status)
        hasConflicts = try c.decodeIfPresent(Bool.self, forKey: .hasConflicts) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        tmuxServer = try c.decode(String.self, forKey: .tmuxServer)
        archivedClaudeSessions = try c.decodeIfPresent([String].self, forKey: .archivedClaudeSessions)
    }
}

public struct Terminal: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var worktreeID: UUID
    public var tmuxWindowID: String
    public var tmuxPaneID: String
    public var label: String?
    public var createdAt: Date
    public var pinnedAt: Date?
    public var claudeSessionID: String?
    public var suspendedAt: Date?
    public var suspendedSnapshot: String?

    public init(id: UUID = UUID(), worktreeID: UUID, tmuxWindowID: String,
                tmuxPaneID: String, label: String? = nil, createdAt: Date = Date(),
                pinnedAt: Date? = nil, claudeSessionID: String? = nil,
                suspendedAt: Date? = nil, suspendedSnapshot: String? = nil) {
        self.id = id
        self.worktreeID = worktreeID
        self.tmuxWindowID = tmuxWindowID
        self.tmuxPaneID = tmuxPaneID
        self.label = label
        self.createdAt = createdAt
        self.pinnedAt = pinnedAt
        self.claudeSessionID = claudeSessionID
        self.suspendedAt = suspendedAt
        self.suspendedSnapshot = suspendedSnapshot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        worktreeID = try c.decode(UUID.self, forKey: .worktreeID)
        tmuxWindowID = try c.decode(String.self, forKey: .tmuxWindowID)
        tmuxPaneID = try c.decode(String.self, forKey: .tmuxPaneID)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        claudeSessionID = try c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        suspendedAt = try c.decodeIfPresent(Date.self, forKey: .suspendedAt)
        suspendedSnapshot = try c.decodeIfPresent(String.self, forKey: .suspendedSnapshot)
    }
}

public struct Note: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var worktreeID: UUID
    public var title: String
    public var content: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), worktreeID: UUID, title: String,
                content: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.worktreeID = worktreeID
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum NotificationType: String, Codable, Sendable {
    case responseComplete = "response_complete"
    case error
    case taskComplete = "task_complete"
    case attentionNeeded = "attention_needed"

    public var severity: Int {
        switch self {
        case .error: 4
        case .attentionNeeded: 3
        case .taskComplete: 2
        case .responseComplete: 1
        }
    }
}

public struct TBDNotification: Codable, Sendable, Identifiable {
    public let id: UUID
    public var worktreeID: UUID
    public var type: NotificationType
    public var message: String?
    public var read: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), worktreeID: UUID, type: NotificationType,
                message: String? = nil, read: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.worktreeID = worktreeID
        self.type = type
        self.message = message
        self.read = read
        self.createdAt = createdAt
    }
}

public enum PRMergeableState: String, Codable, Sendable {
    case open               // PR exists, no review decision yet
    case changesRequested   // reviewer requested changes
    case mergeable          // GitHub considers it clean (checks + reviews satisfied)
    case merged             // PR was merged
    case closed             // PR was closed without merging
}

public struct PRStatus: Codable, Sendable, Equatable {
    public let number: Int
    public let url: String
    public let state: PRMergeableState

    public init(number: Int, url: String, state: PRMergeableState) {
        self.number = number
        self.url = url
        self.state = state
    }
}
