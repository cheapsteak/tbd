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
    /// The PR's title, as the last refresh that resolved it reported.
    ///
    /// Descriptive, like `headBranch` and `baseRef`: nothing matches on it, and
    /// nil means "never observed" rather than "this PR has no title". A binding
    /// hydrated from a cached `Worktree.prStatus` has none, and every row
    /// written before the column existed decodes as nil.
    public let title: String?
    /// Last observed status. nil = never polled since binding.
    public let status: PRStatus?
    public let source: PRBindingSource
    public let detached: Bool
    public let boundAt: Date

    public init(id: UUID = UUID(), worktreeID: UUID, host: String = "github.com",
                owner: String, repo: String, number: Int, url: String,
                headBranch: String? = nil, baseRef: String? = nil,
                title: String? = nil,
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
        self.title = title
        self.status = status
        self.source = source
        self.detached = detached
        self.boundAt = boundAt
    }

    /// A copy carrying everything a refresh observed: the status plus the head
    /// ref, base ref and title the PR reported. The poll folds its observations
    /// back onto the bindings through this before `worst(of:)`,
    /// `allResolved(_:)` or `mergedBindingIsOwnWork` can judge them.
    ///
    /// A **nil** ref or title means "not observed", never "cleared" — the
    /// stored value survives, the same rule the persisted row follows, so a
    /// transient failure cannot blank the branch the CLI renders or the title
    /// the status bar has on screen.
    ///
    /// Status and descriptive fields move together deliberately, rather than
    /// through a status-only sibling: the merge rule judges ownership on
    /// `headBranch`, so a binding folded with this pass's status but the
    /// previous pass's head ref would hold the gate shut for one poll on
    /// evidence it already had.
    public func withObservation(status: PRStatus?, headBranch: String?,
                                baseRef: String?, title: String?) -> PRBinding {
        PRBinding(id: id, worktreeID: worktreeID, host: host, owner: owner, repo: repo,
                  number: number, url: url, headBranch: headBranch ?? self.headBranch,
                  baseRef: baseRef ?? self.baseRef, title: title ?? self.title,
                  status: status, source: source, detached: detached, boundAt: boundAt)
    }

    /// Whether two bindings describe the **same observation**, ignoring when
    /// the status inside them was read.
    ///
    /// **Change detection uses this; `==` does not**, for exactly the reason
    /// `PRStatus.sameValue(as:)` states: `observedAt` advances on every poll, so
    /// an equality that includes it answers "different" every cadence and turns
    /// the poll's persist-on-change into one row UPDATE per binding per tick,
    /// forever, on a fleet whose steady state is zero writes.
    ///
    /// `Equatable` itself keeps the stamp, so a persisted round trip can still
    /// prove the stamp survived.
    public func sameValue(as other: PRBinding) -> Bool {
        unstamped == other.unstamped
    }

    /// This binding with its status's freshness stamp cleared, so the compiler
    /// writes the field-by-field comparison `sameValue(as:)` needs. Every
    /// descriptive field is passed through unchanged — the stamp is the only
    /// thing excluded, so a retitled PR still reads as changed and persists.
    private var unstamped: PRBinding {
        withObservation(status: status?.withObservedAt(nil),
                        headBranch: headBranch, baseRef: baseRef, title: title)
    }

    /// How this one binding is named in the UI: `PR #412` on GitHub, `MR !412`
    /// on GitLab, whose own reference syntax is `!iid`.
    ///
    /// Read from the binding's own `url`, which carries GitLab's
    /// `/-/merge_requests/` marker, and not from its `host` — a host is not
    /// evidence of a forge, so a `host`-shaped derivation renames every
    /// GitHub Enterprise, Bitbucket, Gitea and Codeberg pull request a merge
    /// request. `Forge.forURL` documents the coordinate.
    ///
    /// Per-binding text only. Anything summarising several bindings keeps the
    /// neutral wording, because a worktree can span forges.
    public var refLabel: String {
        Forge.forURL(url).refLabel(number: number)
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

    /// Half of the auto-archive / auto-hibernate trigger: every non-detached
    /// binding is terminal AND at least one merged. A binding with no observed
    /// status is not terminal, so an unpolled PR holds the gate shut.
    ///
    /// Not sufficient on its own — the merged PR must also be the worktree's own
    /// work. See `mergedBindingIsOwnWork(_:branchCandidates:provenancePRNumber:)`.
    static func allResolved(_ bindings: [PRBinding]) -> Bool {
        let live = bindings.filter { !$0.detached }
        guard !live.isEmpty else { return false }
        guard live.allSatisfy({ $0.status?.state.isTerminal == true }) else { return false }
        return live.contains { $0.status?.state == .merged }
    }

    /// The other half: at least one MERGED binding represents the **worktree's
    /// own** work. This is what keeps the multi-PR trigger strictly stronger than
    /// the single-PR rule it replaces.
    ///
    /// `allResolved` judges only the *set*, and a `hook` binding is deliberately
    /// spared the head-ref heal with nothing else re-validating it. So without
    /// this, a worktree whose only binding is a PR its subagent opened — on a
    /// branch the worktree never checked out, in a directory that merely happened
    /// to be the current one — would tear itself down the moment that PR merged,
    /// while its own branch has no PR at all and an agent is still working in it.
    /// The single-PR path could never do that: no branch matched, so no status
    /// ever moved.
    ///
    /// Own work means either of two things, and the second is not belt-and-braces:
    ///
    /// - the merged PR's head branch is one of the worktree's branch candidates.
    ///   Callers pass `PRStatusManager.branchCandidates` / `candidatesFor` — the
    ///   same derivation the matcher and the heal share, so this cannot judge
    ///   against a list the matcher never used. Names compare case-sensitively,
    ///   as git refs do and as `repoBranchKey` already does.
    /// - the merged PR's number is the worktree's `Worktree.prNumber`. A worktree
    ///   created from a **fork** PR row carries a head branch that belongs to the
    ///   fork and will match nothing local; the stored number is the only handle
    ///   that exists for it, and dropping this arm would regress auto-archive for
    ///   exactly the PR-row worktrees the single-PR path handled by number.
    ///
    /// A merged binding whose `headBranch` was never observed satisfies neither
    /// arm on its own: unknown holds the gate SHUT, the same way a nil status
    /// already blocks `allResolved`.
    static func mergedBindingIsOwnWork(_ bindings: [PRBinding],
                                       branchCandidates: [String],
                                       provenancePRNumber: Int?) -> Bool {
        let candidates = Set(branchCandidates)
        return bindings.contains { binding in
            guard !binding.detached, binding.status?.state == .merged else { return false }
            if let provenancePRNumber, binding.number == provenancePRNumber { return true }
            guard let head = binding.headBranch else { return false }
            return candidates.contains(head)
        }
    }
}
