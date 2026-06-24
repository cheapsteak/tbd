import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// Cross-cutting RPC methods that don't fit a single subsystem: notify,
// daemon.status, resolve.path, pr.list/refresh, note.create/list/update.
extension RPCRouterTests {

    // MARK: - Notification Tests

    @Test("notify inserts notification into db")
    func notify() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )

        let request = try RPCRequest(
            method: RPCMethod.notify,
            params: NotifyParams(worktreeID: wt.id, type: .taskComplete, message: "Build done")
        )
        let response = await router.handle(request)

        #expect(response.success)

        let notification = try response.decodeResult(TBDNotification.self)
        #expect(notification.type == .taskComplete)
        #expect(notification.message == "Build done")
    }

    @Test("notify requires worktreeID")
    func notifyRequiresWorktreeID() async throws {
        let request = try RPCRequest(
            method: RPCMethod.notify,
            params: NotifyParams(worktreeID: nil, type: .error, message: "oops")
        )
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("worktreeID") == true)
    }

    // MARK: - Daemon Status

    @Test("daemon.status returns version and uptime")
    func daemonStatus() async throws {
        let request = RPCRequest(method: RPCMethod.daemonStatus)
        let response = await router.handle(request)

        #expect(response.success)

        let status = try response.decodeResult(DaemonStatusResult.self)
        #expect(status.version == TBDConstants.version)
        #expect(status.uptime >= 0)
        #expect(status.connectedClients == 0)
    }

    @Test("daemon.status reports the live connected-client count when wired")
    func daemonStatusReportsConnectedClients() async throws {
        router.connectedClientsProvider = { 3 }
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonStatus))
        #expect(response.success)
        let status = try response.decodeResult(DaemonStatusResult.self)
        #expect(status.connectedClients == 3)
    }

    // MARK: - Resolve Path

    @Test("resolve.path finds repo by path")
    func resolvePathFindsRepo() async throws {
        let path = "/tmp/test-repo-\(UUID().uuidString)"
        let repo = try await db.repos.create(
            path: path,
            displayName: "test-repo",
            defaultBranch: "main"
        )

        let request = try RPCRequest(
            method: RPCMethod.resolvePath,
            params: ResolvePathParams(path: path)
        )
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(ResolvedPathResult.self)
        #expect(result.repoID == repo.id)
        #expect(result.worktreeID == nil)
    }

    @Test("resolve.path finds worktree by path")
    func resolvePathFindsWorktree() async throws {
        let repoPath = "/tmp/test-repo-\(UUID().uuidString)"
        let repo = try await db.repos.create(
            path: repoPath,
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wtPath = "/tmp/test-wt-\(UUID().uuidString)"
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: wtPath,
            tmuxServer: "tbd-test"
        )

        let request = try RPCRequest(
            method: RPCMethod.resolvePath,
            params: ResolvePathParams(path: wtPath)
        )
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(ResolvedPathResult.self)
        #expect(result.repoID == wt.repoID)
        #expect(result.worktreeID == wt.id)
    }

    @Test("resolve.path walks up directories to find repo")
    func resolvePathWalksUp() async throws {
        let repoPath = "/tmp/test-repo-\(UUID().uuidString)"
        let repo = try await db.repos.create(
            path: repoPath,
            displayName: "test-repo",
            defaultBranch: "main"
        )

        // Ask for a subdirectory of the repo
        let subPath = "\(repoPath)/src/lib"
        let request = try RPCRequest(
            method: RPCMethod.resolvePath,
            params: ResolvePathParams(path: subPath)
        )
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(ResolvedPathResult.self)
        #expect(result.repoID == repo.id)
    }

    @Test("resolve.path returns nil for unknown path")
    func resolvePathUnknown() async throws {
        let request = try RPCRequest(
            method: RPCMethod.resolvePath,
            params: ResolvePathParams(path: "/nonexistent/path")
        )
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(ResolvedPathResult.self)
        #expect(result.repoID == nil)
        #expect(result.worktreeID == nil)
    }

    // MARK: - PR Status Tests

    @Test("pr.list returns empty result when no PRs cached")
    func prListEmpty() async throws {
        let request = RPCRequest(method: RPCMethod.prList)
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(PRListResult.self)
        #expect(result.statuses.isEmpty)
    }

    @Test("pr.refresh returns nil for unknown worktree (no gh available in test)")
    func prRefreshUnknown() async throws {
        let request = try RPCRequest(
            method: RPCMethod.prRefresh,
            params: PRRefreshParams(worktreeID: UUID())
        )
        let response = await router.handle(request)
        // Should succeed (gracefully returns nil status)
        #expect(response.success)
        let result = try response.decodeResult(PRRefreshResult.self)
        #expect(result.status == nil)
    }

    // MARK: - Note RPC Tests

    @Test("note.create and note.list work together")
    func noteCreateAndList() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )

        let createReq = try RPCRequest(
            method: RPCMethod.noteCreate,
            params: NoteCreateParams(worktreeID: wt.id)
        )
        let createResp = await router.handle(createReq)
        #expect(createResp.success)

        let note = try createResp.decodeResult(Note.self)
        #expect(note.title == "Note 1")
        #expect(note.worktreeID == wt.id)

        let listReq = try RPCRequest(
            method: RPCMethod.noteList,
            params: NoteListParams(worktreeID: wt.id)
        )
        let listResp = await router.handle(listReq)
        #expect(listResp.success)

        let notes = try listResp.decodeResult([Note].self)
        #expect(notes.count == 1)
    }

    @Test("note.update returns error for missing note")
    func noteUpdateMissing() async throws {
        let updateReq = try RPCRequest(
            method: RPCMethod.noteUpdate,
            params: NoteUpdateParams(noteID: UUID(), title: "x")
        )
        let resp = await router.handle(updateReq)
        #expect(!resp.success)
        #expect(resp.error?.contains("Note not found") == true)
    }
}
