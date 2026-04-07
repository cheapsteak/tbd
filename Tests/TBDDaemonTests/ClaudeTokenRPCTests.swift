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

@Suite("ClaudeToken RPC Handlers")
struct ClaudeTokenRPCTests {

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
        let tokens = (try? await db.claudeTokens.list()) ?? []
        for t in tokens {
            try? ClaudeTokenKeychain.delete(id: t.id.uuidString)
        }
    }

    // MARK: - add

    @Test("add: oauth + .ok stores row, keychain, usage")
    func addOauthOk() async throws {
        let stub = StubClaudeUsageFetcher(responses: [.ok(sampleUsage())])
        let (router, db, _) = makeRouter(stub: stub)
        defer { Task { await cleanupKeychain(db) } }

        let tokenBytes = freshToken()
        let req = try RPCRequest(method: RPCMethod.claudeTokenAdd,
                                 params: ClaudeTokenAddParams(name: "Personal", token: tokenBytes))
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ClaudeTokenAddResult.self)
        #expect(result.warning == nil)
        #expect(result.token.kind == .oauth)

        let listed = try await db.claudeTokens.list()
        #expect(listed.count == 1)
        let kc = try ClaudeTokenKeychain.load(id: result.token.id.uuidString)
        #expect(kc == tokenBytes)
        let usage = try await db.claudeTokenUsage.get(tokenID: result.token.id)
        #expect(usage != nil)
        #expect(usage?.fiveHourPct == 0.42)
        try? ClaudeTokenKeychain.delete(id: result.token.id.uuidString)
    }

    @Test("add: oauth + .http401 rejects without persisting")
    func addOauth401() async throws {
        let stub = StubClaudeUsageFetcher(responses: [.http401])
        let (router, db, _) = makeRouter(stub: stub)
        let req = try RPCRequest(method: RPCMethod.claudeTokenAdd,
                                 params: ClaudeTokenAddParams(name: "Bad", token: freshToken()))
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error == "Token invalid")
        #expect(try await db.claudeTokens.list().isEmpty)
    }

    @Test("add: oauth + .networkError saves with warning, no usage row")
    func addOauthNetworkError() async throws {
        let stub = StubClaudeUsageFetcher(responses: [.networkError("offline")])
        let (router, db, _) = makeRouter(stub: stub)
        defer { Task { await cleanupKeychain(db) } }

        let req = try RPCRequest(method: RPCMethod.claudeTokenAdd,
                                 params: ClaudeTokenAddParams(name: "Maybe", token: freshToken()))
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ClaudeTokenAddResult.self)
        #expect(result.warning != nil)
        #expect(try await db.claudeTokens.list().count == 1)
        #expect(try await db.claudeTokenUsage.get(tokenID: result.token.id) == nil)
        try? ClaudeTokenKeychain.delete(id: result.token.id.uuidString)
    }

    @Test("add: api_key prefix skips fetcher")
    func addApiKey() async throws {
        let stub = StubClaudeUsageFetcher()
        let (router, db, _) = makeRouter(stub: stub)
        defer { Task { await cleanupKeychain(db) } }

        let req = try RPCRequest(method: RPCMethod.claudeTokenAdd,
                                 params: ClaudeTokenAddParams(name: "Work", token: freshToken(Self.apiPrefix)))
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(ClaudeTokenAddResult.self)
        #expect(stub.callCount == 0)
        #expect(result.token.kind == .apiKey)
        #expect(try await db.claudeTokenUsage.get(tokenID: result.token.id) == nil)
        try? ClaudeTokenKeychain.delete(id: result.token.id.uuidString)
    }

    @Test("add: bad prefix rejected")
    func addBadPrefix() async throws {
        let stub = StubClaudeUsageFetcher()
        let (router, db, _) = makeRouter(stub: stub)
        let req = try RPCRequest(method: RPCMethod.claudeTokenAdd,
                                 params: ClaudeTokenAddParams(name: "Junk", token: "garbage"))
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(stub.callCount == 0)
        #expect(try await db.claudeTokens.list().isEmpty)
    }

    @Test("add: token with embedded newline rejected at storage")
    func addRejectsNewline() async throws {
        let (router, db, _) = makeRouter()
        let bad = Self.oauthPrefix + "abc\ndef"
        let req = try RPCRequest(method: RPCMethod.claudeTokenAdd,
                                 params: ClaudeTokenAddParams(name: "Bad", token: bad))
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error?.contains("invalid characters") == true)
        #expect(try await db.claudeTokens.list().isEmpty)
    }

    @Test("add: duplicate name rejected")
    func addDuplicateName() async throws {
        let stub = StubClaudeUsageFetcher(responses: [.ok(sampleUsage())])
        let (router, db, _) = makeRouter(stub: stub)
        defer { Task { await cleanupKeychain(db) } }

        let first = try RPCRequest(method: RPCMethod.claudeTokenAdd,
                                   params: ClaudeTokenAddParams(name: "Personal", token: freshToken()))
        _ = await router.handle(first)

        let second = try RPCRequest(method: RPCMethod.claudeTokenAdd,
                                    params: ClaudeTokenAddParams(name: "Personal", token: freshToken()))
        let resp = await router.handle(second)
        #expect(!resp.success)
        #expect(try await db.claudeTokens.list().count == 1)
    }

    // MARK: - list

    @Test("list joins usage")
    func listJoinsUsage() async throws {
        let (router, db, _) = makeRouter()
        let a = try await db.claudeTokens.create(name: "A", kind: .oauth)
        let b = try await db.claudeTokens.create(name: "B", kind: .apiKey)
        try await db.claudeTokenUsage.upsert(ClaudeTokenUsage(
            tokenID: a.id, fiveHourPct: 0.5, sevenDayPct: 0.1, fetchedAt: Date()
        ))

        let resp = await router.handle(RPCRequest(method: RPCMethod.claudeTokenList))
        #expect(resp.success)
        let result = try resp.decodeResult(ClaudeTokenListResult.self)
        #expect(result.tokens.count == 2)
        let withA = result.tokens.first { $0.token.id == a.id }
        let withB = result.tokens.first { $0.token.id == b.id }
        #expect(withA?.usage != nil)
        #expect(withB?.usage == nil)
    }

    // MARK: - delete

    @Test("delete clears global default + keychain + usage")
    func deleteClearsDefault() async throws {
        let (router, db, _) = makeRouter()
        let tok = try await db.claudeTokens.create(name: "Solo", kind: .oauth)
        try ClaudeTokenKeychain.store(id: tok.id.uuidString, token: "value")
        try await db.claudeTokenUsage.upsert(ClaudeTokenUsage(tokenID: tok.id, fetchedAt: Date()))
        try await db.config.setDefaultClaudeTokenID(tok.id)

        let resp = await router.handle(try RPCRequest(method: RPCMethod.claudeTokenDelete,
                                                      params: ClaudeTokenDeleteParams(id: tok.id)))
        #expect(resp.success)
        #expect(try await db.claudeTokens.get(id: tok.id) == nil)
        #expect(try await db.claudeTokenUsage.get(tokenID: tok.id) == nil)
        #expect(try await db.config.get().defaultClaudeTokenID == nil)
        #expect(try ClaudeTokenKeychain.load(id: tok.id.uuidString) == nil)
    }

    @Test("delete clears repo override")
    func deleteClearsRepoOverride() async throws {
        let (router, db, _) = makeRouter()
        let tok = try await db.claudeTokens.create(name: "Solo", kind: .oauth)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID().uuidString)",
                                              displayName: "r", defaultBranch: "main")
        try await db.repos.setClaudeTokenOverride(id: repo.id, tokenID: tok.id)

        _ = await router.handle(try RPCRequest(method: RPCMethod.claudeTokenDelete,
                                               params: ClaudeTokenDeleteParams(id: tok.id)))
        let after = try await db.repos.get(id: repo.id)
        #expect(after?.claudeTokenOverrideID == nil)
    }

    @Test("delete leaves unrelated default in place")
    func deleteUnrelated() async throws {
        let (router, db, _) = makeRouter()
        let a = try await db.claudeTokens.create(name: "A", kind: .oauth)
        let b = try await db.claudeTokens.create(name: "B", kind: .oauth)
        try await db.config.setDefaultClaudeTokenID(a.id)

        _ = await router.handle(try RPCRequest(method: RPCMethod.claudeTokenDelete,
                                               params: ClaudeTokenDeleteParams(id: b.id)))
        #expect(try await db.config.get().defaultClaudeTokenID == a.id)
    }

    // MARK: - rename

    @Test("rename success")
    func renameSuccess() async throws {
        let (router, db, _) = makeRouter()
        let tok = try await db.claudeTokens.create(name: "Old", kind: .oauth)
        let resp = await router.handle(try RPCRequest(method: RPCMethod.claudeTokenRename,
                                                      params: ClaudeTokenRenameParams(id: tok.id, name: "New")))
        #expect(resp.success)
        #expect(try await db.claudeTokens.get(id: tok.id)?.name == "New")
    }

    @Test("rename duplicate rejected")
    func renameDuplicate() async throws {
        let (router, db, _) = makeRouter()
        let a = try await db.claudeTokens.create(name: "A", kind: .oauth)
        let b = try await db.claudeTokens.create(name: "B", kind: .oauth)
        let resp = await router.handle(try RPCRequest(method: RPCMethod.claudeTokenRename,
                                                      params: ClaudeTokenRenameParams(id: b.id, name: "A")))
        #expect(!resp.success)
        #expect(try await db.claudeTokens.get(id: b.id)?.name == "B")
        _ = a
    }

    // MARK: - defaults

    @Test("setGlobalDefault round-trip")
    func setGlobalDefault() async throws {
        let (router, db, _) = makeRouter()
        let tok = try await db.claudeTokens.create(name: "A", kind: .oauth)
        _ = await router.handle(try RPCRequest(method: RPCMethod.claudeTokenSetGlobalDefault,
                                               params: ClaudeTokenSetGlobalDefaultParams(id: tok.id)))
        #expect(try await db.config.get().defaultClaudeTokenID == tok.id)
        _ = await router.handle(try RPCRequest(method: RPCMethod.claudeTokenSetGlobalDefault,
                                               params: ClaudeTokenSetGlobalDefaultParams(id: nil)))
        #expect(try await db.config.get().defaultClaudeTokenID == nil)
    }

    @Test("setRepoOverride round-trip")
    func setRepoOverride() async throws {
        let (router, db, _) = makeRouter()
        let tok = try await db.claudeTokens.create(name: "A", kind: .oauth)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID().uuidString)",
                                              displayName: "r", defaultBranch: "main")
        _ = await router.handle(try RPCRequest(method: RPCMethod.claudeTokenSetRepoOverride,
                                               params: ClaudeTokenSetRepoOverrideParams(repoID: repo.id, tokenID: tok.id)))
        #expect(try await db.repos.get(id: repo.id)?.claudeTokenOverrideID == tok.id)
        _ = await router.handle(try RPCRequest(method: RPCMethod.claudeTokenSetRepoOverride,
                                               params: ClaudeTokenSetRepoOverrideParams(repoID: repo.id, tokenID: nil)))
        #expect(try await db.repos.get(id: repo.id)?.claudeTokenOverrideID == nil)
    }

    // MARK: - fetchUsage

    @Test("fetchUsage dedupes within 60s")
    func fetchUsageDedupes() async throws {
        let stub = StubClaudeUsageFetcher()
        let (router, db, _) = makeRouter(stub: stub)
        let tok = try await db.claudeTokens.create(name: "A", kind: .oauth)
        try await db.claudeTokenUsage.upsert(ClaudeTokenUsage(
            tokenID: tok.id, fiveHourPct: 0.7, sevenDayPct: 0.2, fetchedAt: Date()
        ))

        let resp = await router.handle(try RPCRequest(method: RPCMethod.claudeTokenFetchUsage,
                                                      params: ClaudeTokenFetchUsageParams(id: tok.id)))
        #expect(resp.success)
        let result = try resp.decodeResult(ClaudeTokenFetchUsageResult.self)
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

        let tok = try await db.claudeTokens.create(name: "A", kind: .oauth)
        try ClaudeTokenKeychain.store(id: tok.id.uuidString, token: "secret")
        try await db.claudeTokenUsage.upsert(ClaudeTokenUsage(
            tokenID: tok.id, fiveHourPct: 0.1, sevenDayPct: 0.0,
            fetchedAt: Date().addingTimeInterval(-120)
        ))

        let resp = await router.handle(try RPCRequest(method: RPCMethod.claudeTokenFetchUsage,
                                                      params: ClaudeTokenFetchUsageParams(id: tok.id)))
        #expect(resp.success)
        let result = try resp.decodeResult(ClaudeTokenFetchUsageResult.self)
        #expect(result.usage.fiveHourPct == 0.99)
        #expect(stub.callCount == 1)
        let cached = try await db.claudeTokenUsage.get(tokenID: tok.id)
        #expect(cached?.fiveHourPct == 0.99)
        try? ClaudeTokenKeychain.delete(id: tok.id.uuidString)
    }

    @Test("fetchUsage propagates 401")
    func fetchUsage401() async throws {
        let stub = StubClaudeUsageFetcher(responses: [.http401])
        let (router, db, _) = makeRouter(stub: stub)
        defer { Task { await cleanupKeychain(db) } }

        let tok = try await db.claudeTokens.create(name: "A", kind: .oauth)
        try ClaudeTokenKeychain.store(id: tok.id.uuidString, token: "secret")
        let resp = await router.handle(try RPCRequest(method: RPCMethod.claudeTokenFetchUsage,
                                                      params: ClaudeTokenFetchUsageParams(id: tok.id)))
        #expect(!resp.success)
        #expect(resp.error?.lowercased().contains("invalid") == true)
        try? ClaudeTokenKeychain.delete(id: tok.id.uuidString)
    }
}
