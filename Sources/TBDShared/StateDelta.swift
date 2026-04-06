import Foundation

// MARK: - Delta Event Types

/// Represents a state change event that can be broadcast to subscribers.
public enum StateDelta: Codable, Sendable {
    case worktreeCreated(WorktreeDelta)
    case worktreeArchived(WorktreeIDDelta)
    case worktreeRevived(WorktreeDelta)
    case worktreeRenamed(WorktreeRenameDelta)
    case notificationReceived(NotificationDelta)
    case repoAdded(RepoDelta)
    case repoRemoved(RepoIDDelta)
    case terminalCreated(TerminalDelta)
    case terminalRemoved(TerminalIDDelta)
    case worktreeConflictsChanged(WorktreeConflictDelta)
    case terminalPinChanged(TerminalPinDelta)
    case worktreeReordered(RepoIDDelta)
    case claudeTokenUsageUpdated(ClaudeTokenUsage)
}

/// Delta payload for worktree creation/revival.
public struct WorktreeDelta: Codable, Sendable {
    public let worktreeID: UUID
    public let repoID: UUID
    public let name: String
    public let path: String
    public let status: WorktreeStatus?
    public init(worktreeID: UUID, repoID: UUID, name: String, path: String, status: WorktreeStatus? = nil) {
        self.worktreeID = worktreeID; self.repoID = repoID
        self.name = name; self.path = path; self.status = status
    }
}

/// Delta payload for worktree archive (just the ID).
public struct WorktreeIDDelta: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

/// Delta payload for worktree rename.
public struct WorktreeRenameDelta: Codable, Sendable {
    public let worktreeID: UUID
    public let displayName: String
    public init(worktreeID: UUID, displayName: String) {
        self.worktreeID = worktreeID; self.displayName = displayName
    }
}

/// Delta payload for notification.
public struct NotificationDelta: Codable, Sendable {
    public let notificationID: UUID
    public let worktreeID: UUID
    public let type: NotificationType
    public let message: String?
    public init(notificationID: UUID, worktreeID: UUID, type: NotificationType, message: String?) {
        self.notificationID = notificationID; self.worktreeID = worktreeID
        self.type = type; self.message = message
    }
}

/// Delta payload for repo addition.
public struct RepoDelta: Codable, Sendable {
    public let repoID: UUID
    public let path: String
    public let displayName: String
    public init(repoID: UUID, path: String, displayName: String) {
        self.repoID = repoID; self.path = path; self.displayName = displayName
    }
}

/// Delta payload for repo removal (just the ID).
public struct RepoIDDelta: Codable, Sendable {
    public let repoID: UUID
    public init(repoID: UUID) { self.repoID = repoID }
}

/// Delta payload for terminal creation.
public struct TerminalDelta: Codable, Sendable {
    public let terminalID: UUID
    public let worktreeID: UUID
    public let label: String?
    public init(terminalID: UUID, worktreeID: UUID, label: String?) {
        self.terminalID = terminalID; self.worktreeID = worktreeID; self.label = label
    }
}

/// Delta payload for terminal removal (just the ID).
public struct TerminalIDDelta: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

/// Delta payload for worktree conflict status change.
public struct WorktreeConflictDelta: Codable, Sendable {
    public let worktreeID: UUID
    public let hasConflicts: Bool
    public init(worktreeID: UUID, hasConflicts: Bool) {
        self.worktreeID = worktreeID; self.hasConflicts = hasConflicts
    }
}

/// Delta payload for terminal pin state change.
public struct TerminalPinDelta: Codable, Sendable {
    public let terminalID: UUID
    public let pinnedAt: Date?
    public init(terminalID: UUID, pinnedAt: Date?) {
        self.terminalID = terminalID; self.pinnedAt = pinnedAt
    }
}
