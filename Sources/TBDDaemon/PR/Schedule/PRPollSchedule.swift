import Foundation
import TBDShared

/// One scheduled item: a PR tracked by number, or a worktree's branch in discovery.
public enum PRPollItemID: Hashable, Sendable {
    case track(PRPollKey)
    case discover(UUID)
}

public struct PRPollBindingFact: Sendable, Equatable {
    public let key: PRPollKey
    /// `nil` means bound but never observed.
    public let state: PRMergeableState?
    public init(key: PRPollKey, state: PRMergeableState?) {
        self.key = key
        self.state = state
    }
}

public struct PRPollWorktreeFacts: Sendable, Equatable {
    public let worktreeID: UUID
    public let active: Bool
    /// False for a row with no branch to match on (`RPCRouter.hasPollableBranch`).
    public let discoverable: Bool
    /// Live (non-detached) bindings only.
    public let bindings: [PRPollBindingFact]
    public init(worktreeID: UUID, active: Bool, discoverable: Bool, bindings: [PRPollBindingFact]) {
        self.worktreeID = worktreeID
        self.active = active
        self.discoverable = discoverable
        self.bindings = bindings
    }
}

public struct PRPollDue: Sendable, Equatable {
    public var discover: Set<UUID>
    public var track: Set<PRPollKey>
    public var isEmpty: Bool { discover.isEmpty && track.isEmpty }
    public init(discover: Set<UUID> = [], track: Set<PRPollKey> = []) {
        self.discover = discover
        self.track = track
    }
}

/// The in-memory PR poll schedule. Pure: no clock, no I/O; every method that
/// needs the time takes it. See docs/specs/2026-10-01-pr-polling-schedule-design.md,
/// "Intervals by status", "Activity as a multiplier" and "The scheduler".
public struct PRPollSchedule: Sendable {
    struct Entry: Sendable {
        var slot: PRPollSlot
        var owners: Set<UUID>
        var lastRun: Date?
        var forcedDue: Date?
        /// When a tracked PR entered `checksRunning`; kept while it stays there.
        var pendingSince: Date?
    }

    private var entries: [PRPollItemID: Entry] = [:]
    private var wasActive: [UUID: Bool] = [:]
    /// The `checksRunning` PRs holding one of the fast tier's slots.
    private var fastSlots: Set<PRPollKey> = []

    public init() {}

    // MARK: - Building items from facts

    public mutating func reconcile(_ facts: [PRPollWorktreeFacts], now: Date) {
        let previous = entries
        var next: [PRPollItemID: Entry] = [:]
        var trackedWorktrees: Set<UUID> = []

        // Track items, keyed by PR so owners from several worktrees merge.
        for wt in facts {
            for binding in wt.bindings {
                guard let slot = PRPollTiers.slot(for: .pr(binding.state), active: wt.active),
                      slot.tier != .closedDiscovery else { continue }
                trackedWorktrees.insert(wt.worktreeID)
                let id = PRPollItemID.track(binding.key)
                if var entry = next[id] {
                    // A second owner this pass: the faster slot wins.
                    if slot.interval < entry.slot.interval { entry.slot = slot }
                    if entry.slot.tier == .checksRunning, entry.pendingSince == nil {
                        entry.pendingSince = previous[id]?.pendingSince ?? now
                    }
                    entry.owners.insert(wt.worktreeID)
                    next[id] = entry
                } else {
                    // First owner this pass: keep timing from the previous pass,
                    // rebuild owners and slot from the facts.
                    var entry = previous[id] ?? Entry(slot: slot, owners: [], lastRun: nil,
                                                      forcedDue: nil, pendingSince: nil)
                    entry.owners = [wt.worktreeID]
                    entry.slot = slot
                    if slot.tier == .checksRunning {
                        let wasRunning = previous[id]?.slot.tier == .checksRunning
                        entry.pendingSince = wasRunning ? (entry.pendingSince ?? now) : now
                    } else {
                        entry.pendingSince = nil
                    }
                    next[id] = entry
                }
            }
        }

        // Discovery items, one per untracked worktree.
        for wt in facts where !trackedWorktrees.contains(wt.worktreeID) {
            guard let subject = Self.discoverySubject(wt),
                  let slot = PRPollTiers.slot(for: subject, active: wt.active) else { continue }
            let id = PRPollItemID.discover(wt.worktreeID)
            var entry = previous[id] ?? Entry(slot: slot, owners: [wt.worktreeID], lastRun: nil,
                                              forcedDue: nil, pendingSince: nil)
            if previous[id] == nil, slot.tier == .closedDiscovery {
                // The closed state was just observed by the track item this pass
                // removed, so the first discovery is a full interval after it.
                entry.lastRun = Self.lastRunOfDroppedTrackItems(of: wt.worktreeID,
                                                                previous: previous, next: next)
            }
            entry.owners = [wt.worktreeID]
            entry.slot = slot
            entry.pendingSince = nil
            next[id] = entry
        }

        // Idle to active makes that worktree's items due now.
        let activated = Set(facts.filter { wasActive[$0.worktreeID] == false && $0.active }.map(\.worktreeID))
        if !activated.isEmpty {
            for (id, entry) in next where !entry.owners.isDisjoint(with: activated) {
                next[id]?.forcedDue = now
            }
        }

        entries = next
        wasActive = Dictionary(facts.map { ($0.worktreeID, $0.active) }, uniquingKeysWith: { $0 || $1 })
        assignFastSlots()
    }

