import Foundation

/// An archive that was held back because the worktree still has declared dev
/// servers running.
///
/// Carries the names rather than the records: the prompt needs to say what is
/// running, and nothing downstream of the prompt acts on a record. Keeping the
/// records out of the app's published state also keeps the confirmation from
/// going stale in a way the user cannot see — by the time they answer, the
/// servers may have exited, and the answer is about intent rather than about a
/// snapshot.
struct PendingArchive: Identifiable, Equatable {
    let worktreeID: UUID
    let worktreeName: String
    let servers: [String]
    /// The `force` the held-back call carried, so confirming re-issues the SAME
    /// archive rather than a subtly different one. `force` means "skip the
    /// archive hook"; a confirmation must not silently turn that on or off.
    let force: Bool

    var id: UUID { worktreeID }

    /// "storybook and dev", "a, b, and c" — the prompt reads as a sentence.
    var serverList: String {
        switch servers.count {
        case 0: return ""
        case 1: return servers[0]
        case 2: return "\(servers[0]) and \(servers[1])"
        default:
            return servers.dropLast().joined(separator: ", ") + ", and " + (servers.last ?? "")
        }
    }
}
