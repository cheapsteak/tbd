import Foundation

public enum RepoStatus: String, Codable, Sendable {
    case ok
    case missing
}

public struct Repo: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var path: String
    public var remoteURL: String?
    public var displayName: String
    public var defaultBranch: String
    public var createdAt: Date
    public var renamePrompt: String?
    public var customInstructions: String?
    public var claudeTokenOverrideID: UUID?
    public var worktreeSlot: String?
    public var worktreeRoot: String?
    public var status: RepoStatus

    public init(id: UUID = UUID(), path: String, remoteURL: String? = nil,
                displayName: String, defaultBranch: String = "main", createdAt: Date = Date(),
                renamePrompt: String? = nil, customInstructions: String? = nil,
                claudeTokenOverrideID: UUID? = nil,
                worktreeSlot: String? = nil, worktreeRoot: String? = nil,
                status: RepoStatus = .ok) {
        self.id = id
        self.path = path
        self.remoteURL = remoteURL
        self.displayName = displayName
        self.defaultBranch = defaultBranch
        self.createdAt = createdAt
        self.renamePrompt = renamePrompt
        self.customInstructions = customInstructions
        self.claudeTokenOverrideID = claudeTokenOverrideID
        self.worktreeSlot = worktreeSlot
        self.worktreeRoot = worktreeRoot
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, path, remoteURL, displayName, defaultBranch, createdAt
        case renamePrompt, customInstructions, claudeTokenOverrideID
        case worktreeSlot, worktreeRoot, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        remoteURL = try c.decodeIfPresent(String.self, forKey: .remoteURL)
        displayName = try c.decode(String.self, forKey: .displayName)
        defaultBranch = try c.decode(String.self, forKey: .defaultBranch)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        renamePrompt = try c.decodeIfPresent(String.self, forKey: .renamePrompt)
        customInstructions = try c.decodeIfPresent(String.self, forKey: .customInstructions)
        claudeTokenOverrideID = try c.decodeIfPresent(UUID.self, forKey: .claudeTokenOverrideID)
        worktreeSlot = try c.decodeIfPresent(String.self, forKey: .worktreeSlot)
        worktreeRoot = try c.decodeIfPresent(String.self, forKey: .worktreeRoot)
        status = try c.decodeIfPresent(RepoStatus.self, forKey: .status) ?? .ok
    }
}

public enum WorktreeStatus: String, Codable, Sendable {
    case active, archived, main, creating, conductor, failed
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
    public var sortOrder: Int = 0

    public init(id: UUID = UUID(), repoID: UUID, name: String, displayName: String,
                branch: String, path: String, status: WorktreeStatus = .active,
                hasConflicts: Bool = false,
                createdAt: Date = Date(), archivedAt: Date? = nil, tmuxServer: String,
                archivedClaudeSessions: [String]? = nil, sortOrder: Int = 0) {
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
        self.sortOrder = sortOrder
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
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
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
    public var claudeTokenID: UUID?

    public init(id: UUID = UUID(), worktreeID: UUID, tmuxWindowID: String,
                tmuxPaneID: String, label: String? = nil, createdAt: Date = Date(),
                pinnedAt: Date? = nil, claudeSessionID: String? = nil,
                suspendedAt: Date? = nil, suspendedSnapshot: String? = nil,
                claudeTokenID: UUID? = nil) {
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
        self.claudeTokenID = claudeTokenID
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
        claudeTokenID = try c.decodeIfPresent(UUID.self, forKey: .claudeTokenID)
    }
}

public enum ClaudeTokenKind: String, Codable, Sendable {
    case oauth
    case apiKey
}

public struct ClaudeToken: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var kind: ClaudeTokenKind
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), name: String, kind: ClaudeTokenKind,
                createdAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct ClaudeTokenUsage: Codable, Sendable, Equatable {
    public var tokenID: UUID
    public var fiveHourPct: Double?
    public var sevenDayPct: Double?
    public var fiveHourResetsAt: Date?
    public var sevenDayResetsAt: Date?
    public var fetchedAt: Date?
    public var lastStatus: String?

    public init(tokenID: UUID, fiveHourPct: Double? = nil, sevenDayPct: Double? = nil,
                fiveHourResetsAt: Date? = nil, sevenDayResetsAt: Date? = nil,
                fetchedAt: Date? = nil, lastStatus: String? = nil) {
        self.tokenID = tokenID
        self.fiveHourPct = fiveHourPct
        self.sevenDayPct = sevenDayPct
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayResetsAt = sevenDayResetsAt
        self.fetchedAt = fetchedAt
        self.lastStatus = lastStatus
    }
}

public struct ClaudeTokenWithUsage: Codable, Sendable, Equatable {
    public let token: ClaudeToken
    public let usage: ClaudeTokenUsage?
    public init(token: ClaudeToken, usage: ClaudeTokenUsage? = nil) {
        self.token = token
        self.usage = usage
    }
}

public struct Config: Codable, Sendable, Equatable {
    public var defaultClaudeTokenID: UUID?

    public init(defaultClaudeTokenID: UUID? = nil) {
        self.defaultClaudeTokenID = defaultClaudeTokenID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultClaudeTokenID = try c.decodeIfPresent(UUID.self, forKey: .defaultClaudeTokenID)
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

// MARK: - SessionSummary

public struct SessionSummary: Codable, Sendable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public let filePath: String
    public let modifiedAt: Date
    public let fileSize: Int64
    public let lineCount: Int
    public let firstUserMessage: String?
    public let lastUserMessage: String?
    public let cwd: String?
    public let gitBranch: String?
    /// Timestamp of the last message in the session (from JSONL), falls back to file mtime.
    public let lastMessageAt: Date

    public init(
        sessionId: String,
        filePath: String,
        modifiedAt: Date,
        fileSize: Int64,
        lineCount: Int,
        firstUserMessage: String?,
        lastUserMessage: String?,
        cwd: String?,
        gitBranch: String?,
        lastMessageAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.filePath = filePath
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
        self.lineCount = lineCount
        self.firstUserMessage = firstUserMessage
        self.lastUserMessage = lastUserMessage
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.lastMessageAt = lastMessageAt ?? modifiedAt
    }
}

// MARK: - Chat Types

public enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct ChatMessage: Codable, Sendable, Identifiable {
    public let id: UUID
    public let role: ChatRole
    public let text: String
    public let timestamp: Date?

    public init(id: UUID = UUID(), role: ChatRole, text: String, timestamp: Date? = nil) {
        self.id = id; self.role = role; self.text = text; self.timestamp = timestamp
    }
}

public struct SessionMessagesParams: Codable, Sendable {
    public let filePath: String
    public init(filePath: String) { self.filePath = filePath }
}
