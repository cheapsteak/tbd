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
    public var profileOverrideID: UUID?
    public var worktreeSlot: String?
    public var worktreeRoot: String?
    public var status: RepoStatus

    public init(id: UUID = UUID(), path: String, remoteURL: String? = nil,
                displayName: String, defaultBranch: String = "main", createdAt: Date = Date(),
                renamePrompt: String? = nil, customInstructions: String? = nil,
                profileOverrideID: UUID? = nil,
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
        self.profileOverrideID = profileOverrideID
        self.worktreeSlot = worktreeSlot
        self.worktreeRoot = worktreeRoot
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, path, remoteURL, displayName, defaultBranch, createdAt
        case renamePrompt, customInstructions, profileOverrideID
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
        profileOverrideID = try c.decodeIfPresent(UUID.self, forKey: .profileOverrideID)
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
    /// HEAD SHA captured at archive time. Used as a fallback when reviving a
    /// worktree whose branch was renamed or deleted before archive ran.
    public var archivedHeadSHA: String?
    /// Transient enrichment populated by the daemon's `worktree.list` handler
    /// for archived worktrees: count of actual session JSONL files in the
    /// resolved Claude project directory. Not persisted in the DB. nil when
    /// not enriched (active worktrees, or archived worktrees whose Claude
    /// project dir could not be resolved).
    public var liveClaudeSessionCount: Int?

    public init(id: UUID = UUID(), repoID: UUID, name: String, displayName: String,
                branch: String, path: String, status: WorktreeStatus = .active,
                hasConflicts: Bool = false,
                createdAt: Date = Date(), archivedAt: Date? = nil, tmuxServer: String,
                archivedClaudeSessions: [String]? = nil, sortOrder: Int = 0,
                archivedHeadSHA: String? = nil,
                liveClaudeSessionCount: Int? = nil) {
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
        self.archivedHeadSHA = archivedHeadSHA
        self.liveClaudeSessionCount = liveClaudeSessionCount
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
        archivedHeadSHA = try c.decodeIfPresent(String.self, forKey: .archivedHeadSHA)
        liveClaudeSessionCount = try c.decodeIfPresent(Int.self, forKey: .liveClaudeSessionCount)
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
    public var profileID: UUID?

    public init(id: UUID = UUID(), worktreeID: UUID, tmuxWindowID: String,
                tmuxPaneID: String, label: String? = nil, createdAt: Date = Date(),
                pinnedAt: Date? = nil, claudeSessionID: String? = nil,
                suspendedAt: Date? = nil, suspendedSnapshot: String? = nil,
                profileID: UUID? = nil) {
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
        self.profileID = profileID
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
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
    }
}

public enum CredentialKind: String, Codable, Sendable {
    case oauth
    case apiKey
}

public struct ModelProfile: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var kind: CredentialKind
    /// Optional Anthropic-compatible endpoint URL. nil = use Claude default
    /// (i.e. don't set ANTHROPIC_BASE_URL when spawning).
    public var baseURL: String?
    /// Optional model id passed via ANTHROPIC_MODEL. nil = use Claude default.
    public var model: String?
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), name: String, kind: CredentialKind,
                baseURL: String? = nil, model: String? = nil,
                createdAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, model, createdAt, lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(CredentialKind.self, forKey: .kind)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

public struct ModelProfileUsage: Codable, Sendable, Equatable {
    public var profileID: UUID
    public var fiveHourPct: Double?
    public var sevenDayPct: Double?
    public var fiveHourResetsAt: Date?
    public var sevenDayResetsAt: Date?
    public var fetchedAt: Date?
    public var lastStatus: String?

    public init(profileID: UUID, fiveHourPct: Double? = nil, sevenDayPct: Double? = nil,
                fiveHourResetsAt: Date? = nil, sevenDayResetsAt: Date? = nil,
                fetchedAt: Date? = nil, lastStatus: String? = nil) {
        self.profileID = profileID
        self.fiveHourPct = fiveHourPct
        self.sevenDayPct = sevenDayPct
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayResetsAt = sevenDayResetsAt
        self.fetchedAt = fetchedAt
        self.lastStatus = lastStatus
    }

