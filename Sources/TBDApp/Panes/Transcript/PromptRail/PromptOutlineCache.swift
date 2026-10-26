import Foundation

/// `PromptOutline.entries(from:)` with each node's projection kept by
/// `(id, contentVersion)`, so rebuilding the outline after an update projects
/// only the prompts that are new or changed. Projecting reads a prompt's whole
/// text — unwrapping its pasted spans, checking whether anyone typed it — and
/// the coordinator rebuilds the outline on every update but a streaming tick,
/// so without this each append would re-read every prompt in the session.
///
/// Kept as the coordinator's other row caches are: content-addressed, so a
/// node whose content changes simply misses, and pruned to the live nodes on
/// every rebuild, so it holds at most one projection per prompt on screen.
/// The result is the uncached builder's, entry for entry.
struct PromptOutlineCache {
    private struct Key: Hashable {
        let id: String
        let version: UInt64
    }

    /// A node's projection, or nil for a candidate that makes no entry (a
    /// prompt nobody typed), which is remembered too.
    private var projections: [Key: PromptOutline.Projection?] = [:]

    /// How many nodes have been projected rather than served from the cache.
    /// A test seam: it says how much work a rebuild did.
    private(set) var projectionCount = 0

    /// The outline of `nodes`, projecting only the nodes this cache has not
    /// seen at their current content, then dropping projections for nodes
    /// `nodes` no longer holds.
    mutating func entries(from nodes: [TranscriptRenderNode]) -> [PromptOutlineEntry] {
        var result: [PromptOutlineEntry] = []
        var live = Set<Key>()
        for (index, node) in nodes.enumerated() where PromptOutline.isCandidate(node) {
            let key = Key(id: node.id, version: node.contentVersion)
            live.insert(key)
            let projection: PromptOutline.Projection?
            if let cached = projections[key] {
                projection = cached
            } else {
                projection = PromptOutline.projection(of: node)
                // `updateValue`, so a nil projection is stored as a value
                // rather than read as a removal.
                projections.updateValue(projection, forKey: key)
                projectionCount += 1
            }
            if let projection { result.append(projection.entry(rowIndex: index)) }
        }
        // Every live key is in the cache by now, so any surplus is stale.
        if projections.count > live.count {
            projections = projections.filter { live.contains($0.key) }
        }
        return result
    }
}
