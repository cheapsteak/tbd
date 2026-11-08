import Foundation

/// Remembers each phone request's ID, method and reply, so a resent request
/// does not act twice (spec section 4.4, "No double actions").
///
/// A phone resends a request when its connection drops before the reply
/// arrives. The first call with a (device, request ID) pair runs `work`; every
/// later call with the same pair and the same method, while the first is
/// still running or after it finished, gets the first run's reply bytes and
/// never calls its own `work`.
///
/// **A request ID names one method.** A later call with a remembered pair and
/// another method is no resend: it runs nothing, stores nothing, and returns
/// the caller's refusal for ``Refusal/requestIDInUse`` at once, without
/// waiting for a run in flight. So a finished `message.send`'s reply is never
/// handed to a `prompt.answer` that reuses its ID.
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
/// takes a device past `perDeviceLimit`, or a run finishes while the device is
/// past it, its oldest finished entries are forgotten, oldest first, until it
/// is back at the limit. An entry still in flight is never evicted, for the
/// same reason it never expires, so a device holds more than the limit while
/// more than that many of its runs are going.
///
/// **Runs in flight are capped per device.** Since an entry in flight is never
/// evicted and never expires, `perDeviceLimit` bounds nothing while runs are
/// going. So a device may have at most `inFlightLimit` runs going at once. A
/// call with a new request ID while the device is at that cap runs nothing,
/// stores nothing and returns the caller's refusal for
/// ``Refusal/tooManyInFlight``; a repeat of an ID already
/// in flight still joins its run, and a repeat of a finished one still gets
/// its reply. The app service enforces the same cap before it calls here, so
/// this cap is defense in depth: the memory stays bounded on its own for any
/// caller that skips the service's check.
actor PhoneRequestMemory {
    /// Why ``reply(deviceID:requestID:method:refusal:work:)`` returned the
    /// caller's refusal without running `work`.
    enum Refusal: Equatable, Sendable {
        /// The device has `inFlightLimit` runs going.
        case tooManyInFlight
        /// The request ID is remembered for a request with another method.
        case requestIDInUse
    }

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
        /// The method of the request that made the entry. A later call with
        /// the same ID is a repeat only when it names this method too.
        let method: PhoneAppMethod
        var state: State
        /// The retention timer, armed once the run finishes.
        var expiry: Task<Void, Never>?
    }

    private struct DeviceEntries {
        var entries: [String: Entry] = [:]
        /// Request IDs, oldest first.
        var order: [String] = []
        /// How many of `entries` are in flight.
        var inFlight = 0
    }

    private let retention: Duration
    private let perDeviceLimit: Int
    private let inFlightLimit: Int
    private let clock: any Clock<Duration>
    private var devices: [UUID: DeviceEntries] = [:]
    private var nextEntryID: UInt64 = 0

    /// How many repeats are waiting right now on a run still in flight. Tests
    /// read it to know that a repeat has joined a run before they let the run
    /// finish.
    private(set) var waitingRepeats = 0

    init(retention: Duration = PhoneAppConstants.requestMemory,
         perDeviceLimit: Int = PhoneAppConstants.requestMemoryPerDevice,
         inFlightLimit: Int = PhoneAppConstants.requestsInFlightPerDevice,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.retention = retention
        self.perDeviceLimit = perDeviceLimit
        self.inFlightLimit = inFlightLimit
        self.clock = clock
    }

    /// Runs `work` once per (deviceID, requestID) within `retention`; a repeat with the same
    /// `method`, in flight or done, returns the first run's reply bytes and does not call `work`.
    ///
    /// `repeated` is false for the call that ran `work`, and for a refused
    /// call, which returns `refusal` of its reason without running `work` or
    /// storing anything: a pair remembered for another method is refused
    /// ``Refusal/requestIDInUse``, and a new pair while the device is at the
    /// in-flight cap ``Refusal/tooManyInFlight``. The entry is stored before
    /// this method first suspends, so two calls that interleave on the actor
    /// cannot both find the pair unknown.
    func reply(deviceID: UUID, requestID: String, method: PhoneAppMethod,
               refusal: @Sendable (Refusal) -> Data,
               work: @escaping @Sendable () async -> Data) async -> (reply: Data, repeated: Bool) {
        if let entry = devices[deviceID]?.entries[requestID] {
            guard entry.method == method else {
                return (refusal(.requestIDInUse), false)
            }
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

        // Defense in depth: `PhoneAppService.handleAppMessage` refuses a
        // device's request past `PhoneAppConstants.requestsInFlightPerDevice`
        // before it calls here, so through the service this never refuses
        // today. It stays because nothing else bounds this memory while
        // runs are going, so the memory must stay safe for a caller that
        // skips that check.
        guard (devices[deviceID]?.inFlight ?? 0) < inFlightLimit else {
            return (refusal(.tooManyInFlight), false)
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
        insert(Entry(id: entryID, method: method, state: .inFlight(run), expiry: nil),
               deviceID: deviceID, requestID: requestID)
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

    /// Stores a new entry in flight and evicts the device's oldest finished
    /// entries while it holds more than `perDeviceLimit`.
    private func insert(_ entry: Entry, deviceID: UUID, requestID: String) {
        var device = devices[deviceID] ?? DeviceEntries()
        device.entries[requestID] = entry
        device.order.append(requestID)
        device.inFlight += 1
        evictPastLimit(&device)
        devices[deviceID] = device
    }

    /// Forgets `device`'s oldest finished entries, oldest first, while it
    /// holds more than `perDeviceLimit`, cancelling their retention timers.
    private func evictPastLimit(_ device: inout DeviceEntries) {
        while device.entries.count > perDeviceLimit, let index = Self.oldestDone(in: device) {
            let evicted = device.order.remove(at: index)
            device.entries.removeValue(forKey: evicted)?.expiry?.cancel()
        }
    }

    /// The position in `order` of the oldest finished entry, or nil when
    /// every entry is still in flight.
    private static func oldestDone(in device: DeviceEntries) -> Int? {
        device.order.firstIndex { device.entries[$0]?.state.isDone == true }
    }

    /// Stores a finished run's reply, starts its retention timer, and evicts
    /// the device's oldest finished entries while it is past `perDeviceLimit`,
    /// so a device a burst took past the limit shrinks back as its runs
    /// finish. Does nothing when the entry is gone, which only
    /// ``forget(deviceID:)`` does to an entry in flight.
    private func finish(deviceID: UUID, requestID: String, entryID: UInt64, reply: Data) {
        guard var device = devices[deviceID], device.entries[requestID]?.id == entryID else { return }
        device.inFlight -= 1
        device.entries[requestID]?.state = .done(reply)
        device.entries[requestID]?.expiry = armExpiry(deviceID: deviceID, requestID: requestID, entryID: entryID)
        evictPastLimit(&device)
        devices[deviceID] = device
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
