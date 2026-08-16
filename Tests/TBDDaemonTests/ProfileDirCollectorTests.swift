import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 2: real filesystem, no database, no `~/tbd`. Everything lives under a
/// per-instance sandbox in `NSTemporaryDirectory()`, and every clock read goes
/// through the collector's injected `now`.
@Suite("ProfileDirCollector enumerates, gates, quarantines and expires profile dirs")
struct ProfileDirCollectorTests: ~Copyable {
    let fm = FileManager.default
    /// Sandbox root for this test instance; everything lives under it.
    let sandbox: URL
    /// Injected profiles base (`ProfileDirCollector(base:)`).
    let base: URL

    init() {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("profile-dir-gc-\(UUID().uuidString)", isDirectory: true)
        base = sandbox.appendingPathComponent("profiles", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    deinit {
        try? fm.removeItem(at: sandbox)
    }

    /// Creates UUID-named directories under the injected base and returns them.
    @discardableResult
    private func makeProfileDirs(_ ids: [UUID]) throws -> [URL] {
        try ids.map { id in
            let url = base.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    private var quarantineBase: URL {
        base.appendingPathComponent(ProfileDirCollector.quarantineDirName, isDirectory: true)
    }

    // MARK: - Enumeration

    @Test("candidates lists UUID-named dirs and skips everything else")
    func candidatesSkipsNonUUIDEntries() throws {
        let id = UUID()
        try makeProfileDirs([id])
        try fm.createDirectory(
            at: base.appendingPathComponent("not-a-uuid", isDirectory: true),
            withIntermediateDirectories: true)
        try fm.createDirectory(at: quarantineBase, withIntermediateDirectories: true)
        // A file whose *name* is a UUID is not a config directory.
        try "x".write(
            to: base.appendingPathComponent(UUID().uuidString.lowercased()),
            atomically: true, encoding: .utf8)

        let found = ProfileDirCollector(base: base).candidates()

        #expect(found.map(\.profileID) == [id])
        #expect(found.first?.path == base.appendingPathComponent(
            id.uuidString.lowercased(), isDirectory: true).path)
        #expect(found.first?.createdAt != nil, "a just-created dir must have a readable creation date")
    }

    @Test("candidates is empty when the profiles base does not exist")
    func candidatesEmptyWhenBaseMissing() {
        let missing = sandbox.appendingPathComponent("no-such-base", isDirectory: true)
        #expect(ProfileDirCollector(base: missing).candidates().isEmpty)
    }

    // MARK: - Gates

    @Test("a dir with a live row is kept")
    func keepsKnownProfile() throws {
        let id = UUID()
        try makeProfileDirs([id])
        let collector = ProfileDirCollector(base: base)
        let candidate = try #require(collector.candidates().first)

        #expect(collector.decide(candidate, knownProfileIDs: [id], referencedProfileIDs: [],
                                 graceSeconds: 0) == .keep(reason: "row-exists"))
    }

