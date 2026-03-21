import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("RPCRouter Tests")
struct RPCRouterTests {
    let db: TBDDatabase
    let router: RPCRouter

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date()
        )
    }

    // MARK: - Repo Tests

    @Test("repo.add validates git repo and inserts into db")
    func repoAdd() async throws {
        // Create a temp git repo
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init"]
        process.currentDirectoryURL = tempDir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        // Make an initial commit so HEAD exists
        let commitProcess = Process()
        commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commitProcess.arguments = ["commit", "--allow-empty", "-m", "init"]
        commitProcess.currentDirectoryURL = tempDir
        commitProcess.standardOutput = Pipe()
        commitProcess.standardError = Pipe()
        try commitProcess.run()
        commitProcess.waitUntilExit()

        let request = try RPCRequest(method: RPCMethod.repoAdd, params: RepoAddParams(path: tempDir.path))
        let response = await router.handle(request)

        #expect(response.success)
        #expect(response.error == nil)

        let repo = try response.decodeResult(Repo.self)
        #expect(repo.path == tempDir.path)
    }

    @Test("repo.add rejects non-git directory")
    func repoAddNonGit() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = try RPCRequest(method: RPCMethod.repoAdd, params: RepoAddParams(path: tempDir.path))
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("Not a git repository") == true)
    }

    @Test("repo.list returns all repos")
    func repoList() async throws {
        // Add a repo directly to db
        _ = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )

        let request = RPCRequest(method: RPCMethod.repoList)
        let response = await router.handle(request)

        #expect(response.success)
        let repos = try response.decodeResult([Repo].self)
        #expect(repos.count >= 1)
    }

    @Test("repo.remove deletes repo from db")
    func repoRemove() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )

        let request = try RPCRequest(
            method: RPCMethod.repoRemove,
            params: RepoRemoveParams(repoID: repo.id)
        )
        let response = await router.handle(request)

        #expect(response.success)

        // Verify it's gone
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched == nil)
    }

    @Test("repo.remove refuses when active worktrees exist without force")
    func repoRemoveRefusesActiveWorktrees() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        _ = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )

        let request = try RPCRequest(
            method: RPCMethod.repoRemove,
            params: RepoRemoveParams(repoID: repo.id, force: false)
        )
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("active worktree") == true)
    }

    // MARK: - Worktree Tests

    @Test("worktree.list returns worktrees filtered by status")
    func worktreeList() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        _ = try await db.worktrees.create(
            repoID: repo.id,
            name: "active-wt",
            branch: "tbd/active-wt",
            path: "/tmp/active-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )

        let request = try RPCRequest(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(repoID: repo.id, status: .active)
        )
        let response = await router.handle(request)

        #expect(response.success)
        let worktrees = try response.decodeResult([Worktree].self)
        #expect(worktrees.count == 1)
        #expect(worktrees[0].name == "active-wt")
    }

    @Test("worktree.rename updates display name")
    func worktreeRename() async throws {
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
            method: RPCMethod.worktreeRename,
            params: WorktreeRenameParams(worktreeID: wt.id, displayName: "My Feature")
        )
        let response = await router.handle(request)

        #expect(response.success)

        let updated = try await db.worktrees.get(id: wt.id)
        #expect(updated?.displayName == "My Feature")
    }

    // MARK: - Terminal Tests

    @Test("terminal.create and terminal.list work together")
    func terminalCreateAndList() async throws {
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

        // Create a terminal
        let createReq = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, cmd: "vim")
        )
        let createResp = await router.handle(createReq)
        #expect(createResp.success)

        let terminal = try createResp.decodeResult(Terminal.self)
        #expect(terminal.worktreeID == wt.id)

        // List terminals
        let listReq = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id)
        )
        let listResp = await router.handle(listReq)
        #expect(listResp.success)

        let terminals = try listResp.decodeResult([Terminal].self)
        #expect(terminals.count == 1)
    }

    @Test("terminal.send dispatches to tmux")
    func terminalSend() async throws {
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
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0"
        )

        let request = try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminal.id, text: "echo hello")
        )
        let response = await router.handle(request)

        // dryRun tmux should succeed
        #expect(response.success)
    }

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

    // MARK: - Unknown Method

    @Test("unknown method returns error")
    func unknownMethod() async throws {
        let request = RPCRequest(method: "foo.bar")
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("Unknown method") == true)
    }
}
