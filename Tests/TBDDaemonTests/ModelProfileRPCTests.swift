import Foundation
import GRDB
import Security
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Stub fetcher with a queued response list.
final class StubClaudeUsageFetcher: ClaudeUsageFetcher, @unchecked Sendable {
    private var responses: [ClaudeUsageStatus]
    private(set) var callCount: Int = 0
    private(set) var lastToken: String? = nil

    init(responses: [ClaudeUsageStatus] = []) {
        self.responses = responses
    }

    func enqueue(_ status: ClaudeUsageStatus) {
        responses.append(status)
    }

    func fetchUsage(token: String) async -> ClaudeUsageStatus {
        callCount += 1
        lastToken = token
        if responses.isEmpty {
            return .networkError("no stub response queued")
        }
        return responses.removeFirst()
    }
}

/// Records every credential a poller sweep hands it, so a test can assert both
/// that a probe fired and what it carried. Returns an empty successful reading:
/// nothing here is testing the parse, only the wiring.
final class CountingProfileUsageFetcher: ProfileUsageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _credentials: [ProfileUsageCredential] = []

    var credentials: [ProfileUsageCredential] { lock.withLock { _credentials } }
    var callCount: Int { lock.withLock { _credentials.count } }

    func fetchUsage(credential: ProfileUsageCredential) async -> ProfileUsageFetchStatus {
        lock.withLock { _credentials.append(credential) }
        return .ok([], organizationID: nil)
    }
}

/// Keychain seam that samples the database from *inside* the delete handler's
/// cleanup block, recording whether the `model_profiles` row still existed at
/// that moment.
///
/// The row is the only pointer to `~/tbd/profiles/<uuid>/`, so every artifact
/// keyed by it must be cleaned while it is still there: a daemon killed
/// between the row delete and the directory removal would otherwise leave a
/// directory nothing can ever attribute or reclaim. The probe is what pins
/// that ordering — it cannot `await`, so it reads the writer synchronously.
final class ProfileRowPresenceProbe: ClaudeCredentialsKeychainDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var _rowPresentAtKeychainDelete: Bool?
    private var _dirPresentAtKeychainDelete: Bool?
    private var _probe: (@Sendable () -> Bool)?
    private var _directoryPath: String?

    /// `nil` when the handler never reached the Keychain cleanup at all.
    var rowPresentAtKeychainDelete: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _rowPresentAtKeychainDelete
    }

    /// The other half of the ordering: the directory removal is the step whose
    /// crash-safety the reorder exists for, and it runs *after* this one. If it
    /// had already happened, the sampled row presence would say nothing about
    /// it.
    var directoryPresentAtKeychainDelete: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _dirPresentAtKeychainDelete
    }

    /// Sampled alongside the row at Keychain-delete time.
    func watchDirectory(_ path: String) {
        lock.lock()
        _directoryPath = path
        lock.unlock()
    }

    /// Installed after the router is built, because the sample reads the very
    /// database the router owns.
    func onDelete(_ probe: @escaping @Sendable () -> Bool) {
        lock.lock()
        _probe = probe
        lock.unlock()
    }

    func deleteGenericPassword(service: String) -> OSStatus {
        lock.lock()
        let probe = _probe
        let directoryPath = _directoryPath
        lock.unlock()
        let present = probe?()
        let directoryPresent = directoryPath.map { FileManager.default.fileExists(atPath: $0) }
        lock.lock()
        _rowPresentAtKeychainDelete = present
        _dirPresentAtKeychainDelete = directoryPresent
        lock.unlock()
        // Nothing was ever stored for a temp-dir profile; the handler treats
        // this as success.
        return errSecItemNotFound
    }
}

// Nested under TBDHomeSerialized: this suite does not *mutate* `TBD_HOME`, it
// depends on the value staying put. `ModelProfileKeychain` is a file store
// under `$TBD_HOME/claude-tokens` and resolves that directory from the
// process-global environment on every call, so a test that seeds a token and
// then drives a handler which reads it back straddles two independent
// resolutions. Run concurrently with a suite that points `TBD_HOME` at its own
// temp directory, the seed and the read land in different homes and the
// handler answers "Secret missing from keychain" — the observed failure. The
// gap is seconds wide in the fast parallel pass, where a test spends most of
// its wall time suspended between awaits.
//
// See `TBDHomeSerializedSuites.swift`: the serialized domain is the only
// mutual exclusion available here, because the handlers reach
// `ModelProfileKeychain` through static members with no injection seam.
extension TBDHomeSerialized {

@Suite("ModelProfile RPC Handlers")
struct ModelProfileRPCTests {

    private static let oauthPrefix = "sk-ant-oat01-"
    private static let apiPrefix = "sk-ant-api03-"

    private func freshToken(_ prefix: String = oauthPrefix) -> String {
        prefix + UUID().uuidString
    }

    private func makeRouter(
        stub: StubClaudeUsageFetcher = StubClaudeUsageFetcher(),
        configDirManager: ClaudeProfileConfigDirManager = ClaudeProfileConfigDirManager(),
        claudeCredentialsKeychain: ClaudeCredentialsKeychainDeleting = SecItemClaudeCredentialsKeychain()
    )
        -> (RPCRouter, TBDDatabase, StubClaudeUsageFetcher)
    {
        let db = try! TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            usageFetcher: stub,
            configDirManager: configDirManager,
            claudeCredentialsKeychain: claudeCredentialsKeychain,
            actuationLog: makeTestActuationLog()
        )
        return (router, db, stub)
    }

    private func sampleUsage() -> ClaudeUsageResult {
        ClaudeUsageResult(
            fiveHourPct: 0.42,
            sevenDayPct: 0.13,
            fiveHourResetsAt: Date().addingTimeInterval(3600),
            sevenDayResetsAt: Date().addingTimeInterval(7 * 86_400)
        )
    }

    /// Cleanup helper that drops every keychain entry for the tokens currently in db.
    private func cleanupKeychain(_ db: TBDDatabase) async {
        let tokens = (try? await db.modelProfiles.list()) ?? []
        for t in tokens {
            try? ModelProfileKeychain.delete(id: t.id.uuidString)
        }
    }

    // MARK: - add

    @Test("add: oauth without token succeeds, no keychain")
    func addOauthNoToken() async throws {
        let (router, db, _) = makeRouter()

        let req = try RPCRequest(method: RPCMethod.modelProfileAdd,
                                 params: ModelProfileAddParams(name: "Work", token: nil))
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileAddResult.self)
        #expect(result.warning == nil)
        #expect(result.profile.kind == .oauth)
        #expect(result.profile.name == "Work")

