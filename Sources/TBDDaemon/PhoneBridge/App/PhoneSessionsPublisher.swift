import Foundation
import os
import TBDShared

/// Keeps one phone's sessions list current after its `sessions.subscribe`
/// (spec section 4.4): on state deltas it gathers the list again, compares it
/// with what the phone has, and emits the change as `sessions.changed`.
///
/// **One window per burst.** The first delta after a quiet spell opens a
/// window of `debounce`; deltas inside it add nothing, and when it ends the
/// list is gathered once, which covers them. A delta that lands after the
/// window ends, while the list is being gathered, opens the next window, so
/// nothing is missed. The window is not restarted by each delta, so a steady
/// stream of deltas, a busy session's hooks, still publishes every
/// `debounce` instead of never.
///
/// **A first window at start.** The baseline was gathered before the
/// publisher subscribed, so `start(baseline:)` opens one window at once to
/// catch any change in between.
///
/// **Times that move alone are not news.** A session whose chip, reason and
/// rate-limit end are unchanged keeps the `changedAt` the phone already has:
/// some states are stamped with the time they were read, and they would
/// otherwise look changed on every gather.
///
/// `stop()` removes the subscriber and ends the work for good; a later
/// `start(baseline:)` does nothing. Every emit happens on the publisher, one
/// at a time, in order.
actor PhoneSessionsPublisher {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    private let gather: @Sendable () async throws -> PhoneSnapshot
    private let emit: @Sendable (SessionsChangedData) async -> Void
    private let subscriptions: StateSubscriptionManager
    private let debounce: Duration
    private let clock: any Clock<Duration>

    /// Whether a window is open: set by the delta that opens one, cleared
    /// when it ends. Lock-guarded, as the subscriber callback that sets it is
    /// synchronous.
    private final class OpenWindow: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false

        /// Opens the window; true when it was closed.
        func open() -> Bool {
            lock.withLock {
                defer { isOpen = true }
                return !isOpen
            }
        }

        func close() {
            lock.withLock { isOpen = false }
        }
    }

    /// What the phone has: the last list it was sent, less what the frames
    /// left out (`sent(_:since:leaving:)`).
    private var baseline: PhoneSnapshot?
    private var subscriberID: StateSubscriptionManager.SubscriberID?
    private var wakeups: AsyncStream<Void>.Continuation?
    private var consumer: Task<Void, Never>?
    private var stopped = false

    init(gather: @escaping @Sendable () async throws -> PhoneSnapshot,
         emit: @escaping @Sendable (SessionsChangedData) async -> Void,
         subscriptions: StateSubscriptionManager,
         debounce: Duration = PhoneAppConstants.sessionsDebounce,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.gather = gather
        self.emit = emit
        self.subscriptions = subscriptions
        self.debounce = debounce
        self.clock = clock
    }

    /// Whether the publisher is subscribed to state deltas: between `start`
    /// and `stop`. For tests.
    var isSubscribed: Bool {
        subscriberID != nil
    }

    /// What the publisher holds the phone to have. For tests.
    var phoneBaseline: PhoneSnapshot? {
        baseline
    }

    /// Subscribes to state deltas, with `baseline` as what the phone has.
    /// Does nothing once started or stopped.
    func start(baseline: PhoneSnapshot) {
        guard !stopped, consumer == nil else { return }
        self.baseline = baseline
        // Each wakeup is a window. Only the delta that opens one yields, so
        // one wakeup waits at most.
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeups = continuation
        let window = OpenWindow()
        // The catch-up window, open before the first delta can arrive.
        _ = window.open()
        subscriberID = subscriptions.addSubscriber { _ in
            if window.open() {
                continuation.yield()
            }
            return true
        }
        continuation.yield()
        let clock = self.clock
        let debounce = self.debounce
        consumer = Task { [weak self] in
            for await _ in stream {
                do {
                    try await clock.sleep(for: debounce)
                } catch {
                    return
                }
                // From here a delta opens the next window, as this gather
                // may read the state from before it.
                window.close()
                guard let self else { return }
                await self.publish()
            }
        }
    }

    /// Removes the subscriber and stops for good.
    func stop() {
        stopped = true
        if let subscriberID {
            subscriptions.removeSubscriber(subscriberID)
            self.subscriberID = nil
        }
        wakeups?.finish()
        wakeups = nil
        consumer?.cancel()
        consumer = nil
    }

    /// Gathers the list, and emits what changed since the phone's baseline.
    private func publish() async {
        guard !stopped, let old = baseline else { return }
        let gathered: PhoneSnapshot
        do {
            gathered = try await gather()
        } catch {
            Self.logger.error(
                "Phone sessions: could not gather the sessions list: \(PhoneAppService.errorType(error), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return
        }
        guard !stopped else { return }
        let new = Self.steadied(gathered, since: old)
        guard let change = Self.diff(old: old, new: new) else {
            baseline = new
            return
        }
        let framed = Self.framed(change, budget: PhoneFrameBudget.eventDataBytes)
        // What the frames left out stays as the phone has it, so the next
        // gather finds it changed again and tries it again.
        baseline = Self.sent(new, since: old, leaving: framed)
        for frame in framed.frames {
            guard !stopped else { return }
            await emit(frame)
        }
    }

    // MARK: - Comparing

    /// What changed from `old` to `new`, or nil when nothing did.
    ///
    /// `layout` is present when it changed in any way: the groups, their
    /// order or names, a group's rows, or a row's depth. A renamed repo
    /// changes only the layout, so comparing the whole of it is what lets
    /// the phone see the new name. `rows` holds every row that is new or
    /// whose value changed, in the new order; `removedRowIDs` the rows that
    /// are gone, in the old order.
    static func diff(old: PhoneSnapshot, new: PhoneSnapshot) -> SessionsChangedData? {
        let layoutChanged = old.layout != new.layout
        var before: [String: PhoneRow] = [:]
        for row in old.rows where before[row.id] == nil {
            before[row.id] = row
        }
        let changed = new.rows.filter { before[$0.id] != $0 }
        let kept = Set(new.rows.map(\.id))
        let removed = old.rows.map(\.id).filter { !kept.contains($0) }
        guard layoutChanged || !changed.isEmpty || !removed.isEmpty else { return nil }
        return SessionsChangedData(layout: layoutChanged ? new.layout : nil, rows: changed, removedRowIDs: removed)
    }

    /// `new`, with each session whose chip, reason and rate-limit end are
    /// the same as in `old` keeping `old`'s `changedAt`, and each row's
    /// `statusChangedAt` following its sessions.
    static func steadied(_ new: PhoneSnapshot, since old: PhoneSnapshot) -> PhoneSnapshot {
        var previous: [PhoneSessionRef: PhoneStatus] = [:]
        for row in old.rows {
            for session in row.sessions {
                previous[session.ref] = session.status
            }
        }
        let rows = new.rows.map { row -> PhoneRow in
            var moved = false
            let sessions = row.sessions.map { session -> PhoneSession in
                guard let before = previous[session.ref],
                      before.chip == session.status.chip,
                      before.reason == session.status.reason,
                      before.untilAt == session.status.untilAt,
                      before.changedAt != session.status.changedAt else {
                    return session
                }
                moved = true
                return PhoneSession(
                    ref: session.ref, agent: session.agent, tabName: session.tabName, status: before,
                    profileName: session.profileName, profileID: session.profileID, model: session.model,
                    capabilities: session.capabilities, openPromptID: session.openPromptID)
            }
            guard moved else { return row }
            return PhoneRow(
                id: row.id, kind: row.kind, name: row.name, remote: row.remote,
                statusChangedAt: sessions.map(\.status.changedAt).max() ?? row.statusChangedAt,
                sessions: sessions)
        }
        return PhoneSnapshot(layout: new.layout, rows: rows, omittedRows: new.omittedRows)
    }

    /// What the phone has once it got `new`'s change from `old` in `framed`'s
    /// frames: `new`, except that what the frames left out is as in `old`. A
    /// row left out keeps its `old` value, or is absent when `old` had none;
    /// a removal left out keeps its `old` row; a layout left out is `old`'s.
    /// Diffing against this finds each left-out item again.
    static func sent(_ new: PhoneSnapshot, since old: PhoneSnapshot, leaving framed: Framed) -> PhoneSnapshot {
        guard framed.leftOutLayout || !framed.leftOutRowIDs.isEmpty || !framed.leftOutRemovedRowIDs.isEmpty else {
            return new
        }
        var before: [String: PhoneRow] = [:]
        for row in old.rows where before[row.id] == nil {
            before[row.id] = row
        }
        var rows = new.rows.compactMap { row -> PhoneRow? in
            guard framed.leftOutRowIDs.contains(row.id) else { return row }
            return before[row.id]
        }
        rows += old.rows.filter { framed.leftOutRemovedRowIDs.contains($0.id) }
        return PhoneSnapshot(
            layout: framed.leftOutLayout ? old.layout : new.layout, rows: rows, omittedRows: new.omittedRows)
    }

    // MARK: - Frames

    /// `frames(_:budget:)`'s frames, with the items they left out.
    struct Framed: Equatable, Sendable {
        var frames: [SessionsChangedData] = []
        /// Whether the layout was left out.
        var leftOutLayout = false
        /// The IDs of the rows left out.
        var leftOutRowIDs: Set<String> = []
        /// The removed row IDs left out.
        var leftOutRemovedRowIDs: Set<String> = []
    }

    /// `data` split into events that each encode, as a whole
    /// `sessions.changed` event envelope with any `seq`, to at most `budget`
    /// bytes. The layout and the removals ride on the first frame, and
    /// removals that do not fit there go on the next; the rows follow in
    /// order, as many to a frame as fit.
    ///
    /// An item that alone cannot fit a frame is left out and logged, and
    /// `framed(_:budget:)` names it. The snapshot builder keeps every row and
    /// the layout well inside a frame, so that does not happen to the list it
    /// builds.
    static func frames(_ data: SessionsChangedData, budget: Int) -> [SessionsChangedData] {
        framed(data, budget: budget).frames
    }

    /// `frames(_:budget:)`, with the items it left out.
    static func framed(_ data: SessionsChangedData, budget: Int) -> Framed {
        if eventSize(data) <= budget {
            return Framed(frames: [data])
        }
        let encoder = PhoneAppCoding.makeEncoder()
        var result = Framed()
        var layout = data.layout
        if let pending = layout, eventSize(SessionsChangedData(layout: pending, rows: [], removedRowIDs: [])) > budget {
            logger.error("Phone sessions: left out a layout too large for a frame")
            layout = nil
            result.leftOutLayout = true
        }
        let removals = data.removedRowIDs
        let rows = data.rows
        // What an element adds to an array: its bytes, and a comma unless it
        // is the first.
        let rowSizes = rows.map { (try? encoder.encode($0).count) ?? Int.max / 2 }
        var nextRemoval = 0
        var nextRow = 0
        while layout != nil || nextRemoval < removals.count || nextRow < rows.count {
            let frameLayout = layout
            layout = nil
            var used = eventSize(SessionsChangedData(layout: frameLayout, rows: [], removedRowIDs: []))
            var frameRemovals: [String] = []
            while nextRemoval < removals.count {
                let id = removals[nextRemoval]
                let quoted = PhoneFrameBudget.escapedLength(id[...].unicodeScalars) + 2
                let cost = quoted + (frameRemovals.isEmpty ? 0 : 1)
                guard used + cost <= budget else { break }
                frameRemovals.append(id)
                used += cost
                nextRemoval += 1
            }
            var frameRows: [PhoneRow] = []
            while nextRow < rows.count {
                let cost = rowSizes[nextRow] + (frameRows.isEmpty ? 0 : 1)
                guard used + cost <= budget else { break }
                frameRows.append(rows[nextRow])
                used += cost
                nextRow += 1
            }
            if frameLayout == nil && frameRemovals.isEmpty && frameRows.isEmpty {
                // The next item does not fit even an empty frame.
                if nextRemoval < removals.count {
                    logger.error("Phone sessions: left out a removed row ID too large for a frame")
                    result.leftOutRemovedRowIDs.insert(removals[nextRemoval])
                    nextRemoval += 1
                } else {
                    logger.error("Phone sessions: left out a row too large for a frame")
                    result.leftOutRowIDs.insert(rows[nextRow].id)
                    nextRow += 1
                }
                continue
            }
            result.frames.append(SessionsChangedData(layout: frameLayout, rows: frameRows, removedRowIDs: frameRemovals))
        }
        return result
    }

    /// Bytes `data` takes as a whole `sessions.changed` event with the
    /// longest `seq`.
    private static func eventSize(_ data: SessionsChangedData) -> Int {
        (try? PhoneAppCoding.event(.sessionsChanged, seq: Int.max, data: data).count) ?? Int.max
    }
}
