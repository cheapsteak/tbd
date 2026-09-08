import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// A `ModelProxySupervisor` stand-in, so the spawn decision can be pinned
/// without a proxy process, a port, or a rendezvous directory.
///
/// It records what it was asked for — that is how the upstream-resolution tests
/// see which URL the route was minted against — and can be told to throw, which
/// is the "no live proxy" case a spawn must survive.
final class FakeModelProxySupervisor: ModelProxySupervising, @unchecked Sendable {
    struct Made: Sendable, Equatable {
        let terminalID: UUID
        let upstream: String
        let streamingEnabled: Bool
    }

    enum Failure: Error { case noProxy }

    /// Nil means `baseURL(for:)` answers nil — a proxy that went away between
    /// minting the route and naming its port.
    var port: Int?
    var throwsOnMakeRoute = false
    var token = "0123456789abcdef0123456789abcdef"
    var snapshot = ModelProxyCapabilitySnapshot.none

    private(set) var made: [Made] = []
    private(set) var retired: [String] = []
    var tokenForTerminal: String?

    init(port: Int? = 51_842) {
        self.port = port
    }

    func makeRoute(
        terminalID: UUID, upstream: String, streamingEnabled: Bool
    ) async throws -> ModelProxyRoute {
        if throwsOnMakeRoute { throw Failure.noProxy }
        made.append(Made(
            terminalID: terminalID, upstream: upstream, streamingEnabled: streamingEnabled))
        return ModelProxyRoute(
            token: token, terminalID: terminalID,
            upstream: upstream, streamingEnabled: streamingEnabled)
    }

    func baseURL(for route: ModelProxyRoute) async -> String? {
        guard let port else { return nil }
        return "http://127.0.0.1:\(port)/r/\(route.token)"
    }

    func retireRoute(token: String, terminalID: UUID) async { retired.append(token) }

    func routeToken(forTerminal terminalID: UUID) async -> String? { tokenForTerminal }

    func capabilitySnapshot() async -> ModelProxyCapabilitySnapshot { snapshot }
}

/// **What a holder spawn's environment becomes when the model proxy is on, and
/// every reason it stays exactly as it was.**
///
/// The governing rule is that a streaming nicety never blocks a spawn (spec,
/// "The daemon" → "Spawn"), so each refusal is asserted as *the caller's own
/// environment, unchanged* rather than as an error — a refusal that quietly
/// dropped a credential the session needed would be a far worse failure than no
/// proxy at all.
@Suite("Model proxy spawn env")
struct ModelProxySpawnEnvTests {
    private static let terminalID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    /// A distinctive stand-in for a credential the session cannot lose. Every
    /// refusal asserts it survives.
    private static let carriedEnv = ["EXAMPLE_CARRIED_SECRET": "placeholder-not-a-credential"]

    private func proxyOnConfig(streaming: Bool = true) -> Config {
        var config = Config()
        config.modelProxyEnabled = true
        config.transcriptStreamingEnabled = streaming
        return config
    }

    private func attach(
        config: Config,
        profileKind: CredentialKind? = .oauth,
        profileBaseURL: String? = nil,
        envOverrideBaseURL: String? = nil,
        overlaySetsBaseURL: Bool = false,
        sensitiveEnv: [String: String]? = nil,
        baseEnvironment: [String: String] = ["TBD_HOME": "/tmp/tbd-spawn-env-tests"],
        supervisor: (any ModelProxyRouting)?
    ) async -> ModelProxyRouteAttachment.Outcome {
        await ModelProxyRouteAttachment.attach(
            terminalID: Self.terminalID,
            config: config,
            profileKind: profileKind,
            profileBaseURL: profileBaseURL,
            envOverrideBaseURL: envOverrideBaseURL,
            overlaySetsBaseURL: overlaySetsBaseURL,
            sensitiveEnv: sensitiveEnv ?? Self.carriedEnv,
            baseEnvironment: baseEnvironment,
            supervisor: supervisor)
    }

    // MARK: - The routed spawn

