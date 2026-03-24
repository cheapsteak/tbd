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

public enum GitStatus: String, Codable, Sendable {
    case current     // branch is ahead of or equal to main — no action needed
    case behind      // main has commits not on this branch
    case conflicts   // would conflict if merged into main
    case merged      // squash-merged into main (set by TBD's merge flow)
}

public struct Worktree: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var repoID: UUID
    public var name: String
    public var displayName: String
    public var branch: String
    public var path: String
    public var status: WorktreeStatus
    public var gitStatus: GitStatus
    public var createdAt: Date
    public var archivedAt: Date?
    public var tmuxServer: String

    public init(id: UUID = UUID(), repoID: UUID, name: String, displayName: String,
                branch: String, path: String, status: WorktreeStatus = .active,
                gitStatus: GitStatus = .current,
                createdAt: Date = Date(), archivedAt: Date? = nil, tmuxServer: String) {
        self.id = id
        self.repoID = repoID
        self.name = name
        self.displayName = displayName
        self.branch = branch
        self.path = path
        self.status = status
        self.gitStatus = gitStatus
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.tmuxServer = tmuxServer
    }
}

public struct Terminal: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var worktreeID: UUID
    public var tmuxWindowID: String
    public var tmuxPaneID: String
    public var label: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), worktreeID: UUID, tmuxWindowID: String,
                tmuxPaneID: String, label: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.worktreeID = worktreeID
        self.tmuxWindowID = tmuxWindowID
        self.tmuxPaneID = tmuxPaneID
        self.label = label
        self.createdAt = createdAt
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
