import Foundation
import GRDB
import TBDShared

/// GRDB Record type for the `notification` table.
struct NotificationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "notification"

    var id: String
    var worktreeID: String
    var type: String
    var message: String?
    var read: Bool
    var createdAt: Date

    init(from notification: TBDNotification) {
        self.id = notification.id.uuidString
        self.worktreeID = notification.worktreeID.uuidString
        self.type = notification.type.rawValue
        self.message = notification.message
        self.read = notification.read
        self.createdAt = notification.createdAt
    }

    func toModel() -> TBDNotification {
        TBDNotification(
            id: UUID(uuidString: id)!,
            worktreeID: UUID(uuidString: worktreeID)!,
            type: NotificationType(rawValue: type)!,
            message: message,
            read: read,
            createdAt: createdAt
        )
    }
}

/// Provides CRUD operations for notifications.
public struct NotificationStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Create a new notification.
    public func create(
        worktreeID: UUID,
        type: NotificationType,
        message: String? = nil
    ) async throws -> TBDNotification {
        let notification = TBDNotification(
            worktreeID: worktreeID,
            type: type,
            message: message
        )
        let record = NotificationRecord(from: notification)
        try await writer.write { db in
            try record.insert(db)
        }
        return notification
    }

    /// Get all unread notifications for a worktree.
    public func unread(worktreeID: UUID) async throws -> [TBDNotification] {
        try await writer.read { db in
            try NotificationRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .filter(Column("read") == false)
                .order(Column("createdAt").desc)
                .fetchAll(db)
                .map { $0.toModel() }
        }
    }

    /// Mark all notifications for a worktree as read.
    public func markRead(worktreeID: UUID) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE notification SET read = 1 WHERE worktreeID = ?",
                arguments: [worktreeID.uuidString]
            )
        }
    }

    /// Get the highest severity unread notification type for a worktree.
    public func highestSeverity(worktreeID: UUID) async throws -> NotificationType? {
        let unreadNotifications = try await unread(worktreeID: worktreeID)
        return unreadNotifications
            .map(\.type)
            .max(by: { $0.severity < $1.severity })
    }
}
