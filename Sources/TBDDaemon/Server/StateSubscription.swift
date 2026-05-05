import Foundation
import TBDShared

// MARK: - State Subscription Manager

/// Manages a list of subscriber callbacks and broadcasts state deltas to all of them.
///
/// Subscribers register a callback that receives encoded JSON data for each delta event.
/// When a subscriber disconnects, it should be removed via `removeSubscriber()`.
public final class StateSubscriptionManager: @unchecked Sendable {
    /// A unique identifier for each subscriber.
    public typealias SubscriberID = UUID

    /// Callback that receives encoded delta JSON data.
    /// Returns `true` if the subscriber is still alive, `false` to unsubscribe.
    public typealias SubscriberCallback = @Sendable (Data) -> Bool

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

    /// Convenience: broadcast a model profile usage update.
    public func broadcastModelProfileUsage(_ usage: ModelProfileUsage) {
        broadcast(delta: .modelProfileUsageUpdated(usage))
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

        var deadIDs = [SubscriberID]()
        for (id, callback) in currentSubscribers {
            let alive = callback(data)
            if !alive {
                deadIDs.append(id)
            }
        }

        if !deadIDs.isEmpty {
            lock.lock()
            for id in deadIDs {
                subscribers.removeValue(forKey: id)
            }
            lock.unlock()
        }
    }
}
