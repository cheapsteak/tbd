import Foundation

struct TerminalRecoveryBudget {
    /// Two attempts permit one retry after an initial repair while bounding
    /// repeated recreation churn when attachment cannot recover.
    static let maximumAttempts = 2

    private var attemptCounts: [UUID: Int] = [:]

    mutating func claimAttempt(for terminalID: UUID) -> Int? {
        let nextAttempt = attemptCounts[terminalID, default: 0] + 1
        guard nextAttempt <= Self.maximumAttempts else { return nil }
        attemptCounts[terminalID] = nextAttempt
        return nextAttempt
    }

    mutating func reset(for terminalID: UUID) {
        attemptCounts.removeValue(forKey: terminalID)
    }
}