        let listed = try await db.modelProfiles.list()
        #expect(listed.count == 1)
        // Verify no keychain entry was written
        let kc = try? ModelProfileKeychain.load(id: result.profile.id.uuidString)
        #expect(kc == nil)
    }

    @Test("add: oauth without token succeeds, warning nil")
    func addOauthWithoutTokenNoWarning() async throws {
        let stub = StubClaudeUsageFetcher()
        let (router, db, _) = makeRouter(stub: stub)

        let req = try RPCRequest(method: RPCMethod.modelProfileAdd,
                                 params: ModelProfileAddParams(name: "Personal", token: nil))
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileAddResult.self)
        #expect(result.warning == nil)
        #expect(result.profile.kind == .oauth)

        let listed = try await db.modelProfiles.list()
        #expect(listed.count == 1)
        // No keychain entry
        let kc = try? ModelProfileKeychain.load(id: result.profile.id.uuidString)
        #expect(kc == nil)
        // Fetcher should never be called for OAuth
        #expect(stub.callCount == 0)
    }

    @Test("add: oauth with token returns warning, ignores token, no keychain")
    func addOauthWithTokenReturnsWarning() async throws {
        let stub = StubClaudeUsageFetcher()
        let (router, db, _) = makeRouter(stub: stub)

        let tokenBytes = freshToken()
        let req = try RPCRequest(method: RPCMethod.modelProfileAdd,
                                 params: ModelProfileAddParams(name: "Personal", token: tokenBytes))
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileAddResult.self)
        #expect(result.warning != nil)
        #expect(result.warning?.contains("OAuth") == true)
        #expect(result.warning?.contains("not stored") == true)
        #expect(result.profile.kind == .oauth)

        let listed = try await db.modelProfiles.list()
        #expect(listed.count == 1)
        // OAuth token provided but not stored per Phase 3
        let kc = try? ModelProfileKeychain.load(id: result.profile.id.uuidString)
        #expect(kc == nil)
        // Fetcher should never be called for OAuth
        #expect(stub.callCount == 0)
    }

    @Test("add: api_key prefix skips fetcher")
    func addApiKey() async throws {
        let stub = StubClaudeUsageFetcher()
        let (router, db, _) = makeRouter(stub: stub)
        defer { Task { await cleanupKeychain(db) } }

        let req = try RPCRequest(method: RPCMethod.modelProfileAdd,
                                 params: ModelProfileAddParams(name: "Work", token: freshToken(Self.apiPrefix)))
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileAddResult.self)
        #expect(stub.callCount == 0)
        #expect(result.profile.kind == .apiKey)
        #expect(try await db.modelProfileUsage.get(profileID: result.profile.id) == nil)
        try? ModelProfileKeychain.delete(id: result.profile.id.uuidString)
    }

    @Test("add: bad prefix rejected")
    func addBadPrefix() async throws {
        let stub = StubClaudeUsageFetcher()
        let (router, db, _) = makeRouter(stub: stub)
        let req = try RPCRequest(method: RPCMethod.modelProfileAdd,
                                 params: ModelProfileAddParams(name: "Junk", token: "garbage"))
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(stub.callCount == 0)
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    @Test("add: token with embedded newline rejected at storage")
    func addRejectsNewline() async throws {
        let (router, db, _) = makeRouter()
        let bad = Self.oauthPrefix + "abc\ndef"
        let req = try RPCRequest(method: RPCMethod.modelProfileAdd,
                                 params: ModelProfileAddParams(name: "Bad", token: bad))
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error?.contains("invalid characters") == true)
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    @Test("add: empty token rejected for proxy profiles")
    func addProxyEmptyTokenRejected() async throws {
        let (router, db, stub) = makeRouter()
        let req = try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(
                name: "EmptyProxy",
                token: "",
                baseURL: "http://127.0.0.1:3456",
                model: nil
            )
        )
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error == "Token cannot be empty")
        #expect(stub.callCount == 0)
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    @Test("add: whitespace-only token rejected for proxy profiles")
    func addProxyWhitespaceTokenRejected() async throws {
        let (router, db, _) = makeRouter()
        let req = try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(
                name: "WhitespaceProxy",
                token: "   ",
                baseURL: "http://127.0.0.1:3456",
                model: nil
            )
        )
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error == "Token cannot be empty")
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    @Test("add: empty token with no baseURL treated as oauth (AC5.3 counterpart)")
    func addEmptyTokenTreatedAsOAuth() async throws {
        let (router, db, _) = makeRouter()
        let req = try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(
                name: "ImplicitOAuth",
                token: nil,
                baseURL: nil,
                model: nil
            )
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileAddResult.self)
        #expect(result.profile.kind == .oauth)
        #expect(try await db.modelProfiles.list().count == 1)
    }

    @Test("add: empty token with baseURL rejected")
    func addEmptyTokenWithBaseURLRejected() async throws {
        let (router, db, _) = makeRouter()
        let req = try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(
                name: "ProxyNoToken",
                token: nil,
                baseURL: "http://127.0.0.1:3456",
                model: nil
            )
        )
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error == "Token cannot be empty")
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    @Test("add: duplicate name rejected")
    func addDuplicateName() async throws {
        let stub = StubClaudeUsageFetcher(responses: [.ok(sampleUsage())])
        let (router, db, _) = makeRouter(stub: stub)
        defer { Task { await cleanupKeychain(db) } }

        let first = try RPCRequest(method: RPCMethod.modelProfileAdd,
                                   params: ModelProfileAddParams(name: "Personal", token: freshToken()))
        _ = await router.handle(first)

        let second = try RPCRequest(method: RPCMethod.modelProfileAdd,
                                    params: ModelProfileAddParams(name: "Personal", token: freshToken()))
        let resp = await router.handle(second)
        #expect(!resp.success)
        #expect(try await db.modelProfiles.list().count == 1)
    }

    // MARK: - token profiles (CredentialKind.oauthToken)

    private func addTokenProfile(_ router: RPCRouter, name: String,
                                 token: String) async throws -> RPCResponse {
        await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(name: name, kind: .claudeToken, token: token)))
    }

    @Test("add: kind .claudeToken stores the secret as an oauthToken profile")
    func addTokenProfileStoresSecret() async throws {
        let (router, db, stub) = makeRouter()
        defer { Task { await cleanupKeychain(db) } }

        let token = freshToken()
        let resp = try await addTokenProfile(router, name: "Acme (token)", token: token)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileAddResult.self)
        #expect(result.profile.kind == .oauthToken)
        // No warning: unlike the signed-in path, the token was kept.
        #expect(result.warning == nil)
        let stored = try ModelProfileKeychain.load(id: result.profile.id.uuidString)
        #expect(stored == token)
        // The legacy api-key usage endpoint is never consulted for this kind.
        #expect(stub.callCount == 0)
    }

    /// A token profile is nothing without its credential, so the row is never
    /// created half-formed: there is no state where the kind says "token" and
    /// no token is stored.
    @Test("add: .claudeToken with no token is rejected and creates nothing")
    func addTokenProfileWithoutSecretRejected() async throws {
        let (router, db, _) = makeRouter()
        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(name: "NoToken", kind: .claudeToken, token: nil)))
        #expect(!resp.success)
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    @Test("add: .claudeToken with a whitespace-only token is rejected")
    func addTokenProfileWithBlankSecretRejected() async throws {
        let (router, db, _) = makeRouter()
        let resp = try await addTokenProfile(router, name: "Blank", token: "   ")
        #expect(!resp.success)
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    @Test("add: .claudeToken with a baseURL is rejected (token profiles are Claude-direct)")
    func addTokenProfileWithBaseURLRejected() async throws {
        let (router, db, _) = makeRouter()
        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(name: "ProxyToken", kind: .claudeToken,
                                          token: freshToken(),
                                          baseURL: "http://127.0.0.1:3456")))
        #expect(!resp.success)
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    /// A newline would break tmux's single-line `-e KEY=VALUE` parsing, so the
    /// store refuses it — and refuses it before any row or secret file exists.
    @Test("add: .claudeToken with an embedded newline is rejected, nothing stored")
    func addTokenProfileWithNewlineRejected() async throws {
        let (router, db, _) = makeRouter()
        let resp = try await addTokenProfile(router, name: "Bad",
                                             token: Self.oauthPrefix + "abc\ndef")
        #expect(!resp.success)
        #expect(resp.error?.contains("invalid characters") == true)
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    @Test("updateToken: replaces the stored secret")
    func updateTokenReplacesStoredSecret() async throws {
        let (router, db, _) = makeRouter()
        defer { Task { await cleanupKeychain(db) } }

        let first = freshToken()
        let resp = try await addTokenProfile(router, name: "Acme (token)", token: first)
        let profile = try resp.decodeResult(ModelProfileAddResult.self).profile

        let second = freshToken()
        let rotate = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileUpdateToken,
            params: ModelProfileUpdateTokenParams(id: profile.id, token: second)))
        #expect(rotate.success)
        let stored = try ModelProfileKeychain.load(id: profile.id.uuidString)
        #expect(stored == second)
        // Rotation keeps the row: the profile's id, config dir and history all
        // survive, which is the whole point of not delete-and-recreating.
        let row = try await db.modelProfiles.get(id: profile.id)
        #expect(row?.kind == .oauthToken)
    }

    @Test("updateToken: a blank token is rejected and leaves the stored secret alone")
    func updateTokenRejectsBlank() async throws {
        let (router, db, _) = makeRouter()
        defer { Task { await cleanupKeychain(db) } }

        let original = freshToken()
        let resp = try await addTokenProfile(router, name: "Acme (token)", token: original)
        let profile = try resp.decodeResult(ModelProfileAddResult.self).profile

        let rotate = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileUpdateToken,
            params: ModelProfileUpdateTokenParams(id: profile.id, token: "   ")))
        #expect(!rotate.success)
        let stored = try ModelProfileKeychain.load(id: profile.id.uuidString)
        #expect(stored == original)
    }

    @Test("updateToken: rejected on a signed-in profile, which stores no secret")
    func updateTokenRejectedOnOAuthProfile() async throws {
        let (router, db, _) = makeRouter()
        defer { Task { await cleanupKeychain(db) } }
        let profile = try await db.modelProfiles.create(name: "SignedIn", kind: .oauth)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileUpdateToken,
            params: ModelProfileUpdateTokenParams(id: profile.id, token: freshToken())))
        #expect(!resp.success)
        // Nothing was written for a kind that authenticates by /login.
        let stored = try ModelProfileKeychain.load(id: profile.id.uuidString)
        #expect(stored == nil)
    }

    @Test("updateToken: unknown id fails with profile-not-found")
    func updateTokenUnknownID() async throws {
        let (router, _, _) = makeRouter()
        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileUpdateToken,
            params: ModelProfileUpdateTokenParams(id: UUID(), token: freshToken())))
        #expect(!resp.success)
        #expect(resp.error == "Profile not found")
    }

    /// A secret that outlives its profile is a credential nothing owns, so
    /// deletion reclaims a token profile's file exactly as it reclaims an
    /// api-key profile's.
    @Test("delete: reclaims a token profile's stored secret")
    func deleteReclaimsTokenSecret() async throws {
        let (router, db, _) = makeRouter(claudeCredentialsKeychain: ProfileRowPresenceProbe())
        defer { Task { await cleanupKeychain(db) } }

        let resp = try await addTokenProfile(router, name: "Acme (token)", token: freshToken())
        let profile = try resp.decodeResult(ModelProfileAddResult.self).profile
        let beforeDelete = try ModelProfileKeychain.load(id: profile.id.uuidString)
        #expect(beforeDelete != nil, "the secret really was stored — otherwise this proves nothing")

        let del = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileDelete,
            params: ModelProfileDeleteParams(id: profile.id)))
        #expect(del.success)
        let afterDelete = try ModelProfileKeychain.load(id: profile.id.uuidString)
        #expect(afterDelete == nil)
    }

    /// The app never holds a profile secret, so the daemon computes the four
    /// characters the settings row shows — and sends nothing else.
    @Test("list: a token profile carries the masked tail, a signed-in one does not")
    func listCarriesTokenTail() async throws {
        let (router, db, _) = makeRouter()
        defer { Task { await cleanupKeychain(db) } }

        let resp = try await addTokenProfile(router, name: "Acme (token)",
                                             token: "sk-ant-oat01-AAAA4f2a")
        let tokenProfile = try resp.decodeResult(ModelProfileAddResult.self).profile
        let oauthProfile = try await db.modelProfiles.create(name: "SignedIn", kind: .oauth)

        let listResp = await router.handle(RPCRequest(method: RPCMethod.modelProfileList))
        #expect(listResp.success)
        let result = try listResp.decodeResult(ModelProfileListResult.self)
        let tokenEntry = result.profiles.first { $0.profile.id == tokenProfile.id }
        let oauthEntry = result.profiles.first { $0.profile.id == oauthProfile.id }
        #expect(tokenEntry?.tokenTail == "4f2a")
        #expect(oauthEntry?.tokenTail == nil)
        // The secret itself never leaves the daemon: the whole encoded list
        // payload contains the tail and nothing more of the token.
        let encoded = try JSONEncoder().encode(result)
        let wirePayload = String(decoding: encoded, as: UTF8.self)
        #expect(!wirePayload.contains("sk-ant-oat01-AAAA4f2a"))
        #expect(wirePayload.contains("4f2a"))
    }

    @Test("list: a stored secret shorter than four characters yields no tail")
    func listShortSecretYieldsNoTail() async throws {
        let (router, db, _) = makeRouter()
        defer { Task { await cleanupKeychain(db) } }

        let resp = try await addTokenProfile(router, name: "Stub", token: "abc")
        let profile = try resp.decodeResult(ModelProfileAddResult.self).profile

        let listResp = await router.handle(RPCRequest(method: RPCMethod.modelProfileList))
        let result = try listResp.decodeResult(ModelProfileListResult.self)
        let entry = result.profiles.first { $0.profile.id == profile.id }
        #expect(entry?.tokenTail == nil)
    }

    /// A poller wired the way `Daemon.swift` wires the real one — profiles read
    /// from this router's database, the secret read back through the same
    /// `ModelProfileKeychain` the add handler wrote it to — with both fetchers
    /// replaced by counters. Never `start()`ed: these tests exercise the
    /// targeted creation probe, not the cadence loop.
    private func makeCountingPoller(
        db: TBDDatabase,
        fetcher: CountingProfileUsageFetcher,
        tokenFetcher: CountingProfileUsageFetcher
    ) -> OAuthProfileUsagePoller {
        OAuthProfileUsagePoller(
            profilesProvider: { try await db.modelProfiles.list() },
            loginIdentity: { _ in nil },
            configDirPath: { id in "/tmp/profiles/\(id.uuidString)/claude" },
            fetcher: fetcher,
            tokenFetcher: tokenFetcher,
            profileSecret: { id in try? ModelProfileKeychain.load(id: id.uuidString) },
            broadcast: {},
            sleeper: { _ in }
        )
    }

    /// The creation probe is deliberately fire-and-forget — it must not delay
    /// the add response — so it lands after the RPC returns. Bounded, so a
    /// wiring regression fails fast instead of hanging the suite; the same
    /// window is reused for the negative cases, where the positive test above
    /// is the evidence that the window is long enough to have caught a probe.
    private func waitForProbes(_ fetcher: CountingProfileUsageFetcher,
                               toReach target: Int,
                               within seconds: Double = 3) async {
        let deadline = Date().addingTimeInterval(seconds)
        while fetcher.callCount < target, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A bad paste must be caught at creation — the row shows a rejected token
    /// straight away — rather than at the user's first spawn.
    @Test("add: creating a token profile probes usage exactly once")
    func addTokenProfileProbesOnce() async throws {
        let (router, db, _) = makeRouter()
        defer { Task { await cleanupKeychain(db) } }
        let oauthFetcher = CountingProfileUsageFetcher()
        let tokenFetcher = CountingProfileUsageFetcher()
        router.oauthUsagePoller = makeCountingPoller(
            db: db, fetcher: oauthFetcher, tokenFetcher: tokenFetcher)

        let token = freshToken()
        let resp = try await addTokenProfile(router, name: "Acme (token)", token: token)
        #expect(resp.success)

        await waitForProbes(tokenFetcher, toReach: 1)
        #expect(tokenFetcher.callCount == 1)
        // Not just "a probe happened": it carried the secret the add had only
        // just stored, which is the whole chain — handler to keychain to poller.
        #expect(tokenFetcher.credentials == [.token(token)])
        // Dispatch is by kind, so the signed-in fetcher is never consulted.
        #expect(oauthFetcher.callCount == 0)
    }

    /// Off-branch: creating a signed-in profile spends no billed request. Its
    /// usage endpoint is free and the cadence sweep already serves it.
    @Test("add: creating a signed-in profile probes nothing")
    func addOAuthProfileProbesNothing() async throws {
        let (router, db, _) = makeRouter()
        defer { Task { await cleanupKeychain(db) } }
        let oauthFetcher = CountingProfileUsageFetcher()
        let tokenFetcher = CountingProfileUsageFetcher()
        router.oauthUsagePoller = makeCountingPoller(
            db: db, fetcher: oauthFetcher, tokenFetcher: tokenFetcher)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(name: "SignedIn", token: nil)))
        #expect(resp.success)

        await waitForProbes(tokenFetcher, toReach: 1, within: 0.5)
        #expect(tokenFetcher.callCount == 0)
        #expect(oauthFetcher.callCount == 0)
    }

    /// Off-branch: rotation is not creation. Each probe is a real billed
    /// request, and the spec asks for one per creation only — the next session
    /// turn refreshes a rotated profile.
    @Test("updateToken: rotating a token spends no additional probe")
    func updateTokenProbesNothing() async throws {
        let (router, db, _) = makeRouter()
        defer { Task { await cleanupKeychain(db) } }
        let oauthFetcher = CountingProfileUsageFetcher()
        let tokenFetcher = CountingProfileUsageFetcher()
        router.oauthUsagePoller = makeCountingPoller(
            db: db, fetcher: oauthFetcher, tokenFetcher: tokenFetcher)

        let resp = try await addTokenProfile(router, name: "Acme (token)", token: freshToken())
        let profile = try resp.decodeResult(ModelProfileAddResult.self).profile
        await waitForProbes(tokenFetcher, toReach: 1)
        #expect(tokenFetcher.callCount == 1, "the creation probe is the baseline this test measures against")

        let rotate = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileUpdateToken,
            params: ModelProfileUpdateTokenParams(id: profile.id, token: freshToken())))
        #expect(rotate.success)

        await waitForProbes(tokenFetcher, toReach: 2, within: 0.5)
        #expect(tokenFetcher.callCount == 1)
    }

    @Test("fetchUsage: rejected for token profiles (the setup token 403s there)")
    func fetchUsageRejectsTokenProfiles() async throws {
        let (router, db, stub) = makeRouter()
        defer { Task { await cleanupKeychain(db) } }

        let resp = try await addTokenProfile(router, name: "Acme (token)", token: freshToken())
        let profile = try resp.decodeResult(ModelProfileAddResult.self).profile

        let usage = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileFetchUsage,
            params: ModelProfileFetchUsageParams(id: profile.id)))
        #expect(!usage.success)
        #expect(usage.error?.contains("token") == true)
        #expect(stub.callCount == 0)
    }

    // MARK: - list

    @Test("list joins usage")
    func listJoinsUsage() async throws {
        let (router, db, _) = makeRouter()
        let a = try await db.modelProfiles.create(name: "A", kind: .oauth)
        let b = try await db.modelProfiles.create(name: "B", kind: .apiKey)
        try await db.modelProfileUsage.upsert(ModelProfileUsage(
            profileID: a.id, fiveHourPct: 0.5, sevenDayPct: 0.1, fetchedAt: Date()
        ))

        let resp = await router.handle(RPCRequest(method: RPCMethod.modelProfileList))
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileListResult.self)
        #expect(result.profiles.count == 2)
        let withA = result.profiles.first { $0.profile.id == a.id }
        let withB = result.profiles.first { $0.profile.id == b.id }
        #expect(withA?.usage != nil)
        #expect(withB?.usage == nil)
    }

    // MARK: - delete

    @Test("delete clears global default + keychain + usage")
    func deleteClearsDefault() async throws {
        let (router, db, _) = makeRouter()
        defer { Task { await cleanupKeychain(db) } }

        // Use an API-key profile (the only kind that stores keychain entries)
        let tok = try await db.modelProfiles.create(name: "Solo", kind: .apiKey)
        let token = freshToken(Self.apiPrefix)
        try ModelProfileKeychain.store(id: tok.id.uuidString, token: token)
        try await db.modelProfileUsage.upsert(ModelProfileUsage(profileID: tok.id, fetchedAt: Date()))
        try await db.config.setDefaultProfileID(tok.id)

        let resp = await router.handle(try RPCRequest(method: RPCMethod.modelProfileDelete,
                                                      params: ModelProfileDeleteParams(id: tok.id)))
        #expect(resp.success)
        #expect(try await db.modelProfiles.get(id: tok.id) == nil)
        #expect(try await db.modelProfileUsage.get(profileID: tok.id) == nil)
        #expect(try await db.config.get().defaultProfileID == nil)
        #expect(try ModelProfileKeychain.load(id: tok.id.uuidString) == nil)
    }

    @Test("delete clears repo override")
    func deleteClearsRepoOverride() async throws {
        let (router, db, _) = makeRouter()
        let tok = try await db.modelProfiles.create(name: "Solo", kind: .oauth)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID().uuidString)",
                                              displayName: "r", defaultBranch: "main")
        try await db.repos.setProfileOverride(id: repo.id, profileID: tok.id)

        _ = await router.handle(try RPCRequest(method: RPCMethod.modelProfileDelete,
                                               params: ModelProfileDeleteParams(id: tok.id)))
        let after = try await db.repos.get(id: repo.id)
        #expect(after?.profileOverrideID == nil)
    }

    @Test("delete leaves unrelated default in place")
    func deleteUnrelated() async throws {
        let (router, db, _) = makeRouter()
        let a = try await db.modelProfiles.create(name: "A", kind: .oauth)
        let b = try await db.modelProfiles.create(name: "B", kind: .oauth)
        try await db.config.setDefaultProfileID(a.id)

        _ = await router.handle(try RPCRequest(method: RPCMethod.modelProfileDelete,
                                               params: ModelProfileDeleteParams(id: b.id)))
        #expect(try await db.config.get().defaultProfileID == a.id)
    }

    @Test("delete bedrock: succeeds even with no keychain entry")
    func deleteBedrockNoKeychain() async throws {
        let (router, db, _) = makeRouter()
        let bedrock = try await db.modelProfiles.create(
            name: "Bedrock",
            kind: .bedrock,
            baseURL: nil,
            model: "anthropic.claude-sonnet-4-5",
            awsRegion: "us-west-2",
            awsProfile: nil
        )
        let resp = await router.handle(try RPCRequest(method: RPCMethod.modelProfileDelete,
                                                      params: ModelProfileDeleteParams(id: bedrock.id)))
        #expect(resp.success)
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    @Test("delete oauth: removes per-profile config directory")
    func deleteOAuthRemovesConfigDir() async throws {
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBaseDir) }

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBaseDir)
        let (router, db, _) = makeRouter(configDirManager: manager)

        // Create an OAuth profile and ensure its config dir is created with temp base
        let oauthProfile = try await db.modelProfiles.create(name: "OAuth", kind: .oauth)
        let _ = try manager.ensureOAuthDir(forProfileID: oauthProfile.id)
        let profileDir = manager.profileDirectory(forProfileID: oauthProfile.id)

        // Verify dir exists before deletion
        #expect(FileManager.default.fileExists(atPath: profileDir.path))

        // Delete the profile via RPC; the handler uses the injected manager
        let resp = await router.handle(try RPCRequest(method: RPCMethod.modelProfileDelete,
                                                      params: ModelProfileDeleteParams(id: oauthProfile.id)))
        #expect(resp.success)

        // Verify the profile is removed from the database
        #expect(try await db.modelProfiles.list().isEmpty)
        // Verify the config directory was deleted
        #expect(!FileManager.default.fileExists(atPath: profileDir.path))
    }

    @Test("delete apiKey: removes per-profile config directory")
    func deleteAPIKeyRemovesConfigDir() async throws {
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBaseDir) }

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBaseDir)
        let (router, db, _) = makeRouter(configDirManager: manager)
        defer { Task { await cleanupKeychain(db) } }

        // Create an API key profile and ensure its config dir is created with temp base
        let apiKeyProfile = try await db.modelProfiles.create(name: "APIKey", kind: .apiKey)
        let token = freshToken(Self.apiPrefix)
        try ModelProfileKeychain.store(id: apiKeyProfile.id.uuidString, token: token)

        let _ = try manager.ensureAPIKeyDir(forProfileID: apiKeyProfile.id, apiKey: token)
        let profileDir = manager.profileDirectory(forProfileID: apiKeyProfile.id)

        // Verify dir exists before deletion
        #expect(FileManager.default.fileExists(atPath: profileDir.path))

        // Delete the profile via RPC; the handler uses the injected manager
        let resp = await router.handle(try RPCRequest(method: RPCMethod.modelProfileDelete,
                                                      params: ModelProfileDeleteParams(id: apiKeyProfile.id)))
        #expect(resp.success)

        // Verify the profile is removed from the database
        #expect(try await db.modelProfiles.list().isEmpty)
        // Verify the config directory was deleted
        #expect(!FileManager.default.fileExists(atPath: profileDir.path))
    }

    @Test("delete: artifact cleanup runs while the profile row still exists")
    func deleteCleansArtifactsBeforeRemovingRow() async throws {
        let tempBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-delete-order-\(UUID().uuidString)", isDirectory: true)
        let tempHostDir = tempBaseDir.appendingPathComponent("host-claude", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHostDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBaseDir) }

        let manager = ClaudeProfileConfigDirManager(
            baseDirectory: tempBaseDir.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: tempHostDir
        )
        let probe = ProfileRowPresenceProbe()
        let (router, db, _) = makeRouter(configDirManager: manager, claudeCredentialsKeychain: probe)

        let profile = try await db.modelProfiles.create(name: "OrderCanary", kind: .oauth)
        _ = try manager.ensureOAuthDir(forProfileID: profile.id)
        let profileDir = manager.profileDirectory(forProfileID: profile.id)
        #expect(FileManager.default.fileExists(atPath: profileDir.path))

        // The probe runs synchronously inside the handler, so it reads the
        // writer directly rather than awaiting a store call.
        let writer = db.writerForTests
        let idString = profile.id.uuidString
        probe.watchDirectory(profileDir.path)
        probe.onDelete {
            let count = try? writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM model_profiles WHERE id = ?",
                    arguments: [idString]
                )
            }
            return (count ?? 0) > 0
        }

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileDelete,
            params: ModelProfileDeleteParams(id: profile.id)
        ))
        #expect(resp.success)

        // Row-keyed cleanup must happen while the row still exists; otherwise a
        // crash mid-handler leaves a profile directory nothing points at.
        #expect(probe.rowPresentAtKeychainDelete == true)
        // And the sample has to precede the directory removal for that to mean
        // anything — otherwise the observed "row present" could be true of a
        // handler that had already unlinked the directory.
        #expect(probe.directoryPresentAtKeychainDelete == true)
        // The reorder must not weaken the outcome: both artifacts still go.
        #expect(!FileManager.default.fileExists(atPath: profileDir.path))
        #expect(try await db.modelProfiles.get(id: profile.id) == nil)
    }

    /// The other half of the reorder's contract, and the reason a collector is
    /// needed at all: a directory removal that fails is log-only and must NOT
    /// abort the delete. The user asked for the profile to be gone, so the row
    /// still goes — and the leftover directory becomes `ProfileDirCollector`'s
    /// problem rather than the RPC's.
    @Test("delete: a failed directory removal still deletes the profile row")
    func deleteSurvivesAFailedDirectoryRemoval() async throws {
        let tempBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-delete-rmfail-\(UUID().uuidString)", isDirectory: true)
        let tempHostDir = tempBaseDir.appendingPathComponent("host-claude", isDirectory: true)
        let profilesDir = tempBaseDir.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHostDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        defer {
            // Restore write permission first, or the teardown cannot remove the
            // tree it just made unwritable.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: profilesDir.path)
            try? FileManager.default.removeItem(at: tempBaseDir)
        }

        let manager = ClaudeProfileConfigDirManager(
            baseDirectory: profilesDir, hostBaseDirectory: tempHostDir)
        let (router, db, _) = makeRouter(
            configDirManager: manager, claudeCredentialsKeychain: ProfileRowPresenceProbe())

        let profile = try await db.modelProfiles.create(name: "RmFailCanary", kind: .oauth)
        _ = try manager.ensureOAuthDir(forProfileID: profile.id)
        let profileDir = manager.profileDirectory(forProfileID: profile.id)

        // Unlinking a child needs write permission on the parent, so this makes
        // the handler's `removeItem` fail without touching the child itself.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: profilesDir.path)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileDelete,
            params: ModelProfileDeleteParams(id: profile.id)
        ))

        #expect(resp.success, "a best-effort cleanup failure must not fail the RPC")
        #expect(FileManager.default.fileExists(atPath: profileDir.path),
                "the removal really did fail — otherwise this test proves nothing")
        #expect(try await db.modelProfiles.get(id: profile.id) == nil)
    }

    @Test("delete preserves host mirror targets across multiple slots and removes sidecars")
    func deletePreservesHostMirrors() async throws {
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tempHostDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempHostDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempBaseDir)
            try? FileManager.default.removeItem(at: tempHostDir)
        }

        let fm = FileManager.default

        // Pre-create host slots
        try fm.createDirectory(at: tempHostDir.appendingPathComponent("projects", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: tempHostDir.appendingPathComponent("plugins", isDirectory: true), withIntermediateDirectories: true)
        try "# Host CLAUDE.md".write(to: tempHostDir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        let manager = ClaudeProfileConfigDirManager(baseDirectory: tempBaseDir, hostBaseDirectory: tempHostDir)
        let (router, db, _) = makeRouter(configDirManager: manager)
        defer { Task { await cleanupKeychain(db) } }

        // Create an OAuth profile and ensure its config dir with mirror symlinks
        let oauthProfile = try await db.modelProfiles.create(name: "OAuth", kind: .oauth)
        let profileClaudeDir = manager.configDirectory(forProfileID: oauthProfile.id)
        _ = try manager.ensureOAuthDir(forProfileID: oauthProfile.id)

        // Write sentinel files in host slots
        let projectsSentinel = tempHostDir.appendingPathComponent("projects/-Users-test-cwd/sentinel.jsonl")
        try fm.createDirectory(at: projectsSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "PROJECTS_SENTINEL".write(to: projectsSentinel, atomically: true, encoding: .utf8)

        let pluginsSentinel = tempHostDir.appendingPathComponent("plugins/sentinel.txt")
        try "PLUGINS_SENTINEL".write(to: pluginsSentinel, atomically: true, encoding: .utf8)

        // Create a sidecar by seeding profile-side CLAUDE.md, then calling ensure again
        let profileClaudeFile = profileClaudeDir.appendingPathComponent("CLAUDE.md")
        try "# Profile CLAUDE.md".write(to: profileClaudeFile, atomically: true, encoding: .utf8)
        _ = try manager.ensureOAuthDir(forProfileID: oauthProfile.id)

        let profileDir = manager.profileDirectory(forProfileID: oauthProfile.id)

        // Verify symlinks were created
        let profileProjects = profileClaudeDir.appendingPathComponent("projects")
        let profilePlugins = profileClaudeDir.appendingPathComponent("plugins")
        #expect((try? fm.destinationOfSymbolicLink(atPath: profileProjects.path)) != nil)
        #expect((try? fm.destinationOfSymbolicLink(atPath: profilePlugins.path)) != nil)
        #expect((try? fm.destinationOfSymbolicLink(atPath: profileClaudeFile.path)) != nil)

        // Verify sidecar was created
        let sidecar = profileClaudeDir.appendingPathComponent("CLAUDE.md.profile-local")
        #expect(fm.fileExists(atPath: sidecar.path))
        let sidecarContent = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(sidecarContent == "# Profile CLAUDE.md")

        // Delete the profile via RPC
        let resp = await router.handle(try RPCRequest(method: RPCMethod.modelProfileDelete,
                                                      params: ModelProfileDeleteParams(id: oauthProfile.id)))
        #expect(resp.success)

        // Verify the profile directory was deleted
        #expect(!fm.fileExists(atPath: profileDir.path))

        // Verify host sentinels still exist with original content
        #expect(fm.fileExists(atPath: projectsSentinel.path))
        #expect(fm.fileExists(atPath: pluginsSentinel.path))

        let projectsContent = try String(contentsOf: projectsSentinel, encoding: .utf8)
        #expect(projectsContent == "PROJECTS_SENTINEL")

        let pluginsContent = try String(contentsOf: pluginsSentinel, encoding: .utf8)
        #expect(pluginsContent == "PLUGINS_SENTINEL")

        // Verify sidecar is also gone (deleted with the profile dir)
        #expect(!fm.fileExists(atPath: sidecar.path))
    }

    // MARK: - rename

    @Test("rename success")
    func renameSuccess() async throws {
        let (router, db, _) = makeRouter()
        let tok = try await db.modelProfiles.create(name: "Old", kind: .oauth)
        let resp = await router.handle(try RPCRequest(method: RPCMethod.modelProfileRename,
                                                      params: ModelProfileRenameParams(id: tok.id, name: "New")))
        #expect(resp.success)
        #expect(try await db.modelProfiles.get(id: tok.id)?.name == "New")
    }

    @Test("rename duplicate rejected")
    func renameDuplicate() async throws {
        let (router, db, _) = makeRouter()
        let a = try await db.modelProfiles.create(name: "A", kind: .oauth)
        let b = try await db.modelProfiles.create(name: "B", kind: .oauth)
        let resp = await router.handle(try RPCRequest(method: RPCMethod.modelProfileRename,
                                                      params: ModelProfileRenameParams(id: b.id, name: "A")))
        #expect(!resp.success)
        #expect(try await db.modelProfiles.get(id: b.id)?.name == "B")
        _ = a
    }

    // MARK: - defaults

    @Test("setGlobalDefault round-trip")
    func setGlobalDefault() async throws {
        let (router, db, _) = makeRouter()
        let tok = try await db.modelProfiles.create(name: "A", kind: .oauth)
        _ = await router.handle(try RPCRequest(method: RPCMethod.modelProfileSetGlobalDefault,
                                               params: ModelProfileSetGlobalDefaultParams(id: tok.id)))
        #expect(try await db.config.get().defaultProfileID == tok.id)
        _ = await router.handle(try RPCRequest(method: RPCMethod.modelProfileSetGlobalDefault,
                                               params: ModelProfileSetGlobalDefaultParams(id: nil)))
        #expect(try await db.config.get().defaultProfileID == nil)
    }

    @Test("setPrimaryAgentPreference round-trip and list reports value")
    func setPrimaryAgentPreference() async throws {
        let (router, db, _) = makeRouter()
        let setResp = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileSetPrimaryAgentPreference,
            params: ModelProfileSetAgentPreferenceParams(preference: .codex)
        ))
        #expect(setResp.success)
        #expect(try await db.config.get().primaryAgentPreference == .codex)

        let listResp = await router.handle(RPCRequest(method: RPCMethod.modelProfileList))
        let result = try listResp.decodeResult(ModelProfileListResult.self)
        #expect(result.primaryAgentPreference == .codex)
    }

    @Test("setRepoOverride round-trip")
    func setRepoOverride() async throws {
        let (router, db, _) = makeRouter()
        let tok = try await db.modelProfiles.create(name: "A", kind: .oauth)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID().uuidString)",
                                              displayName: "r", defaultBranch: "main")
        _ = await router.handle(try RPCRequest(method: RPCMethod.modelProfileSetRepoOverride,
                                               params: ModelProfileSetRepoOverrideParams(repoID: repo.id, profileID: tok.id)))
        #expect(try await db.repos.get(id: repo.id)?.profileOverrideID == tok.id)
        _ = await router.handle(try RPCRequest(method: RPCMethod.modelProfileSetRepoOverride,
                                               params: ModelProfileSetRepoOverrideParams(repoID: repo.id, profileID: nil)))
        #expect(try await db.repos.get(id: repo.id)?.profileOverrideID == nil)
    }

    // MARK: - fetchUsage

    @Test("fetchUsage dedupes within 60s")
    func fetchUsageDedupes() async throws {
        let stub = StubClaudeUsageFetcher()
        let (router, db, _) = makeRouter(stub: stub)
        let tok = try await db.modelProfiles.create(name: "A", kind: .apiKey)
        try ModelProfileKeychain.store(id: tok.id.uuidString, token: freshToken(Self.apiPrefix))
        defer { try? ModelProfileKeychain.delete(id: tok.id.uuidString) }
        try await db.modelProfileUsage.upsert(ModelProfileUsage(
            profileID: tok.id, fiveHourPct: 0.7, sevenDayPct: 0.2, fetchedAt: Date()
        ))

        let resp = await router.handle(try RPCRequest(method: RPCMethod.modelProfileFetchUsage,
                                                      params: ModelProfileFetchUsageParams(id: tok.id)))
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileFetchUsageResult.self)
        #expect(result.usage.fiveHourPct == 0.7)
        #expect(stub.callCount == 0)
    }

    @Test("fetchUsage refreshes after 60s")
    func fetchUsageRefreshes() async throws {
        let new = ClaudeUsageResult(
            fiveHourPct: 0.99, sevenDayPct: 0.5,
            fiveHourResetsAt: Date().addingTimeInterval(3600),
            sevenDayResetsAt: Date().addingTimeInterval(7 * 86_400)
        )
        let stub = StubClaudeUsageFetcher(responses: [.ok(new)])
        let (router, db, _) = makeRouter(stub: stub)
        defer { Task { await cleanupKeychain(db) } }

        let tok = try await db.modelProfiles.create(name: "A", kind: .apiKey)
        try ModelProfileKeychain.store(id: tok.id.uuidString, token: freshToken(Self.apiPrefix))
        try await db.modelProfileUsage.upsert(ModelProfileUsage(
            profileID: tok.id, fiveHourPct: 0.1, sevenDayPct: 0.0,
            fetchedAt: Date().addingTimeInterval(-120)
        ))

        let resp = await router.handle(try RPCRequest(method: RPCMethod.modelProfileFetchUsage,
                                                      params: ModelProfileFetchUsageParams(id: tok.id)))
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileFetchUsageResult.self)
        #expect(result.usage.fiveHourPct == 0.99)
        #expect(stub.callCount == 1)
        let cached = try await db.modelProfileUsage.get(profileID: tok.id)
        #expect(cached?.fiveHourPct == 0.99)
        try? ModelProfileKeychain.delete(id: tok.id.uuidString)
    }

    @Test("fetchUsage propagates 401")
    func fetchUsage401() async throws {
        let stub = StubClaudeUsageFetcher(responses: [.http401])
        let (router, db, _) = makeRouter(stub: stub)
        defer { Task { await cleanupKeychain(db) } }

        let tok = try await db.modelProfiles.create(name: "A", kind: .apiKey)
        try ModelProfileKeychain.store(id: tok.id.uuidString, token: freshToken(Self.apiPrefix))
        let resp = await router.handle(try RPCRequest(method: RPCMethod.modelProfileFetchUsage,
                                                      params: ModelProfileFetchUsageParams(id: tok.id)))
        #expect(!resp.success)
        #expect(resp.error?.lowercased().contains("invalid") == true)
        try? ModelProfileKeychain.delete(id: tok.id.uuidString)
    }

    // MARK: - bedrock add

    @Test("add bedrock: persists fields, skips token + keychain + probe")
    func addBedrockHappyPath() async throws {
        let stub = StubClaudeUsageFetcher()
        let (router, db, _) = makeRouter(stub: stub)
        let req = try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(
                name: "Bedrock prod",
                kind: .bedrock,
                token: nil,
                baseURL: nil,
                model: "anthropic.claude-sonnet-4-5",
                awsRegion: "us-west-2",
                awsProfile: "acme-prod"
            )
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileAddResult.self)
        #expect(result.warning == nil)
        #expect(result.profile.kind == .bedrock)
        #expect(result.profile.awsRegion == "us-west-2")
        #expect(result.profile.awsProfile == "acme-prod")
        let stored = try await db.modelProfiles.list()
        #expect(stored.count == 1)
        #expect(stored.first?.kind == .bedrock)
        #expect(stored.first?.awsRegion == "us-west-2")
        #expect(stored.first?.awsProfile == "acme-prod")
        // No keychain entry should be written for bedrock profiles
        #expect(try ModelProfileKeychain.load(id: result.profile.id.uuidString) == nil)
        // Usage fetcher must not be called
        #expect(stub.callCount == 0)
    }

    @Test("add bedrock: rejects missing region")
    func addBedrockMissingRegion() async throws {
        let (router, db, _) = makeRouter()
        let req = try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(
                name: "Bedrock",
                kind: .bedrock,
                token: nil,
                baseURL: nil,
                model: "anthropic.claude-sonnet-4-5",
                awsRegion: "",
                awsProfile: nil
            )
        )
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error?.lowercased().contains("region") == true)
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    @Test("add bedrock: rejects missing model")
    func addBedrockMissingModel() async throws {
        let (router, db, _) = makeRouter()
        let req = try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(
                name: "Bedrock",
                kind: .bedrock,
                token: nil,
                baseURL: nil,
                model: "",
                awsRegion: "us-west-2",
                awsProfile: nil
            )
        )
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error?.lowercased().contains("model") == true)
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    @Test("add bedrock: whitespace-only awsProfile normalized to nil")
    func addBedrockEmptyAwsProfileNormalized() async throws {
        let (router, db, _) = makeRouter()
        let req = try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(
                name: "Bedrock",
                kind: .bedrock,
                token: nil,
                baseURL: nil,
                model: "anthropic.claude-sonnet-4-5",
                awsRegion: "us-west-2",
                awsProfile: "   "
            )
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let stored = try await db.modelProfiles.list()
        #expect(stored.first?.awsProfile == nil)
    }

    // MARK: - updateBedrock

    @Test("modelProfile.updateBedrock: persists new region/profile/model")
    func updateBedrockHappyPath() async throws {
        let (router, db, _) = makeRouter()
        let row = try await db.modelProfiles.create(
            name: "Bedrock",
            kind: .bedrock,
            baseURL: nil,
            model: "old",
            awsRegion: "us-west-2",
            awsProfile: "old-profile"
        )
        let req = try RPCRequest(
            method: RPCMethod.modelProfileUpdateBedrock,
            params: ModelProfileUpdateBedrockParams(
                id: row.id,
                awsRegion: "us-east-1",
                awsProfile: "new-profile",
                model: "new"
            )
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let updated = try await db.modelProfiles.get(id: row.id)
        #expect(updated?.awsRegion == "us-east-1")
        #expect(updated?.awsProfile == "new-profile")
        #expect(updated?.model == "new")
    }

    @Test("modelProfile.updateBedrock: rejects non-bedrock profile")
    func updateBedrockWrongKind() async throws {
        let (router, db, _) = makeRouter()
        defer { Task { await cleanupKeychain(db) } }
        let token = freshToken()
        let addReq = try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(name: "OAuth", token: token)
        )
        let addResp = await router.handle(addReq)
        #expect(addResp.success)
        let listed = try await db.modelProfiles.list()
        let oauthProfile = listed.first { $0.kind == .oauth }!
        let req = try RPCRequest(
            method: RPCMethod.modelProfileUpdateBedrock,
            params: ModelProfileUpdateBedrockParams(
                id: oauthProfile.id,
                awsRegion: "us-west-2",
                awsProfile: nil,
                model: "m"
            )
        )
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error?.lowercased().contains("bedrock") == true)
    }

    @Test("modelProfile.updateBedrock: empty awsProfile normalized to nil")
    func updateBedrockEmptyAwsProfileNormalized() async throws {
        let (router, db, _) = makeRouter()
        let row = try await db.modelProfiles.create(
            name: "Bedrock",
            kind: .bedrock,
            model: "m",
            awsRegion: "us-west-2",
            awsProfile: "old"
        )
        let req = try RPCRequest(
            method: RPCMethod.modelProfileUpdateBedrock,
            params: ModelProfileUpdateBedrockParams(
                id: row.id,
                awsRegion: "us-west-2",
                awsProfile: "   ",
                model: "m"
            )
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let updated = try await db.modelProfiles.get(id: row.id)
        #expect(updated?.awsProfile == nil)
    }

    @Test("modelProfile.updateBedrock: rejects empty region")
    func updateBedrockMissingRegion() async throws {
        let (router, db, _) = makeRouter()
        let row = try await db.modelProfiles.create(
            name: "Bedrock",
            kind: .bedrock,
            model: "m",
            awsRegion: "us-west-2",
            awsProfile: nil
        )
        let req = try RPCRequest(
            method: RPCMethod.modelProfileUpdateBedrock,
            params: ModelProfileUpdateBedrockParams(
                id: row.id,
                awsRegion: "",
                awsProfile: nil,
                model: "m"
            )
        )
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error?.lowercased().contains("region") == true)
    }

    // MARK: - fetchUsage bedrock rejection

    @Test("fetchUsage rejects bedrock profiles")
    func fetchUsageRejectsBedrock() async throws {
        let stub = StubClaudeUsageFetcher()
        let (router, db, _) = makeRouter(stub: stub)
        let row = try await db.modelProfiles.create(
            name: "Bedrock",
            kind: .bedrock,
            baseURL: nil,
            model: "anthropic.claude-sonnet-4-5",
            awsRegion: "us-west-2",
            awsProfile: nil
        )
        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.modelProfileFetchUsage,
            params: ModelProfileFetchUsageParams(id: row.id)
        ))
        #expect(!resp.success)
        #expect(resp.error?.lowercased().contains("not available") == true)
        #expect(stub.callCount == 0)
    }

    // MARK: - fallbackModels (Idea 2: user-settable via RPC)

    @Test("add: forwards fallbackModels to the stored oauth profile")
    func addForwardsFallbackModels() async throws {
        let (router, db, _) = makeRouter()
        let req = try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(
                name: "WithFallback", token: nil,
                fallbackModels: ["claude-haiku-4-5-20251001", "claude-sonnet-4-5"]
            )
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileAddResult.self)
        #expect(result.profile.fallbackModels == ["claude-haiku-4-5-20251001", "claude-sonnet-4-5"])
        let reloaded = try await db.modelProfiles.get(id: result.profile.id)
        #expect(reloaded?.fallbackModels == ["claude-haiku-4-5-20251001", "claude-sonnet-4-5"])
    }

    @Test("add: normalizes fallbackModels — trims, drops blanks, caps at 3")
    func addNormalizesFallbackModels() async throws {
        let (router, db, _) = makeRouter()
        let req = try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(
                name: "Normalize", token: nil,
                fallbackModels: ["  a  ", "", "b", "   ", "c", "d"]
            )
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileAddResult.self)
        // Trimmed, blanks dropped, capped at 3, order preserved.
        #expect(result.profile.fallbackModels == ["a", "b", "c"])
        _ = db
    }

    @Test("add: nil fallbackModels stores nil")
    func addNilFallbackModels() async throws {
        let (router, _, _) = makeRouter()
        let req = try RPCRequest(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(name: "NoFallback", token: nil)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileAddResult.self)
        #expect(result.profile.fallbackModels == nil)
    }

    @Test("updateEndpoint: forwards fallbackModels (set then clear)")
    func updateEndpointForwardsFallbackModels() async throws {
        let (router, db, _) = makeRouter()
        let row = try await db.modelProfiles.create(name: "P", kind: .oauth)

        let setReq = try RPCRequest(
            method: RPCMethod.modelProfileUpdateEndpoint,
            params: ModelProfileUpdateEndpointParams(
                id: row.id, baseURL: nil, model: "opus",
                fallbackModels: ["claude-haiku-4-5-20251001"]
            )
        )
        #expect(await router.handle(setReq).success)
        #expect(try await db.modelProfiles.get(id: row.id)?.fallbackModels == ["claude-haiku-4-5-20251001"])

        let clearReq = try RPCRequest(
            method: RPCMethod.modelProfileUpdateEndpoint,
            params: ModelProfileUpdateEndpointParams(
                id: row.id, baseURL: nil, model: "opus", fallbackModels: nil
            )
        )
        #expect(await router.handle(clearReq).success)
        #expect(try await db.modelProfiles.get(id: row.id)?.fallbackModels == nil)
    }

    @Test("updateBedrock: forwards fallbackModels")
    func updateBedrockForwardsFallbackModels() async throws {
        let (router, db, _) = makeRouter()
        let row = try await db.modelProfiles.create(
            name: "B", kind: .bedrock, model: "anthropic.claude-sonnet-4-5", awsRegion: "us-west-2"
        )
        let req = try RPCRequest(
            method: RPCMethod.modelProfileUpdateBedrock,
            params: ModelProfileUpdateBedrockParams(
                id: row.id, awsRegion: "us-east-1", awsProfile: nil,
                model: "anthropic.claude-sonnet-4-5",
                fallbackModels: ["anthropic.claude-haiku-4-5"]
            )
        )
        #expect(await router.handle(req).success)
        #expect(try await db.modelProfiles.get(id: row.id)?.fallbackModels == ["anthropic.claude-haiku-4-5"])
    }

    // MARK: - prepareConfigDir

    private func makeTempConfigDirManager() -> (ClaudeProfileConfigDirManager, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-prepare-configdir-\(UUID().uuidString)", isDirectory: true)
        let manager = ClaudeProfileConfigDirManager(
            baseDirectory: base.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: base.appendingPathComponent("host-claude", isDirectory: true)
        )
        return (manager, base)
    }

    @Test("prepareConfigDir: oauth profile gets a seeded dir and its path back")
    func prepareConfigDirOAuth() async throws {
        let (manager, base) = makeTempConfigDirManager()
        defer { try? FileManager.default.removeItem(at: base) }
        let (router, db, _) = makeRouter(configDirManager: manager)

        let profile = try await db.modelProfiles.create(name: "LoginTarget", kind: .oauth)
        let req = try RPCRequest(
            method: RPCMethod.modelProfilePrepareConfigDir,
            params: ModelProfilePrepareConfigDirParams(id: profile.id)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfilePrepareConfigDirResult.self)
        #expect(result.configDirPath == manager.configDirectory(forProfileID: profile.id).path)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: result.configDirPath, isDirectory: &isDir))
        #expect(isDir.boolValue)
        // Seeded with the minimal OAuth .claude.json (hasCompletedOnboarding).
        let claudeJSON = result.configDirPath + "/.claude.json"
        #expect(FileManager.default.fileExists(atPath: claudeJSON))
    }

    @Test("prepareConfigDir: idempotent — second call returns the same path")
    func prepareConfigDirIdempotent() async throws {
        let (manager, base) = makeTempConfigDirManager()
        defer { try? FileManager.default.removeItem(at: base) }
        let (router, db, _) = makeRouter(configDirManager: manager)

        let profile = try await db.modelProfiles.create(name: "Twice", kind: .oauth)
        let req = try RPCRequest(
            method: RPCMethod.modelProfilePrepareConfigDir,
            params: ModelProfilePrepareConfigDirParams(id: profile.id)
        )
        let first = try (await router.handle(req)).decodeResult(ModelProfilePrepareConfigDirResult.self)
        let second = try (await router.handle(req)).decodeResult(ModelProfilePrepareConfigDirResult.self)
        #expect(first.configDirPath == second.configDirPath)
    }

    @Test("prepareConfigDir: rejects non-oauth kinds with the kind in the error")
    func prepareConfigDirRejectsNonOAuth() async throws {
        let (manager, base) = makeTempConfigDirManager()
        defer { try? FileManager.default.removeItem(at: base) }
        let (router, db, _) = makeRouter(configDirManager: manager)

        let apiKey = try await db.modelProfiles.create(name: "Keyed", kind: .apiKey)
        let bedrock = try await db.modelProfiles.create(
            name: "West", kind: .bedrock, model: "anthropic.claude-sonnet-4-5", awsRegion: "us-west-2"
        )

        for (profile, kind) in [(apiKey, "apiKey"), (bedrock, "bedrock")] {
            let req = try RPCRequest(
                method: RPCMethod.modelProfilePrepareConfigDir,
                params: ModelProfilePrepareConfigDirParams(id: profile.id)
            )
            let resp = await router.handle(req)
            #expect(!resp.success)
            #expect(resp.error?.contains(kind) == true)
            // No config dir was provisioned for the rejected profile.
            let dir = manager.configDirectory(forProfileID: profile.id)
            #expect(!FileManager.default.fileExists(atPath: dir.path))
        }
    }

    @Test("prepareConfigDir: unknown id fails with profile-not-found")
    func prepareConfigDirUnknownID() async throws {
        let (router, _, _) = makeRouter()
        let req = try RPCRequest(
            method: RPCMethod.modelProfilePrepareConfigDir,
            params: ModelProfilePrepareConfigDirParams(id: UUID())
        )
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error == "Profile not found")
    }
}

}
