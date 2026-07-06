import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "claudeCredentialStore")

/// Reads and writes the full Claude Code credentials blob for a given isolated
/// `CLAUDE_CONFIG_DIR`, so the daemon can refresh an expired OAuth access token
/// and persist the rotated pair back where the CLI reads it.
///
/// Reads shell out to `/usr/bin/security find-generic-password` (the items are
/// ACL'd to specific client binaries; a direct Security-framework read would
/// prompt). Writes use `/usr/bin/security add-generic-password -U`, which
/// updates the existing item's secret in place while preserving its service and
/// account attributes. When the keychain item is absent, both fall back to the
/// on-disk `<configDir>/.credentials.json` file Claude Code writes when the
/// keychain is unavailable.
public protocol ClaudeCredentialStoring: Sendable {
    /// Read the raw credentials blob bytes for the config dir, or nil when none
    /// is stored (not logged in). Throws only on unexpected read errors.
    func readBlob(forConfigDirPath path: String) async throws -> Data?
    /// Persist a new credentials blob for the config dir. Returns true on
    /// success; false when the write was denied/failed (caller should then treat
    /// the profile as needing re-login rather than assume the refresh stuck).
    func writeBlob(_ data: Data, forConfigDirPath path: String) async -> Bool
}

public struct SecurityCLIClaudeCredentialStore: ClaudeCredentialStoring {
    /// The keychain account attribute Claude Code stores (the macOS short user
    /// name). Resolved once from the environment; `add-generic-password`
    /// requires an account to target the right item.
    private let account: String

    public init(account: String = NSUserName()) {
        self.account = account
    }

    // MARK: Read

    public func readBlob(forConfigDirPath path: String) async throws -> Data? {
        let service = ClaudeCodeCredentialsKeychain.serviceName(forConfigDirPath: path)
        let outcome = try await SecurityCLIOAuthTokenReader.runSecurityFindGenericPassword(service: service)
        switch outcome {
        case .found(let data):
            return data
        case .notFound:
            let fileURL = URL(fileURLWithPath: path).appendingPathComponent(".credentials.json")
            return try? Data(contentsOf: fileURL)
        }
    }

    // MARK: Write

    public func writeBlob(_ data: Data, forConfigDirPath path: String) async -> Bool {
        let service = ClaudeCodeCredentialsKeychain.serviceName(forConfigDirPath: path)
        guard let secret = String(data: data, encoding: .utf8) else {
            logger.error("refreshed credential blob is not valid UTF-8; refusing to write")
            return false
        }
        let ok = await Self.runSecurityAddGenericPassword(
            account: account, service: service, secret: secret)
        if !ok {
            logger.warning("keychain write-back denied/failed for service \(service, privacy: .public)")
            // Best-effort: also refresh the on-disk fallback file if it exists,
            // so a CLI running in file-mode still benefits. Never creates the
            // file (that would be surprising); only overwrites an existing one.
            let fileURL = URL(fileURLWithPath: path).appendingPathComponent(".credentials.json")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? data.write(to: fileURL, options: [.atomic])
            }
        }
        return ok
    }

    /// Run `security add-generic-password -a <acct> -s <svc> -w <secret> -U`.
    /// `-U` updates the item in place if it exists (preserving attributes),
    /// creating it otherwise. Passing the secret via `-w <value>` avoids a
    /// prompt. Never routes through a shell. Returns true on exit 0.
    static func runSecurityAddGenericPassword(account: String, service: String, secret: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password",
            "-a", account,
            "-s", service,
            "-w", secret,
            "-U",
        ]
        process.environment = [:]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
