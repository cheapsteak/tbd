import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

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

@Suite("ModelProfile RPC Handlers")
struct ModelProfileRPCTests {

    private static let oauthPrefix = "sk-ant-oat01-"
    private static let apiPrefix = "sk-ant-api03-"

    private func freshToken(_ prefix: String = oauthPrefix) -> String {
        prefix + UUID().uuidString
    }

    private func makeRouter(stub: StubClaudeUsageFetcher = StubClaudeUsageFetcher())
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
            usageFetcher: stub
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

    @Test("add: oauth + .ok stores row, keychain, usage")
    func addOauthOk() async throws {
        let stub = StubClaudeUsageFetcher(responses: [.ok(sampleUsage())])
        let (router, db, _) = makeRouter(stub: stub)
        defer { Task { await cleanupKeychain(db) } }

        let tokenBytes = freshToken()
        let req = try RPCRequest(method: RPCMethod.modelProfileAdd,
                                 params: ModelProfileAddParams(name: "Personal", token: tokenBytes))
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileAddResult.self)
        #expect(result.warning == nil)
        #expect(result.profile.kind == .oauth)

        let listed = try await db.modelProfiles.list()
        #expect(listed.count == 1)
        let kc = try ModelProfileKeychain.load(id: result.profile.id.uuidString)
        #expect(kc == tokenBytes)
        let usage = try await db.modelProfileUsage.get(profileID: result.profile.id)
        #expect(usage != nil)
        #expect(usage?.fiveHourPct == 0.42)
        try? ModelProfileKeychain.delete(id: result.profile.id.uuidString)
    }

    @Test("add: oauth + .http401 rejects without persisting")
    func addOauth401() async throws {
        let stub = StubClaudeUsageFetcher(responses: [.http401])
        let (router, db, _) = makeRouter(stub: stub)
        let req = try RPCRequest(method: RPCMethod.modelProfileAdd,
                                 params: ModelProfileAddParams(name: "Bad", token: freshToken()))
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error == "Token invalid")
        #expect(try await db.modelProfiles.list().isEmpty)
    }

    @Test("add: oauth + .networkError saves with warning, no usage row")
    func addOauthNetworkError() async throws {
        let stub = StubClaudeUsageFetcher(responses: [.networkError("offline")])
        let (router, db, _) = makeRouter(stub: stub)
        defer { Task { await cleanupKeychain(db) } }

        let req = try RPCRequest(method: RPCMethod.modelProfileAdd,
                                 params: ModelProfileAddParams(name: "Maybe", token: freshToken()))
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ModelProfileAddResult.self)
        #expect(result.warning != nil)
        #expect(try await db.modelProfiles.list().count == 1)
        #expect(try await db.modelProfileUsage.get(profileID: result.profile.id) == nil)
        try? ModelProfileKeychain.delete(id: result.profile.id.uuidString)
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
        let tok = try await db.modelProfiles.create(name: "Solo", kind: .oauth)
        try ModelProfileKeychain.store(id: tok.id.uuidString, token: "value")
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
        let tok = try await db.modelProfiles.create(name: "A", kind: .oauth)
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

        let tok = try await db.modelProfiles.create(name: "A", kind: .oauth)
        try ModelProfileKeychain.store(id: tok.id.uuidString, token: "secret")
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

        let tok = try await db.modelProfiles.create(name: "A", kind: .oauth)
        try ModelProfileKeychain.store(id: tok.id.uuidString, token: "secret")
        let resp = await router.handle(try RPCRequest(method: RPCMethod.modelProfileFetchUsage,
                                                      params: ModelProfileFetchUsageParams(id: tok.id)))
        #expect(!resp.success)
        #expect(resp.error?.lowercased().contains("invalid") == true)
        try? ModelProfileKeychain.delete(id: tok.id.uuidString)
    }
}
