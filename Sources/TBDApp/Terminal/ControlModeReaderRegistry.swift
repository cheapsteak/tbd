import Foundation

/// App-scoped owner of `ControlModeStreamReader` instances. Held by
/// `AppState`; keyed by `FDVendHeader.routingKey` (worktreeID/paneID) so
/// views can retrieve the reader on setup without owning it.
actor ControlModeReaderRegistry {
    private var readers: [String: (reader: ControlModeStreamReader, generation: UInt64?)] = [:]

    /// Register a reader for `routingKey` and start it, recording the attach
    /// `generation` that owns it. If one already exists, flag it stopped and
    /// replace it (the old reader's fd is closed by its own thread once the
    /// daemon-side detach EOFs it).
    @discardableResult
    func registerReader(routingKey: String, fd: Int32, generation: UInt64? = nil,
                        onChunk: @escaping @Sendable (Data) -> Void) -> ControlModeStreamReader {
        if let existing = readers.removeValue(forKey: routingKey) { existing.reader.stop() }
        let reader = ControlModeStreamReader(routingKey: routingKey, fd: fd, onChunk: onChunk)
        readers[routingKey] = (reader, generation)
        reader.start()
        return reader
    }

    func reader(for routingKey: String) -> ControlModeStreamReader? { readers[routingKey]?.reader }

    /// Stop and forget the reader for `routingKey` — generation-scoped
    /// (R10-4, same convention as `AppState.controlModePaneDetached`): a
    /// stale cleanup's remove landing AFTER a fast re-attach registered a
    /// fresh reader must not stop the successor. When `generation` is
    /// present, the removal applies only if it matches the recorded owner;
    /// `nil` on either side clears unconditionally (a record stored without
    /// a generation cannot be discriminated).
    func remove(routingKey: String, generation: UInt64? = nil) {
        guard let entry = readers[routingKey] else { return }
        if let generation, let recorded = entry.generation, recorded != generation { return }
        readers.removeValue(forKey: routingKey)
        entry.reader.stop()
    }

    func stopAll() {
        for entry in readers.values { entry.reader.stop() }
        readers.removeAll()
    }
}
