import Foundation
import Security
import TBDShared

/// Deletion support for an isolated Claude Code config dir. The shared
/// `ClaudeCodeCredentialsKeychain` derives its service name; it always has a
/// suffix and cannot target the user's default unsuffixed credential item.
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
