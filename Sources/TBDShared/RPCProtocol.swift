import Foundation

// MARK: - RPC Request / Response

/// RPC request with method string and raw JSON params.
/// The router decodes params based on the method string.
/// Params are stored as a JSON string so the wire format is human-readable (not base64).
public struct RPCRequest: Codable, Sendable {
    public let method: String
    public let params: String

    public init(method: String, params: String = "{}") {
        self.method = method
        self.params = params
    }

    /// Convenience: encode a Codable param struct into an RPCRequest.
    public init<P: Encodable>(method: String, params: P) throws {
        self.method = method
        let data = try JSONEncoder().encode(params)
        self.params = String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Decode the params JSON string into Data for JSONDecoder consumption.
    public var paramsData: Data {
        Data(params.utf8)
    }
}

/// RPC response with success flag, optional raw JSON result, and optional error message.
/// The caller decodes the result based on what it expects for the method it called.
/// Result is stored as a JSON string so the wire format is human-readable (not base64).
public struct RPCResponse: Codable, Sendable {
    public let success: Bool
    public let result: String?
    public let error: String?

    public init<R: Encodable>(result: R) throws {
        self.success = true
        let data = try JSONEncoder().encode(result)
        self.result = String(data: data, encoding: .utf8)
        self.error = nil
    }

    public init(error: String) {
        self.success = false
        self.result = nil
        self.error = error
    }

    /// Convenience for success responses with no meaningful result payload.
    public static func ok() -> RPCResponse {
        RPCResponse(successWithNoResult: ())
    }

    private init(successWithNoResult: Void) {
        self.success = true
        self.result = nil
        self.error = nil
    }

    /// Decode the result payload into the expected type.
    public func decodeResult<R: Decodable>(_ type: R.Type) throws -> R {
        guard let resultString = result else {
            throw RPCError.noResultData
        }
        let data = Data(resultString.utf8)
        return try JSONDecoder().decode(type, from: data)
    }
}

public enum RPCError: Error, Sendable {
    case noResultData
}

// MARK: - RPC Method Names

public enum RPCMethod {
    public static let repoAdd = "repo.add"
    public static let repoRemove = "repo.remove"
    public static let repoList = "repo.list"
    public static let worktreeCreate = "worktree.create"
    public static let worktreeList = "worktree.list"
    public static let worktreeArchive = "worktree.archive"
    public static let worktreeRevive = "worktree.revive"
    public static let worktreeRename = "worktree.rename"
    public static let worktreeReorder = "worktree.reorder"
    public static let terminalCreate = "terminal.create"
    public static let terminalList = "terminal.list"
    public static let terminalSend = "terminal.send"
    public static let terminalDelete = "terminal.delete"
    public static let terminalSetPin = "terminal.setPin"
    public static let notify = "notify"
    public static let daemonStatus = "daemon.status"
    public static let stateSubscribe = "state.subscribe"
    public static let resolvePath = "resolve.path"
    public static let notificationsList = "notifications.list"
    public static let notificationsMarkRead = "notifications.markRead"
    public static let prList    = "pr.list"
    public static let prRefresh = "pr.refresh"
    public static let cleanup = "cleanup"
    public static let worktreeSelectionChanged = "worktree.selectionChanged"
    public static let terminalSuspend = "terminal.suspend"
    public static let terminalResume = "terminal.resume"
    public static let worktreeSuspend = "worktree.suspend"
    public static let worktreeResume = "worktree.resume"
    public static let terminalRecreateWindow = "terminal.recreateWindow"
    public static let noteCreate = "note.create"
    public static let noteGet = "note.get"
    public static let noteUpdate = "note.update"
    public static let noteDelete = "note.delete"
    public static let noteList = "note.list"
    public static let terminalOutput = "terminal.output"
    public static let conductorSetup = "conductor.setup"
    public static let conductorStart = "conductor.start"
    public static let conductorStop = "conductor.stop"
    public static let conductorTeardown = "conductor.teardown"
    public static let conductorList = "conductor.list"
    public static let conductorStatus = "conductor.status"
    public static let conductorSuggest = "conductor.suggest"
    public static let conductorClearSuggestion = "conductor.clearSuggestion"
    public static let terminalConversation = "terminal.conversation"
    public static let repoUpdateInstructions = "repo.updateInstructions"
}

public struct NotificationsListResult: Codable, Sendable {
    public let notifications: [UUID: NotificationType]
    public init(notifications: [UUID: NotificationType]) { self.notifications = notifications }
}

public struct NotificationsMarkReadParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct PRListResult: Codable, Sendable {
    public let statuses: [UUID: PRStatus]
    public init(statuses: [UUID: PRStatus]) { self.statuses = statuses }
}

public struct PRRefreshParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

// PRRefreshResult wraps an optional PRStatus.
// nil means no PR found for this worktree's branch.
public struct PRRefreshResult: Codable, Sendable {
    public let status: PRStatus?
    public init(status: PRStatus?) { self.status = status }
}

// MARK: - Parameter Structs

public struct RepoAddParams: Codable, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
}

