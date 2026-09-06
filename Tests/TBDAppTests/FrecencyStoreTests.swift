import Foundation
import Testing
@testable import TBDApp

/// Frecency: usage count decayed with a seven-day half-life, floored at ten
/// percent. It is a TIEBREAK, never a rank — a command you used yesterday must
/// not outrank an exact-name match you just typed.
///
/// `Date` is data here, not behavior, so the seam is `now: () -> Date` rather
/// than a `Clock` (CLAUDE.md, "Duration is behavior, Date is data").
///
/// `FrecencyStore` is `@MainActor`-isolated (every `UserDefaults` holder in
/// this tree is), so the whole suite runs on the main actor.
@MainActor
@Suite("FrecencyStore")
struct FrecencyStoreTests {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func store(_ suiteName: String, now: Date) -> FrecencyStore {
        FrecencyStore(defaults: UserDefaults(suiteName: suiteName)!, now: { now })
    }

    // MARK: - The curve

    @Test func aFreshUseScoresItsFullCount() {
        #expect(FrecencyStore.decayed(usageCount: 4, lastUsedAt: epoch, now: epoch) == 4)
    }

    @Test func sevenDaysHalvesIt() {
        let score = FrecencyStore.decayed(
            usageCount: 4, lastUsedAt: epoch, now: epoch.addingTimeInterval(7 * 86_400))
        #expect(abs(score - 2) < 0.0001)
    }

    @Test func fourteenDaysQuartersIt() {
        let score = FrecencyStore.decayed(
            usageCount: 4, lastUsedAt: epoch, now: epoch.addingTimeInterval(14 * 86_400))
        #expect(abs(score - 1) < 0.0001)
    }

    /// **The floor is what keeps an old favourite from vanishing.** Without it a
    /// command used heavily a year ago decays to indistinguishable-from-never,
    /// and the tiebreak stops carrying any memory at all.
    @Test func itNeverDecaysBelowTenPercent() {
        let score = FrecencyStore.decayed(
            usageCount: 10, lastUsedAt: epoch, now: epoch.addingTimeInterval(365 * 86_400))
        #expect(score >= 1.0, "10 uses floored at 10% is 1.0, however long ago: \(score)")
    }

    /// A clock that went backwards must not inflate a score.
    @Test func aFutureTimestampDoesNotAmplify() {
        let score = FrecencyStore.decayed(
            usageCount: 3, lastUsedAt: epoch.addingTimeInterval(86_400), now: epoch)
        #expect(score <= 3)
    }

    // MARK: - The store

    @Test func anUnknownCommandScoresZero() {
        let suiteName = "FrecencyStoreTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        #expect(store(suiteName, now: epoch).score("never-used") == 0)
    }

    @Test func recordingAccumulatesAndPersists() {
        let suiteName = "FrecencyStoreTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let first = store(suiteName, now: epoch)
        first.record("compact")
        first.record("compact")
        #expect(first.score("compact") == 2)

        // A separate instance over the same suite reads the same numbers.
        let later = store(suiteName, now: epoch.addingTimeInterval(7 * 86_400))
        #expect(abs(later.score("compact") - 1) < 0.0001)
    }

    /// Recording refreshes the timestamp, so a re-used command climbs back.
    @Test func aNewUseResetsTheDecayClock() {
        let suiteName = "FrecencyStoreTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        store(suiteName, now: epoch).record("compact")
        let weekLater = store(suiteName, now: epoch.addingTimeInterval(7 * 86_400))
        weekLater.record("compact")
        #expect(weekLater.score("compact") > 1.5,
                "a fresh use must beat the decayed one it replaced")
    }
}
