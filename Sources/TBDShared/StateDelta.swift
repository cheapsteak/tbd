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
    case repoRenamed(RepoRenameDelta)
    case repoHiddenChanged(RepoHiddenDelta)
    case repoExpandedChanged(RepoExpandedDelta)
    case terminalCreated(TerminalDelta)
    case terminalRemoved(TerminalIDDelta)
    case worktreeConflictsChanged(WorktreeConflictDelta)
    case terminalPinChanged(TerminalPinDelta)
    case worktreeReordered(RepoIDDelta)
    case modelProfileUsageUpdated(ModelProfileUsage)
    case modelProfilesChanged
    case terminalSessionUpdated(TerminalSessionDelta)
    case terminalActivityUpdated(TerminalActivityDelta)
    case worktreeMoved(WorktreeMovedDelta)
}

/// Delta payload for Claude session ID/transcript path rollover, fired when
/// the SessionStart hook bridge reports a new session for an existing
/// terminal (e.g., post-`/clear`, `/compact`, or initial startup).
public struct TerminalSessionDelta: Codable, Sendable {
    public let terminalID: UUID
    public let worktreeID: UUID
    public let sessionID: String
    public let transcriptPath: String?
    public init(terminalID: UUID, worktreeID: UUID, sessionID: String, transcriptPath: String?) {
        self.terminalID = terminalID
        self.worktreeID = worktreeID
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
    }
}

public struct TerminalActivityDelta: Codable, Sendable {
    public let terminalID: UUID
    public let worktreeID: UUID
    public let activityState: TerminalActivityState
    public init(terminalID: UUID, worktreeID: UUID, activityState: TerminalActivityState) {
        self.terminalID = terminalID
        self.worktreeID = worktreeID
        self.activityState = activityState
    }
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
    /// Optional terminal that triggered the notification. The app uses this
    /// to route a banner click to the originating tab. Nil when the
    /// notification didn't come from a specific terminal or from an older
    /// daemon that didn't include the field.
    public let terminalID: UUID?
    /// When true, the app foregrounds and selects the originating tab
    /// immediately (the `--activate` "loud" focus push). Defaults false so
    /// existing notify broadcasts and older daemons keep the soft behavior.
    public let activate: Bool
    public init(notificationID: UUID, worktreeID: UUID, type: NotificationType,
                message: String?, terminalID: UUID? = nil, activate: Bool = false) {
        self.notificationID = notificationID; self.worktreeID = worktreeID
        self.type = type; self.message = message
        self.terminalID = terminalID
        self.activate = activate
    }

    enum CodingKeys: String, CodingKey {
        case notificationID, worktreeID, type, message, terminalID, activate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notificationID = try c.decode(UUID.self, forKey: .notificationID)
        worktreeID = try c.decode(UUID.self, forKey: .worktreeID)
        type = try c.decode(NotificationType.self, forKey: .type)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        terminalID = try c.decodeIfPresent(UUID.self, forKey: .terminalID)
        activate = try c.decodeIfPresent(Bool.self, forKey: .activate) ?? false
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

/// Delta payload for repo rename.
public struct RepoRenameDelta: Codable, Sendable {
    public let repoID: UUID
    public let displayName: String
    public init(repoID: UUID, displayName: String) {
        self.repoID = repoID; self.displayName = displayName
    }
}

/// Delta payload for repo hidden-flag change.
public struct RepoHiddenDelta: Codable, Sendable {
    public let repoID: UUID
    public let hidden: Bool
    public init(repoID: UUID, hidden: Bool) {
        self.repoID = repoID; self.hidden = hidden
    }
}

/// Delta payload for repo expand/collapse change.
public struct RepoExpandedDelta: Codable, Sendable {
    public let repoID: UUID
    public let expanded: Bool
    public init(repoID: UUID, expanded: Bool) {
        self.repoID = repoID; self.expanded = expanded
    }
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

public struct WorktreeMovedDelta: Codable, Sendable {
    public let worktreeID: UUID
    public let newParentID: UUID?
    public let newSortOrder: Int

    public init(worktreeID: UUID, newParentID: UUID?, newSortOrder: Int) {
        self.worktreeID = worktreeID
        self.newParentID = newParentID
        self.newSortOrder = newSortOrder
    }
}