    /// What an untracked worktree is discovered as, or `nil` for no item.
    private static func discoverySubject(_ wt: PRPollWorktreeFacts) -> PRPollSubject? {
        let states = wt.bindings.map(\.state)
        if states.contains(.merged) { return nil }
        if states.contains(.closed) { return .pr(.closed) }
        if wt.bindings.isEmpty && wt.discoverable { return .noPR }
        return nil
    }

    /// The latest `lastRun` among last pass's track items this worktree owned
    /// and no longer owns.
    private static func lastRunOfDroppedTrackItems(of worktreeID: UUID,
                                                   previous: [PRPollItemID: Entry],
                                                   next: [PRPollItemID: Entry]) -> Date? {
        var latest: Date?
        for (id, entry) in previous {
            guard case .track = id, entry.owners.contains(worktreeID),
                  next[id]?.owners.contains(worktreeID) != true,
                  let run = entry.lastRun else { continue }
            latest = latest.map { max($0, run) } ?? run
        }
        return latest
    }

    /// The oldest `checksRunning` PRs, by `pendingSince` then key, hold the fast slots.
    private mutating func assignFastSlots() {
        var pending: [(since: Date, key: PRPollKey)] = []
        for (id, entry) in entries {
            guard case .track(let key) = id, entry.slot.tier == .checksRunning else { continue }
            pending.append((entry.pendingSince ?? .distantPast, key))
        }
        pending.sort { ($0.since, $0.key) < ($1.since, $1.key) }
        fastSlots = Set(pending.prefix(PRPollTiers.fastTierCapacity).map(\.key))
    }

    private func isFast(_ id: PRPollItemID) -> Bool {
        if case .track(let key) = id { return fastSlots.contains(key) }
        return false
    }

    /// The tier the governor sees: fast-tier overflow counts as waiting.
    private func effectiveTier(_ id: PRPollItemID, _ entry: Entry) -> PRPollTier {
        entry.slot.tier == .checksRunning && !isFast(id) ? .waiting : entry.slot.tier
    }

    /// The interval before any stretch.
    private func baseInterval(_ id: PRPollItemID, _ entry: Entry) -> Duration {
        entry.slot.tier == .checksRunning && !isFast(id) ? PRPollTiers.fastTierOverflowInterval : entry.slot.interval
    }

    // MARK: - Due times

    public func interval(of id: PRPollItemID, decision: PRPollGovernor.Decision) -> Duration? {
        guard let entry = entries[id] else { return nil }
        let base = baseInterval(id, entry)
        guard PRPollTiers.isStretchable(effectiveTier(id, entry)),
              case .run(let factor) = decision else { return base }
        return PRPollGovernor.stretched(base, by: factor)
    }

    /// `min(forcedDue, lastRun + effectiveInterval)`; a never-run item is due at once.
    /// `nil` when the item cannot run under this decision.
    private func dueDate(_ id: PRPollItemID, _ entry: Entry, _ decision: PRPollGovernor.Decision) -> Date? {
        if decision == .brake && !isFast(id) { return nil }
        guard let lastRun = entry.lastRun else { return .distantPast }
        let interval = interval(of: id, decision: decision) ?? entry.slot.interval
        let scheduled = lastRun.addingTimeInterval(PRPollGovernor.seconds(interval))
        guard let forced = entry.forcedDue else { return scheduled }
        return min(scheduled, forced)
    }

    public func due(at now: Date, decision: PRPollGovernor.Decision) -> PRPollDue {
        var due = PRPollDue()
        for (id, entry) in entries {
            guard let date = dueDate(id, entry, decision), date <= now else { continue }
            switch id {
            case .track(let key): due.track.insert(key)
            case .discover(let worktreeID): due.discover.insert(worktreeID)
            }
        }
        return due
    }

    public func nextDue(decision: PRPollGovernor.Decision) -> Date? {
        entries.compactMap { dueDate($0.key, $0.value, decision) }.min()
    }

    /// Every item that ran waits a full interval, whatever its outcome.
    public mutating func markRan(_ due: PRPollDue, at now: Date) {
        let ids = due.track.map(PRPollItemID.track) + due.discover.map(PRPollItemID.discover)
        for id in ids where entries[id] != nil {
            entries[id]?.lastRun = now
            entries[id]?.forcedDue = nil
        }
    }

    /// Makes every item the worktree owns due now. Moves due times only.
    public mutating func trigger(worktreeID: UUID, now: Date) {
        for (id, entry) in entries where entry.owners.contains(worktreeID) {
            entries[id]?.forcedDue = now
        }
    }

    // MARK: - Inspection

    /// One load per item at its unstretched interval; the governor applies the stretch.
    public func loads() -> [PRPollGovernor.Load] {
        entries.map { id, entry in
            let tier = effectiveTier(id, entry)
            return PRPollGovernor.Load(interval: baseInterval(id, entry),
                                       points: PRPollTiers.points(for: tier),
                                       stretchable: PRPollTiers.isStretchable(tier))
        }
    }

    public func tier(of id: PRPollItemID) -> PRPollTier? { entries[id]?.slot.tier }

    public func owners(of key: PRPollKey) -> Set<UUID> { entries[.track(key)]?.owners ?? [] }
}
