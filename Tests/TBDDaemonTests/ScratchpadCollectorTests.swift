import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

@Suite("ScratchpadCollector")
struct ScratchpadCollectorTests: ~Copyable {
    let fm = FileManager.default
    let tmpDir: URL

    init() {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scratchpad-test-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
        try? fm.removeItem(at: tmpDir)
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

    @Test("cleanUp removes scratchpad dir and returns record")
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
        let record = await collector.cleanUp(forRemovedWorktreePath: worktreePath, now: now)

        #expect(record != nil)
        #expect(record?.kind == ReapKind.scratchpad)
        #expect(record?.repoPath == "")
        #expect(record?.worktreePath == scratchpadDir.path)
        #expect(record?.apparentBytes != nil)
        #expect(!fm.fileExists(atPath: scratchpadDir.path))
    }

    @Test("cleanUp returns nil when scratchpad does not exist")
    func testCleanUpNonExistent() async {
        let collector = ScratchpadCollector(base: tmpDir)
        let worktreePath = "/Users/chang/tbd/worktrees/nonexistent"

        let record = await collector.cleanUp(forRemovedWorktreePath: worktreePath, now: Date())

        #expect(record == nil)
    }

    @Test("reconcile removes only scratchpads for nonexistent worktrees")
    func testReconcileRemovesGoneWorktrees() async {
        let collector = ScratchpadCollector(base: tmpDir)

        let existingWT = "/tmp/existing-wt"
        let goneWT = "/tmp/gone-wt"

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

        let records = await collector.reconcile(knownPaths: [existingWT, goneWT], now: Date())

        // Clean up the test worktree
        try? fm.removeItem(atPath: existingWT)

        #expect(records.count == 1)
        #expect(records[0].kind == ReapKind.scratchpad)
        #expect(records[0].worktreePath == goneDir.path)
        #expect(!fm.fileExists(atPath: goneDir.path))
        #expect(fm.fileExists(atPath: existingDir.path))
    }

    @Test("reconcile preserves unrelated dirs in base")
    func testReconcilePreservesUnrelated() async {
        let collector = ScratchpadCollector(base: tmpDir)

        let worktreePath = "/tmp/some-wt"
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

        let records = await collector.reconcile(knownPaths: [worktreePath], now: Date())

        // Clean up test worktree
        try? fm.removeItem(atPath: worktreePath)

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

        let records = await collector.reconcile(knownPaths: ["/tmp/some-wt"], now: Date())

        #expect(records.count == 0)
    }
}
