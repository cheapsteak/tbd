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

    @Test("control-mode input-health delta round-trips through broadcast")
    func inputHealthDeltaRoundTrips() throws {
        let manager = StateSubscriptionManager()
        let received = SendableBox<Data>()
        manager.addSubscriber { data in
            received.append(data)
            return true
        }

        let worktreeID = UUID()
        manager.broadcast(delta: .controlModeInputHealthChanged(ControlModeInputHealthDelta(
            worktreeID: worktreeID, paneID: "%7", healthy: false)))

        #expect(received.count == 1)
        // Decode exactly like the app's subscription loop does.
        let decoded = try JSONDecoder().decode(StateDelta.self, from: received.values[0])
        guard case .controlModeInputHealthChanged(let delta) = decoded else {
            Issue.record("decoded wrong case: \(decoded)")
            return
        }
        #expect(delta.worktreeID == worktreeID)
        #expect(delta.paneID == "%7")
        #expect(delta.healthy == false)
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

    @Test("send delivers to the named subscriber only")
    func sendDeliversToOneSubscriber() {
        let manager = StateSubscriptionManager()
        let otherReceived = SendableBox<Data>()
        let targetReceived = SendableBox<Data>()
        manager.addSubscriber { data in
            otherReceived.append(data)
            return true
        }
        let target = manager.addSubscriber { data in
            targetReceived.append(data)
            return true
        }

        manager.send(delta: makeDelta(), to: target)

        #expect(targetReceived.count == 1)
        #expect(otherReceived.count == 0)
        // An id no longer subscribed is a no-op.
        manager.send(delta: makeDelta(), to: UUID())
        #expect(targetReceived.count == 1)
        #expect(otherReceived.count == 0)
    }

    @Test("send removes the subscriber when it returns false")
    func sendRemovesDeadSubscriber() {
        let manager = StateSubscriptionManager()
        let dead = manager.addSubscriber { _ in false }
        manager.addSubscriber { _ in true }
        manager.send(delta: makeDelta(), to: dead)
        #expect(manager.subscriberCount == 1)
    }
}
