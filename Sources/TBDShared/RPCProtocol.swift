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
    public static let terminalCreate = "terminal.create"
    public static let terminalList = "terminal.list"
    public static let terminalSend = "terminal.send"
    public static let notify = "notify"
    public static let daemonStatus = "daemon.status"
    public static let stateSubscribe = "state.subscribe"
    public static let resolvePath = "resolve.path"
    public static let notificationsList = "notifications.list"
    public static let notificationsMarkRead = "notifications.markRead"
    public static let worktreeMerge = "worktree.merge"
    public static let worktreeMergeStatus = "worktree.mergeStatus"
    public static let cleanup = "cleanup"
}

public struct NotificationsListResult: Codable, Sendable {
    public let notifications: [UUID: NotificationType]
    public init(notifications: [UUID: NotificationType]) { self.notifications = notifications }
}

public struct NotificationsMarkReadParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
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

public struct WorktreeMergeParams: Codable, Sendable {
    public let worktreeID: UUID
    public let archiveAfter: Bool
    public init(worktreeID: UUID, archiveAfter: Bool = false) {
        self.worktreeID = worktreeID; self.archiveAfter = archiveAfter
    }
}

public struct WorktreeMergeStatusParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct TerminalCreateParams: Codable, Sendable {
    public let worktreeID: UUID
    public let cmd: String?
    public init(worktreeID: UUID, cmd: String? = nil) {
        self.worktreeID = worktreeID; self.cmd = cmd
    }
}

public struct TerminalListParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct TerminalSendParams: Codable, Sendable {
    public let terminalID: UUID
    public let text: String
    public init(terminalID: UUID, text: String) {
        self.terminalID = terminalID; self.text = text
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

public struct WorktreeMergeStatusResult: Codable, Sendable {
    public let canMerge: Bool
    public let reason: String?
    public let commitCount: Int
    public init(canMerge: Bool, reason: String?, commitCount: Int) {
        self.canMerge = canMerge; self.reason = reason; self.commitCount = commitCount
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
