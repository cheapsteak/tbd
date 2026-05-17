import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// Repo-scoped RPC methods: repo.add, repo.list, repo.remove,
// repo.updateInstructions, plus the unknown-method fallthrough (a
// generic router behavior that doesn't belong with any single subsystem).
extension RPCRouterTests {

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

    // MARK: - Unknown Method

    @Test("unknown method returns error")
    func unknownMethod() async throws {
        let request = RPCRequest(method: "foo.bar")
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("Unknown method") == true)
    }
}
