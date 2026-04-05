import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Thread-safe box for accumulating values in @Sendable closures.
private final class SendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []

    func append(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        _values.append(value)
    }

    var values: [T] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    var count: Int { values.count }
}

@Suite("StateSubscriptionManager")
struct StateSubscriptionTests {

    private func makeDelta() -> StateDelta {
        .repoAdded(RepoDelta(repoID: UUID(), path: "/tmp/test", displayName: "test"))
    }

    @Test("broadcast removes dead subscriber that returns false")
    func broadcastRemovesDeadSubscriber() {
        let manager = StateSubscriptionManager()
        let liveReceived = SendableBox<Data>()

        // Live subscriber — returns true
        manager.addSubscriber { data in
            liveReceived.append(data)
            return true
        }
        // Dead subscriber — returns false
        manager.addSubscriber { _ in
            return false
        }

        #expect(manager.subscriberCount == 2)

        manager.broadcast(delta: makeDelta())

        #expect(manager.subscriberCount == 1)
        #expect(liveReceived.count == 1)
    }

    @Test("broadcast suppresses conductor worktree deltas")
    func broadcastSuppressesConductorDeltas() {
        let manager = StateSubscriptionManager()
        let received = SendableBox<Data>()

        manager.addSubscriber { data in
            received.append(data)
            return true
        }

        // Conductor worktree delta should be suppressed
        let conductorWorktree = WorktreeDelta(
            worktreeID: UUID(), repoID: UUID(), name: "conductor-test",
            path: "/tmp/test", status: .conductor
        )
        manager.broadcast(delta: .worktreeCreated(conductorWorktree))
        #expect(received.count == 0)

        // Conductor terminal delta should be suppressed
        let conductorTerminal = TerminalDelta(
            terminalID: UUID(), worktreeID: UUID(), label: "conductor:main"
        )
        manager.broadcast(delta: .terminalCreated(conductorTerminal))
        #expect(received.count == 0)

        // Non-conductor delta should be delivered
        manager.broadcast(delta: makeDelta())
        #expect(received.count == 1)
    }

    @Test("broadcast delivers to all live subscribers")
    func broadcastDeliversToAll() {
        let manager = StateSubscriptionManager()
        let firstReceived = SendableBox<Data>()
        let secondReceived = SendableBox<Data>()

        manager.addSubscriber { data in
            firstReceived.append(data)
            return true
        }
        manager.addSubscriber { data in
            secondReceived.append(data)
            return true
        }

        manager.broadcast(delta: makeDelta())

        #expect(firstReceived.count == 1)
        #expect(secondReceived.count == 1)
        #expect(manager.subscriberCount == 2)
    }
}
