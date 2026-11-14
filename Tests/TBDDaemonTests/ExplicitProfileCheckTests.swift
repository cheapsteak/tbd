import Foundation
import Testing
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// `ExplicitProfileCheck.refusal(for:requireCredentials:)` on its own: each
/// refusal's exact copy, and each kind that passes. The reads are fakes.
@Suite("ExplicitProfileCheck")
struct ExplicitProfileCheckTests {
    private func check(
        _ profile: ModelProfile?, secret: String? = nil, identity: String? = nil
    ) -> ExplicitProfileCheck {
        ExplicitProfileCheck(
            profile: { id in profile?.id == id ? profile : nil },
            secret: { _ in secret },
            loginIdentity: { _ in identity })
    }

    @Test func missingRefused() async throws {
        let id = UUID()
        let refusal = try await check(nil).refusal(for: id, requireCredentials: true)
        #expect(refusal == "Model profile \(id.uuidString) does not exist. Run tbd profile list to see the profiles.")
    }

    @Test func missingRefusedEvenWhenCredentialsNotRequired() async throws {
        let id = UUID()
        let refusal = try await check(nil).refusal(for: id, requireCredentials: false)
        #expect(refusal == "Model profile \(id.uuidString) does not exist. Run tbd profile list to see the profiles.")
    }

    @Test(arguments: [String?.none, ""])
    func loggedOutOAuthRefused(identity: String?) async throws {
        let profile = ModelProfile(name: "acme-work", kind: .oauth)
        let refusal = try await check(profile, identity: identity)
            .refusal(for: profile.id, requireCredentials: true)
        #expect(refusal == "Model profile 'acme-work' is not logged in. Run tbd profile login acme-work, then try again.")
    }

    @Test(arguments: [String?.none, ""])
    func tokenWithoutSecretRefused(secret: String?) async throws {
        let profile = ModelProfile(name: "acme-work", kind: .oauthToken)
        let refusal = try await check(profile, secret: secret)
            .refusal(for: profile.id, requireCredentials: true)
        #expect(refusal == "Model profile 'acme-work' has no stored token. Add one in TBD Settings → Model Profiles, then try again.")
    }

    @Test(arguments: [String?.none, ""])
    func apiKeyWithoutSecretRefused(secret: String?) async throws {
        let profile = ModelProfile(name: "acme-work", kind: .apiKey)
        let refusal = try await check(profile, secret: secret)
            .refusal(for: profile.id, requireCredentials: true)
        #expect(refusal == "Model profile 'acme-work' has no stored API key. Add one in TBD Settings → Model Profiles, then try again.")
    }

    /// AWS owns a Bedrock profile's credentials, so nothing of TBD's is read.
    @Test func bedrockPasses() async throws {
        let profile = ModelProfile(name: "acme-bedrock", kind: .bedrock)
        #expect(try await check(profile).refusal(for: profile.id, requireCredentials: true) == nil)
    }

    @Test func loggedInOAuthPasses() async throws {
        let profile = ModelProfile(name: "acme-work", kind: .oauth)
        let refusal = try await check(profile, identity: "person@acme.example")
            .refusal(for: profile.id, requireCredentials: true)
        #expect(refusal == nil)
    }

    @Test func tokenWithSecretPasses() async throws {
        let profile = ModelProfile(name: "acme-work", kind: .oauthToken)
        let refusal = try await check(profile, secret: "sk-ant-oat01-TEST")
            .refusal(for: profile.id, requireCredentials: true)
        #expect(refusal == nil)
    }

    @Test func apiKeyWithSecretPasses() async throws {
        let profile = ModelProfile(name: "acme-work", kind: .apiKey)
        let refusal = try await check(profile, secret: "sk-ant-api-TEST")
            .refusal(for: profile.id, requireCredentials: true)
        #expect(refusal == nil)
    }

    /// A login session's profile is not logged in yet, by design.
    @Test func loggedOutOAuthPassesWhenCredentialsNotRequired() async throws {
        let profile = ModelProfile(name: "acme-work", kind: .oauth)
        #expect(try await check(profile).refusal(for: profile.id, requireCredentials: false) == nil)
    }

    @Test(arguments: [CredentialKind.oauthToken, .apiKey])
    func secretlessPassesWhenCredentialsNotRequired(kind: CredentialKind) async throws {
        let profile = ModelProfile(name: "acme-work", kind: kind)
        #expect(try await check(profile).refusal(for: profile.id, requireCredentials: false) == nil)
    }
}

