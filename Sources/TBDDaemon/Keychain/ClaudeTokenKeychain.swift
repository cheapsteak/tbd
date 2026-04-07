import Foundation

/// File-backed secret store for Claude OAuth tokens.
///
/// **Naming note:** the type is still `ClaudeTokenKeychain` for historical
/// reasons — the original implementation used macOS Keychain, but Keychain's
/// per-binary ACL model is incompatible with an unbundled / unsigned SPM
/// daemon that rebuilds frequently (each rebuild changes the binary signature
/// and the legacy keychain's `SecItemCopyMatching` hangs forever waiting on a
/// user-auth GUI prompt that a background daemon can't display, wedging the
/// keychain's global mutex for every other thread in the process).
///
/// We now write tokens as plain files under `~/.tbd/claude-tokens/<uuid>.token`
/// with mode 0600 (parent dir 0700). This matches the storage model used by
/// `claude setup-token` itself (writes to `~/.claude/.credentials.json`), as
/// well as `gh`, `aws`, `kubectl`, `docker`, `npm`, and most other CLI tools
/// on macOS. The threat model is effectively equivalent to the Keychain for
/// the cases that matter (multi-user POSIX perms, FileVault-at-rest) and
/// strictly better than the deadlock we had with Keychain.
public enum ClaudeTokenKeychainError: Error, Equatable {
    case dataEncoding
    case permissionMismatch(String)
    case ownerMismatch
    case ioFailure(String)
}

public enum ClaudeTokenKeychain {
    /// Storage directory. Resolved lazily so tests can override via TMPDIR if needed.
    private static var storageDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".tbd/claude-tokens", isDirectory: true)
    }

    private static func fileURL(id: String) -> URL {
        storageDir.appendingPathComponent("\(id).token", isDirectory: false)
    }

    /// Create the storage directory if missing, with mode 0700.
    private static func ensureStorageDir() throws {
        let dir = storageDir
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        } else {
            // Enforce 0700 on an existing dir in case it was created with a
            // looser umask by an earlier version of the code or by the user.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    /// Store (or overwrite) a token.
    public static func store(id: String, token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw ClaudeTokenKeychainError.dataEncoding
        }
        try ensureStorageDir()
        let url = fileURL(id: id)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ClaudeTokenKeychainError.ioFailure(error.localizedDescription)
        }
        // Atomic write uses a temp file + rename, which may drop our intended
        // mode bits. Set them explicitly after the write.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// Load a token. Returns nil if no file exists for the given id.
    /// Throws if the file exists but has wrong mode or wrong owner — we don't
    /// want to return tokens from a misconfigured restore.
    public static func load(id: String) throws -> String? {
        let url = fileURL(id: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: url.path)
        } catch {
            throw ClaudeTokenKeychainError.ioFailure(error.localizedDescription)
        }

        if let perms = attrs[.posixPermissions] as? NSNumber {
            let mode = perms.int16Value & 0o777
            if mode != 0o600 {
                throw ClaudeTokenKeychainError.permissionMismatch(
                    String(format: "expected 0600, got 0%o", mode)
                )
            }
        }
        if let ownerID = attrs[.ownerAccountID] as? NSNumber {
            if ownerID.uint32Value != getuid() {
                throw ClaudeTokenKeychainError.ownerMismatch
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ClaudeTokenKeychainError.ioFailure(error.localizedDescription)
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw ClaudeTokenKeychainError.dataEncoding
        }
        return token
    }

    /// Idempotent delete.
    public static func delete(id: String) throws {
        let url = fileURL(id: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            throw ClaudeTokenKeychainError.ioFailure(error.localizedDescription)
        }
    }
}