public struct RepoRemoveParams: Codable, Sendable {
    public let repoID: UUID
    public let force: Bool
    public init(repoID: UUID, force: Bool = false) { self.repoID = repoID; self.force = force }
}

public struct RepoUpdateInstructionsParams: Codable, Sendable {
    public let repoID: UUID
    public let renamePrompt: String?
    public let customInstructions: String?
    public init(repoID: UUID, renamePrompt: String?, customInstructions: String?) {
        self.repoID = repoID
        self.renamePrompt = renamePrompt
        self.customInstructions = customInstructions
    }
}

public struct WorktreeCreateParams: Codable, Sendable {
    public let repoID: UUID
    public let name: String?
    public init(repoID: UUID, name: String? = nil) { self.repoID = repoID; self.name = name }
}

public struct WorktreeListParams: Codable, Sendable {
    public let repoID: UUID?
    public let status: WorktreeStatus?
    public init(repoID: UUID? = nil, status: WorktreeStatus? = nil) {
        self.repoID = repoID; self.status = status
    }
}

public struct WorktreeArchiveParams: Codable, Sendable {
    public let worktreeID: UUID
    public let force: Bool
    public init(worktreeID: UUID, force: Bool = false) {
        self.worktreeID = worktreeID; self.force = force
    }
}

public struct WorktreeReviveParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct WorktreeRenameParams: Codable, Sendable {
    public let worktreeID: UUID
    public let displayName: String
    public init(worktreeID: UUID, displayName: String) {
        self.worktreeID = worktreeID; self.displayName = displayName
    }
}

public struct WorktreeReorderParams: Codable, Sendable {
    public let repoID: UUID
    public let worktreeIDs: [UUID]
    public init(repoID: UUID, worktreeIDs: [UUID]) {
        self.repoID = repoID; self.worktreeIDs = worktreeIDs
    }
}

public enum TerminalCreateType: String, Codable, Sendable {
    case shell
    case claude
}

public struct TerminalCreateParams: Codable, Sendable {
    public let worktreeID: UUID
    public let cmd: String?
    public let type: TerminalCreateType?
    /// Session ID to resume from (for forking a Claude session).
    public let resumeSessionID: String?
    public init(worktreeID: UUID, cmd: String? = nil, type: TerminalCreateType? = nil, resumeSessionID: String? = nil) {
        self.worktreeID = worktreeID; self.cmd = cmd; self.type = type; self.resumeSessionID = resumeSessionID
    }
}

public struct TerminalListParams: Codable, Sendable {
    public let worktreeID: UUID?
    public init(worktreeID: UUID? = nil) { self.worktreeID = worktreeID }
}

public struct TerminalSendParams: Codable, Sendable {
    public let terminalID: UUID
    public let text: String
    public init(terminalID: UUID, text: String) {
        self.terminalID = terminalID; self.text = text
    }
}

public struct TerminalDeleteParams: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

public struct TerminalSetPinParams: Codable, Sendable {
    public let terminalID: UUID
    public let pinned: Bool
    public init(terminalID: UUID, pinned: Bool) {
        self.terminalID = terminalID; self.pinned = pinned
    }
}

public struct NotifyParams: Codable, Sendable {
    public let worktreeID: UUID?
    public let type: NotificationType
    public let message: String?
    public init(worktreeID: UUID? = nil, type: NotificationType, message: String? = nil) {
        self.worktreeID = worktreeID; self.type = type; self.message = message
    }
}

public struct ResolvePathParams: Codable, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
}

public struct WorktreeSelectionChangedParams: Codable, Sendable {
    public let selectedWorktreeIDs: [UUID]
    /// Whether to suspend idle terminals on departure. Nil defaults to true
    /// for backwards compatibility with older clients that omit this field.
    public let suspendEnabled: Bool?
    public init(selectedWorktreeIDs: [UUID], suspendEnabled: Bool? = nil) {
        self.selectedWorktreeIDs = selectedWorktreeIDs
        self.suspendEnabled = suspendEnabled
    }
}

