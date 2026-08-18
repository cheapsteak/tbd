import Foundation

/// Which forge a pull request or merge request lives on.
///
/// Derived at parse time and carried on `PRNode`; never persisted. The
/// `worktree_pull_request.host` column is the durable fact, and the forge is
/// recomputed from it, so adding a case here needs no migration.
public enum Forge: String, Codable, Sendable, CaseIterable {
    case github
    case gitlab
}

public extension Forge {
    /// Classify a host. `github.com` is GitHub; every other host is treated as
    /// GitLab here.
    ///
    /// This is a *composition* fallback, not host discovery — the only thing
    /// that can really know which self-managed hosts are GitLab is
    /// `GitLabHostResolver`, reading what the user already told `glab`. The
    /// callers of this function have already been handed a host that came from
    /// a repo identity or from a URL a GitLab pattern matched, and they need a
    /// shape to write, not a fact to establish. The known limitation is a
    /// GitHub Enterprise host, which classifies as `.gitlab`; the paths that
    /// call this previously hardcoded `github.com` outright, so Enterprise was
    /// already unserved and is not newly broken.
    static func forHost(_ host: String) -> Forge {
        host.lowercased() == "github.com" ? .github : .gitlab
    }
}