    enum CodingKeys: String, CodingKey {
        case profileID, tokenID  // tokenID is the legacy key for one release window
        case fiveHourPct, sevenDayPct, fiveHourResetsAt, sevenDayResetsAt, fetchedAt, lastStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .profileID) {
            profileID = id
        } else {
            profileID = try c.decode(UUID.self, forKey: .tokenID)
        }
        fiveHourPct = try c.decodeIfPresent(Double.self, forKey: .fiveHourPct)
        sevenDayPct = try c.decodeIfPresent(Double.self, forKey: .sevenDayPct)
        fiveHourResetsAt = try c.decodeIfPresent(Date.self, forKey: .fiveHourResetsAt)
        sevenDayResetsAt = try c.decodeIfPresent(Date.self, forKey: .sevenDayResetsAt)
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profileID, forKey: .profileID)
        try c.encodeIfPresent(fiveHourPct, forKey: .fiveHourPct)
        try c.encodeIfPresent(sevenDayPct, forKey: .sevenDayPct)
        try c.encodeIfPresent(fiveHourResetsAt, forKey: .fiveHourResetsAt)
        try c.encodeIfPresent(sevenDayResetsAt, forKey: .sevenDayResetsAt)
        try c.encodeIfPresent(fetchedAt, forKey: .fetchedAt)
        try c.encodeIfPresent(lastStatus, forKey: .lastStatus)
    }
}

public struct ModelProfileWithUsage: Codable, Sendable, Equatable {
    public let profile: ModelProfile
    public let usage: ModelProfileUsage?
    public init(profile: ModelProfile, usage: ModelProfileUsage? = nil) {
        self.profile = profile
        self.usage = usage
    }
}


public struct Config: Codable, Sendable, Equatable {
    public var defaultProfileID: UUID?

    public init(defaultProfileID: UUID? = nil) {
        self.defaultProfileID = defaultProfileID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultProfileID = try c.decodeIfPresent(UUID.self, forKey: .defaultProfileID)
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

// MARK: - Session Messages Params

public struct SessionMessagesParams: Codable, Sendable {
    public let filePath: String
    public init(filePath: String) { self.filePath = filePath }
}

// MARK: - Transcript Items (rich rendering)

public enum SystemKind: String, Codable, Sendable {
    case toolReminder
    case hookOutput
    case environmentDetails
    case slashEnvelope
    case skillBody
    case other
}

public struct ToolResult: Codable, Sendable {
    public let text: String
    public let truncatedTo: Int?
    public let isError: Bool
    public init(text: String, truncatedTo: Int?, isError: Bool) {
        self.text = text
        self.truncatedTo = truncatedTo
        self.isError = isError
    }
}

public struct Subagent: Codable, Sendable {
    public let agentID: String
    public let agentType: String?
    public let items: [TranscriptItem]
    public init(agentID: String, agentType: String?, items: [TranscriptItem]) {
        self.agentID = agentID
        self.agentType = agentType
        self.items = items
    }
}

public indirect enum TranscriptItem: Codable, Sendable, Identifiable {
    case userPrompt(id: String, text: String, timestamp: Date?)
    case assistantText(id: String, text: String, timestamp: Date?)
    case toolCall(id: String, name: String, inputJSON: String,
                  result: ToolResult?, subagent: Subagent?, timestamp: Date?)
    case thinking(id: String, text: String, timestamp: Date?)
    case systemReminder(id: String, kind: SystemKind, text: String, timestamp: Date?)
    case slashCommand(id: String, name: String, args: String?, timestamp: Date?)

    public var id: String {
        switch self {
        case .userPrompt(let id, _, _): return id
        case .assistantText(let id, _, _): return id
        case .toolCall(let id, _, _, _, _, _): return id
        case .thinking(let id, _, _): return id
        case .systemReminder(let id, _, _, _): return id
        case .slashCommand(let id, _, _, _): return id
        }
    }

    public var timestamp: Date? {
        switch self {
        case .userPrompt(_, _, let t),
             .assistantText(_, _, let t),
             .toolCall(_, _, _, _, _, let t),
             .thinking(_, _, let t),
             .systemReminder(_, _, _, let t),
             .slashCommand(_, _, _, let t):
            return t
        }
    }
}
