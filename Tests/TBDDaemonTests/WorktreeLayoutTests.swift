import Testing
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

    @Test func basePathUsesSlotWhenNoOverride() {
        var repo = Repo(path: "/tmp/x", displayName: "X")
        repo.worktreeSlot = "x"
        let layout = WorktreeLayout()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(layout.basePath(for: repo) == "\(home)/tbd/worktrees/x")
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
