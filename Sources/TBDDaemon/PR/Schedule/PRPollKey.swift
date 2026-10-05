import Foundation
import TBDShared

/// One PR, wherever it is bound. Lowercased the way
/// `PRStatusManager.groupBindingsByRepo` groups, so two worktrees on one PR share a key.
public struct PRPollKey: Hashable, Sendable, Comparable {
    public let host: String
    public let owner: String
    public let repo: String
    public let number: Int

    public init(host: String, owner: String, repo: String, number: Int) {
        self.host = host.lowercased()
        self.owner = owner.lowercased()
        self.repo = repo.lowercased()
        self.number = number
    }

    public init(_ binding: PRBinding) {
        self.init(host: binding.host, owner: binding.owner, repo: binding.repo, number: binding.number)
    }

    public static func < (lhs: PRPollKey, rhs: PRPollKey) -> Bool {
        (lhs.host, lhs.owner, lhs.repo, lhs.number) < (rhs.host, rhs.owner, rhs.repo, rhs.number)
    }
}
