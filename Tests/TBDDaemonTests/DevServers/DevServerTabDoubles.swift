import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Answers by terminal id; unknown terminals read `.gone`.
final class FakeDevServerTabInspector: DevServerTabInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [UUID: DevServerTabStatus] = [:]

    func set(_ status: DevServerTabStatus, for terminalID: UUID) {
        lock.lock(); defer { lock.unlock() }
        statuses[terminalID] = status
    }

    func status(of terminal: Terminal, tmuxServer: String) async -> DevServerTabStatus {
        lookup(terminal.id)
    }

    // Synchronous so the lock is never held across a suspension point.
    private func lookup(_ id: UUID) -> DevServerTabStatus {
        lock.lock(); defer { lock.unlock() }
        return statuses[id] ?? .gone
    }
}
