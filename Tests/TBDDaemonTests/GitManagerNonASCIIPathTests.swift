import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib

/// Resolves symlinks the way git's `worktree list --porcelain` does. Foundation's
/// `URL.resolvingSymlinksInPath()` does NOT follow macOS's `/var` →
/// `/private/var` symlink; C `realpath()` does, and git reports the resolved
/// form, so fixtures must canonicalize before comparing.
private func canonicalPath(_ path: String) -> String {
    guard let cReal = realpath(path, nil) else { return path }
    defer { free(cReal) }
    return String(cString: cReal)
}

/// Tier 2 (real `git` subprocesses, real filesystem, no `~/tbd`).
///
/// `GitManager.run` pins `LC_ALL=C` / `LANG=C` on every git subprocess so that
/// stderr phrasing stays stable for the destructive failed-create cleanup gate.
/// That pin also sets `LC_CTYPE`, which raises a fair question: does it push git
/// into octal-escaping non-ASCII bytes in the porcelain output this file's
/// parsers consume? None of those parsers decode `\303\251`-style escapes, so an
/// escaped path or branch name would silently become a *wrong* value rather than
/// a failure — the orphan-GC sweep would stop recognizing its own worktrees, and
/// the branch picker would offer names that cannot be checked out.
///
/// Measured answer: no. `worktree list --porcelain` and `for-each-ref` emit raw
/// UTF-8 bytes with and without the pin; the escaping that *does* happen in
/// `status --porcelain` is `core.quotePath` (default true), which is
/// locale-independent and predates this pin — and neither `status` consumer
/// parses paths out of that output anyway.
///
/// This suite pins that as a property instead of a transcript. Every assertion
/// is a **round trip**: the value GitManager returns must equal the exact
/// non-ASCII string the fixture created. Emptiness checks would pass just as
/// happily against `caf\303\251`, so they are deliberately not what is asserted.
///
/// (Swift's `String` equality is Unicode canonical equivalence, so an NFC/NFD
/// difference introduced by the filesystem compares equal — while an octal
/// escape, being plain ASCII backslashes and digits, does not.)
@Suite("GitManager non-ASCII paths and refs")
struct GitManagerNonASCIIPathTests {
    /// Directory name for the linked worktree — Latin-1 accents plus CJK.
    static let worktreeFolder = "wt-café-日本"
    /// Branch checked out in that worktree.
    static let checkedOutBranch = "feature/naïve"
    /// Branch that exists but is checked out nowhere, so `listBranches`'
    /// in-use filter keeps it.
    static let idleBranch = "expérience/日本"
    /// Untracked file used to dirty the worktree.
    static let untrackedFile = "café-日本.txt"

    let tempDir: URL
    let repoDir: URL
    let worktreeDir: URL

    init() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-nonascii-git-\(UUID().uuidString)")
        repoDir = tempDir.appendingPathComponent("repo")
        worktreeDir = tempDir.appendingPathComponent(Self.worktreeFolder)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        try await shell("git init -q -b main && git commit -q --allow-empty -m 'init'", at: repoDir)
        try await shell(
            "git worktree add -q -b '\(Self.checkedOutBranch)' '\(worktreeDir.path)'",
            at: repoDir
        )
        try await shell("git branch '\(Self.idleBranch)'", at: repoDir)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Tests

    @Test("worktreeList round-trips a non-ASCII path and branch")
    func worktreeListRoundTripsNonASCII() async throws {
        defer { cleanup() }
        let expectedPath = canonicalPath(worktreeDir.path)

        let entries = try await GitManager().worktreeList(repoPath: repoDir.path)
        let entry = try #require(
            entries.first { $0.path == expectedPath },
            "No worktree entry matched \(expectedPath); got \(entries.map(\.path))"
        )
        #expect(entry.branch == Self.checkedOutBranch)
        // An octal-escaped path or ref would be pure ASCII backslash sequences.
        #expect(!entry.path.contains("\\"))
        #expect(!entry.branch.contains("\\"))
    }

    @Test("worktreeListDetailed round-trips a non-ASCII path and branch")
    func worktreeListDetailedRoundTripsNonASCII() async throws {
        defer { cleanup() }
        let expectedPath = canonicalPath(worktreeDir.path)

        let entries = try await GitManager().worktreeListDetailed(repoPath: repoDir.path)
        let entry = try #require(
            entries.first { $0.path == expectedPath },
            "No detailed entry matched \(expectedPath); got \(entries.map(\.path))"
        )
        #expect(entry.branch == Self.checkedOutBranch)
        #expect(entry.headSHA.count == 40)
        #expect(!entry.path.contains("\\"))
    }

    @Test("listBranches round-trips a non-ASCII branch name")
    func listBranchesRoundTripsNonASCII() async throws {
        defer { cleanup() }

        let refs = try await GitManager().listBranches(repoPath: repoDir.path)
        let names = refs.map(\.name)
        let idle = try #require(
            refs.first { $0.name == Self.idleBranch },
            "Expected \(Self.idleBranch) among \(names)"
        )
        #expect(idle.isRemote == false)
        #expect(idle.localName == Self.idleBranch)
        #expect(!idle.name.contains("\\"))
    }

    /// Cross-parser round trip: `listBranches` drops branches already checked
    /// out by comparing `for-each-ref` short names against the branch names
    /// `worktreeList` parsed out of the porcelain. If either side escaped its
    /// non-ASCII bytes and the other did not, the two spellings would stop
    /// matching and the taken branch would be offered as available.
    @Test("listBranches filters a non-ASCII branch that a worktree already holds")
    func listBranchesFiltersNonASCIIInUseBranch() async throws {
        defer { cleanup() }

        let names = try await GitManager().listBranches(repoPath: repoDir.path).map(\.name)
        #expect(
            !names.contains(Self.checkedOutBranch),
            "\(Self.checkedOutBranch) is checked out in a worktree and must be filtered; got \(names)"
        )
    }

    /// `isDirty` and `hasUncommittedChanges` only test `status --porcelain` for
    /// emptiness, so they cannot be sensitive to how the path inside is spelled.
    /// What they *can* get wrong is the verdict, so both arms are asserted: a
    /// clean worktree must read clean, and a worktree dirtied only by a
    /// non-ASCII-named file must read dirty. (That file's name is what
    /// `core.quotePath` octal-escapes in the output — locale-independently, with
    /// or without the pin — which is exactly the escaping no parser here reads.)
    @Test("dirty checks report both arms for a non-ASCII filename")
    func dirtyChecksReportBothArmsForNonASCIIFilename() async throws {
        defer { cleanup() }
        let git = GitManager()

        let cleanIsDirty = await git.isDirty(worktreePath: worktreeDir.path)
        #expect(cleanIsDirty == false)
        let cleanHasChanges = try await git.hasUncommittedChanges(repoPath: worktreeDir.path)
        #expect(cleanHasChanges == false)

        try Data("x".utf8).write(
            to: worktreeDir.appendingPathComponent(Self.untrackedFile)
        )

        let dirtyIsDirty = await git.isDirty(worktreePath: worktreeDir.path)
        #expect(dirtyIsDirty == true)
        let dirtyHasChanges = try await git.hasUncommittedChanges(repoPath: worktreeDir.path)
        #expect(dirtyHasChanges == true)
    }
}
