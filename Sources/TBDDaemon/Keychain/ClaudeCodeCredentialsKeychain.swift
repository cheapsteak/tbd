import CryptoKit
import Foundation
import Security

/// Claude Code stores OAuth credentials in the login keychain as a generic
/// password whose service name is derived from the `CLAUDE_CONFIG_DIR` path:
///
///     "Claude Code-credentials-<first 8 lowercase hex chars of sha256(path)>"
///
/// Known vector (verified empirically): sha256 of
/// "/Users/zionts/.claude-profiles/zadam" starts with `db64a81f`, and the
/// keychain item "Claude Code-credentials-db64a81f" pairs with that dir.
///
/// The bare "Claude Code-credentials" item (no suffix) belongs to the user's
/// default `~/.claude` and must NEVER be touched by TBD. Every service name
/// produced here always carries a path-derived suffix, so deleting through
/// this namespace can never target the bare item.
public enum ClaudeCodeCredentialsKeychain {
    /// Base service name used by Claude Code. The unsuffixed form belongs to
    /// the user's default config dir — TBD only ever appends a suffix to it.
    public static let baseServiceName = "Claude Code-credentials"

    /// First 8 lowercase-hex characters of sha256 of the config dir path
    /// string (the exact string, no normalization — matches how Claude Code
    /// hashes `CLAUDE_CONFIG_DIR`).
    public static func serviceSuffix(forConfigDirPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    /// Full keychain service name for the credentials item belonging to the
    /// given config dir. Always suffixed — never returns the bare item name.
    public static func serviceName(forConfigDirPath path: String) -> String {
        "\(baseServiceName)-\(serviceSuffix(forConfigDirPath: path))"
    }
}

/// Injection seam for deleting Claude Code credential items, so tests can
/// assert "delete was requested with the right service name" without touching
/// the real login keychain.
public protocol ClaudeCredentialsKeychainDeleting: Sendable {
    /// Delete the generic-password item with the given service name.
    /// Returns the raw `SecItemDelete`-style status; `errSecItemNotFound`
    /// counts as success for callers (nothing to clean).
    func deleteGenericPassword(service: String) -> OSStatus
}

extension ClaudeCredentialsKeychainDeleting {
    /// Delete the Claude Code credentials item for the given config dir path.
    /// The service name is always derived (suffixed) from the path, so this
    /// can never target the bare "Claude Code-credentials" item.
    public func deleteCredentials(forConfigDirPath path: String) -> OSStatus {
        deleteGenericPassword(
            service: ClaudeCodeCredentialsKeychain.serviceName(forConfigDirPath: path)
        )
    }
}

/// Live implementation backed by the Security framework.
public struct SecItemClaudeCredentialsKeychain: ClaudeCredentialsKeychainDeleting {
    public init() {}

    public func deleteGenericPassword(service: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        return SecItemDelete(query as CFDictionary)
    }
}
