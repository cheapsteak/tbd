import Foundation

/// Memoizes path resolution for one transcript pane.
///
/// A reference type on purpose: the resolver closure is captured into a
/// `TranscriptCardContext` that SwiftUI rebuilds on every body evaluation, so
/// the memo has to outlive the struct that carries it. The pane owns one and it
/// lives as long as the pane does.
///
/// Misses are memoized as well as hits — "this token names nothing" is the
/// common answer in transcript prose, and the one it is least worth re-asking
/// the filesystem. A file APPEARING later is not invalidated: that is a rare
/// case, and the cost of getting it wrong is one path that stays plain text
/// until the pane is rebuilt. A change of worktree ROOT is, because it
/// invalidates every relative answer at once — see `resolve(_:root:using:)`.
@MainActor
final class TranscriptLinkResolverCache {
    private var memo: [String: String?] = [:]
    /// The root every entry in `memo` was computed against. Nil until the
    /// first resolve, which is distinct from `""` — a pane whose worktree row
    /// has not loaded resolves against an empty root and memoizes real misses.
    private var memoRoot: String?

    /// The key drops any trailing `:line` or `:line:col`, because the answer
    /// does not depend on it — `ClickedPathResolver` strips the same suffix
    /// before its existence check and the viewer takes no line argument. Keying
    /// on the raw token would give grep output, which cites one file at many
    /// lines, one entry and one `stat()` per line.
    ///
    /// `root` is not part of the key — it is the same for every token in a
    /// pane — so a change of root drops the whole memo instead. The root a
    /// pane resolves against changes when its worktree row arrives after the
    /// first render, and every relative answer memoized against the old root
    /// is wrong under the new one.
    func resolve(_ token: String, root: String, using resolve: (String) -> String?) -> String? {
        if memoRoot != root {
            memo.removeAll()
            memoRoot = root
        }
        let key = ClickedPathResolver.strippingLineSuffix(token)
        // Double optional: the outer level is "have we asked", the inner is the
        // answer. `memo[key] != nil` is the hit test, including a cached nil.
        if let cached = memo[key] { return cached }
        let result = resolve(key)
        memo[key] = result
        return result
    }
}
