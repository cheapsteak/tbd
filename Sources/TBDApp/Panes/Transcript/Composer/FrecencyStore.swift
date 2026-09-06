import Foundation

/// How often a command was used, decayed by how long ago.
///
/// A **tiebreak**, never a rank. It settles the order of two rows an exact,
/// prefix or fuzzy match already put level with each other; it must never let a
/// command you used yesterday outrank the one whose name you just typed in full.
///
/// One global store keyed by command name, in app defaults, not one per
/// worktree: a person's habits are theirs, and a per-worktree store would forget
/// them every time they started fresh work.
///
/// Seven-day half-life, floored at ten percent of the raw count. The floor is
/// what keeps an old favourite from decaying to indistinguishable-from-never —
/// without it the tiebreak carries no memory at all after a couple of months.
///
/// `Date` here is **data**: a persisted timestamp compared against a time. So the
/// seam is `now: () -> Date`, not a `Clock`.
///
/// `UserDefaults`-holding types in this tree are main-actor isolated rather than
/// bare `Sendable` structs (precedent: `CLIInstallerCoordinator`,
/// `LegacyHooksCoordinator`); its only consumer, `CompletionController`, is
/// main-actor too.
@MainActor
final class FrecencyStore {
    nonisolated static let defaultsKey = "composerCommandFrecency"
    nonisolated static let halfLife: TimeInterval = 7 * 86_400
    /// The fraction of the raw count a score can never fall below.
    nonisolated static let floor = 0.1

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    /// The decay curve, pure so it is testable without a store.
    ///
    /// A `lastUsedAt` in the future — a clock that went backwards, a synced
    /// defaults file from another machine — is clamped to now rather than
    /// amplifying the score.
    nonisolated static func decayed(usageCount: Int, lastUsedAt: Date, now: Date) -> Double {
        let raw = Double(usageCount)
        guard raw > 0 else { return 0 }
        let elapsed = max(0, now.timeIntervalSince(lastUsedAt))
        let decayed = raw * pow(0.5, elapsed / halfLife)
        return max(decayed, raw * floor)
    }

    func score(_ name: String) -> Double {
        guard let entry = entries()[name],
              let count = entry["count"] as? Int,
              let stamp = entry["lastUsedAt"] as? Double else { return 0 }
        return Self.decayed(
            usageCount: count, lastUsedAt: Date(timeIntervalSince1970: stamp), now: now())
    }

    /// Accept a completion: one more use, clock reset.
    func record(_ name: String) {
        var all = entries()
        let previous = (all[name]?["count"] as? Int) ?? 0
        all[name] = ["count": previous + 1, "lastUsedAt": now().timeIntervalSince1970]
        defaults.set(all, forKey: Self.defaultsKey)
    }

    private func entries() -> [String: [String: Any]] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String: Any]] ?? [:]
    }
}