    @Test("a proxied spawn gets the route's base URL, a loopback NO_PROXY, and a stream path")
    func routedSpawnCarriesTheRoute() async throws {
        let supervisor = FakeModelProxySupervisor(port: 51_842)
        let home = "/tmp/tbd-spawn-env-\(UUID().uuidString.prefix(8))"
        let outcome = await attach(
            config: proxyOnConfig(),
            baseEnvironment: ["TBD_HOME": home],
            supervisor: supervisor)

        let baseURL = try #require(outcome.sensitiveEnv["ANTHROPIC_BASE_URL"])
        #expect(baseURL == "http://127.0.0.1:51842/r/\(supervisor.token)")
        #expect(baseURL.contains(supervisor.token), "the base URL must name the route token")
        let noProxy = try #require(outcome.sensitiveEnv["NO_PROXY"])
        #expect(noProxy.split(separator: ",").contains("127.0.0.1"))
        #expect(outcome.streamPath == "\(home)/streams/\(Self.terminalID.uuidString).jsonl")
        #expect(outcome.token == supervisor.token, "the outcome must name the route it minted")
        // Nothing the caller was carrying may be lost on the way through.
        #expect(outcome.sensitiveEnv["EXAMPLE_CARRIED_SECRET"]
            == Self.carriedEnv["EXAMPLE_CARRIED_SECRET"])
    }

    /// The route carries the *effective* streaming flag, not the raw column: a
    /// hand-edited row with streaming on and the proxy off streams nothing, and
    /// a route may not describe that state.
    @Test("the route carries the effective streaming flag, not the raw column")
    func routeCarriesEffectiveStreaming() async throws {
        let on = FakeModelProxySupervisor()
        _ = await attach(config: proxyOnConfig(streaming: true), supervisor: on)
        #expect(on.made.first?.streamingEnabled == true)

        let off = FakeModelProxySupervisor()
        _ = await attach(config: proxyOnConfig(streaming: false), supervisor: off)
        #expect(off.made.first?.streamingEnabled == false)
    }

    // MARK: - Upstream resolution

    @Test("the profile's base URL becomes the route's upstream")
    func profileBaseURLIsTheUpstream() async throws {
        let supervisor = FakeModelProxySupervisor()
        _ = await attach(
            config: proxyOnConfig(),
            profileBaseURL: "https://gateway.acme.example",
            envOverrideBaseURL: "https://override.acme.example",
            supervisor: supervisor)
        #expect(supervisor.made.first?.upstream == "https://gateway.acme.example")
    }

    @Test("an env-override base URL is the upstream when the profile names none")
    func envOverrideBaseURLIsTheUpstream() async throws {
        let supervisor = FakeModelProxySupervisor()
        _ = await attach(
            config: proxyOnConfig(),
            profileBaseURL: nil,
            envOverrideBaseURL: "https://override.acme.example",
            supervisor: supervisor)
        #expect(supervisor.made.first?.upstream == "https://override.acme.example")
    }

    @Test("with neither, the upstream is the public API")
    func defaultUpstream() async throws {
        let supervisor = FakeModelProxySupervisor()
        _ = await attach(config: proxyOnConfig(), supervisor: supervisor)
        #expect(supervisor.made.first?.upstream == "https://api.anthropic.com")
    }

    /// A profile whose base URL is present but empty must fall through rather
    /// than become an upstream nothing can connect to.
    @Test("an empty profile base URL falls through to the next source")
    func emptyProfileBaseURLFallsThrough() async throws {
        let supervisor = FakeModelProxySupervisor()
        _ = await attach(
            config: proxyOnConfig(),
            profileBaseURL: "   ",
            envOverrideBaseURL: "https://override.acme.example",
            supervisor: supervisor)
        #expect(supervisor.made.first?.upstream == "https://override.acme.example")
    }

    // MARK: - Every reason a spawn stays unproxied

    @Test("the flag off leaves the environment untouched")
    func flagOffIsUnchanged() async throws {
        let supervisor = FakeModelProxySupervisor()
        let outcome = await attach(config: Config(), supervisor: supervisor)
        #expect(outcome.sensitiveEnv == Self.carriedEnv)
        #expect(outcome.streamPath == nil)
        #expect(outcome.token == nil)
        #expect(supervisor.made.isEmpty, "a disabled flag must not mint a route")
    }

    @Test("a Bedrock profile is never routed")
    func bedrockIsUnchanged() async throws {
        let supervisor = FakeModelProxySupervisor()
        let outcome = await attach(
            config: proxyOnConfig(), profileKind: .bedrock, supervisor: supervisor)
        #expect(outcome.sensitiveEnv == Self.carriedEnv)
        #expect(outcome.streamPath == nil)
        #expect(supervisor.made.isEmpty)
    }

    @Test("no supervisor leaves the environment untouched")
    func noSupervisorIsUnchanged() async throws {
        let outcome = await attach(config: proxyOnConfig(), supervisor: nil)
        #expect(outcome.sensitiveEnv == Self.carriedEnv)
        #expect(outcome.streamPath == nil)
    }

    /// Claude Code applies `settings.json`'s `env` after the process
    /// environment, so a base URL there wins and the session would talk to the
    /// user's endpoint while TBD believed it was proxied.
    @Test("a settings overlay that sets ANTHROPIC_BASE_URL is not fought")
    func overlayBaseURLIsUnchanged() async throws {
        let supervisor = FakeModelProxySupervisor()
        let outcome = await attach(
            config: proxyOnConfig(), overlaySetsBaseURL: true, supervisor: supervisor)
        #expect(outcome.sensitiveEnv == Self.carriedEnv)
        #expect(outcome.streamPath == nil)
        #expect(supervisor.made.isEmpty, "a route must not be minted for a session that ignores it")
    }

    @Test("a supervisor that cannot mint a route spawns unproxied")
    func makeRouteThrowingIsUnchanged() async throws {
        let supervisor = FakeModelProxySupervisor()
        supervisor.throwsOnMakeRoute = true
        let outcome = await attach(config: proxyOnConfig(), supervisor: supervisor)
        #expect(outcome.sensitiveEnv == Self.carriedEnv)
        #expect(outcome.streamPath == nil)
    }

    /// The proxy went away between minting the route and naming its port. The
    /// spawn proceeds unproxied AND the route it will never use is retired,
    /// because nothing else names it: no row carries it, and no session will.
    @Test("a route with no port to name is retired rather than left behind")
    func routeWithNoPortIsRetired() async throws {
        let supervisor = FakeModelProxySupervisor(port: nil)
        let outcome = await attach(config: proxyOnConfig(), supervisor: supervisor)
        #expect(outcome.sensitiveEnv == Self.carriedEnv)
        #expect(outcome.streamPath == nil)
        #expect(supervisor.retired == [supervisor.token])
    }

    // MARK: - NO_PROXY

    @Test("NO_PROXY extends an existing list without reordering or duplicating it")
    func noProxyExtends() {
        #expect(ModelProxyEnv.noProxy(extending: "corp.example")
            == "corp.example,127.0.0.1,localhost")
        #expect(ModelProxyEnv.noProxy(extending: nil) == "127.0.0.1,localhost")
        #expect(ModelProxyEnv.noProxy(extending: "") == "127.0.0.1,localhost")
    }

    /// A wake re-derives the whole environment from the same overrides the
    /// create path used, so a non-idempotent merge would grow the variable by
    /// two entries per park/wake cycle.
    @Test("NO_PROXY is idempotent")
    func noProxyIsIdempotent() {
        let once = ModelProxyEnv.noProxy(extending: "corp.example")
        #expect(ModelProxyEnv.noProxy(extending: once) == once)
        #expect(ModelProxyEnv.noProxy(extending: "127.0.0.1,corp.example")
            == "127.0.0.1,corp.example,localhost")
        #expect(ModelProxyEnv.noProxy(extending: " corp.example , localhost ")
            == "corp.example,localhost,127.0.0.1")
    }

    /// The session's own `NO_PROXY` — an env override the user set — outranks
    /// the daemon's, because it is the value that would otherwise have reached
    /// the session.
    @Test("NO_PROXY extends the session's own value ahead of the daemon's")
    func noProxyPrefersTheSessionValue() async throws {
        let outcome = await attach(
            config: proxyOnConfig(),
            sensitiveEnv: ["NO_PROXY": "session.example"],
            baseEnvironment: ["TBD_HOME": "/tmp/tbd-x", "NO_PROXY": "daemon.example"],
            supervisor: FakeModelProxySupervisor())
        #expect(outcome.sensitiveEnv["NO_PROXY"] == "session.example,127.0.0.1,localhost")
    }

    @Test("NO_PROXY falls back to the daemon's own value")
    func noProxyFallsBackToTheDaemonValue() async throws {
        let outcome = await attach(
            config: proxyOnConfig(),
            baseEnvironment: ["TBD_HOME": "/tmp/tbd-x", "NO_PROXY": "daemon.example"],
            supervisor: FakeModelProxySupervisor())
        #expect(outcome.sensitiveEnv["NO_PROXY"] == "daemon.example,127.0.0.1,localhost")
    }

    // MARK: - The token never reaches argv

    /// **The rule the whole `sensitiveEnv` routing exists for.** A route token
    /// is a bearer credential for this session's upstream, and `holderLaunch`
    /// inlines `env` as `export K='v';` in front of the command — which lands
    /// in the job's argv, where one `ps -ww` reads it. This composes the launch
    /// exactly as `WorktreeLifecycle+Create` does and asserts both halves.
    @Test("the route token reaches the job's environment and never its command line")
    func tokenTravelsInTheEnvironmentOnly() async throws {
        let supervisor = FakeModelProxySupervisor(port: 51_842)
        let outcome = await attach(config: proxyOnConfig(), supervisor: supervisor)

        let launch = WorktreeLifecycle.holderLaunch(
            shellCommand: "claude --session-id \(Self.terminalID.uuidString)",
            env: [
                "TBD_WORKTREE_ID": UUID().uuidString,
                "TBD_TERMINAL_ID": Self.terminalID.uuidString,
            ],
            sensitiveEnv: outcome.sensitiveEnv,
            workingDirectory: "/tmp/a-worktree",
            cols: 120,
            rows: 40,
            environment: ["SHELL": "/bin/zsh"])

        #expect(launch.environment["ANTHROPIC_BASE_URL"]?.contains(supervisor.token) == true)
        let commandLine = ([launch.executable] + launch.arguments).joined(separator: " ")
        #expect(
            !commandLine.contains(supervisor.token),
            """
            the route token reached the holder's command line, where `ps` shows it to every \
            process running as this user: \(commandLine)
            """)
        #expect(!commandLine.contains("ANTHROPIC_BASE_URL"))
        #expect(!commandLine.contains("NO_PROXY"))
    }
}

