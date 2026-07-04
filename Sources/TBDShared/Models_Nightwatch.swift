import Foundation

// MARK: - Clearance Kind

public enum ClearanceKind: String, Codable, Sendable, CaseIterable {
    case preclear
    case small_safe
    case in_channel
}

// MARK: - Clearance

/// A SHA-pinned clearance record for a PR that was cleared to merge.
/// Stored append-only in the clearance ledger.
public struct Clearance: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let prNumber: Int
    public let repo: String
    public let clearedWhenSHA: String
    public let prStateAtClear: String?
    public let clearanceKind: ClearanceKind
    public let grantedBy: String?
    public let grantedAt: Date
    public let voidReason: String?

    public init(
        id: String = UUID().uuidString,
        prNumber: Int,
        repo: String,
        clearedWhenSHA: String,
        prStateAtClear: String? = nil,
        clearanceKind: ClearanceKind,
        grantedBy: String? = nil,
        grantedAt: Date = Date(),
        voidReason: String? = nil
    ) {
        self.id = id
        self.prNumber = prNumber
        self.repo = repo
        self.clearedWhenSHA = clearedWhenSHA
        self.prStateAtClear = prStateAtClear
        self.clearanceKind = clearanceKind
        self.grantedBy = grantedBy
        self.grantedAt = grantedAt
        self.voidReason = voidReason
    }
}

// MARK: - Audit Action

public enum AuditAction: String, Codable, Sendable, CaseIterable {
    case wouldMerge
    case hold
    case escalate
    case clearanceVoided
}

// MARK: - Audit Log Entry

/// An audit record of a merge gate decision or action.
public struct AuditLogEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let action: AuditAction
    public let prNumber: Int?
    public let repo: String?
    public let headSHA: String?
    public let mergeCommit: String?
    public let timestamp: Date
    public let details: String?

    public init(
        id: String = UUID().uuidString,
        action: AuditAction,
        prNumber: Int? = nil,
        repo: String? = nil,
        headSHA: String? = nil,
        mergeCommit: String? = nil,
        timestamp: Date = Date(),
        details: String? = nil
    ) {
        self.id = id
        self.action = action
        self.prNumber = prNumber
        self.repo = repo
        self.headSHA = headSHA
        self.mergeCommit = mergeCommit
        self.timestamp = timestamp
        self.details = details
    }
}
