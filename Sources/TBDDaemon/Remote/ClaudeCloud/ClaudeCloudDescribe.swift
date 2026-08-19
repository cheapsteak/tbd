import Foundation
import TBDShared

/// The compiled provider's static, offline `describe` answer.
///
/// It touches no network and no credential store, and it does NOT vary with
/// the signed-in account. `attach` is declared because the provider
/// implements it — it knows the command, composes the argv, and spawns on the
/// pane's PTY. Whether a given account is PERMITTED to attach is an
/// entitlement: a runtime condition of the account, the same kind of fact as
/// an expired credential, and not a capability. Making `describe` dynamic to
/// express it would put a network round trip inside the one verb the contract
/// requires to answer without one, and would make the Attach segment appear
/// and vanish rather than explain itself.
///
/// Capabilities are a promise a caller acts on — the app offers a
/// corresponding action, and `retire()`'s capability check lets a declared
/// verb reach this provider — so nothing is declared here that
/// `ClaudeCloudInvoker.run` cannot actually carry out.
///
/// Several capability names are deliberately ABSENT, and each absence is a
/// fact about the vendor surface rather than an unimplemented verb:
///
/// - `stop` — nothing exposed terminates a running cloud session. That is
///   also why `contract_versions` is `[2]` alone: major 1 requires `stop`.
/// - `log` — a cloud session has no terminal to scroll.
/// - `transcript` — no supported interface reads a cloud session's
///   conversation.
///
/// `land`, `archive` and `unarchive` are ALSO absent, but for a different
/// reason than the three above: this is a real gap in the current build, not
/// a fact about the vendor. `ClaudeCloudInvoker.run` answers all three with
/// `not_implemented` — they are a later slice of this feature, which will
/// re-add each capability string together with its implementation in the
/// same change. Declaring them ahead of that would offer the app an action
/// (Land, Archive, Unarchive on a cloud lane) that always fails.
enum ClaudeCloudDescribe {
    static let capabilities = ["send", "attach"]

    static let json = Data(#"""
    {
      "contract_versions": [2],
      "name": "\#(ClaudeCloudProvider.name)",
      "capabilities": ["send", "attach"],
      "create_params": [
        {"name": "repo", "type": "string", "label": "Repository", "required": true},
        {"name": "branch", "type": "string", "label": "Branch"},
        {"name": "prompt", "type": "text", "label": "Initial prompt", "required": true},
        {"name": "environment", "type": "string", "label": "Environment"}
      ]
    }
    """#.utf8)
}
