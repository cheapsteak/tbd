import Foundation

/// Which discovery source first proposed a binding. Retained for diagnostics
/// and so a manual attach can be told apart from an inferred one.
public enum PRBindingSource: String, Codable, Sendable, CaseIterable {
    case hook       // scraped from a `gh pr create` tool result
    case branch     // matched by head branch against the viewer's PRs
    case manual     // `tbd pr attach`, or seeded from Worktree.prNumber
}

/// A durable statement that a pull request belongs to a worktree.
///
/// Bindings are the multi-PR replacement for the single `Worktree.prStatus` /
/// `Worktree.prNumber` pair. `detached` is a tombstone, not a delete: a removed
/// binding must stay on record or the next poll or hook fire would re-create it.
public struct PRBinding: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let worktreeID: UUID
    public let host: String
    public let owner: String
    public let repo: String
    public let number: Int
    public let url: String
    public let headBranch: String?
    public let baseRef: String?
    /// Last observed status. nil = never polled since binding.
    public let status: PRStatus?
    public let source: PRBindingSource
    public let detached: Bool
    public let boundAt: Date

    public init(id: UUID = UUID(), worktreeID: UUID, host: String = "github.com",
                owner: String, repo: String, number: Int, url: String,
                headBranch: String? = nil, baseRef: String? = nil,
                status: PRStatus? = nil, source: PRBindingSource,
                detached: Bool = false, boundAt: Date = Date()) {
        self.id = id
        self.worktreeID = worktreeID
        self.host = host
        self.owner = owner
        self.repo = repo
        self.number = number
        self.url = url
        self.headBranch = headBranch
        self.baseRef = baseRef
        self.status = status
        self.source = source
        self.detached = detached
        self.boundAt = boundAt
    }

    /// A copy carrying a freshly observed status. The poll refreshes bindings
    /// into a `[bindingID: PRStatus]` map and has to fold that map back onto the
    /// bindings before `worst(of:)` or `allResolved(_:)` can judge them.
    public func withStatus(_ status: PRStatus?) -> PRBinding {
        PRBinding(id: id, worktreeID: worktreeID, host: host, owner: owner, repo: repo,
                  number: number, url: url, headBranch: headBranch, baseRef: baseRef,
                  status: status, source: source, detached: detached, boundAt: boundAt)
    }

    /// Identity for deduplication — matches the table's UNIQUE constraint.
    /// Owner and repo compare case-insensitively because GitHub treats them so.
    public var identityKey: String {
        "\(host.lowercased())\u{1}\(owner.lowercased())\u{1}\(repo.lowercased())\u{1}\(number)"
    }
}

public extension PRMergeableState {
    /// Merged and closed are the only states with no further transition to await.
    var isTerminal: Bool { self == .merged || self == .closed }

    /// How loudly this state asks for the user's attention; higher wins when
    /// one icon must stand for several PRs. Terminal states rank lowest —
    /// a merged PR needs nothing.
    ///
    /// The order is the design's: checks failing, blocked, changes requested,
    /// pending, mergeable, draft. It is defined once here because the toolbar
    /// icon, the sidebar dot and the `Worktree.prStatus` column all read it,
    /// and they must not be able to disagree.
    var attentionSeverity: Int {
        switch self {
        case .checksFailed:     return 6
        case .blocked:          return 5
        case .changesRequested: return 4
        case .pending:          return 3
        case .mergeable:        return 2
        case .draft:            return 1
        case .merged, .closed:  return 0
        }
    }
}

public extension PRBinding {
    /// The binding whose state most needs attention, ignoring tombstones.
    /// Ties break toward the lower PR number so the choice is stable.
    static func worst(of bindings: [PRBinding]) -> PRBinding? {
        bindings
            .filter { !$0.detached }
            .min { lhs, rhs in
                let l = lhs.status?.state.attentionSeverity ?? -1
                let r = rhs.status?.state.attentionSeverity ?? -1
                if l != r { return l > r }
                return lhs.number < rhs.number
            }
    }

    /// The auto-archive / auto-hibernate trigger: every non-detached binding is
    /// terminal AND at least one merged. A binding with no observed status is
    /// not terminal, so an unpolled PR holds the gate shut.
    static func allResolved(_ bindings: [PRBinding]) -> Bool {
        let live = bindings.filter { !$0.detached }
        guard !live.isEmpty else { return false }
        guard live.allSatisfy({ $0.status?.state.isTerminal == true }) else { return false }
        return live.contains { $0.status?.state == .merged }
    }
}
