import CryptoKit
import Darwin
import Foundation

/// The service name Claude Code uses for an isolated CLAUDE_CONFIG_DIR.
/// The unsuffixed item belongs to the default config dir and is never used
/// for a TBD profile.
public enum ClaudeCodeCredentialsKeychain {
    public static let baseServiceName = "Claude Code-credentials"

    public static func serviceSuffix(forConfigDirPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    public static func serviceName(forConfigDirPath path: String) -> String {
        "\(baseServiceName)-\(serviceSuffix(forConfigDirPath: path))"
    }
}

/// Login keychain account for this process. `getpwuid` uses the process UID,
/// so a launchd job with no USER or LOGNAME still resolves the real account.
public enum ClaudeCredentialAccount {
    public static func current() -> String? {
        // swiftlint:disable:next no_passwd_home_lookup - Read the login account name; no home directory is resolved.
        guard let user = getpwuid(getuid()), let name = user.pointee.pw_name else { return nil }
        let account = String(cString: name)
        return valid(account) ? account : nil
    }

    public static func valid(_ account: String) -> Bool {
        !account.isEmpty && account.lowercased() != "unknown"
    }
}
