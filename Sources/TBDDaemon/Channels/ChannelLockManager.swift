import Foundation

/// In-process, per-channel async serialization. Each channel name gets a
/// dedicated actor that linearizes write operations, so the daemon only
/// holds one channel's `flock` at a time per channel.
///
/// Cross-process protection comes from `FileLock` on the sidecar `.lock`
/// file; this manager only handles in-process concurrency.
actor ChannelLockManager {
    private var locks: [String: ChannelSerial] = [:]

    func withLock<T: Sendable>(_ name: String, _ body: @Sendable () async throws -> T) async throws -> T {
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
actor ChannelSerial {
    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await body()
    }
}
