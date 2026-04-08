import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct RepoHealthValidatorTests {

    /// Make a real git repo at a tmp path. Returns the path.
    private func makeGitRepo() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase-b-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["commit", "--allow-empty", "-m", "init"]] {
            let p = Process()
            p.launchPath = "/usr/bin/env"
            p.arguments = ["git", "-C", tmp.path] + args
            try p.run()
            p.waitUntilExit()
        }
        return tmp
    }

    @Test func validatesExistingGitRepo() async throws {
        let url = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: url) }
        var repo = Repo(path: url.path, displayName: "real")
        repo.worktreeSlot = "real"
        let v = RepoHealthValidator(git: GitManager())
        #expect(await v.validate(repo: repo) == .ok)
    }

    @Test func reportsMissingForNonexistentPath() async throws {
        var repo = Repo(path: "/this/path/does/not/exist/at/all/\(UUID().uuidString)", displayName: "ghost")
        repo.worktreeSlot = "ghost"
        let v = RepoHealthValidator(git: GitManager())
        #expect(await v.validate(repo: repo) == .missing)
    }

    @Test func reportsMissingForNonGitDirectory() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase-b-not-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var repo = Repo(path: tmp.path, displayName: "tmp")
        repo.worktreeSlot = "tmp"
        let v = RepoHealthValidator(git: GitManager())
        #expect(await v.validate(repo: repo) == .missing)
    }

    @Test func conductorPseudoRepoAlwaysOK() async throws {
        var repo = Repo(
            id: TBDConstants.conductorsRepoID,
            path: "/nonexistent/conductors-\(UUID().uuidString)",
            displayName: "Conductors"
        )
        repo.worktreeSlot = "conductors"
        #expect(await RepoHealthValidator(git: GitManager()).validate(repo: repo) == .ok)
    }

    @Test func validateAllPersistsTransitions() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/this/path/does/not/exist/\(UUID().uuidString)",
            displayName: "ghost",
            defaultBranch: "main"
        )
        // Starts ok by default.
        #expect((try await db.repos.get(id: repo.id))?.status == .ok)
        await RepoHealthValidator(git: GitManager()).validateAll(db: db)
        #expect((try await db.repos.get(id: repo.id))?.status == .missing)
    }
}
