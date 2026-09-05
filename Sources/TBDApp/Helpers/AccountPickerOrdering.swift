import Foundation
import TBDShared

/// Pure ordering for the account picker sheet rows (design 2026-09-05 §8.2).
///
/// When balancing is on, eligible rows come first (in picker score order), then
/// ineligible rows (in `sortedForPicker` order). When off, all rows use
/// `sortedForPicker` order. No rows are dropped.
enum AccountPickerOrdering {
    struct Result {
        let ordered: [ModelProfileWithUsage]
        let balancedPickID: UUID?
    }

    static func order(
        entries: [ModelProfileWithUsage],
        balancingOn: Bool,
        liveCount: (UUID) -> Int,
        defaultProfileID: UUID?,
        now: Date
    ) -> Result {
        guard balancingOn else {
            // Balancing off: return display order, no balanced pick
            return Result(
                ordered: ProfileUsagePresentation.sortedForPicker(entries),
                balancedPickID: nil
            )
        }

        // Balancing on: eligible rows (score order) + ineligible rows (sortedForPicker order)
        let candidates = ProfilePoolCandidates.fromApp(
            entries: entries,
            liveCounts: liveCount,
            defaultProfileID: defaultProfileID
        )
        let ranked = ProfilePoolPicker.ranked(
            candidates: candidates,
            excludingAccountKeys: [],
            now: now
        )

        // Build eligible-rows-first order
        var ordered: [ModelProfileWithUsage] = []
        var seen = Set<UUID>()

        // Add ranked (eligible) rows first, preserving score order
        for rankedID in ranked {
            if let entry = entries.first(where: { $0.profile.id == rankedID }) {
                ordered.append(entry)
                seen.insert(rankedID)
            }
        }

        // Add remaining (ineligible) rows in sortedForPicker order
        let remaining = ProfileUsagePresentation.sortedForPicker(
            entries.filter { !seen.contains($0.profile.id) }
        )
        ordered.append(contentsOf: remaining)

        // balancedPickID is the first ranked (first eligible), or nil if none
        let balancedPickID = ranked.first

        return Result(ordered: ordered, balancedPickID: balancedPickID)
    }
}
