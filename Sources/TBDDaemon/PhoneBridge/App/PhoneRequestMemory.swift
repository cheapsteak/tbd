import Foundation

/// Remembers each phone request's ID and reply, so a resent request does not
/// act twice (spec section 4.4, "No double actions").
///
/// A phone resends a request when its connection drops before the reply
/// arrives. The first call with a (device, request ID) pair runs `work`; every
/// later call with the same pair, while the first is still running or after it
/// finished, gets the first run's reply bytes and never calls its own `work`.
///
/// **Runs belong to the memory, not to their callers.** `work` runs in a task
/// the memory starts, so neither the first caller nor any repeat can cancel
/// it: a dropped connection cannot abort an action halfway, and a resend after
/// a reconnect joins the run already going. A cancelled caller keeps waiting
/// and gets the reply like everyone else, which is why the app service makes
/// this call from a task of its own rather than from the bridge's handler
/// call. Only ``forget(deviceID:)`` cancels a run.
///
/// **Retention counts from the reply.** An entry starts its `retention` timer
/// when its run finishes, so an entry cannot expire while its run is going and
/// let a repeat start a second one. The timer sleeps on the injected clock.
///
/// **The per-device limit evicts finished entries only.** When a new entry
/// takes a device past `perDeviceLimit`, its oldest finished entries are
/// forgotten, oldest first, until it is back at the limit. An entry still in
/// flight is never evicted, for the same reason it never expires, so a device
/// holds more than the limit while more than that many of its runs are going.
actor PhoneRequestMemory {
    private enum State {
        case inFlight(Task<Data, Never>)
        case done(Data)

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }
    }

    private struct Entry {
        /// Tells this entry from a later one under the same key, so a run or a
        /// timer that outlives its entry cannot touch its successor.
        let id: UInt64
        var state: State
        /// The retention timer, armed once the run finishes.
        var expiry: Task<Void, Never>?
    }

    private struct DeviceEntries {
        var entries: [String: Entry] = [:]
        /// Request IDs, oldest first.
        var order: [String] = []
    }

    private let retention: Duration
    private let perDeviceLimit: Int
    private let clock: any Clock<Duration>
    private var devices: [UUID: DeviceEntries] = [:]
    private var nextEntryID: UInt64 = 0

    /// How many repeats are waiting right now on a run still in flight. Tests
    /// read it to know that a repeat has joined a run before they let the run
    /// finish.
    private(set) var waitingRepeats = 0

    init(retention: Duration = PhoneAppConstants.requestMemory,
         perDeviceLimit: Int = PhoneAppConstants.requestMemoryPerDevice,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.retention = retention
        self.perDeviceLimit = perDeviceLimit
        self.clock = clock
    }

    /// Runs `work` once per (deviceID, requestID) within `retention`; a repeat, in flight or done,
    /// returns the first run's reply bytes and does not call `work`.
    ///
    /// `repeated` is false only for the call that ran `work`. The entry is
    /// stored before this method first suspends, so two calls that interleave
    /// on the actor cannot both find the pair unknown.
    func reply(deviceID: UUID, requestID: String,
               work: @escaping @Sendable () async -> Data) async -> (reply: Data, repeated: Bool) {
        if let entry = devices[deviceID]?.entries[requestID] {
            switch entry.state {
            case .done(let reply):
                return (reply, true)
            case .inFlight(let run):
                waitingRepeats += 1
                defer { waitingRepeats -= 1 }
                let reply = await run.value
                return (reply, true)
            }
        }

        let entryID = nextEntryID
        nextEntryID &+= 1
        // The run cannot reach `finish` before `insert` below: both are on
        // this actor, and this method holds it until its first `await`.
        let run = Task {
            let reply = await work()
            self.finish(deviceID: deviceID, requestID: requestID, entryID: entryID, reply: reply)
            return reply
        }
        insert(Entry(id: entryID, state: .inFlight(run), expiry: nil), deviceID: deviceID, requestID: requestID)
        let reply = await run.value
        return (reply, false)
    }

    /// Forgets everything kept for `deviceID`, for a phone that can send no
    /// more requests, such as a revoked one.
    ///
    /// It cancels every retention timer the device has, and it cancels the
    /// device's runs still in flight, so a revoked phone's work stops as soon
    /// as that work notices. A cancelled run still returns whatever bytes its
    /// `work` returns, and every caller waiting on it, repeats included, gets
    /// those bytes. The finished run is not stored.
    ///
    /// Afterwards the device's request IDs are unknown: a later call with one
    /// of them runs its `work` again.
    func forget(deviceID: UUID) {
        guard let forgotten = devices.removeValue(forKey: deviceID) else { return }
        for entry in forgotten.entries.values {
            entry.expiry?.cancel()
            if case .inFlight(let run) = entry.state {
                run.cancel()
            }
        }
    }

    /// Whether a call with this pair now would be a repeat. For tests.
    func remembers(deviceID: UUID, requestID: String) -> Bool {
        devices[deviceID]?.entries[requestID] != nil
    }

    // MARK: - Entries

    /// Stores a new entry and evicts the device's oldest finished entries
    /// while it holds more than `perDeviceLimit`.
    private func insert(_ entry: Entry, deviceID: UUID, requestID: String) {
        var device = devices[deviceID] ?? DeviceEntries()
        device.entries[requestID] = entry
        device.order.append(requestID)
        while device.entries.count > perDeviceLimit, let index = Self.oldestDone(in: device) {
            let evicted = device.order.remove(at: index)
            device.entries.removeValue(forKey: evicted)?.expiry?.cancel()
        }
        devices[deviceID] = device
    }

    /// The position in `order` of the oldest finished entry, or nil when
    /// every entry is still in flight.
    private static func oldestDone(in device: DeviceEntries) -> Int? {
        device.order.firstIndex { device.entries[$0]?.state.isDone == true }
    }

    /// Stores a finished run's reply and starts its retention timer. Does
    /// nothing when the entry is gone, which only ``forget(deviceID:)`` does
    /// to an entry in flight.
    private func finish(deviceID: UUID, requestID: String, entryID: UInt64, reply: Data) {
        guard devices[deviceID]?.entries[requestID]?.id == entryID else { return }
        devices[deviceID]?.entries[requestID]?.state = .done(reply)
        devices[deviceID]?.entries[requestID]?.expiry = armExpiry(
            deviceID: deviceID, requestID: requestID, entryID: entryID)
    }

    private func armExpiry(deviceID: UUID, requestID: String, entryID: UInt64) -> Task<Void, Never> {
        let clock = self.clock
        let retention = self.retention
        return Task {
            do {
                try await clock.sleep(for: retention)
            } catch {
                return
            }
            self.expire(deviceID: deviceID, requestID: requestID, entryID: entryID)
        }
    }

    private func expire(deviceID: UUID, requestID: String, entryID: UInt64) {
        guard var device = devices[deviceID], device.entries[requestID]?.id == entryID else { return }
        device.entries.removeValue(forKey: requestID)
        device.order.removeAll { $0 == requestID }
        devices[deviceID] = device.entries.isEmpty ? nil : device
    }
}
