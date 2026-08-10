import Foundation

/// Runs `operation` over every element of `items` concurrently, with at most
/// `limit` children in flight at once, and returns the outputs in **completion
/// order** (not input order — callers here key each output by worktree, so
/// ordering carries no meaning).
///
/// The unbounded shape this replaces — `for item in items { group.addTask … }` —
/// looks free because a task group only ever holds child *tasks*, but each of
/// these children parks a blocking `connect`/`recv` loop on the cooperative
/// thread pool for as long as the daemon takes to answer. On a full fleet that
/// is one child per worktree every poll, bounded only by the RPC receive
/// deadline. The pool has a fixed width; saturating it stalls unrelated work,
/// which is exactly the hazard `DaemonClient.makeConnectedSocket` documents when
/// it arms `SO_RCVTIMEO`.
///
/// The window is maintained by seeding `limit` children and then adding one more
/// for each result collected, so the group never holds more than `limit`
/// outstanding children regardless of how long any single one takes.
///
/// `limit` is clamped to at least 1; a zero or negative window would otherwise
/// seed nothing and return an empty result for a non-empty input.
func mapConcurrently<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    limit: Int,
    _ operation: @escaping @Sendable (Item) async -> Output
) async -> [Output] {
    guard !items.isEmpty else { return [] }
    let window = max(1, limit)
    return await withTaskGroup(of: Output.self) { group in
        var next = 0
        while next < items.count && next < window {
            let item = items[next]
            group.addTask { await operation(item) }
            next += 1
        }
        var collected: [Output] = []
        collected.reserveCapacity(items.count)
        for await output in group {
            collected.append(output)
            if next < items.count {
                let item = items[next]
                group.addTask { await operation(item) }
                next += 1
            }
        }
        return collected
    }
}
