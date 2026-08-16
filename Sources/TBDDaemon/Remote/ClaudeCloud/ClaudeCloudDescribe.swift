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
/// Three capability names are deliberately ABSENT, and each absence is a fact
/// about the vendor surface rather than an unimplemented verb:
///
/// - `stop` — nothing exposed terminates a running cloud session. That is
///   also why `contract_versions` is `[2]` alone: major 1 requires `stop`.
/// - `log` — a cloud session has no terminal to scroll.
/// - `transcript` — no supported interface reads a cloud session's
///   conversation.
///
/// `archive` and `unarchive` ARE declared, implemented against this
/// provider's own ledger: the ledger is the only inventory this provider has,
/// so retiring a row within it is a real retirement of the only inventory
/// that exists here. Nothing is sent to Anthropic, and the row says so.
enum ClaudeCloudDescribe {
    static let capabilities = ["send", "attach", "land", "archive", "unarchive"]

    static let json = Data(#"""
    {
      "contract_versions": [2],
      "name": "\#(ClaudeCloudProvider.name)",
      "capabilities": ["send", "attach", "land", "archive", "unarchive"],
      "create_params": [
        {"name": "repo", "type": "string", "label": "Repository", "required": true},
        {"name": "branch", "type": "string", "label": "Branch"},
        {"name": "prompt", "type": "text", "label": "Initial prompt", "required": true},
        {"name": "environment", "type": "string", "label": "Environment"}
      ]
    }
    """#.utf8)
}
