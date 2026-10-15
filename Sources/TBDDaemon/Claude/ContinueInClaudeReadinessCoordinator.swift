import Foundation

/// One SessionStart observation for a process TBD launched behind a pending
/// terminal-incarnation fence. The database row intentionally remains Codex
/// until the replacement transaction consumes this machine fact and commits
/// the complete Claude identity atomically.
struct ContinueInClaudeReadyEvent: Sendable, Equatable {
    let sessionID: String
    let transcriptPath: String?
    let source: String?
    let cwd: String?
    let observedAt: Date
}

enum ContinueInClaudeReadinessError: LocalizedError, Equatable {
    case timedOut
    case notArmed

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "The replacement agent did not report SessionStart before the readiness deadline."
        case .notArmed:
            return "The replacement readiness fence was not armed."
        }
    }
}

/// Remembers an exact-token SessionStart even when it beats the transaction's
/// suspension point. Keys include the durable process incarnation, so delayed
/// hooks from the source, a failed destination, or an earlier recovery cannot
/// satisfy a later launch.
actor ContinueInClaudeReadinessCoordinator {
    struct Key: Hashable, Sendable {
        let terminalID: UUID
        let incarnationID: UUID
    }

    private struct Waiter {
        let continuation: CheckedContinuation<ContinueInClaudeReadyEvent, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let clock: any Clock<Duration>
    private var armed: Set<Key> = []
    private var remembered: [Key: ContinueInClaudeReadyEvent] = [:]
    private var waiters: [Key: Waiter] = [:]

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    func arm(_ key: Key) {
        clear(key)
        armed.insert(key)
    }

    /// Returns false when no current transaction owns this token. Callers
    /// still answer a hook with soft success; false only means it was stale.
    @discardableResult
    func noteReady(
        _ event: ContinueInClaudeReadyEvent,
        for key: Key
    ) -> Bool {
        guard armed.contains(key) else { return false }
        if let waiter = waiters.removeValue(forKey: key) {
            armed.remove(key)
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: event)
        } else {
            remembered[key] = event
        }
        return true
    }

    func wait(
        for key: Key,
        timeout: Duration = .seconds(15)
    ) async throws -> ContinueInClaudeReadyEvent {
        guard armed.contains(key) else {
            throw ContinueInClaudeReadinessError.notArmed
        }
        if let event = remembered.removeValue(forKey: key) {
            armed.remove(key)
            return event
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [clock] in
                    do {
                        try await clock.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self.expire(key)
                }
                waiters[key] = Waiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask)
            }
        } onCancel: {
            Task { await self.cancel(key) }
        }
    }

    func clear(_ key: Key) {
        armed.remove(key)
        remembered.removeValue(forKey: key)
        if let waiter = waiters.removeValue(forKey: key) {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    func clear(terminalID: UUID) {
        let keys = armed.filter { $0.terminalID == terminalID }
        for key in keys { clear(key) }
    }

    private func expire(_ key: Key) {
        guard let waiter = waiters.removeValue(forKey: key) else { return }
        armed.remove(key)
        remembered.removeValue(forKey: key)
        waiter.continuation.resume(throwing: ContinueInClaudeReadinessError.timedOut)
    }

    private func cancel(_ key: Key) {
        clear(key)
    }
}
