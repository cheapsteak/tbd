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

    // MARK: - Claude Terminal Creation

    @Test("terminal.create with type claude sets label and sessionID")
    func terminalCreateClaude() async throws {
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
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        )
        let createResp = await router.handle(createReq)
        #expect(createResp.success)

        let terminal = try createResp.decodeResult(Terminal.self)
        #expect(terminal.label == "claude")
        #expect(terminal.claudeSessionID != nil)
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

    // MARK: - Terminal Output

    @Test("terminal.output returns error when terminal not found")
    func terminalOutputReturnsError_whenTerminalNotFound() async throws {
        let params = TerminalOutputParams(terminalID: UUID())
        let request = try RPCRequest(method: RPCMethod.terminalOutput, params: params)
        let response = await router.handle(request)
        #expect(!response.success)
        #expect(response.error?.contains("Terminal not found") == true)
    }

    // MARK: - Unknown Method

    @Test("unknown method returns error")
    func unknownMethod() async throws {
        let request = RPCRequest(method: "foo.bar")
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("Unknown method") == true)
    }

    // MARK: - Repo Instructions Tests

    @Test("repo.updateInstructions stores and retrieves instructions")
    func repoUpdateInstructions() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )

        let request = try RPCRequest(
            method: RPCMethod.repoUpdateInstructions,
            params: RepoUpdateInstructionsParams(
                repoID: repo.id,
                renamePrompt: "Use cw/4/feat- prefix",
                customInstructions: "Always use pytest"
            )
        )
        let response = await router.handle(request)

        #expect(response.success)
        let updated = try response.decodeResult(Repo.self)
        #expect(updated.renamePrompt == "Use cw/4/feat- prefix")
        #expect(updated.customInstructions == "Always use pytest")

        // Verify via repo.list
        let listResp = await router.handle(RPCRequest(method: RPCMethod.repoList))
        let repos = try listResp.decodeResult([Repo].self)
        let found = repos.first { $0.id == repo.id }
        #expect(found?.renamePrompt == "Use cw/4/feat- prefix")
        #expect(found?.customInstructions == "Always use pytest")
    }

    @Test("repo.updateInstructions with nil clears instructions")
    func repoUpdateInstructionsClear() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )

        // Set instructions
        let setReq = try RPCRequest(
            method: RPCMethod.repoUpdateInstructions,
            params: RepoUpdateInstructionsParams(repoID: repo.id, renamePrompt: "test", customInstructions: "test")
        )
        _ = await router.handle(setReq)

        // Clear them
        let clearReq = try RPCRequest(
            method: RPCMethod.repoUpdateInstructions,
            params: RepoUpdateInstructionsParams(repoID: repo.id, renamePrompt: nil, customInstructions: nil)
        )
        let response = await router.handle(clearReq)

        #expect(response.success)
        let updated = try response.decodeResult(Repo.self)
        #expect(updated.renamePrompt == nil)
        #expect(updated.customInstructions == nil)
    }

    @Test("repo.updateInstructions returns error for unknown repo")
    func repoUpdateInstructionsUnknownRepo() async throws {
        let request = try RPCRequest(
            method: RPCMethod.repoUpdateInstructions,
            params: RepoUpdateInstructionsParams(repoID: UUID(), renamePrompt: nil, customInstructions: nil)
        )
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("Repository not found") == true)
    }

    @Test("existing repos have nil instructions after migration")
    func existingReposNilInstructions() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )

        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.renamePrompt == nil)
        #expect(fetched?.customInstructions == nil)
    }
}
