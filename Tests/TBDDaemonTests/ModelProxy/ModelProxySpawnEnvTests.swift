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

    /// How many times the terminal-id lookup was made. It is a directory
    /// listing that decodes every route file in production, so a teardown that
    /// can prove there is nothing to find must not make it at all — counting is
    /// the only way to see the difference between "skipped" and "found
    /// nothing".
    private(set) var tokenLookups = 0

    func routeToken(forTerminal terminalID: UUID) async -> String? {
        tokenLookups += 1
        return tokenForTerminal
    }

    func capabilitySnapshot() async -> ModelProxyCapabilitySnapshot { snapshot }

    /// The runtime flag's two gestures, recorded rather than performed: the
    /// config RPC's whole job is to make exactly one of these calls, and
    /// counting them is how that is checked without a proxy process.
    private(set) var startCalls = 0
    private(set) var drainCalls = 0

    func startIfEnabled() async { startCalls += 1 }
    func beginDraining() async { drainCalls += 1 }
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

    /// The `TBD_HOME` every path in this suite is composed against.
    ///
    /// Under the wrapper's scratch root rather than a shared `/tmp` name.
    /// Nothing writes through these dictionaries today — the supervisor is a
    /// fake and `streamFilePath` is a pure computation — but the name would be
    /// shared with every concurrently running worktree, and the first assertion
    /// that did write would escape the fence. Every other suite here derives
    /// its root this way.
    private static let fencedHome = fencedScratchRoot(prefix: "tbdmpse")

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
        baseEnvironment: [String: String] =
            ["TBD_HOME": ModelProxySpawnEnvTests.fencedHome],
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
        let home = fencedScratchRoot(prefix: "tbdmpse")
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

    // MARK: - The gate both spawn sites share

    /// `attachIfRoutable` is the create path's and the wake path's whole
    /// routing decision, gate included, so each half of that gate needs its own
    /// case: a third spawn site gets these refusals by calling one function
    /// instead of copying four steps and losing one.
    @Test("a tmux spawn is never routed")
    func routableRefusesATmuxSpawn() async throws {
        let supervisor = FakeModelProxySupervisor()
        let outcome = await ModelProxyRouteAttachment.attachIfRoutable(
            terminalID: Self.terminalID, isHolderSpawn: false, config: proxyOnConfig(),
            profileKind: .oauth, profileBaseURL: nil, envOverrides: Self.carriedEnv,
            overlayPath: nil, holderEnvironment: ["TBD_HOME": Self.fencedHome],
            supervisor: supervisor)

        #expect(outcome.routed == false)
        #expect(outcome.sensitiveEnv == Self.carriedEnv)
        #expect(supervisor.made.isEmpty)
    }

    @Test("a daemon with no holder registry routes nothing")
    func routableRefusesWithoutARegistry() async throws {
        let supervisor = FakeModelProxySupervisor()
        let outcome = await ModelProxyRouteAttachment.attachIfRoutable(
            terminalID: Self.terminalID, isHolderSpawn: true, config: proxyOnConfig(),
            profileKind: .oauth, profileBaseURL: nil, envOverrides: Self.carriedEnv,
            overlayPath: nil, holderEnvironment: nil, supervisor: supervisor)

        #expect(outcome.routed == false)
        #expect(outcome.sensitiveEnv == Self.carriedEnv)
        #expect(supervisor.made.isEmpty)
    }

    /// A config that could not be read is not a state in which a route may be
    /// minted: the flag is the whole gate and an unreadable one is off.
    @Test("a config that could not be read routes nothing")
    func routableRefusesWithoutAConfig() async throws {
        let supervisor = FakeModelProxySupervisor()
        let outcome = await ModelProxyRouteAttachment.attachIfRoutable(
            terminalID: Self.terminalID, isHolderSpawn: true, config: nil,
            profileKind: .oauth, profileBaseURL: nil, envOverrides: Self.carriedEnv,
            overlayPath: nil, holderEnvironment: ["TBD_HOME": Self.fencedHome],
            supervisor: supervisor)

        #expect(outcome.routed == false)
        #expect(supervisor.made.isEmpty)
    }

    /// The positive half, with the three inputs above at the values every
    /// refusal changes exactly one of: a holder spawn, a config with the flag
    /// on, and a registry environment. The env-override base URL and the
    /// stream path prove the caller's overrides really did reach `attach`.
    @Test("a holder spawn with the flag on and a registry is routed")
    func routableRoutesAHolderSpawn() async throws {
        let supervisor = FakeModelProxySupervisor(port: 51_842)
        let home = fencedScratchRoot(prefix: "tbdmpse")
        let outcome = await ModelProxyRouteAttachment.attachIfRoutable(
            terminalID: Self.terminalID, isHolderSpawn: true, config: proxyOnConfig(),
            profileKind: .oauth, profileBaseURL: nil,
            envOverrides: Self.carriedEnv.merging(
                ["ANTHROPIC_BASE_URL": "https://override.acme.example"]) { _, new in new },
            overlayPath: nil, holderEnvironment: ["TBD_HOME": home], supervisor: supervisor)

        #expect(outcome.routed)
        #expect(outcome.sensitiveEnv["ANTHROPIC_BASE_URL"]
            == "http://127.0.0.1:51842/r/\(supervisor.token)")
        #expect(
            supervisor.made.first?.upstream == "https://override.acme.example",
            "the caller's overrides are where the env-override upstream comes from")
        #expect(outcome.streamPath == "\(home)/streams/\(Self.terminalID.uuidString).jsonl")
        #expect(outcome.sensitiveEnv["EXAMPLE_CARRIED_SECRET"]
            == Self.carriedEnv["EXAMPLE_CARRIED_SECRET"])
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
            baseEnvironment: [
                "TBD_HOME": Self.fencedHome, "NO_PROXY": "daemon.example",
            ],
            supervisor: FakeModelProxySupervisor())
        #expect(outcome.sensitiveEnv["NO_PROXY"] == "session.example,127.0.0.1,localhost")
    }

    @Test("NO_PROXY falls back to the daemon's own value")
    func noProxyFallsBackToTheDaemonValue() async throws {
        let outcome = await attach(
            config: proxyOnConfig(),
            baseEnvironment: [
                "TBD_HOME": Self.fencedHome, "NO_PROXY": "daemon.example",
            ],
            supervisor: FakeModelProxySupervisor())
        #expect(outcome.sensitiveEnv["NO_PROXY"] == "daemon.example,127.0.0.1,localhost")
    }

    // MARK: - The composed spawn

    /// The profile endpoint a routed spawn must NOT be sent to. Distinctive so
    /// an assertion can name it, and an `.example` host so nothing can resolve
    /// it if a defect ever let a real request out.
    private static let profileBaseURL = "https://gateway.acme.example"

    /// Composes the primary spawn the way `WorktreeLifecycle+Create` composes
    /// it — `attach`, then a **real** `ClaudeSpawnCommandBuilder.build` with the
    /// base URL the routing decision leaves it, then the same merge and the same
    /// `holderLaunch` — and answers with what the job would actually run.
    ///
    /// A helper rather than three copies because the two assertions below differ
    /// in one input (whether the proxy is on) and must not be able to drift
    /// apart anywhere else.
    private func composeSpawn(
        config: Config, supervisor: (any ModelProxyRouting)?
    ) async -> (launch: HolderLaunchRequest, attachment: ModelProxyRouteAttachment.Outcome) {
        let attachment = await attach(
            config: config,
            profileBaseURL: Self.profileBaseURL,
            sensitiveEnv: Self.carriedEnv,
            supervisor: supervisor)
        let spawn = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: Self.terminalID.uuidString,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            profileKind: .oauth,
            // The production seam, not a paraphrase of it: both spawn sites
            // call exactly this.
            profileBaseURL: attachment.builderBaseURL(profile: Self.profileBaseURL),
            profileConfigDir: "/tmp/a-profile-dir",
            cmd: nil,
            shellFallback: "/bin/zsh",
            fileExists: { _ in false })
        let sensitiveEnv = attachment.sensitiveEnv
            .merging(spawn.sensitiveEnv) { _, builder in builder }
        let launch = WorktreeLifecycle.holderLaunch(
            shellCommand: spawn.command,
            env: [
                "TBD_WORKTREE_ID": UUID().uuidString,
                "TBD_TERMINAL_ID": Self.terminalID.uuidString,
            ],
            sensitiveEnv: sensitiveEnv,
            workingDirectory: "/tmp/a-worktree",
            cols: 120,
            rows: 40,
            environment: ["SHELL": "/bin/zsh"])
        return (launch, attachment)
    }

    private func commandLine(_ launch: HolderLaunchRequest) -> String {
        ([launch.executable] + launch.arguments).joined(separator: " ")
    }

    /// **The defect this pins.** `build` re-exports every profile routing key
    /// inline into the command string, and those exports run AFTER the process
    /// environment is applied — so a profile with its own `ANTHROPIC_BASE_URL`
    /// used to clobber the route's, and the session went straight to the
    /// profile endpoint while the row recorded a stream file that never filled.
    /// Deciding routing before `build` is what keeps one endpoint in play: the
    /// composed spawn names the proxy, in the environment and in the export,
    /// and the profile's endpoint nowhere at all.
    @Test("a routed spawn carries the proxy base URL, and the profile's endpoint nowhere")
    func routedSpawnIsNotClobberedByTheProfileEndpoint() async throws {
        let supervisor = FakeModelProxySupervisor(port: 51_842)
        let (launch, attachment) = await composeSpawn(
            config: proxyOnConfig(), supervisor: supervisor)

        #expect(attachment.routed, "the fixture must route, or this proves nothing")
        // The route was minted against the profile's endpoint: it survives as
        // the upstream and only as the upstream.
        #expect(supervisor.made.first?.upstream == Self.profileBaseURL)

        let proxyURL = "http://127.0.0.1:51842/r/\(supervisor.token)"
        #expect(launch.environment["ANTHROPIC_BASE_URL"] == proxyURL)
        #expect(launch.environment["ANTHROPIC_BASE_URL"] != Self.profileBaseURL)

        let command = commandLine(launch)
        #expect(
            !command.contains(Self.profileBaseURL),
            "the profile endpoint reached the command line of a routed spawn: \(command)")
    }

    /// **The rc-file defence, in the direction that matters now.** The inline
    /// export runs after the shell's startup files, so it is what a user whose
    /// `.zshrc` sets `ANTHROPIC_BASE_URL` would otherwise lose the route to. A
    /// routed spawn must export the *proxy* URL there — the same value the
    /// process environment carries, from the same field, so the two cannot
    /// drift.
    @Test("a routed spawn exports the proxy URL inline, so an rc file cannot take the route away")
    func routedSpawnDefendsItsRouteAgainstRCFiles() async throws {
        let supervisor = FakeModelProxySupervisor(port: 51_842)
        let (launch, _) = await composeSpawn(
            config: proxyOnConfig(), supervisor: supervisor)

        let command = commandLine(launch)
        let proxyURL = "http://127.0.0.1:51842/r/\(supervisor.token)"
        #expect(
            command.contains("export ANTHROPIC_BASE_URL="),
            "a routed spawn must re-export its endpoint after the rc files: \(command)")
        #expect(
            command.contains(proxyURL),
            "the inline export names something other than the route: \(command)")

        // **Positional, and this is the half that says the export *wins*.**
        // The builder prefixes its inline exports to the `claude` invocation,
        // and the shell evaluates the whole command string only after its
        // startup files — so an export that sits before the invocation runs
        // after every rc file and before the agent starts, which is the one
        // ordering an rc file cannot get in front of. Simulating a competing rc
        // file for real would mean running an interactive shell and reading
        // what it resolved, which is a live test rather than this one; what is
        // assertable here is the position that makes the outcome inevitable.
        let exportRange = try #require(
            command.range(of: "export ANTHROPIC_BASE_URL="),
            "the routed spawn exports no base URL at all: \(command)")
        let invocationRange = try #require(
            command.range(of: "claude --session-id"),
            "the composed command does not invoke claude: \(command)")
        #expect(
            exportRange.upperBound <= invocationRange.lowerBound,
            "the route export must precede the agent it is exported for: \(command)")

        #expect(launch.environment["ANTHROPIC_BASE_URL"] == proxyURL)
        // `NO_PROXY` is not one of the builder's routing keys and must stay out
        // of the command line: it rides the process environment alone.
        #expect(!command.contains("NO_PROXY"))
    }

    /// The wake path composes its spawn inside `HibernationCoordinator`, behind
    /// a parked row, a resolved profile, a holder registry and an actor, so this
    /// suite cannot drive it end to end. What it CAN pin is the one expression
    /// the two sites share — the seam both of them call to decide what the
    /// builder is told — so a wake that regressed to passing the profile's URL
    /// would have to do it by not calling this at all.
    @Test("the builder is told the route's endpoint, not the profile's, once a route is in play")
    func builderBaseURLDropsTheProfileEndpointWhenRouted() async throws {
        let supervisor = FakeModelProxySupervisor(port: 51_842)
        let routed = await attach(
            config: proxyOnConfig(),
            profileBaseURL: Self.profileBaseURL,
            supervisor: supervisor)
        #expect(routed.routed)
        #expect(
            routed.builderBaseURL(profile: Self.profileBaseURL)
                == "http://127.0.0.1:51842/r/\(supervisor.token)",
            "a routed spawn must hand the builder the route's own URL")

        // Every unrouted outcome hands the profile's URL straight through.
        let refused = await attach(
            config: Config(),
            profileBaseURL: Self.profileBaseURL,
            supervisor: FakeModelProxySupervisor(port: 51_842))
        #expect(!refused.routed)
        #expect(refused.builderBaseURL(profile: Self.profileBaseURL) == Self.profileBaseURL)
        #expect(
            ModelProxyRouteAttachment.Outcome.unproxied([:])
                .builderBaseURL(profile: nil) == nil)
    }

    /// The discriminating half: with the proxy off, the profile's endpoint must
    /// still reach the session both ways it always did — in the environment and
    /// as the inline export that outranks an rc file. Without this, a fix that
    /// dropped the profile URL unconditionally would pass the test above.
    @Test("an unproxied spawn keeps the profile endpoint, inline export included")
    func unproxiedSpawnKeepsTheProfileEndpoint() async throws {
        let (launch, attachment) = await composeSpawn(
            config: Config(), supervisor: FakeModelProxySupervisor(port: 51_842))

        #expect(!attachment.routed, "the proxy flag is off, so nothing may be routed")
        #expect(launch.environment["ANTHROPIC_BASE_URL"] == Self.profileBaseURL)
        #expect(commandLine(launch).contains("export ANTHROPIC_BASE_URL="))
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
