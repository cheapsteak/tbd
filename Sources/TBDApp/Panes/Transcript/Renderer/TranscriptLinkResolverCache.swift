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
/// the filesystem. The cache is never invalidated: a file appearing later is a
/// rare case, and the cost of getting it wrong is one path that stays plain
/// text until the pane is rebuilt.
@MainActor
final class TranscriptLinkResolverCache {
    private var memo: [String: String?] = [:]

    func resolve(_ token: String, using resolve: (String) -> String?) -> String? {
        // Double optional: the outer level is "have we asked", the inner is the
        // answer. `memo[token] != nil` is the hit test, including a cached nil.
        if let cached = memo[token] { return cached }
        let result = resolve(token)
        memo[token] = result
        return result
    }
}
