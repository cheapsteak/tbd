import Foundation

/// In-process, per-channel async serialization. Each channel name gets a
/// dedicated actor that linearizes write operations, so the daemon only
/// holds one channel's `flock` at a time per channel.
///
/// Cross-process protection comes from `FileLock` on the sidecar `.lock`
/// file; this manager only handles in-process concurrency.
actor ChannelLockManager {
    private var locks: [String: ChannelSerial] = [:]

    func withLock<T: Sendable>(_ name: String, _ body: @Sendable () throws -> T) async throws -> T {
        let serial = serial(for: name)
        return try await serial.run(body)
    }

    private func serial(for name: String) -> ChannelSerial {
        if let existing = locks[name] { return existing }
        let made = ChannelSerial()
        locks[name] = made
        return made
    }
}

/// One channel's async-serial queue. Posts arrive concurrently; this
/// actor's mailbox order is the channel's write order.
///
/// The body type is *synchronous* on purpose: the whole point of this
/// actor is serialization, and an `async` body would suspend on every
/// internal `await`, opening the door to actor reentrancy and silently
/// reintroducing the post/archive race we previously fixed. Keeping
/// the type synchronous makes the contract compiler-enforced rather
/// than relying on a comment.
actor ChannelSerial {
    func run<T: Sendable>(_ body: @Sendable () throws -> T) throws -> T {
        try body()
    }
}
