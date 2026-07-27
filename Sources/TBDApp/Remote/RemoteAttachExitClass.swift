import Foundation
import TBDShared

/// How a local `attach` process's exit code is read by the app — a
/// three-way split, not a boolean, because "the provider can't authenticate"
/// is a different condition from "the transport dropped" and wants different
/// handling and different words on screen.
///
/// Pure policy: no SwiftUI/AppKit/AppState dependency, mirroring
/// `RemoteReconnectPolicy`/`RemoteAttachLifecycle`'s shape. Built on the
/// shared `ProviderFailureClass` so the app and the daemon classify the same
/// exit code the same way (the contract's error model is one table, not two
/// implementations).
///
/// Nothing here parses `attach`'s output: per
/// `docs/remote-provider-contract.md` § `attach`, that stdout is a PTY byte
/// stream and MUST NOT be parsed, so the exit code is the whole signal.
enum RemoteAttachExitClass: Equatable {
    /// The user detached (exit 0), or no exit code was readable at all.
    /// `nil` is deliberately grouped here: an unreadable code is not
    /// evidence of failure, and guessing would put alarming words on screen
    /// for a normal detach.
    case clean
    /// The provider could not authenticate (exit class 4). Retrying is not
    /// the fix — a human has to re-authenticate — so this must never be
    /// framed as an unexpected session exit.
    case authNeeded
    /// Any other non-zero exit: an unreachable host, a dropped connection, a
    /// crashed shim. Presumed transient and eligible for automatic reconnect
    /// once the provider is healthy again.
    case unexpected

    static func classify(exitCode: Int32?) -> RemoteAttachExitClass {
        guard let exitCode else { return .clean }
        switch ProviderFailureClass(exitCode: exitCode) {
        case .none: return .clean            // exit 0
        case .authNeeded: return .authNeeded
        case .permanent, .contractBug, .transient: return .unexpected
        }
    }
}
