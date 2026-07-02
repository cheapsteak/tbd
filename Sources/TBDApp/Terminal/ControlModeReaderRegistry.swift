import Foundation

/// App-scoped owner of `ControlModeStreamReader` instances. Held by
/// `AppState`; keyed by `FDVendHeader.routingKey` (worktreeID/paneID) so
/// views can retrieve the reader on setup without owning it.
actor ControlModeReaderRegistry {
    private var readers: [String: ControlModeStreamReader] = [:]

    /// Register a reader for `routingKey` and start it. If one already
    /// exists, flag it stopped and replace it (the old reader's fd is closed
    /// by its own thread once the daemon-side detach EOFs it).
    @discardableResult
    func registerReader(routingKey: String, fd: Int32,
                        onChunk: @escaping @Sendable (Data) -> Void) -> ControlModeStreamReader {
        if let existing = readers.removeValue(forKey: routingKey) { existing.stop() }
        let reader = ControlModeStreamReader(routingKey: routingKey, fd: fd, onChunk: onChunk)
        readers[routingKey] = reader
        reader.start()
        return reader
    }

    func reader(for routingKey: String) -> ControlModeStreamReader? { readers[routingKey] }

    func remove(routingKey: String) {
        if let reader = readers.removeValue(forKey: routingKey) { reader.stop() }
    }

    func stopAll() {
        for reader in readers.values { reader.stop() }
        readers.removeAll()
    }
}
