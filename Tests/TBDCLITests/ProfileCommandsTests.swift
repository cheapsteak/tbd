import ArgumentParser
import Foundation
import Testing
import TBDShared

@testable import TBDCLI

@Suite("ProfileCommands")
struct ProfileCommandsTests {

    private func entry(
        name: String,
        kind: CredentialKind = .oauth,
        loginIdentity: String? = nil,
        id: UUID = UUID()
    ) -> ModelProfileWithUsage {
        let profile = ModelProfile(id: id, name: name, kind: kind)
        return ModelProfileWithUsage(profile: profile, loginIdentity: loginIdentity)
    }

    // MARK: - Identity column rendering

    @Test func identityCell_oauthLoggedIn_showsEmail() {
        #expect(profileIdentityCell(kind: .oauth, loginIdentity: "zadam@longeye.co") == "zadam@longeye.co")
    }

    @Test func identityCell_oauthNotLoggedIn_showsNeedsLogin() {
        #expect(profileIdentityCell(kind: .oauth, loginIdentity: nil) == "needs /login")
    }

    @Test func identityCell_oauthEmptyIdentity_showsNeedsLogin() {
        #expect(profileIdentityCell(kind: .oauth, loginIdentity: "") == "needs /login")
    }

    @Test func identityCell_apiKey_showsDash() {
        #expect(profileIdentityCell(kind: .apiKey, loginIdentity: nil) == "—")
    }

    @Test func identityCell_bedrock_showsDash() {
        // loginIdentity should never be set for non-oauth kinds, but even if a
        // daemon sent one, the column stays a dash.
        #expect(profileIdentityCell(kind: .bedrock, loginIdentity: "stray@example.com") == "—")
    }

