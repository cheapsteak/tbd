import Foundation

/// One-shot account and usage snapshot returned by Codex's machine-readable
/// app-server API. All fields are optional so newer/older Codex versions can
/// add or omit account metadata without breaking the picker.
public struct CodexUsageResult: Codable, Sendable, Equatable {
    public let account: CodexAccount?
    public let rateLimits: [CodexRateLimitSnapshot]
    public let unavailableReason: String?

    public init(
        account: CodexAccount? = nil,
        rateLimits: [CodexRateLimitSnapshot] = [],
        unavailableReason: String? = nil
    ) {
        self.account = account
        self.rateLimits = rateLimits
        self.unavailableReason = unavailableReason
    }
}

public struct CodexAccount: Codable, Sendable, Equatable {
    public let type: String
    public let email: String?
    public let planType: String?

    public init(type: String, email: String? = nil, planType: String? = nil) {
        self.type = type
        self.email = email
        self.planType = planType
    }
}

public struct CodexRateLimitSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let limitId: String?
    public let limitName: String?
    public let planType: String?
    public let rateLimitReachedType: String?
    public let spendControlReached: Bool?
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?

    public var id: String {
        limitId ?? limitName ?? "codex"
    }

    public init(
        limitId: String? = nil,
        limitName: String? = nil,
        planType: String? = nil,
        rateLimitReachedType: String? = nil,
        spendControlReached: Bool? = nil,
        primary: CodexRateLimitWindow? = nil,
        secondary: CodexRateLimitWindow? = nil
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
        self.spendControlReached = spendControlReached
        self.primary = primary
        self.secondary = secondary
    }
}

public struct CodexRateLimitWindow: Codable, Sendable, Equatable {
    public let usedPercent: Int
    public let windowDurationMins: Int?
    public let resetsAt: Int?

    public init(usedPercent: Int, windowDurationMins: Int? = nil, resetsAt: Int? = nil) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}
