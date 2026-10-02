import Foundation

/// Keeps projected GitHub spend under a fixed share of the budget. Pure.
/// See the spec, "Cost telemetry and the governor".
public enum PRPollGovernor {
    public struct Load: Sendable, Equatable {
        public let interval: Duration
        public let points: Double
        public let stretchable: Bool
        public init(interval: Duration, points: Double, stretchable: Bool) {
            self.interval = interval
            self.points = points
            self.stretchable = stretchable
        }
    }

    public struct Budget: Sendable, Equatable {
        public let remaining: Int
        public let secondsUntilReset: TimeInterval
        public init(remaining: Int, secondsUntilReset: TimeInterval) {
            self.remaining = remaining
            self.secondsUntilReset = secondsUntilReset
        }
    }

    public enum Decision: Sendable, Equatable {
        case run(stretch: Double)
        /// Only the fast tier runs.
        case brake
    }

    public static let hourlyCap: Double = 1000

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    public static func stretched(_ interval: Duration, by factor: Double) -> Duration {
        let base = seconds(interval)
        let ceiling = max(base, seconds(PRPollTiers.maxStretchedInterval))
        return .milliseconds(Int64((min(base * max(factor, 1), ceiling) * 1000).rounded()))
    }

    public static func projectedHourlySpend(_ loads: [Load], stretch: Double) -> Double {
        loads.reduce(0) { sum, load in
            let interval = load.stretchable ? stretched(load.interval, by: stretch) : load.interval
            return sum + 3600 / seconds(interval) * load.points
        }
    }

    public static func decide(loads: [Load], budget: Budget?) -> Decision {
        func fitsBudget(_ spend: Double) -> Bool {
            guard let budget else { return true }
            return spend * budget.secondsUntilReset / 3600 <= Double(budget.remaining)
        }
        func fits(_ k: Double) -> Bool {
            let spend = projectedHourlySpend(loads, stretch: k)
            return spend <= hourlyCap && fitsBudget(spend)
        }
        let maxSeconds = seconds(PRPollTiers.maxStretchedInterval)
        let kMax = loads.filter(\.stretchable)
            .map { maxSeconds / seconds($0.interval) }
            .max().map { max($0, 1) } ?? 1
        if !fitsBudget(projectedHourlySpend(loads, stretch: kMax)) { return .brake }
        if fits(1) { return .run(stretch: 1) }
        if !fits(kMax) { return .run(stretch: kMax) }   // cap unreachable; budget leg holds
        var lo = 1.0, hi = kMax
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            if fits(mid) { hi = mid } else { lo = mid }
        }
        return .run(stretch: hi)
    }
}

/// Server budget readings turned into local deadlines. `resetAt` is compared
/// with local time exactly once, at receipt, clamped to [0, 1 h]; every later
/// comparison is local time against a local deadline.
public struct PRPollBudgetState: Sendable, Equatable {
    public private(set) var remaining: Int?
    public private(set) var resetDeadline: Date?
    public private(set) var brakeUntil: Date?

    public init() {}

    public mutating func recordReading(remaining: Int, resetAt: Date, receivedAt: Date) {
        let left = min(max(resetAt.timeIntervalSince(receivedAt), 0), 3600)
        self.remaining = remaining
        self.resetDeadline = receivedAt.addingTimeInterval(left)
    }

    public mutating func recordRateLimitError(at now: Date) {
        if let deadline = resetDeadline, deadline > now {
            brakeUntil = deadline
        } else {
            brakeUntil = now.addingTimeInterval(3600)
        }
    }

    public func budget(at now: Date) -> PRPollGovernor.Budget? {
        guard let remaining, let deadline = resetDeadline, deadline > now else { return nil }
        return PRPollGovernor.Budget(remaining: remaining, secondsUntilReset: deadline.timeIntervalSince(now))
    }

    public func isBraked(at now: Date) -> Bool {
        guard let brakeUntil else { return false }
        return now < brakeUntil
    }

    public mutating func decide(loads: [PRPollGovernor.Load], at now: Date) -> PRPollGovernor.Decision {
        if isBraked(at: now) { return .brake }
        let decision = PRPollGovernor.decide(loads: loads, budget: budget(at: now))
        if decision == .brake, let deadline = resetDeadline { brakeUntil = deadline }
        return decision
    }
}
