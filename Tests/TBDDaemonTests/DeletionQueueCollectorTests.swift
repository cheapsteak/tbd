import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared
import TestSupport

@Suite("DeletionQueueCollector")
struct DeletionQueueCollectorTests {

    /// Every gate except `grace` is independent of the clock, so the default
    /// collector pins `now` to a fixed instant and the grace tests pass their
    /// own. `graceSeconds: 0` in a test means "the grace gate cannot fire".
    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeCollector(now: Date = fixedNow) -> DeletionQueueCollector {
        DeletionQueueCollector(git: GitManager(), now: { now })
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

    /// `Worktree.init` requires `displayName` and `tmuxServer`; neither has a
    /// default. Keeps every field the collector reads explicit.
    private func row(
        repoID: UUID?, name: String, path: String,
        status: WorktreeStatus = .archived, archivedAt: Date? = nil
    ) -> Worktree {
        Worktree(
            id: UUID(), repoID: repoID, name: name, displayName: name,
            branch: name, path: path, status: status,
            archivedAt: archivedAt, tmuxServer: "tbd-test"
        )
    }

    // MARK: - Provenance gate

    @Test func reapsAnArchivedLinkedWorktreeInsideATBDPrefix() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // `archivedAt` nil with a wide grace window on purpose: an unstamped
        // row must NOT be held by the grace gate (see `decide`), or every
        // pre-stamp leftover would become permanently unreclaimable.
        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: f.worktree,
            repoPath: f.repo, allowedPrefixes: [f.pool], locked: false,
            archivedAt: nil
        )
        #expect(await makeCollector().decide(candidate, liveCWDs: [], graceSeconds: 86400) == .reap)
    }

    @Test func keepsALockedWorktree() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // The user locked it deliberately; that outranks every other signal.
        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: f.worktree,
            repoPath: f.repo, allowedPrefixes: [f.pool], locked: true
        )
        #expect(await makeCollector().decide(candidate, liveCWDs: [], graceSeconds: 0)
                == .keep(reason: "locked"))
    }

    @Test func keepsACandidateArchivedInsideTheGraceWindow() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // The shape of an archive still in phase 2: the row already reads
        // `.archived` (phase 1 flipped it) while the archive hook is still
        // running and the rename has not happened yet. Reaping here would
        // rename the directory out from under that hook.
        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: f.worktree,
            repoPath: f.repo, allowedPrefixes: [f.pool], locked: false,
            archivedAt: Self.fixedNow.addingTimeInterval(-30)
        )
        #expect(await makeCollector().decide(candidate, liveCWDs: [], graceSeconds: 3600)
                == .keep(reason: "grace"))
    }

    @Test func reapsACandidateArchivedBeforeTheGraceWindow() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // Same fixture, same stamped row — only older than the window. The
        // grace gate must delay a reclaim, never prevent one.
        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: f.worktree,
            repoPath: f.repo, allowedPrefixes: [f.pool], locked: false,
            archivedAt: Self.fixedNow.addingTimeInterval(-7200)
        )
        #expect(await makeCollector().decide(candidate, liveCWDs: [], graceSeconds: 3600) == .reap)
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
        #expect(await makeCollector().decide(candidate, liveCWDs: [], graceSeconds: 0)
                == .keep(reason: "not-tbd-prefix"))
    }

    @Test func keepsASymlinkPlantedInsideAPoolThatPointsOutsideIt() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // The authorization boundary this gate exists for. A path that merely
        // *reads* as TBD-owned is not proof: anyone who can write into a pool
        // (or a row that names such a path) could otherwise point the sweep's
        // recursive delete at an arbitrary directory. `resolvedPath` runs both
        // sides through `realpath(3)` precisely so the comparison is made on
        // where the path lands, not on how it spells.
        let outside = f.tmp.appendingPathComponent("outside").path
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "precious".write(toFile: outside + "/keepme.txt", atomically: true, encoding: .utf8)
        let evil = (f.pool as NSString).appendingPathComponent("evil")
        try FileManager.default.createSymbolicLink(atPath: evil, withDestinationPath: outside)

        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: evil,
            repoPath: f.repo, allowedPrefixes: [f.pool], locked: false
        )
        #expect(await makeCollector().decide(candidate, liveCWDs: [], graceSeconds: 0)
                == .keep(reason: "not-tbd-prefix"))
        #expect(FileManager.default.fileExists(atPath: outside + "/keepme.txt"))
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
        #expect(await makeCollector().decide(candidate, liveCWDs: [], graceSeconds: 0)
                == .keep(reason: "not-linked"))
    }

    @Test func anArchivedScratchSpaceKeepsItsFolder() async throws {
        let (tmp, _) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // `scratch.archive` flips the row to `.archived` and leaves the folder
        // on disk — unlike `scratch.delete`, nothing goes to Trash — and
        // `scratch.revive` needs that folder. So an archived scratch row whose
        // directory exists is a normal, supported, user-chosen state, and
        // reaping on it would delete every archived scratch space on the
        // machine.
        //
        // The fixture sits SQUARELY INSIDE its allowed prefix and passes every
        // other gate, so the assertion can only land on the repoless branch:
        // were that branch changed to reap, this test goes red.
        let scratchPrefix = tmp.appendingPathComponent("scratch").path
        let space = (scratchPrefix as NSString).appendingPathComponent("my-notes")
        try FileManager.default.createDirectory(atPath: space, withIntermediateDirectories: true)
        try "notes".write(toFile: space + "/notes.md", atomically: true, encoding: .utf8)

        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: space,
            repoPath: nil, allowedPrefixes: [scratchPrefix], locked: false,
            archivedAt: Self.fixedNow.addingTimeInterval(-86400)
        )
        #expect(await makeCollector().decide(candidate, liveCWDs: [], graceSeconds: 3600)
                == .keep(reason: "no-repo"))
        #expect(FileManager.default.fileExists(atPath: space + "/notes.md"))
    }

    @Test func keepsAWorktreeWithALiveProcessInside() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let candidate = InterruptedArchive(
            worktreeID: UUID(), path: f.worktree,
            repoPath: f.repo, allowedPrefixes: [f.pool], locked: false
        )
        #expect(await makeCollector().decide(
            candidate, liveCWDs: [f.worktree + "/src"], graceSeconds: 0
        ) == .keep(reason: "live-cwd"))
    }

    // MARK: - Candidate enumeration

    @Test func interruptedArchivesSelectsOnlyArchivedRowsWhoseDirectoryExists() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let repoID = UUID()
        let present = row(repoID: repoID, name: "present", path: f.worktree)
        let vanished = row(repoID: repoID, name: "gone", path: f.pool + "/gone")
        let active = row(repoID: repoID, name: "active", path: f.worktree, status: .active)

        let found = await makeCollector().interruptedArchives(
            worktrees: [present, vanished, active],
            repoPathByID: [repoID: f.repo],
            prefixesByRepoID: [repoID: [f.pool]],
            scratchPrefix: "/nonexistent-scratch"
        )
        #expect(found.map(\.path) == [f.worktree])
    }

    @Test func interruptedArchivesCarriesTheRowsArchivedAt() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // The grace gate is only as good as the timestamp reaching it: a
        // candidate built without `archivedAt` would read as unstamped and
        // skip the gate entirely.
        let repoID = UUID()
        let stamp = Self.fixedNow.addingTimeInterval(-42)
        let found = await makeCollector().interruptedArchives(
            worktrees: [row(repoID: repoID, name: "wt", path: f.worktree, archivedAt: stamp)],
            repoPathByID: [repoID: f.repo],
            prefixesByRepoID: [repoID: [f.pool]],
            scratchPrefix: "/nonexistent-scratch"
        )
        #expect(found.first?.archivedAt == stamp)
    }

    @Test func aGitLockedWorktreeIsDerivedAsLocked() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // `locked` is DERIVED from `git worktree list --porcelain`, not handed
        // in — a hand-built `InterruptedArchive(locked: true)` proves only
        // that `decide` reads the field. This proves the field gets set.
        try await shell("git worktree lock \(f.worktree)", at: URL(fileURLWithPath: f.repo))

        let repoID = UUID()
        let found = await makeCollector().interruptedArchives(
            worktrees: [row(repoID: repoID, name: "wt", path: f.worktree)],
            repoPathByID: [repoID: f.repo],
            prefixesByRepoID: [repoID: [f.pool]],
            scratchPrefix: "/nonexistent-scratch"
        )
        let candidate = try #require(found.first)
        #expect(candidate.locked)
        #expect(await makeCollector().decide(candidate, liveCWDs: [], graceSeconds: 0)
                == .keep(reason: "locked"))
    }

    @Test func aRepoWhoseListingFailsMakesItsCandidatesReadAsLocked() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // A listing failure must never read as "nothing is locked": the sweep
        // would then reclaim directories whose lock state it never learned.
        let notARepo = f.tmp.appendingPathComponent("not-a-repo").path
        try FileManager.default.createDirectory(atPath: notARepo, withIntermediateDirectories: true)

        let repoID = UUID()
        let found = await makeCollector().interruptedArchives(
            worktrees: [row(repoID: repoID, name: "wt", path: f.worktree)],
            repoPathByID: [repoID: notARepo],
            prefixesByRepoID: [repoID: [f.pool]],
            scratchPrefix: "/nonexistent-scratch"
        )
        let candidate = try #require(found.first)
        #expect(candidate.locked)
        #expect(await makeCollector().decide(candidate, liveCWDs: [], graceSeconds: 0)
                == .keep(reason: "locked"))
    }

    @Test func aForgottenWorktreeIsNeverACandidate() async throws {
        let f = try await makeLinkedWorktree()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        // `forgetWorktree` hard-deletes the row rather than flipping it to
        // `.archived`, precisely so a directory the user chose to keep cannot
        // be reclaimed. `f.worktree` is TBD-shaped in every way this
        // collector can check on disk — inside a TBD-owned prefix, a real
        // linked worktree of `f.repo` — so if `interruptedArchives` ever
        // stopped filtering on row presence (e.g. started enumerating the
        // prefix directly instead of walking `worktrees:`), this directory is
        // exactly what it would wrongly pick up.
        //
        // A SECOND, archived worktree shares the pool so the call is not
        // vacuous: the row filter has something to return, and the assertion
        // is that it returns that one and only that one. Passing an empty
        // `worktrees:` would assert nothing but `[].isEmpty`.
        let archivedPath = (f.pool as NSString).appendingPathComponent("archived")
        try await shell("git worktree add \(archivedPath) -b archived", at: URL(fileURLWithPath: f.repo))

        let repoID = UUID()
        let found = await makeCollector().interruptedArchives(
            worktrees: [row(repoID: repoID, name: "archived", path: archivedPath)],
            repoPathByID: [repoID: f.repo],
            prefixesByRepoID: [repoID: [f.pool]],
            scratchPrefix: "/nonexistent-scratch"
        )
        #expect(found.map(\.path) == [archivedPath])
        #expect(FileManager.default.fileExists(atPath: f.worktree))
    }

    // MARK: - Path resolution

    @Test func resolvedPathReturnsPromptlyForANonAbsolutePath() {
        // The walk-up loop climbs `deletingLastPathComponent` until it hits
        // `"/"`. For a relative path that never happens — `""` deletes its
        // last component to `""` forever — so a non-absolute input must be
        // rejected up front rather than fed into the loop. Without that
        // guard this call hangs the calling thread indefinitely, which
        // inside a background sweep means hanging the daemon; this test's
        // whole point is that the call returns at all.
        let result = makeCollector().resolvedPath("relative/path")
        #expect(result == "relative/path")
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
