import Foundation
import TBDShared

/// Where a composer's message goes.
///
/// A local Claude terminal takes a paste through `terminal.send` (or a wake
/// when it is parked); a remote session takes one `remote.sendMessage`, which
/// the daemon turns into the provider's `send <id> --submit`
/// (docs/specs/2026-09-25-remote-session-transcript-design.md, "Composer").
///
/// The two are different enough that the composer branches on this rather
/// than on a flag: a remote target has no completion inventory (that comes
/// from a local terminal), no image staging (a staged image is a local path
/// the remote machine cannot read), and no wake path.
enum ComposerTarget {
    case terminal(Terminal, LocalWorktree)
    case remote(RemoteSessionSelection)

    /// The identity drafts and focus registrations are keyed by.
    var key: ComposerKey {
        switch self {
        case .terminal(let terminal, _): return .terminal(terminal.id)
        case .remote(let selection): return .remote(selection)
        }
    }

    /// Whether this target takes staged images and slash-command completion.
    /// Both depend on the local machine: the inventory is probed from a local
    /// terminal's Claude Code, and an attachment is a path on this disk.
    var supportsLocalAffordances: Bool {
        if case .terminal = self { return true }
        return false
    }
}

/// The key a composer's draft and focus registrations live under. Hashable
/// and value-only, unlike `ComposerTarget`, whose terminal case carries whole
/// rows that change on every refresh.
enum ComposerKey: Hashable {
    case terminal(UUID)
    case remote(RemoteSessionSelection)
}
