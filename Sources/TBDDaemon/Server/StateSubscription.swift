import Foundation
import TBDShared

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

// MARK: - State Subscription Manager

/// Manages a list of subscriber callbacks and broadcasts state deltas to all of them.
///
/// Subscribers register a callback that receives encoded JSON data for each delta event.
/// When a subscriber disconnects, it should be removed via `removeSubscriber()`.
public final class StateSubscriptionManager: @unchecked Sendable {
    /// A unique identifier for each subscriber.
    public typealias SubscriberID = UUID

    /// Callback that receives encoded delta JSON data.
    public typealias SubscriberCallback = @Sendable (Data) -> Void

    private let lock = NSLock()
    private var subscribers: [SubscriberID: SubscriberCallback] = [:]

    public init() {}

    /// Add a subscriber and return its ID for later removal.
    @discardableResult
    public func addSubscriber(_ callback: @escaping SubscriberCallback) -> SubscriberID {
        let id = SubscriberID()
        lock.lock()
        defer { lock.unlock() }
        subscribers[id] = callback
        return id
    }

    /// Remove a subscriber by ID.
    public func removeSubscriber(_ id: SubscriberID) {
        lock.lock()
        defer { lock.unlock() }
        subscribers.removeValue(forKey: id)
    }

    /// Number of active subscribers.
    public var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribers.count
    }

    /// Broadcast a delta event to all subscribers.
    ///
    /// Encodes the delta as JSON and sends it to each subscriber callback.
    /// Failed encodings are silently ignored.
    public func broadcast(delta: StateDelta) {
        // Suppress deltas for conductor worktrees/terminals — app doesn't display them
        switch delta {
        case .worktreeCreated(let d), .worktreeRevived(let d):
            if d.status == .conductor { return }
        case .terminalCreated(let d):
            if d.label?.hasPrefix("conductor:") == true { return }
        case .terminalRemoved:
            break // Can't cheaply check — terminal already deleted. Low impact.
        default:
            break
        }

        guard let data = try? JSONEncoder().encode(delta) else { return }

        lock.lock()
        let currentSubscribers = subscribers
        lock.unlock()

        for (_, callback) in currentSubscribers {
            callback(data)
        }
    }
}