/// `ClaudeHookOverlay.overlaySetsEnv` — the read that decides whether a route
/// can be honored at all.
@Suite("Model proxy overlay base URL detection")
struct ModelProxyOverlayEnvTests {
    private func withOverlay(
        _ json: String, _ body: (String) throws -> Void
    ) throws {
        let dir = fencedScratchRoot(prefix: "tbd-overlay-env")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/settings.json"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        try body(path)
    }

    @Test("an overlay whose env sets the key is detected")
    func detectsTheKey() throws {
        try withOverlay(#"{"env": {"ANTHROPIC_BASE_URL": "https://gateway.acme.example"}}"#) {
            #expect(ClaudeHookOverlay.overlaySetsEnv("ANTHROPIC_BASE_URL", overlayPath: $0))
        }
    }

    @Test("an overlay with an env block that does not set the key answers false")
    func otherKeysDoNotCount() throws {
        try withOverlay(#"{"env": {"ANTHROPIC_MODEL": "a-model"}}"#) {
            #expect(!ClaudeHookOverlay.overlaySetsEnv("ANTHROPIC_BASE_URL", overlayPath: $0))
        }
    }

    /// Only the TOP-LEVEL `env` object decides: Claude Code reads no other one,
    /// so a key nested somewhere else must not refuse a spawn a route.
    @Test("a key outside the top-level env object does not count")
    func nestedKeysDoNotCount() throws {
        try withOverlay(#"{"hooks": {"env": {"ANTHROPIC_BASE_URL": "https://x.example"}}}"#) {
            #expect(!ClaudeHookOverlay.overlaySetsEnv("ANTHROPIC_BASE_URL", overlayPath: $0))
        }
    }

    @Test("no overlay, a missing file, and bytes that are not JSON all answer false")
    func absenceAnswersFalse() throws {
        #expect(!ClaudeHookOverlay.overlaySetsEnv("ANTHROPIC_BASE_URL", overlayPath: nil))
        #expect(!ClaudeHookOverlay.overlaySetsEnv(
            "ANTHROPIC_BASE_URL", overlayPath: "/nonexistent/tbd/settings.json"))
        try withOverlay("not json at all") {
            #expect(!ClaudeHookOverlay.overlaySetsEnv("ANTHROPIC_BASE_URL", overlayPath: $0))
        }
    }
}
