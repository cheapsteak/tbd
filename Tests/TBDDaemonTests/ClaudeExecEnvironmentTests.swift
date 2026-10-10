import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// `ClaudeSpawnCommandBuilder.execEnvironment`, the environment
/// `tbd profile exec` gives its child, held against the environment a spawned
/// session gets from the same profile.
@Suite("ClaudeSpawnCommandBuilder.execEnvironment")
struct ClaudeExecEnvironmentTests {

    private static let secret = "sk-ant-oat01-fake"

    /// One profile of each kind with every field set, so a key any kind can
    /// produce shows up in at least one of them.
    private struct Profile {
        let kind: CredentialKind
        let secret: String?
        let baseURL: String?
        let model: String?
        let awsRegion: String?
        let awsProfile: String?
        let configDir: String?
    }

    private static let everyKind: [Profile] = [
        Profile(kind: .oauth, secret: nil, baseURL: "https://models.acme.example",
                model: "claude-sonnet-4-5", awsRegion: nil, awsProfile: nil,
                configDir: "/profiles/oauth/claude"),
        Profile(kind: .oauthToken, secret: secret, baseURL: "https://models.acme.example",
                model: "claude-sonnet-4-5", awsRegion: nil, awsProfile: nil,
                configDir: "/profiles/token/claude"),
        Profile(kind: .apiKey, secret: "sk-ant-api03-fake", baseURL: "https://models.acme.example",
                model: "claude-sonnet-4-5", awsRegion: nil, awsProfile: nil,
                configDir: "/profiles/key/claude"),
        Profile(kind: .bedrock, secret: nil, baseURL: nil,
                model: "anthropic.claude-sonnet-4-5", awsRegion: "us-west-2",
                awsProfile: "acme-prod", configDir: nil),
    ]

    private func exec(_ p: Profile, envOverrides: [String: String] = [:]) -> [String: String] {
        ClaudeSpawnCommandBuilder.execEnvironment(
            profileSecret: p.secret,
            profileKind: p.kind,
            profileBaseURL: p.baseURL,
            profileModel: p.model,
            profileAwsRegion: p.awsRegion,
            profileAwsProfile: p.awsProfile,
            profileConfigDir: p.configDir,
            envOverrides: envOverrides
        )
    }

    private func spawn(_ p: Profile) -> ClaudeSpawnCommandBuilder.Result {
        ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: p.secret,
            profileKind: p.kind,
            profileBaseURL: p.baseURL,
            profileModel: p.model,
            profileAwsRegion: p.awsRegion,
            profileAwsProfile: p.awsProfile,
            profileConfigDir: p.configDir,
            cmd: nil,
            shellFallback: ""
        )
    }

    @Test("for every kind, exec gets exactly what a spawned session gets from its profile")
    func matchesSpawnForEveryKind() {
        // What a spawn adds for its terminal rather than its profile.
        let terminalOnly = Set(ClaudeEnvRegistry.all.map(\.envVar)).union(["DISABLE_AUTO_UPDATE"])
        for p in Self.everyKind {
            let fromSpawn = spawn(p).sensitiveEnv.filter { !terminalOnly.contains($0.key) }
            #expect(exec(p) == fromSpawn, "kind \(p.kind.rawValue)")
        }
    }

    @Test("a token profile gets its token under CLAUDE_CODE_OAUTH_TOKEN, beside its config dir")
    func tokenProfile() {
        let p = Self.everyKind[1]
        #expect(exec(p) == [
            "CLAUDE_CODE_OAUTH_TOKEN": Self.secret,
            "CLAUDE_CONFIG_DIR": "/profiles/token/claude",
            "ANTHROPIC_BASE_URL": "https://models.acme.example",
            "ANTHROPIC_MODEL": "claude-sonnet-4-5",
        ])
    }

    @Test("a signed-in profile never gets a token, even a stray one")
    func signedInProfileIgnoresStraySecret() {
        let env = ClaudeSpawnCommandBuilder.execEnvironment(
            profileSecret: Self.secret, profileKind: .oauth,
            profileConfigDir: "/profiles/oauth/claude")
        #expect(env == ["CLAUDE_CONFIG_DIR": "/profiles/oauth/claude"])
    }

    @Test("overrides fill in around the profile and never replace its keys")
    func overridesSitUnderTheProfile() {
        let p = Self.everyKind[1]
        let env = exec(p, envOverrides: [
            "EXTRA": "1",
            "CLAUDE_CODE_OAUTH_TOKEN": "override",
            "CLAUDE_CONFIG_DIR": "/override",
        ])
        #expect(env["EXTRA"] == "1")
        #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == Self.secret)
        #expect(env["CLAUDE_CONFIG_DIR"] == "/profiles/token/claude")
    }

    @Test("profileKeys is exactly what the builder can produce, less the general-purpose AWS settings")
    func profileKeysMatchTheBuilderVocabulary() {
        // The keys any profile kind can put in an exec environment.
        let produced = Self.everyKind.reduce(into: Set<String>()) { keys, p in
            keys.formUnion(exec(p).keys)
        }
        #expect(ProfileExecEnvironment.profileKeys == produced.subtracting(["AWS_REGION", "AWS_PROFILE"]))
    }

    @Test("the other selectors are ones no profile sets, and the CLI clears both groups")
    func otherSelectorsAreDisjointFromTheProfile() {
        let produced = Self.everyKind.reduce(into: Set<String>()) { keys, p in
            keys.formUnion(exec(p).keys)
        }
        #expect(ProfileExecEnvironment.otherSelectors.isDisjoint(with: produced))
        #expect(ProfileExecEnvironment.clearedKeys
            == ProfileExecEnvironment.profileKeys.union(ProfileExecEnvironment.otherSelectors))
    }
}
