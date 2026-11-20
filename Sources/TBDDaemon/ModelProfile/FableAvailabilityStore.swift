import Foundation
import TBDShared

/// The daemon's latest `FableAvailability` per profile, refreshed only on
/// demand.
///
/// Nothing here runs on a timer. A probe happens when something asks for a
/// reading that is missing or past its TTL: a Fable spawn, `tbd profile
/// fable-check`, or `tbd profile list --refresh-fable`. Probes are bounded:
/// one at a time per profile (a second ask joins the one in flight) and at
/// most `maxConcurrentProbes` across profiles.
///
/// In memory only. A restart forgets everything, which costs one probe per
/// account the next time a Fable spawn needs it. Nothing secret is held: the
/// value is a state, a short code and a time.
public actor FableAvailabilityStore {
    /// Runs one probe for a profile and classifies it. Never throws: every
    /// failure is an `unknown` reading.
    public typealias Probe = @Sendable (UUID) async -> FableAvailability

    public static let maxConcurrentProbes = 2

    private var entries: [UUID: FableAvailability] = [:]
    private var inFlight: [UUID: Task<FableAvailability, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let probe: Probe
    private let now: @Sendable () -> Date

    public init(probe: @escaping Probe, now: @Sendable @escaping () -> Date = { Date() }) {
        self.probe = probe
        self.now = now
    }

    /// The latest reading for a profile at any age, or nil if never checked.
    public func current(_ id: UUID) -> FableAvailability? { entries[id] }

    /// Every reading held, at any age.
    public func all() -> [UUID: FableAvailability] { entries }

    /// Whether a profile has no reading, or one past its TTL.
    public func needsRefresh(_ id: UUID) -> Bool {
        guard let entry = entries[id] else { return true }
        return !entry.isFresh(now: now())
    }

    /// Record a reading seen elsewhere (a session that showed the credits
    /// line). Replaces whatever is held.
    public func record(_ availability: FableAvailability, for id: UUID) {
        entries[id] = availability
    }

    /// Probe each profile whose reading is missing or stale (every profile
    /// when `force`), and return the readings for all of `ids`.
    ///
    /// `deadline` bounds how long the caller waits. Probes still running at
    /// the deadline are not cancelled: they finish and record their result,
    /// but the caller gets whatever is held now, so a profile still unchecked
    /// is simply absent from the result.
    @discardableResult
    public func refresh(
        _ ids: [UUID], force: Bool = false, deadline: TimeInterval? = nil
    ) async -> [UUID: FableAvailability] {
        var seen = Set<UUID>()
        let wanted = ids.filter { seen.insert($0).inserted }
        let pending = wanted.filter { force || needsRefresh($0) }.map { start($0) }

        if !pending.isEmpty {
            if let deadline {
                await Self.waitForAll(pending, orUntil: deadline)
            } else {
                for task in pending { _ = await task.value }
            }
        }
        var result: [UUID: FableAvailability] = [:]
        for id in wanted { if let entry = entries[id] { result[id] = entry } }
        return result
    }

    // MARK: - Private

    private func start(_ id: UUID) -> Task<FableAvailability, Never> {
        if let existing = inFlight[id] { return existing }
        let task = Task { [probe] in
            await self.acquire()
            let reading = await probe(id)
            self.release()
            self.finish(id, reading)
            return reading
        }
        inFlight[id] = task
        return task
    }

    private func finish(_ id: UUID, _ reading: FableAvailability) {
        entries[id] = reading
        inFlight[id] = nil
    }

    private func acquire() async {
        if running < Self.maxConcurrentProbes {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // The slot passes straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var fired = false
        func set(_ c: CheckedContinuation<Void, Never>) {
            lock.lock(); defer { lock.unlock() }
            if fired { c.resume() } else { continuation = c }
        }
        func fire() {
            lock.lock()
            let c = continuation
            continuation = nil
            let first = !fired
            fired = true
            lock.unlock()
            if first { c?.resume() }
        }
    }

    private static func waitForAll(
        _ tasks: [Task<FableAvailability, Never>], orUntil deadline: TimeInterval
    ) async {
        let once = Once()
        let waiter = Task {
            for task in tasks { _ = await task.value }
            once.fire()
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(deadline))
            once.fire()
        }
        await withCheckedContinuation { once.set($0) }
        waiter.cancel()
        timer.cancel()
    }
}