    @Test("an orphan referenced by a terminal row is kept")
    func keepsTerminalReferenced() throws {
        let id = UUID()
        try makeProfileDirs([id])
        let collector = ProfileDirCollector(base: base)
        let candidate = try #require(collector.candidates().first)

        #expect(collector.decide(candidate, knownProfileIDs: [], referencedProfileIDs: [id],
                                 graceSeconds: 0) == .keep(reason: "terminal-reference"))
    }

    @Test("a young orphan is kept by the grace window")
    func keepsYoungOrphan() throws {
        let id = UUID()
        try makeProfileDirs([id])
        let collector = ProfileDirCollector(base: base)
        let candidate = try #require(collector.candidates().first)

        #expect(collector.decide(candidate, knownProfileIDs: [], referencedProfileIDs: [],
                                 graceSeconds: 3600) == .keep(reason: "grace"))
    }

    @Test("an orphan whose age cannot be read is kept")
    func keepsUnknownAge() {
        let collector = ProfileDirCollector(base: base)
        let candidate = ProfileDirCandidate(
            profileID: UUID(), path: base.appendingPathComponent("x").path, createdAt: nil)

        #expect(collector.decide(candidate, knownProfileIDs: [], referencedProfileIDs: [],
                                 graceSeconds: 0) == .keep(reason: "unknown-age"))
    }

    @Test("an aged, unreferenced orphan is reapable")
    func reapsAgedOrphan() throws {
        let id = UUID()
        try makeProfileDirs([id])
        let collector = ProfileDirCollector(base: base)
        let candidate = try #require(collector.candidates().first)

        #expect(collector.decide(candidate, knownProfileIDs: [], referencedProfileIDs: [],
                                 graceSeconds: 0) == .reap)
    }

    // MARK: - Reap

    @Test("reap renames into .reaped and records both paths")
    func reapQuarantines() async throws {
        let id = UUID()
        try makeProfileDirs([id])
        let dir = base.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try "secret".write(
            to: dir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)

        let fixed = Date(timeIntervalSince1970: 1_760_000_000)
        let collector = ProfileDirCollector(base: base, now: { fixed })
        let candidate = try #require(collector.candidates().first)

        let record = try #require(await collector.reap(candidate))

        #expect(record.kind == .profileDir)
        #expect(record.repoPath == "")
        #expect(record.worktreePath == candidate.path)
        #expect(record.reapedAt == fixed)
        #expect(!fm.fileExists(atPath: candidate.path), "the rename is the commit point")

        let quarantine = try #require(record.quarantinePath)
        #expect(quarantine.hasPrefix(quarantineBase.path + "/"))
        #expect(fm.fileExists(atPath: quarantine))
        #expect(fm.fileExists(atPath: quarantine + "/.credentials.json"),
                "quarantine must preserve the directory's contents, not just its name")
        #expect(collector.candidates().isEmpty, "the quarantine is never a candidate")
    }

    @Test("a failed quarantine keeps the directory and reports no record")
    func reapFailureKeepsDirectory() async throws {
        let id = UUID()
        try makeProfileDirs([id])
        // A regular file where the quarantine directory belongs: creating the
        // quarantine base fails, so the rename never happens.
        try "not a directory".write(to: quarantineBase, atomically: true, encoding: .utf8)

        let collector = ProfileDirCollector(base: base)
        let candidate = try #require(collector.candidates().first)

        #expect(await collector.reap(candidate) == nil)
        #expect(fm.fileExists(atPath: candidate.path), "a failed reap must leave the candidate untouched")
    }

    // MARK: - Quarantine expiry

    @Test("quarantine entries expire only after the retention window")
    func expiryRespectsRetention() async throws {
        let id = UUID()
        try makeProfileDirs([id])
        let reapedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let atReap = ProfileDirCollector(base: base, now: { reapedAt })
        let candidate = try #require(atReap.candidates().first)
        let record = try #require(await atReap.reap(candidate))
        let quarantine = try #require(record.quarantinePath)

        let day: TimeInterval = 86_400
        let early = ProfileDirCollector(base: base, now: { reapedAt.addingTimeInterval(29 * day) })
        #expect(early.expiredQuarantineEntries(retentionDays: 30).isEmpty)

        let late = ProfileDirCollector(base: base, now: { reapedAt.addingTimeInterval(31 * day) })
        #expect(late.expiredQuarantineEntries(retentionDays: 30) == [quarantine])
        #expect(late.purge(quarantinePath: quarantine))
        #expect(!fm.fileExists(atPath: quarantine))
    }

    @Test("expiry is empty when there is no quarantine directory")
    func expiryEmptyWithoutQuarantine() {
        #expect(ProfileDirCollector(base: base).expiredQuarantineEntries(retentionDays: 30).isEmpty)
    }

    @Test("an entry whose name carries no timestamp falls back to the directory's own dates")
    func expiryFallsBackToDirectoryDates() throws {
        try fm.createDirectory(at: quarantineBase, withIntermediateDirectories: true)
        let stale = quarantineBase.appendingPathComponent("no-stamp-here", isDirectory: true)
        let fresh = quarantineBase.appendingPathComponent("also-unparseable", isDirectory: true)
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let old = now.addingTimeInterval(-90 * 86_400)
        try fm.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: stale.path)
        try fm.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: fresh.path)

        let collector = ProfileDirCollector(base: base, now: { now })

        #expect(collector.expiredQuarantineEntries(retentionDays: 30) == [stale.path])
    }

    // MARK: - Purge

    @Test("purge refuses a path outside the quarantine directory")
    func purgeRefusesOutsidePaths() throws {
        let victim = base.appendingPathComponent("victim", isDirectory: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)

        #expect(!ProfileDirCollector(base: base).purge(quarantinePath: victim.path))
        #expect(fm.fileExists(atPath: victim.path))
    }

    @Test("purge refuses the quarantine directory itself")
    func purgeRefusesQuarantineRoot() throws {
        try fm.createDirectory(at: quarantineBase, withIntermediateDirectories: true)

        #expect(!ProfileDirCollector(base: base).purge(quarantinePath: quarantineBase.path))
        #expect(fm.fileExists(atPath: quarantineBase.path))
    }

    @Test("purge reports failure when the entry cannot be removed")
    func purgeReportsRemovalFailure() {
        let ghost = quarantineBase.appendingPathComponent("gone-already", isDirectory: true)

        #expect(!ProfileDirCollector(base: base).purge(quarantinePath: ghost.path))
    }
}
