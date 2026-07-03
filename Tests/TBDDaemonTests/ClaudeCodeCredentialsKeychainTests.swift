import Foundation
import Testing
@testable import TBDDaemonLib

/// Recorder stub — captures requested service names without touching the
/// real login keychain.
final class RecordingCredentialsKeychain: ClaudeCredentialsKeychainDeleting, @unchecked Sendable {
    private(set) var deletedServices: [String] = []
    var statusToReturn: OSStatus = errSecSuccess

    func deleteGenericPassword(service: String) -> OSStatus {
        deletedServices.append(service)
        return statusToReturn
    }
}

@Suite("ClaudeCodeCredentialsKeychain")
struct ClaudeCodeCredentialsKeychainTests {

    // MARK: - Suffix computation

    @Test("known vector: sha256 of zadam profile path starts with db64a81f")
    func knownVector() {
        let path = "/Users/zionts/.claude-profiles/zadam"
        #expect(ClaudeCodeCredentialsKeychain.serviceSuffix(forConfigDirPath: path) == "db64a81f")
        #expect(
            ClaudeCodeCredentialsKeychain.serviceName(forConfigDirPath: path)
                == "Claude Code-credentials-db64a81f"
        )
    }

    @Test("suffix is always 8 lowercase hex chars")
    func suffixFormat() {
        for path in [
            "/Users/someone/tbd/profiles/abc123/claude",
            "",
            "relative/path",
            "/path/with spaces/and-Ünïcode",
        ] {
            let suffix = ClaudeCodeCredentialsKeychain.serviceSuffix(forConfigDirPath: path)
            #expect(suffix.count == 8)
            #expect(suffix.allSatisfy { "0123456789abcdef".contains($0) })
        }
    }

    @Test("different paths produce different suffixes")
    func suffixVariesByPath() {
        let a = ClaudeCodeCredentialsKeychain.serviceSuffix(forConfigDirPath: "/a")
        let b = ClaudeCodeCredentialsKeychain.serviceSuffix(forConfigDirPath: "/b")
        #expect(a != b)
    }

    // MARK: - Safety: never the bare item

    @Test("service name always carries a suffix — never the bare credentials item")
    func serviceNameNeverBare() {
        for path in ["", "/", "/Users/x/tbd/profiles/y/claude", "Claude Code-credentials"] {
            let name = ClaudeCodeCredentialsKeychain.serviceName(forConfigDirPath: path)
            #expect(name != ClaudeCodeCredentialsKeychain.baseServiceName)
            #expect(name.hasPrefix("Claude Code-credentials-"))
            #expect(name.count == "Claude Code-credentials-".count + 8)
        }
    }

    // MARK: - deleteCredentials(forConfigDirPath:)

    @Test("deleteCredentials requests the derived, suffixed service name")
    func deleteRequestsDerivedServiceName() {
        let recorder = RecordingCredentialsKeychain()
        let path = "/Users/zionts/.claude-profiles/zadam"
        let status = recorder.deleteCredentials(forConfigDirPath: path)
        #expect(status == errSecSuccess)
        #expect(recorder.deletedServices == ["Claude Code-credentials-db64a81f"])
    }
}
