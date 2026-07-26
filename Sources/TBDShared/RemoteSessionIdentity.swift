import CryptoKit
import Foundation

/// Deterministic identity for a remote-session mirror row.
///
/// Remote sessions have no native UUID — the provider contract
/// (`docs/remote-provider-contract.md` § Identity & drift) keys everything
/// by the pair `(provider name, session id)`, an opaque provider-minted
/// string. The sidebar's `List(selection:)` needs a `UUID` to tag rows with
/// (the same way local rows tag by `Worktree.id`), so this manufactures one.
///
/// STABILITY CONTRACT: `uuid(provider:sessionID:)` must be a pure function
/// of its two arguments alone — no randomness, no persisted counter, no
/// clock. That's what makes the id survive a daemon restart or an app
/// restart with zero migration: it is never itself the stored source of
/// truth, it's re-derived identically every time from data that's already
/// durable (the `remote_session` table's primary key IS
/// `(provider, sessionID)`, and the provider contract requires the
/// provider's own id to be "durable across reboots of whatever the session
/// runs on").
///
/// Derivation: RFC 4122 §4.3-shaped name-based UUID — version nibble set to
/// 5, variant bits set to the DCE/RFC4122 pattern — computed over
/// SHA-256(namespace bytes || provider UTF-8 || 0x00 || sessionID UTF-8),
/// keeping the first 16 bytes of the digest. This deliberately deviates from
/// strict RFC 4122 v5 (which mandates SHA-1): SHA-256 has no known collision
/// weaknesses, and CryptoKit's `SHA256` is already used elsewhere in this
/// codebase (`ClaudeCodeCredentialsKeychain`). Nothing outside this codebase
/// needs to reproduce these exact bytes — only local uniqueness/stability —
/// so exact RFC compliance isn't a goal; the version/variant bits are set
/// purely so the result has the same shape every other UUID in this
/// codebase expects.
public enum RemoteSessionIdentity {
    /// Fixed namespace UUID for this derivation. Generated once (`uuidgen`)
    /// and committed here — it must NEVER change. Changing it would
    /// reassign every existing remote row a different id on the next daemon
    /// restart, breaking `selectedRemoteSession`/List selection continuity
    /// and orphaning anything keyed by the old id (rename overrides, unread
    /// bookkeeping).
    private static let namespace = UUID(uuidString: "944493D9-6FBE-48E6-8375-128D8A22E788")!

    /// The deterministic identity for the mirror row keyed by
    /// `(provider, sessionID)`.
    public static func uuid(provider: String, sessionID: String) -> UUID {
        var data = Data()
        withUnsafeBytes(of: namespace.uuid) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(provider.utf8))
        data.append(0)
        data.append(contentsOf: Array(sessionID.utf8))

        var digest = Array(SHA256.hash(data: data).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50   // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80   // RFC4122 variant
        let tuple: uuid_t = (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: tuple)
    }
}
