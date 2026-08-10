import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared
import TestSupport

@Suite("DeletionQueueCollector")
struct DeletionQueueCollectorTests {

    private func makeCollector() -> DeletionQueueCollector {
        DeletionQueueCollector(git: GitManager())
    }

    /// A real linked worktree at `<pool>/<name>` where `<pool>` is treated as
    /// a TBD-owned prefix. Returns (tmp, repoPath, pool, worktreePath).
    private func makeLinkedWorktree(
        name: String = "wt"
    ) async throws -> (tmp: URL, repo: String, pool: String, worktree: String) {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        let pool = tmp.appendingPathComponent("pool").path
        try FileManager.default.createDirectory(atPath: pool, withIntermediateDirectories: true)
        let wt = (pool as NSString).appendingPathComponent(name)
        try await shell("git worktree add \(wt) -b \(name)", at: repo)
        return (tmp, repo.path, pool, wt)
    }

    // MARK: - Provenance gate

    @Test func reapsAnArchivedLinkedWorktreeInsideATBDPrefix() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: f.worktree,
            repoPath: f.repo, allowedPrefixes: [f.pool], locked: false
        )
        #expect(await makeCollector().decide(candidate, liveCWDs: []) == .reap)
    }

    @Test func keepsALockedWorktree() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // The user locked it deliberately; that outranks every other signal.
        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: f.worktree,
            repoPath: f.repo, allowedPrefixes: [f.pool], locked: true
        )
        #expect(await makeCollector().decide(candidate, liveCWDs: [])
                == .keep(reason: "locked"))
    }

    @Test func keepsAWorktreeOutsideEveryTBDPrefix() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // An adopted worktree can live anywhere; TBD did not create it and
        // must never reclaim it.
        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: f.worktree,
            repoPath: f.repo, allowedPrefixes: ["/some/other/pool"], locked: false
        )
        #expect(await makeCollector().decide(candidate, liveCWDs: [])
                == .keep(reason: "not-tbd-prefix"))
    }

    @Test func keepsADirectoryThatIsNotALinkedWorktreeOfItsRepo() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // A plain directory sitting in the pool: right place, no linkage proof.
        let decoy = (f.pool as NSString).appendingPathComponent("decoy")
        try FileManager.default.createDirectory(atPath: decoy, withIntermediateDirectories: true)

        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: decoy,
            repoPath: f.repo, allowedPrefixes: [f.pool], locked: false
        )
        #expect(await makeCollector().decide(candidate, liveCWDs: [])
                == .keep(reason: "not-linked"))
    }

    @Test func keepsARepolessCandidateOutsideTheScratchPrefix() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // repoPath nil means scratch, and scratch is only ever under the
        // scratch prefix. Anything else is unprovable.
        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: f.worktree,
            repoPath: nil, allowedPrefixes: [f.pool], locked: false
        )
        #expect(await makeCollector().decide(candidate, liveCWDs: [])
                == .keep(reason: "no-repo"))
    }

    @Test func keepsAWorktreeWithALiveProcessInside() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: f.worktree,
            repoPath: f.repo, allowedPrefixes: [f.pool], locked: false
        )
        #expect(await makeCollector().decide(candidate, liveCWDs: [f.worktree + "/src"])
                == .keep(reason: "live-cwd"))
    }

    // MARK: - Candidate enumeration

    @Test func interruptedArchivesSelectsOnlyArchivedRowsWhoseDirectoryExists() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let repoID = UUID()
        // `Worktree.init` requires `displayName` and `tmuxServer`; neither has
        // a default. Keep every field the collector reads explicit.
        func row(name: String, path: String, status: WorktreeStatus) -> Worktree {
            Worktree(
                id: UUID(), repoID: repoID, name: name, displayName: name,
                branch: name, path: path, status: status, tmuxServer: "tbd-test"
            )
        }
        let present = row(name: "present", path: f.worktree, status: .archived)
        let vanished = row(name: "gone", path: f.pool + "/gone", status: .archived)
        let active = row(name: "active", path: f.worktree, status: .active)

        let found = await makeCollector().interruptedArchives(
            worktrees: [present, vanished, active],
            repoPathByID: [repoID: f.repo],
            prefixesByRepoID: [repoID: [f.pool]],
            scratchPrefix: "/nonexistent-scratch"
        )
        #expect(found.map(\.path) == [f.worktree])
    }

    @Test func aForgottenWorktreeIsNeverACandidate() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // `forgetWorktree` hard-deletes the row rather than flipping it to
        // `.archived`, precisely so a directory the user chose to keep cannot
        // be reclaimed. With no row, the directory is invisible here however
        // TBD-shaped its path looks.
        let found = await makeCollector().interruptedArchives(
            worktrees: [],
            repoPathByID: [UUID(): f.repo],
            prefixesByRepoID: [:],
            scratchPrefix: "/nonexistent-scratch"
        )
        #expect(found.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.worktree))
    }

    // MARK: - Reap

    @Test func reapMovesTheDirectoryIntoTheQueueAndReturnsTheEntry() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: f.worktree,
            repoPath: f.repo, allowedPrefixes: [f.pool], locked: false
        )
        let entry = await makeCollector().reap(candidate)

        #expect(entry != nil)
        #expect(!FileManager.default.fileExists(atPath: f.worktree))
        // Registration dropped too, so nothing re-adopts it.
        let registered = try await GitManager().worktreeList(repoPath: f.repo)
        #expect(!registered.contains { $0.path == f.worktree })
    }
}