// Nested under TBDHomeSerialized: every test points the process-global
// `TBD_HOME` at its own scratch directory, so the per-session settings file a
// spawn writes under `~/tbd/runtime/` lands there. See
// TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
/// `worktree.create` with `profileID` and `terminal.create` with
/// `overrideProfileID`: an unusable profile is refused before anything of the
/// create exists, a usable one is used and skips balancing. Tier 2: an
/// in-memory database, a dry-run tmux, the holder spawn double, a real git
/// repo and a scratch directory; no process is started.
@Suite("An explicit model profile is checked before a create")
struct ExplicitProfileRPCTests {
    /// Counts the balancing pool's reads, so a test can tell whether a spawn
    /// took a balanced pick.
    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        /// Counts one call and returns the count it reached.
        @discardableResult
        func bump() -> Int { lock.withLock { _count += 1; return _count } }
        var count: Int { lock.withLock { _count } }
    }

    /// How a profile's stored key is lost between its check and the spawn's
    /// own load of the profile.
    enum KeyLoss: String, CaseIterable, Sendable {
        /// The key is deleted, so the load finds no key.
        case deleted
        /// The key's file fails the store's checks, so the load throws.
        case unreadable

        /// A read of the store that serves the key to its first read, the
        /// check's, and meets the loss on every read after it.
        func reader() -> @Sendable (ModelProfileKeychain.Store, String) throws -> String? {
            let reads = CallCounter()
            return { store, id in
                guard reads.bump() > 1 else { return try store.load(id: id) }
                switch self {
                case .deleted:
                    try store.delete(id: id)
                    return try store.load(id: id)
                case .unreadable:
                    throw ModelProfileKeychainError.permissionMismatch("expected 0600, got 0644")
                }
            }
        }
    }

    struct Fixture {
        let router: RPCRouter
        let db: TBDDatabase
        /// Every session a create opened.
        let holder: FakeHolderLaunch
        let repo: Repo
        let repoDir: URL
        let worktree: Worktree
        let configDirManager: ClaudeProfileConfigDirManager
        let keychain: ModelProfileKeychain.Store
        let poolReads: CallCounter
        let actuationLogPath: String

        func createTerminal(_ params: TerminalCreateParams) async throws -> RPCResponse {
            await router.handle(try RPCRequest(method: RPCMethod.terminalCreate, params: params))
        }

        func createWorktree(_ params: WorktreeCreateParams) async throws -> RPCResponse {
            await router.handle(try RPCRequest(method: RPCMethod.worktreeCreate, params: params))
        }

        /// Writes the account email Claude Code records after `/login` into
        /// the profile's isolated config directory.
        func logIn(_ profile: ModelProfile) throws {
            let dir = configDirManager.configDirectory(forProfileID: profile.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"oauthAccount":{"emailAddress":"person@acme.example"}}"#.utf8)
                .write(to: dir.appendingPathComponent(".claude.json"))
        }

        /// A profile of `kind` with nothing behind it: never logged in, and no
        /// stored secret.
        func bareProfile(_ kind: CredentialKind, name: String = "acme-work") async throws -> ModelProfile {
            try await db.modelProfiles.create(name: name, kind: kind)
        }

        /// A logged-in OAuth profile.
        func usableProfile(name: String) async throws -> ModelProfile {
            let profile = try await db.modelProfiles.create(name: name, kind: .oauth)
            try logIn(profile)
            return profile
        }

        /// Each unusable explicit profile, with the refusal it gets.
        func unusableProfiles() async throws -> [(id: UUID, error: String)] {
            let missing = UUID()
            let oauth = try await bareProfile(.oauth, name: "acme-oauth")
            let token = try await bareProfile(.oauthToken, name: "acme-token")
            let apiKey = try await bareProfile(.apiKey, name: "acme-key")
            return [
                (missing, "Model profile \(missing.uuidString) does not exist. Run tbd profile list to see the profiles."),
                (oauth.id, "Model profile 'acme-oauth' is not logged in. Run tbd profile login acme-oauth, then try again."),
                (token.id, "Model profile 'acme-token' has no stored token. Add one in TBD Settings → Model Profiles, then try again."),
                (apiKey.id, "Model profile 'acme-key' has no stored API key. Add one in TBD Settings → Model Profiles, then try again."),
            ]
        }

        /// Waits until the create's detached phases leave `.creating` — or
        /// remove the row, which a failed create does — and returns the row.
        func settledWorktree(_ id: UUID) async throws -> Worktree? {
            let outcome = await pollUntilTrue(
                timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(50)
            ) {
                do {
                    guard let row = try await db.worktrees.get(id: id) else { return true }
                    return row.status != .creating
                } catch {
                    return false
                }
            }
            #expect(outcome == .satisfied, "the create never left .creating")
            return try await db.worktrees.get(id: id)
        }

        /// The settled worktree's Claude primary.
        func claudePrimary(of response: RPCResponse) async throws -> TBDShared.Terminal {
            #expect(response.success, "\(response.error ?? "")")
            let pending = try response.decodeResult(Worktree.self)
            let settled = try #require(try await settledWorktree(pending.id))
            #expect(settled.status == .active)
            let terminals = try await db.terminals.list(worktreeID: pending.id)
            return try #require(terminals.first { $0.kind == .claude })
        }

        /// Every row the router appended to its actuation log, in order.
        func actuationRows() throws -> [[String: Any]] {
            guard let contents = try? String(contentsOfFile: actuationLogPath, encoding: .utf8) else {
                return []
            }
            return try contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line in
                    try #require(
                        try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                }
        }
    }

    /// `readSecret`, when given, replaces the resolver's read of a stored
    /// secret. The explicit-profile check and the spawn's own load both read
    /// through it, so a test can change what the second read finds.
    private func withFixture(
        readSecret: (@Sendable (ModelProfileKeychain.Store, String) throws -> String?)? = nil,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-explicit-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let priorTBDHome = setTBDHome(home.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: scratch)
        }

        let actuationDirectory = scratch.appendingPathComponent("actuations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: actuationDirectory, withIntermediateDirectories: true)
        let actuationLogPath = actuationDirectory.appendingPathComponent("actuations.jsonl").path

        let holder = FakeHolderLaunch()
        let registry = makeHolderRegistryDouble(launch: holder)
        let tmux = TmuxManager(dryRun: true)
        let db = try TBDDatabase(inMemory: true)
        let claudeBase = scratch.appendingPathComponent("claude", isDirectory: true)
        let configDirManager = ClaudeProfileConfigDirManager(
            baseDirectory: claudeBase.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: claudeBase.appendingPathComponent("claude-host", isDirectory: true))
        let keychain = ModelProfileKeychain.Store(environment: ["TBD_HOME": home.path])
        let poolReads = CallCounter()
        // One resolver for the lifecycle (worktree.create's primary) and the
        // router (terminal.create), whose balancing pool counts its reads.
        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles, repos: db.repos, config: db.config,
            keychain: { id in
                if let readSecret { return try readSecret(keychain, id) }
                return try keychain.load(id: id)
            },
            candidateSource: ProfilePoolCandidateSource(
                profiles: db.modelProfiles,
                snapshots: db.oauthUsageSnapshots,
                terminals: db.terminals,
                loginIdentity: { id in
                    poolReads.bump()
                    return configDirManager.loginIdentity(forProfileID: id)
                }),
            reservations: ProfilePickReservations())
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            modelProfileResolver: resolver,
            configDirManager: configDirManager,
            preSessionPollInterval: 0.05)
        lifecycle.holderRegistry = registry
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            startTime: Date(),
            usageFetcher: StubClaudeUsageFetcher(),
            modelProfileResolver: resolver,
            configDirManager: configDirManager,
            // A login tab arms an identity watcher; keep it short-lived.
            loginSessions: LoginSessionCoordinator(delays: .init(
                identityPollInterval: .milliseconds(50),
                identityPollTimeout: .milliseconds(250))),
            sessionsDir: scratch.appendingPathComponent("sessions", isDirectory: true),
            actuationLog: ActuationLog(path: actuationLogPath),
            modelProfileKeychain: keychain)
        router.holderRegistry = registry

        let repoDir = scratch.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try await shell("git init -b main && git commit --allow-empty -m 'init'", at: repoDir)
        let repo = try await makeTestRepo(db: db, tempDir: scratch, repoDir: repoDir)
        // terminal.create refuses a worktree whose directory is missing.
        let worktreePath = scratch.appendingPathComponent("wt", isDirectory: true).path
        try FileManager.default.createDirectory(
            atPath: worktreePath, withIntermediateDirectories: true)
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: worktreePath, tmuxServer: "tbd-test")

        try await body(Fixture(
            router: router, db: db, holder: holder, repo: repo, repoDir: repoDir,
            worktree: worktree, configDirManager: configDirManager, keychain: keychain,
            poolReads: poolReads, actuationLogPath: actuationLogPath))
    }

    // MARK: - worktree.create

    /// Refused before phase 1, so nothing of the create exists: no worktree
    /// row, no git worktree, no branch, no actuation row, no session.
    @Test func worktreeCreateRefusesUnusableProfileBeforeCreating() async throws {
        try await withFixture { f in
            for unusable in try await f.unusableProfiles() {
                let resp = try await f.createWorktree(WorktreeCreateParams(
                    repoID: f.repo.id, folder: "refused", profileID: unusable.id,
                    primaryAgentPreference: .claude))
                #expect(!resp.success)
                #expect(resp.error == unusable.error)
            }

            #expect(try await f.db.worktrees.list(repoID: f.repo.id).map(\.id) == [f.worktree.id])
            let git = GitManager()
            #expect(try await git.worktreeList(repoPath: f.repoDir.path).count == 1)
            #expect(try await git.localBranchExists(repoPath: f.repoDir.path, name: "tbd/refused") == false)
            #expect(try f.actuationRows().isEmpty)
            #expect(f.holder.launches.isEmpty)
        }
    }

    @Test func worktreeCreateWithBedrockProfileProceeds() async throws {
        try await withFixture { f in
            let bedrock = try await f.db.modelProfiles.create(
                name: "acme-bedrock", kind: .bedrock, awsRegion: "us-west-2")
            let primary = try await f.claudePrimary(of: try await f.createWorktree(
                WorktreeCreateParams(
                    repoID: f.repo.id, profileID: bedrock.id, primaryAgentPreference: .claude)))
            #expect(primary.profileID == bedrock.id)
        }
    }

    /// With balancing on, an explicit profile is used as given and the pool
    /// is never read; without one, the same create takes a balanced pick.
    @Test func worktreeCreateExplicitProfileSkipsBalancing() async throws {
        try await withFixture { f in
            let explicit = try await f.usableProfile(name: "acme-work")
            let other = try await f.usableProfile(name: "acme-personal")
            try await f.db.config.setDefaultProfileID(other.id)
            try await f.db.config.setProfileBalancingEnabled(true)

            let primary = try await f.claudePrimary(of: try await f.createWorktree(
                WorktreeCreateParams(
                    repoID: f.repo.id, profileID: explicit.id, primaryAgentPreference: .claude)))
            #expect(primary.profileID == explicit.id)
            #expect(f.poolReads.count == 0)

            // Control: the same create without a profile reads the pool.
            _ = try await f.claudePrimary(of: try await f.createWorktree(
                WorktreeCreateParams(repoID: f.repo.id, primaryAgentPreference: .claude)))
            #expect(f.poolReads.count > 0)
        }
    }

    // MARK: - terminal.create

    /// Refused after the request row and before any spawn work: no terminal
    /// row, no session, and the request closed as a not-eligible refusal.
    @Test func terminalCreateRefusesUnusableProfile() async throws {
        try await withFixture { f in
            let unusable = try await f.unusableProfiles()
            for (index, profile) in unusable.enumerated() {
                let resp = try await f.createTerminal(TerminalCreateParams(
                    worktreeID: f.worktree.id, type: .claude, overrideProfileID: profile.id))
                #expect(!resp.success)
                #expect(resp.error == profile.error)

                let rows = try f.actuationRows()
                #expect(rows.count == 2 * (index + 1))
                #expect(rows.dropLast().last?["method"] as? String == "terminal.create")
                let outcome = try #require(rows.last)
                #expect(outcome["result"] as? String == "refused")
                #expect(outcome["reason"] as? String == "not-eligible")
                #expect(outcome["error"] as? String == resp.error)
            }
            #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
            #expect(f.holder.launches.isEmpty)
        }
    }

    /// A profile that passes its check but loses its key before the spawn
    /// loads it is refused as well, rather than starting the tab on the
    /// machine's own login: no terminal row, no session, and the request closed
    /// as a not-eligible refusal.
    @Test(arguments: KeyLoss.allCases)
    func terminalCreateRefusesProfileLostAfterItsCheck(loss: KeyLoss) async throws {
        try await withFixture(readSecret: loss.reader()) { f in
            let apiKey = try await f.bareProfile(.apiKey, name: "acme-key")
            try f.keychain.store(id: apiKey.id.uuidString, token: "sk-ant-api-TEST")

            let resp = try await f.createTerminal(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .claude, overrideProfileID: apiKey.id))
            #expect(!resp.success)
            #expect(resp.error == "Model profile \(apiKey.id.uuidString) could not be loaded: it was deleted or lost its credentials after it was checked. Nothing was started.")

            let rows = try f.actuationRows()
            #expect(rows.count == 2)
            let outcome = try #require(rows.last)
            #expect(outcome["result"] as? String == "refused")
            #expect(outcome["reason"] as? String == "not-eligible")
            #expect(outcome["error"] as? String == resp.error)
            #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
            #expect(f.holder.launches.isEmpty)
        }
    }

    /// A resume pinned to a profile goes through the same check.
    @Test func terminalCreateResumeWithUnusableProfileRefused() async throws {
        try await withFixture { f in
            for unusable in try await f.unusableProfiles() {
                let resp = try await f.createTerminal(TerminalCreateParams(
                    worktreeID: f.worktree.id, resumeSessionID: UUID().uuidString,
                    overrideProfileID: unusable.id))
                #expect(!resp.success)
                #expect(resp.error == unusable.error)
            }
            #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
            #expect(f.holder.launches.isEmpty)
        }
    }

    /// A login session exists to log its profile in, so a logged-out OAuth
    /// profile still spawns there.
    @Test func loginSessionOnLoggedOutOAuthSpawns() async throws {
        try await withFixture { f in
            let profile = try await f.bareProfile(.oauth)
            let resp = try await f.createTerminal(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .claude,
                overrideProfileID: profile.id, loginSession: true))
            #expect(resp.success, "\(resp.error ?? "")")
            let terminal = try resp.decodeResult(TBDShared.Terminal.self)
            #expect(terminal.label == TerminalLabel.login)
            #expect(terminal.profileID == profile.id)
        }
    }

    /// Existence still applies to a login session.
    @Test func loginSessionOnMissingProfileRefused() async throws {
        try await withFixture { f in
            let missing = UUID()
            let resp = try await f.createTerminal(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .claude,
                overrideProfileID: missing, loginSession: true))
            #expect(!resp.success)
            #expect(resp.error == "Model profile \(missing.uuidString) does not exist. Run tbd profile list to see the profiles.")
            #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
            #expect(f.holder.launches.isEmpty)
        }
    }

    @Test func terminalCreateWithUsableProfilesProceeds() async throws {
        try await withFixture { f in
            let bedrock = try await f.db.modelProfiles.create(
                name: "acme-bedrock", kind: .bedrock, awsRegion: "us-west-2")
            let oauth = try await f.usableProfile(name: "acme-oauth")
            let token = try await f.bareProfile(.oauthToken, name: "acme-token")
            try f.keychain.store(id: token.id.uuidString, token: "sk-ant-oat01-TEST")
            let apiKey = try await f.bareProfile(.apiKey, name: "acme-key")
            try f.keychain.store(id: apiKey.id.uuidString, token: "sk-ant-api-TEST")

            for profile in [bedrock, oauth, token, apiKey] {
                let resp = try await f.createTerminal(TerminalCreateParams(
                    worktreeID: f.worktree.id, type: .claude, overrideProfileID: profile.id))
                #expect(resp.success, "\(profile.name): \(resp.error ?? "")")
                let terminal = try resp.decodeResult(TBDShared.Terminal.self)
                #expect(terminal.profileID == profile.id)
            }
        }
    }

    /// With balancing on, an explicit profile is used as given and the pool
    /// is never read; without one, the same create takes a balanced pick.
    @Test func terminalCreateExplicitProfileSkipsBalancing() async throws {
        try await withFixture { f in
            let explicit = try await f.usableProfile(name: "acme-work")
            let other = try await f.usableProfile(name: "acme-personal")
            try await f.db.config.setDefaultProfileID(other.id)
            try await f.db.config.setProfileBalancingEnabled(true)

            let resp = try await f.createTerminal(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .claude, overrideProfileID: explicit.id))
            #expect(resp.success, "\(resp.error ?? "")")
            #expect(try resp.decodeResult(TBDShared.Terminal.self).profileID == explicit.id)
            #expect(f.poolReads.count == 0)

            // Control: the same create without a profile reads the pool.
            let balanced = try await f.createTerminal(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .claude))
            #expect(balanced.success, "\(balanced.error ?? "")")
            #expect(f.poolReads.count > 0)
        }
    }

    /// A shell has no use for a profile: one that would be refused for Claude
    /// is ignored, as before.
    @Test func shellIgnoresExplicitProfile() async throws {
        try await withFixture { f in
            let resp = try await f.createTerminal(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .shell, overrideProfileID: UUID()))
            #expect(resp.success, "\(resp.error ?? "")")
            #expect(try resp.decodeResult(TBDShared.Terminal.self).profileID == nil)
        }
    }
}
}