public struct TerminalSuspendParams: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

public struct TerminalResumeParams: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

public struct WorktreeSuspendParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct WorktreeResumeParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct TerminalRecreateWindowParams: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

public struct NoteCreateParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct NoteGetParams: Codable, Sendable {
    public let noteID: UUID
    public init(noteID: UUID) { self.noteID = noteID }
}

public struct NoteUpdateParams: Codable, Sendable {
    public let noteID: UUID
    public let title: String?
    public let content: String?
    public init(noteID: UUID, title: String? = nil, content: String? = nil) {
        self.noteID = noteID; self.title = title; self.content = content
    }
}

public struct NoteDeleteParams: Codable, Sendable {
    public let noteID: UUID
    public init(noteID: UUID) { self.noteID = noteID }
}

public struct NoteListParams: Codable, Sendable {
    public let worktreeID: UUID?
    public init(worktreeID: UUID? = nil) { self.worktreeID = worktreeID }
}

// MARK: - Result Structs

public struct DaemonStatusResult: Codable, Sendable {
    public let version: String
    public let uptime: TimeInterval
    public let connectedClients: Int
    public init(version: String, uptime: TimeInterval, connectedClients: Int) {
        self.version = version; self.uptime = uptime; self.connectedClients = connectedClients
    }
}

public struct ResolvedPathResult: Codable, Sendable {
    public let repoID: UUID?
    public let worktreeID: UUID?
    public init(repoID: UUID?, worktreeID: UUID?) {
        self.repoID = repoID; self.worktreeID = worktreeID
    }
}

public struct CleanupResult: Codable, Sendable {
    public let reposProcessed: Int
    public let worktreesReconciled: Int
    public let errors: [String]
    public init(reposProcessed: Int, worktreesReconciled: Int, errors: [String] = []) {
        self.reposProcessed = reposProcessed
        self.worktreesReconciled = worktreesReconciled
        self.errors = errors
    }
}

// MARK: - Terminal Output

public struct TerminalOutputParams: Codable, Sendable {
    public let terminalID: UUID
    public let lines: Int?
    public init(terminalID: UUID, lines: Int? = nil) {
        self.terminalID = terminalID; self.lines = lines
    }
}

public struct TerminalOutputResult: Codable, Sendable {
    public let output: String
    public init(output: String) { self.output = output }
}

// MARK: - Conductor

public struct ConductorSetupParams: Codable, Sendable {
    public let name: String
    public let repos: [String]?
    public let worktrees: [String]?
    public let terminalLabels: [String]?
    public let heartbeatIntervalMinutes: Int?
    public init(name: String, repos: [String]? = nil, worktrees: [String]? = nil,
                terminalLabels: [String]? = nil,
                heartbeatIntervalMinutes: Int? = nil) {
        self.name = name; self.repos = repos; self.worktrees = worktrees
        self.terminalLabels = terminalLabels
        self.heartbeatIntervalMinutes = heartbeatIntervalMinutes
    }
}

public struct ConductorNameParams: Codable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

public struct ConductorListResult: Codable, Sendable {
    public let conductors: [Conductor]
    public init(conductors: [Conductor]) { self.conductors = conductors }
}

public struct ConductorStatusResult: Codable, Sendable {
    public let conductor: Conductor
    public let isRunning: Bool
    public init(conductor: Conductor, isRunning: Bool) {
        self.conductor = conductor; self.isRunning = isRunning
    }
}

public struct ConductorSuggestParams: Codable, Sendable {
    public let name: String
    public let worktreeID: UUID
    public let label: String?
    public init(name: String, worktreeID: UUID, label: String? = nil) {
        self.name = name; self.worktreeID = worktreeID; self.label = label
    }
}

// MARK: - Terminal Conversation

public struct TerminalConversationParams: Codable, Sendable {
    public let terminalID: UUID
    public let messages: Int?  // number of assistant messages to return, default 1
    public init(terminalID: UUID, messages: Int? = nil) {
        self.terminalID = terminalID; self.messages = messages
    }
}

public struct TerminalConversationResult: Codable, Sendable {
    public let messages: [ConversationMessage]
    public let sessionID: String?
    public init(messages: [ConversationMessage], sessionID: String? = nil) {
        self.messages = messages; self.sessionID = sessionID
    }
}

public struct ConversationMessage: Codable, Sendable {
    public let role: String  // "assistant" or "user"
    public let content: String
    public init(role: String, content: String) {
        self.role = role; self.content = content
    }
}