    @Test func identityCell_tokenProfile_showsMaskedTail() {
        // Mirrors the app's `Token •••• <tail>` caption: no verifiable identity
        // exists for a setup token, but the tail tells two token profiles apart.
        #expect(profileIdentityCell(kind: .oauthToken, loginIdentity: nil, tokenTail: "4f2a")
            == "•••• 4f2a")
    }

    @Test func identityCell_tokenProfileWithoutTail_saysNoToken() {
        #expect(profileIdentityCell(kind: .oauthToken, loginIdentity: nil, tokenTail: nil)
            == "no token")
        #expect(profileIdentityCell(kind: .oauthToken, loginIdentity: nil, tokenTail: "")
            == "no token")
    }

    @Test func identityCell_tokenProfile_ignoresStrayLoginIdentity() {
        // A token profile has no /login identity; even if a daemon sent one the
        // column stays on the credential story.
        #expect(profileIdentityCell(kind: .oauthToken,
                                    loginIdentity: "stray@example.com",
                                    tokenTail: "4f2a") == "•••• 4f2a")
    }

    // MARK: - profile login refusal messages

    @Test func loginRefusal_tokenProfile_namesTheTokenAndTheRepair() {
        let message = profileLoginUnsupportedMessage(name: "work", kind: .oauthToken)
        #expect(message.contains("'work'"))
        #expect(message.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(message.contains("claude setup-token"))
        // Points at the affordance that actually exists (the app's Settings
        // pane); `tbd profile` has no token-replacement subcommand to name.
        #expect(message.contains("Replace token"))
        // The old copy attributed the wrong reason to token profiles.
        #expect(!message.contains("API-key profiles"))
        #expect(!message.contains("a oauthToken profile"))
    }

    @Test func loginRefusal_apiKey_keepsItsOwnReason() {
        let message = profileLoginUnsupportedMessage(name: "direct", kind: .apiKey)
        #expect(message.contains("API-key profiles carry their own key"))
        #expect(!message.contains("setup-token"))
    }

    @Test func loginRefusal_bedrock_keepsItsOwnReason() {
        let message = profileLoginUnsupportedMessage(name: "aws", kind: .bedrock)
        #expect(message.contains("AWS credentials"))
        #expect(!message.contains("setup-token"))
    }

    // MARK: - Usage age marker

    @Test func usageAgeMarker_freshOrUnknown_isNil() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(usageAgeMarker(fetchedAt: nil, now: now) == nil)
        #expect(usageAgeMarker(fetchedAt: now.addingTimeInterval(-299), now: now) == nil)
    }

    @Test func usageAgeMarker_formatsMinutesHoursDays() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(usageAgeMarker(fetchedAt: now.addingTimeInterval(-300), now: now) == "(updated 5m ago)")
        #expect(usageAgeMarker(fetchedAt: now.addingTimeInterval(-59 * 60), now: now) == "(updated 59m ago)")
        #expect(usageAgeMarker(fetchedAt: now.addingTimeInterval(-3 * 3600), now: now) == "(updated 3h ago)")
        #expect(usageAgeMarker(fetchedAt: now.addingTimeInterval(-49 * 3600), now: now) == "(updated 2d ago)")
    }

    // MARK: - Name resolution

    @Test func resolveProfile_exactName() throws {
        let profiles = [entry(name: "work"), entry(name: "personal")]
        let resolved = try resolveProfile(named: "personal", in: profiles)
        #expect(resolved.profile.name == "personal")
    }

    @Test func resolveProfile_exactNameWinsOverCaseInsensitive() throws {
        let profiles = [entry(name: "Work"), entry(name: "work")]
        let resolved = try resolveProfile(named: "work", in: profiles)
        #expect(resolved.profile.name == "work")
    }

    @Test func resolveProfile_uniqueCaseInsensitiveMatch() throws {
        let profiles = [entry(name: "Work"), entry(name: "personal")]
        let resolved = try resolveProfile(named: "WORK", in: profiles)
        #expect(resolved.profile.name == "Work")
    }

    @Test func resolveProfile_ambiguousCaseInsensitiveThrows() {
        let profiles = [entry(name: "Work"), entry(name: "work")]
        #expect(throws: CLIError.self) {
            _ = try resolveProfile(named: "WORK", in: profiles)
        }
    }

    @Test func resolveProfile_byUUID() throws {
        let id = UUID()
        let profiles = [entry(name: "work", id: id), entry(name: "personal")]
        let resolved = try resolveProfile(named: id.uuidString, in: profiles)
        #expect(resolved.profile.id == id)
    }

    @Test func resolveProfile_missingListsAvailableNames() {
        let profiles = [entry(name: "work"), entry(name: "personal")]
        do {
            _ = try resolveProfile(named: "nope", in: profiles)
            Issue.record("expected resolveProfile to throw")
        } catch {
            let message = "\(error)"
            #expect(message.contains("nope"))
            #expect(message.contains("personal"))
            #expect(message.contains("work"))
        }
    }

    @Test func resolveProfile_emptyListExplains() {
        do {
            _ = try resolveProfile(named: "work", in: [])
            Issue.record("expected resolveProfile to throw")
        } catch {
            #expect("\(error)".contains("No model profiles exist"))
        }
    }

    // MARK: - Login env scrubbing

    @Test func sanitizedLoginEnvironment_removesPoisonVarsKeepsRest() {
        let base = [
            "ANTHROPIC_API_KEY": "sk-ant-api03-xxx",
            "ANTHROPIC_AUTH_TOKEN": "token",
            "ANTHROPIC_BASE_URL": "http://localhost:8080",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "PATH": "/usr/bin",
            "HOME": "/Users/x",
        ]
        let sanitized = sanitizedLoginEnvironment(base: base)
        for key in loginPoisonEnvVars {
            #expect(sanitized[key] == nil, "expected \(key) to be scrubbed")
        }
        #expect(sanitized["PATH"] == "/usr/bin")
        #expect(sanitized["HOME"] == "/Users/x")
    }

    // MARK: - Executable lookup

    @Test func findExecutable_findsOnlyExecutableFiles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("tbd-find-exec-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let exec = dir.appendingPathComponent("claude")
        try Data("#!/bin/sh\n".utf8).write(to: exec)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)
        let plain = dir.appendingPathComponent("not-exec")
        try Data().write(to: plain)

        let searchPath = "/nonexistent-dir:\(dir.path)"
        #expect(findExecutable(named: "claude", searchPath: searchPath) == exec.path)
        #expect(findExecutable(named: "not-exec", searchPath: searchPath) == nil)
        #expect(findExecutable(named: "missing", searchPath: searchPath) == nil)
    }

    // MARK: - Command wiring

    @Test func profileCommandRegisteredOnRoot() {
        let names = TBDCommand.configuration.subcommands.map { String(describing: $0) }
        #expect(names.contains("ProfileCommand"))
    }

    @Test func subcommandsRegistered() {
        let names = ProfileCommand.configuration.subcommands.map { String(describing: $0) }
        #expect(names == ["ProfileList", "ProfileSetDefault", "ProfileLogin"])
    }

    @Test func setDefaultParsesClearFlag() throws {
        let cmd = try ProfileSetDefault.parse(["--clear"])
        #expect(cmd.clear)
        #expect(cmd.name == nil)
    }

    @Test func setDefaultParsesName() throws {
        let cmd = try ProfileSetDefault.parse(["work"])
        #expect(!cmd.clear)
        #expect(cmd.name == "work")
    }

    @Test func loginRequiresName() {
        #expect(throws: Error.self) {
            _ = try ProfileLogin.parse([])
        }
    }

    @Test func listParsesJSONFlag() throws {
        let cmd = try ProfileList.parse(["--json"])
        #expect(cmd.json)
    }
}
