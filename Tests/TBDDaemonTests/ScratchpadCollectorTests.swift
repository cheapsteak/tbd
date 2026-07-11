import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

@Suite("ScratchpadCollector")
struct ScratchpadCollectorTests: ~Copyable {
    let fm = FileManager.default
    /// Sandbox root for this test instance; everything lives under it.
    let sandbox: URL
    /// Injected scratchpad base (`ScratchpadCollector(base:)`).
    let tmpDir: URL
    /// Parent for fixture "worktree" directories — inside the sandbox so
    /// parallel test runs never collide on shared literal paths like
    /// `/tmp/existing-wt`.
    let wtParent: URL

    init() {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scratchpad-test-\(UUID().uuidString)")
        tmpDir = sandbox.appendingPathComponent("base")
        wtParent = sandbox.appendingPathComponent("worktrees")
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: wtParent, withIntermediateDirectories: true)
    }

    deinit {
        try? fm.removeItem(at: sandbox)
    }

    @Test("slug replaces forward slashes with hyphens")
    func testSlugConversion() {
        let slug = ScratchpadCollector.slug(forWorktreePath: "/Users/chang/tbd/worktrees/some-wt")
        #expect(slug == "-Users-chang-tbd-worktrees-some-wt")
    }

    @Test("slug with single component")
    func testSlugSingleComponent() {
        let slug = ScratchpadCollector.slug(forWorktreePath: "somepath")
        #expect(slug == "somepath")
    }

    @Test("slug with empty string")
    func testSlugEmpty() {
        let slug = ScratchpadCollector.slug(forWorktreePath: "")
        #expect(slug == "")
    }

    @Test("cleanUp removes scratchpad dir and returns record stamped with repoPath")
    func testCleanUpSuccess() async {
        let collector = ScratchpadCollector(base: tmpDir)
        let worktreePath = "/Users/chang/tbd/worktrees/test-wt"
        let slug = ScratchpadCollector.slug(forWorktreePath: worktreePath)

        let scratchpadDir = tmpDir.appendingPathComponent(slug)
        try? fm.createDirectory(at: scratchpadDir, withIntermediateDirectories: true)

        // Create some dummy files to measure
        let file1 = scratchpadDir.appendingPathComponent("file1.txt")
        try? "test content".write(to: file1, atomically: true, encoding: .utf8)

        let now = Date()
        let record = await collector.cleanUp(forRemovedWorktreePath: worktreePath, repoPath: "/Users/chang/tbd", now: now)

        #expect(record != nil)
        #expect(record?.kind == ReapKind.scratchpad)
        #expect(record?.repoPath == "/Users/chang/tbd")
        #expect(record?.worktreePath == scratchpadDir.path)
        #expect(record?.apparentBytes != nil)
        #expect(!fm.fileExists(atPath: scratchpadDir.path))
    }

    @Test("cleanUp stamps an empty repoPath when the caller has none to give")
    func testCleanUpStampsEmptyRepoPathWhenUnknown() async {
        let collector = ScratchpadCollector(base: tmpDir)
        let worktreePath = "/Users/chang/tbd/worktrees/test-wt-2"
        let slug = ScratchpadCollector.slug(forWorktreePath: worktreePath)
        let scratchpadDir = tmpDir.appendingPathComponent(slug)
        try? fm.createDirectory(at: scratchpadDir, withIntermediateDirectories: true)

        let record = await collector.cleanUp(forRemovedWorktreePath: worktreePath, repoPath: "", now: Date())

        #expect(record?.repoPath == "")
    }

    @Test("cleanUp returns nil when scratchpad does not exist")
    func testCleanUpNonExistent() async {
        let collector = ScratchpadCollector(base: tmpDir)
        let worktreePath = "/Users/chang/tbd/worktrees/nonexistent"

        let record = await collector.cleanUp(forRemovedWorktreePath: worktreePath, repoPath: "/Users/chang/tbd", now: Date())

        #expect(record == nil)
    }

    @Test("reconcile removes only scratchpads for nonexistent worktrees, stamped with each pair's repoPath")
    func testReconcileRemovesGoneWorktrees() async {
        let collector = ScratchpadCollector(base: tmpDir)

        let existingWT = wtParent.appendingPathComponent("existing-wt").path
        let goneWT = wtParent.appendingPathComponent("gone-wt").path

        // Create scratchpads for both
        let existingSlug = ScratchpadCollector.slug(forWorktreePath: existingWT)
        let goneSlug = ScratchpadCollector.slug(forWorktreePath: goneWT)

        let existingDir = tmpDir.appendingPathComponent(existingSlug)
        let goneDir = tmpDir.appendingPathComponent(goneSlug)

        try? fm.createDirectory(at: existingDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: goneDir, withIntermediateDirectories: true)

        // Add dummy file to measure
        try? "test".write(to: goneDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        // Create the existing worktree dir
        try? fm.createDirectory(atPath: existingWT, withIntermediateDirectories: true)

        let records = await collector.reconcile(
            knownPaths: [
                (worktreePath: existingWT, repoPath: "/repo/existing"),
                (worktreePath: goneWT, repoPath: "/repo/gone"),
            ],
            now: Date()
        )

        #expect(records.count == 1)
        #expect(records[0].kind == ReapKind.scratchpad)
        #expect(records[0].worktreePath == goneDir.path)
        #expect(records[0].repoPath == "/repo/gone", "must stamp the repoPath from its own pair, not the survivor's")
        #expect(!fm.fileExists(atPath: goneDir.path))
        #expect(fm.fileExists(atPath: existingDir.path))
    }

    @Test("reconcile preserves unrelated dirs in base")
    func testReconcilePreservesUnrelated() async {
        let collector = ScratchpadCollector(base: tmpDir)

        let worktreePath = wtParent.appendingPathComponent("some-wt").path
        let unrelatedDir = tmpDir.appendingPathComponent("unrelated-project")

        // Create the scratchpad
        let slug = ScratchpadCollector.slug(forWorktreePath: worktreePath)
        let scratchpadDir = tmpDir.appendingPathComponent(slug)
        try? fm.createDirectory(at: scratchpadDir, withIntermediateDirectories: true)
        try? "test".write(to: scratchpadDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        // Create unrelated directory
        try? fm.createDirectory(at: unrelatedDir, withIntermediateDirectories: true)
        try? "unrelated".write(to: unrelatedDir.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        // Create the worktree so it won't be cleaned
        try? fm.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)

        let records = await collector.reconcile(
            knownPaths: [(worktreePath: worktreePath, repoPath: "/repo/some")], now: Date()
        )

        // Scratchpad should still exist because worktree exists
        #expect(records.count == 0)
        #expect(fm.fileExists(atPath: scratchpadDir.path))
        // Unrelated directory should still exist
        #expect(fm.fileExists(atPath: unrelatedDir.path))
    }

    @Test("reconcile is no-op when base dir missing")
    func testReconcileMissingBase() async {
        let missingBase = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nonexistent-base-\(UUID().uuidString)")

        let collector = ScratchpadCollector(base: missingBase)

        let records = await collector.reconcile(
            knownPaths: [(worktreePath: wtParent.appendingPathComponent("gone-wt").path, repoPath: "/repo/gone")],
            now: Date()
        )

        #expect(records.count == 0)
    }
}
