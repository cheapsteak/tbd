import Foundation

/// Where moved rows land among their new siblings.
///
/// One pure function shared by the daemon's `WorktreeStore.moveMany`, which
/// writes the order, and the app, which applies the same move locally before
/// the daemon answers. Both sides running the same placement is what lets the
/// app's rows land where the daemon will put them: the daemon's group also
/// holds rows the app does not list (archived ones), but placement keeps the
/// relative order of every row it does not carry, so the two agree on each
/// row both sides hold.
public enum SiblingPlacement {
    /// `group` without any `carried` ID, with `carried` inserted, in the order
    /// given, immediately before `before`, or appended when `before` is nil or
    /// is not among the remaining rows.
    ///
    /// A carried ID that is not in `group` is inserted too: it is a row joining
    /// the group from elsewhere. A carried ID named twice is placed once, at its
    /// first position, so the result never holds a row twice. Rows that are not
    /// carried keep their relative order.
    public static func place(group: [UUID], carried: [UUID], before: UUID?) -> [UUID] {
        var seen = Set<UUID>()
        let moving = carried.filter { seen.insert($0).inserted }
        var result = group.filter { !seen.contains($0) }
        let index = before.flatMap { result.firstIndex(of: $0) } ?? result.endIndex
        result.insert(contentsOf: moving, at: index)
        return result
    }
}
