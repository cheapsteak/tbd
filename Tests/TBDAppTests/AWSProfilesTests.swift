import Foundation
import Testing
@testable import TBDApp

@Suite("AWSProfiles parser")
struct AWSProfilesTests {

    private func writeTempFile(_ contents: String) throws -> String {
        let dir = NSTemporaryDirectory()
        let path = "\(dir)aws-profiles-test-\(UUID().uuidString)"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("config: recognizes [default] and [profile NAME]")
    func configDefaultAndProfile() throws {
        let path = try writeTempFile("""
        [default]
        region = us-east-1
        [profile acme-prod]
        sso_session = main
        [profile acme-staging]
        region = us-west-2
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let names = AWSProfiles.parseConfig(at: path)
        #expect(names == ["default", "acme-prod", "acme-staging"])
    }

    @Test("config: skips [sso-session], [services], [plugins]")
    func configSkipsNonProfileSections() throws {
        let path = try writeTempFile("""
        [profile real]
        region = us-west-2
        [sso-session main]
        sso_start_url = https://example.com
        [services my-services]
        s3 =
        [plugins endpoint]
        cli_legacy_plugin_path = /tmp
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let names = AWSProfiles.parseConfig(at: path)
        #expect(names == ["real"])
    }

    @Test("credentials: every [NAME] is a profile")
    func credentialsAllSections() throws {
        let path = try writeTempFile("""
        [default]
        aws_access_key_id = AKIA000
        [acme-prod]
        aws_secret_access_key = secret
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let names = AWSProfiles.parseCredentials(at: path)
        #expect(names == ["default", "acme-prod"])
    }

    @Test("discover: union of config + credentials, sorted + deduped")
    func discoverUnion() throws {
        let cfg = try writeTempFile("""
        [default]
        [profile production]
        """)
        let creds = try writeTempFile("""
        [default]
        [staging]
        """)
        defer {
            try? FileManager.default.removeItem(atPath: cfg)
            try? FileManager.default.removeItem(atPath: creds)
        }

        let names = AWSProfiles.discover(configPath: cfg, credentialsPath: creds)
        #expect(names == ["default", "production", "staging"])
    }

    @Test("discover: missing files return empty list")
    func discoverMissingFiles() {
        let names = AWSProfiles.discover(
            configPath: "/tmp/definitely-does-not-exist-\(UUID().uuidString)",
            credentialsPath: "/tmp/also-does-not-exist-\(UUID().uuidString)"
        )
        #expect(names.isEmpty)
    }

    @Test("config: handles whitespace inside brackets")
    func configWhitespace() throws {
        let path = try writeTempFile("""
        [ default ]
        [profile  spaced-name  ]
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let names = AWSProfiles.parseConfig(at: path)
        #expect(names == ["default", "spaced-name"])
    }
}
