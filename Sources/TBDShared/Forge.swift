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
    /// Classify a request from its own URL.
    ///
    /// `/-/merge_requests/` is the coordinate, because it is a fact about the
    /// request rather than a guess about where it lives: GitLab always inserts
    /// `/-/` between a project path and a resource, and no other forge uses
    /// that segment — which is why `PRBindingExtractor` anchors its GitLab
    /// pattern on the same literal. Every URL that reaches here was either
    /// matched by one of those patterns or composed alongside one, so the
    /// marker is present exactly when the request is a merge request. Matched
    /// case-insensitively, and `.github` when the marker is absent.
    ///
    /// The HOST cannot answer this question. "Not github.com" describes GitHub
    /// Enterprise, Bitbucket, Gitea and Codeberg as readily as it describes a
    /// self-managed GitLab, and all of them serve `/pull/<n>`, so a
    /// host-shaped classifier mislabels every non-GitLab fleet that is not on
    /// github.com — including the label under a binding a user attached by
    /// number. A host is only ever evidence of GitLab when someone declared it
    /// so: where no URL exists yet, because the daemon is composing one for a
    /// bare `tbd pr attach <number>`, the shape comes from
    /// `GitLabHostResolver` reading what the user already told `glab`, never
    /// from the hostname's shape.
    static func forURL(_ url: String) -> Forge {
        url.lowercased().contains("/-/merge_requests/") ? .gitlab : .github
    }

    /// How this forge names ONE request in its own vocabulary — `PR #412` on
    /// GitHub, `MR !412` on GitLab, which is the reference syntax GitLab itself
    /// uses everywhere from commit messages to its own UI.
    ///
    /// Only per-binding text may use this. Anything summarising SEVERAL
    /// bindings keeps neutral wording, because one worktree can hold bindings
    /// on both forges at once and no single vocabulary would be true of them.
    func refLabel(number: Int) -> String {
        switch self {
        case .github: return "\(refNoun) #\(number)"
        case .gitlab: return "\(refNoun) !\(number)"
        }
    }

    /// The same vocabulary `refLabel` composes its label from, for the
    /// sentences that name a request the surface has ALREADY numbered — a
    /// hover card whose headline says `PR#412` may not say the number twice,
    /// but it still must not call a merge request a PR. Composed into
    /// `refLabel` rather than kept beside it, so there is one noun per forge
    /// and no second table to drift.
    var refNoun: String {
        switch self {
        case .github: return "PR"
        case .gitlab: return "MR"
        }
    }

    /// What the forge calls itself, for text naming where a click lands.
    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        }
    }
}
