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
