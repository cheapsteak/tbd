import Testing
import TestSupport
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct WorktreeLayoutTests {

    @Test func sanitizeLowercases() {
        #expect(WorktreeLayout.sanitize("MyApp") == "myapp")
    }

    @Test func sanitizeReplacesBadChars() {
        #expect(WorktreeLayout.sanitize("my app!") == "my-app")
        #expect(WorktreeLayout.sanitize("a/b\\c") == "a-b-c")
    }

    @Test func sanitizeCollapsesDashRuns() {
        #expect(WorktreeLayout.sanitize("a   b") == "a-b")
        #expect(WorktreeLayout.sanitize("--a--b--") == "a-b")
    }

    @Test func sanitizeAllowsDotUnderscore() {
        #expect(WorktreeLayout.sanitize("my_app.v2") == "my_app.v2")
    }

    @Test func sanitizeEmptyOrReserved() {
        #expect(WorktreeLayout.sanitize("...") == "")
        #expect(WorktreeLayout.sanitize("") == "")
        #expect(WorktreeLayout.sanitize("   ") == "")
    }

    @Test func basePathUsesOverrideWhenSet() {
        var repo = Repo(path: "/tmp/x", displayName: "X")
        repo.worktreeSlot = "x"
        repo.worktreeRoot = "/var/tmp/custom"
        let layout = WorktreeLayout()
        #expect(layout.basePath(for: repo) == "/var/tmp/custom")
    }

    /// Asserted against `TBDConstants.worktreesDir`, not a hand-built
    /// `$HOME/tbd/worktrees`. `basePath` used to build that string itself,
    /// which meant it ignored `TBD_HOME` and wrote real worktrees into the
    /// developer's home no matter where the run was pointed. Re-deriving the
    /// expectation from `$HOME` here would restate the bug as the contract.
    @Test func basePathUsesSlotWhenNoOverride() {
        var repo = Repo(path: "/tmp/x", displayName: "X")
        repo.worktreeSlot = "x"
        let layout = WorktreeLayout()
        #expect(layout.basePath(for: repo) == TBDConstants.worktreesDir.path + "/x")
    }

    @Test func legacyAndCanonicalPrefixesReturnsBoth() {
        var repo = Repo(path: "/tmp/myrepo", displayName: "X")
        repo.worktreeSlot = "x"
        let layout = WorktreeLayout()
        let prefixes = layout.legacyAndCanonicalPrefixes(for: repo)
        #expect(prefixes.count == 2)
        #expect(prefixes[0] == layout.basePath(for: repo))
        #expect(prefixes[1] == "/tmp/myrepo/.tbd/worktrees")
    }

    @Test func currentVersionIsOne() {
        #expect(WorktreeLayout.currentVersion == 1)
    }
}

// Nested under TBDHomeSerialized: mutates the process-global `TBD_HOME`.
// See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
    @Suite("WorktreeLayout — TBD_HOME redirection")
    struct WorktreeLayoutTBDHomeTests {

        /// The containment property `scripts/test.sh` depends on: point the
        /// run at a scratch home and fresh worktrees follow it. Without this,
        /// a run fenced behind `TBD_HOME` still created real directories under
        /// the developer's `~/tbd/worktrees` — ~2.9k of them, once.
        @Test func basePathFollowsTBDHome() {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-layout-\(UUID().uuidString)", isDirectory: true)
            let priorTBDHome = setTBDHome(scratch.path)
            defer { restoreTBDHome(priorTBDHome) }

            var repo = Repo(path: "/tmp/x", displayName: "X")
            repo.worktreeSlot = "x"
            #expect(WorktreeLayout().basePath(for: repo) == scratch.path + "/worktrees/x")
        }

        /// The override still wins over `TBD_HOME` — the two seams compose in
        /// one order only, and a repo pinned to an explicit root must not be
        /// dragged into the scratch home.
        @Test func explicitWorktreeRootStillBeatsTBDHome() {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-layout-\(UUID().uuidString)", isDirectory: true)
            let priorTBDHome = setTBDHome(scratch.path)
            defer { restoreTBDHome(priorTBDHome) }

            var repo = Repo(path: "/tmp/x", displayName: "X")
            repo.worktreeSlot = "x"
            repo.worktreeRoot = "/var/tmp/custom"
            #expect(WorktreeLayout().basePath(for: repo) == "/var/tmp/custom")
        }
    }
}
