import Foundation

/// Stores per-profile secrets (oauth tokens / api keys) in a file-backed
/// store, keyed by profile id.
///
/// **Storage path note:** the on-disk path `~/.tbd/claude-tokens/<uuid>.token`
/// MUST NOT change. Existing entries are keyed by it; renaming the directory
/// would break tokens for users upgrading from the previous build.
///
/// We use plain files under `~/.tbd/claude-tokens/<uuid>.token` with mode 0600
/// (parent dir 0700). This matches the storage model used by `claude
/// setup-token` itself, as well as `gh`, `aws`, `kubectl`, `docker`, `npm`,
/// and most other CLI tools on macOS. The threat model is effectively
/// equivalent to the macOS Keychain for the cases that matter (multi-user
/// POSIX perms, FileVault-at-rest) and strictly better than Keychain's
/// per-binary ACL model for an unbundled / unsigned SPM daemon that rebuilds
/// frequently.
public enum ModelProfileKeychainError: Error, Equatable {
    case dataEncoding
    case permissionMismatch(String)
    case ownerMismatch
    case ioFailure(String)
}

public enum ModelProfileKeychain {
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

    /// Store (or overwrite) a secret.
    public static func store(id: String, token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw ModelProfileKeychainError.dataEncoding
        }
        try ensureStorageDir()
        let url = fileURL(id: id)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ModelProfileKeychainError.ioFailure(error.localizedDescription)
        }
        // Atomic write uses a temp file + rename, which may drop our intended
        // mode bits. Set them explicitly after the write.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// Load a secret. Returns nil if no file exists for the given id.
    /// Throws if the file exists but has wrong mode or wrong owner — we don't
    /// want to return secrets from a misconfigured restore.
    public static func load(id: String) throws -> String? {
        let url = fileURL(id: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: url.path)
        } catch {
            throw ModelProfileKeychainError.ioFailure(error.localizedDescription)
        }

        if let perms = attrs[.posixPermissions] as? NSNumber {
            let mode = perms.int16Value & 0o777
            if mode != 0o600 {
                throw ModelProfileKeychainError.permissionMismatch(
                    String(format: "expected 0600, got 0%o", mode)
                )
            }
        }
        if let ownerID = attrs[.ownerAccountID] as? NSNumber {
            if ownerID.uint32Value != getuid() {
                throw ModelProfileKeychainError.ownerMismatch
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ModelProfileKeychainError.ioFailure(error.localizedDescription)
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw ModelProfileKeychainError.dataEncoding
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
            throw ModelProfileKeychainError.ioFailure(error.localizedDescription)
        }
    }
}
