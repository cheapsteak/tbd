import Foundation
import TBDShared

/// Resolves a `PeerSender` to the worktree it came from, by exact
/// `displayName` match against a caller-supplied worktree list.
///
/// A pure function of its arguments: no I/O, no `AppState`, no singletons.
/// The worktree list is a parameter so this is testable without standing up
/// a pane, and so tail-parse-style callers can pass whatever snapshot of
/// active worktrees they hold.
///
/// Refusing to guess between duplicate display names is deliberate:
/// navigating to the wrong session is worse than not navigating, because it
/// looks like it worked. See
/// `docs/specs/2026-08-25-peer-message-attribution-design.md`,
/// "Resolution is a pure function over the worktree list".
enum PeerSenderResolver {
    static func resolve(_ sender: PeerSender, worktrees: [Worktree]) -> UUID? {
        // An asserted sender carries no verified identity to resolve.
        // Verification gates this, not whether `from` happens to match a
        // display name.
        guard sender.verified, let name = sender.name else { return nil }

        let matches = worktrees.filter { $0.displayName == name }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }
}
