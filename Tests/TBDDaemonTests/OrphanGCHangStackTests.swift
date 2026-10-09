import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 2: a real filesystem plus an in-memory database, and nothing that can
/// reach the developer's real `~/Library/Logs/TBD/hang-stacks` — the base is
/// injected at a temp directory on every `OrphanGC` this suite builds, and the
/// collector is also exercised directly against the same sandbox.
@Suite("OrphanGC reclaims hang-stack diagnostics")
struct OrphanGCHangStackTests: ~Copyable {
    let fm = FileManager.default
    /// Sandbox root for this test instance; everything lives under it.
    let sandbox: URL
    /// Injected hang-stacks base (`OrphanGC(hangStackBase:)`).
    let hangStackBase: URL
    /// Injected scratchpad base, so the sweep's scratchpad phase can never
    /// reach the developer's real Claude store.
    let scratchpadBase: URL
    /// Injected profiles base, for the same reason.
    let profileBase: URL
    /// Fixed sweep clock. Every fixture's age is expressed relative to it, so
    /// nothing here depends on wall time.
    let clock = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orphan-gc-hang-stacks-\(UUID().uuidString)", isDirectory: true)
        hangStackBase = sandbox.appendingPathComponent("hang-stacks", isDirectory: true)
        scratchpadBase = sandbox.appendingPathComponent("scratchpads", isDirectory: true)
        profileBase = sandbox.appendingPathComponent("profiles", isDirectory: true)
        for dir in [hangStackBase, scratchpadBase, profileBase] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? fm.removeItem(at: sandbox)
    }

    // MARK: - Fixtures

    private func makeGC(
        db: TBDDatabase, broadcast: @escaping @Sendable (StateDelta) -> Void = { _ in }
    ) -> OrphanGC {
        let fixed = clock
        return OrphanGC(
            db: db, git: GitManager(),
            broadcast: broadcast,
            liveCWDsProvider: { [] },
            scratchpadBase: scratchpadBase,
            now: { fixed },
            profileDirBase: profileBase,
            hangStackBase: hangStackBase
        )
    }

    /// One hang-stack file, aged `age` before the sweep clock. The name carries
    /// the index so ordering is legible in a failure message.
    @discardableResult
    private func makeHangFile(
        _ name: String, age: TimeInterval, bytes: Int = 32
    ) throws -> URL {
        let url = hangStackBase.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        let stamp = clock.addingTimeInterval(-age)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        return url
    }

    /// The fixture both headline tests use: 1,400 files young enough to pass
    /// the age test and 600 well past it, for 2,000 in total. With the flag on
    /// this exercises BOTH halves of the policy at once — the 600 aged-out
    /// files go by `maxAge`, and 400 of the young ones go by the count cap,
    /// leaving exactly `maxFiles` behind.
    private func makeTwoThousandFiles() throws {
        for index in 0..<1400 {
            // 1 day plus a per-file minute, so every file has a distinct mtime
            // and the newest-first ranking is total.
            try makeHangFile(
                "hang-young-\(String(format: "%04d", index)).txt",
                age: 86_400 + Double(index) * 60)
        }
        for index in 0..<600 {
            try makeHangFile(
                "hang-old-\(String(format: "%04d", index)).txt",
                age: 20 * 86_400 + Double(index) * 60)
        }
    }

    private func fileNames() throws -> [String] {
        try fm.contentsOfDirectory(atPath: hangStackBase.path).sorted()
    }

    // MARK: - Flag gates

    @Test("the hang-stack flag ships off: a real sweep leaves 2,000 aged files untouched")
    func flagOffIsNoOp() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try makeTwoThousandFiles()

        let result = await makeGC(db: db).sweep()

        #expect(try fileNames().count == 2000)
        #expect(!result.planned.contains { $0.hasPrefix("REAP hang-stacks ") })
        #expect(result.reaped == 0)
        #expect(try await db.reapRecords.list(repoPath: nil).isEmpty)
    }

    @Test("with the flag off a dry run still plans what enabling it would reclaim")
    func flagOffDryRunStillPlans() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try makeTwoThousandFiles()

        let result = await makeGC(db: db).sweep(dryRun: true)

        // The whole point of the bypass: a user deciding whether to flip a
        // default-off flag can preview exactly what it would reclaim.
        let line = try #require(result.planned.first { $0.hasPrefix("REAP hang-stacks ") })
        #expect(line.contains("files=1000"))
        #expect(result.reaped == 0)
        #expect(try fileNames().count == 2000)
    }

    @Test("gcEnabled off keeps everything even with the hang-stack flag on")
    func masterSwitchStillGoverns() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        try await db.config.setGCHangStacksEnabled(true)
        try makeTwoThousandFiles()

        let result = await makeGC(db: db).sweep()

        #expect(result.planned == ["gc disabled"])
        #expect(try fileNames().count == 2000)
    }

    // MARK: - Reaping

    @Test("flag on: trimmed to the newest 1000, with everything past 14 days gone")
    func flagOnTrimsByAgeAndCount() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCHangStacksEnabled(true)
        try makeTwoThousandFiles()

        let result = await makeGC(db: db).sweep()

        let survivors = try fileNames()
        #expect(survivors.count == HangStackRetention.maxFiles)
        #expect(result.reaped == 1000)
        // Nothing past `maxAge` survives — the whole 600-file old cohort is
        // gone regardless of where it ranked.
        #expect(!survivors.contains { $0.hasPrefix("hang-old-") })
        // And the count cap took the 400 oldest of the young cohort: the
        // survivors are exactly indices 0..999, the newest ones.
        #expect(survivors.first == "hang-young-0000.txt")
        #expect(survivors.last == "hang-young-0999.txt")
    }

    @Test("grace keeps the newest file out of the ranking entirely")
    func graceProtectsTheNewestFile() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCHangStacksEnabled(true)
        // Exactly `maxFiles` files old enough to be considered, plus one the
        // app could still be appending resamples to. The count discriminates:
        // with grace applied the eligible set is exactly 1000 and nothing is
        // selected; without it the set would be 1001 and the oldest file would
        // be reaped.
        for index in 0..<HangStackRetention.maxFiles {
            try makeHangFile(
                "hang-aged-\(String(format: "%04d", index)).txt",
                age: 2 * 86_400 + Double(index) * 60)
        }
        let fresh = try makeHangFile("hang-fresh.txt", age: 600)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: fresh.path))
        #expect(try fileNames().count == HangStackRetention.maxFiles + 1)
        #expect(result.reaped == 0)
        #expect(!result.planned.contains { $0.hasPrefix("REAP hang-stacks ") })
    }

    @Test("the whitelist holds: only hang-*.txt regular files are candidates")
    func whitelistHolds() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCHangStacksEnabled(true)
        for index in 0..<5 {
            try makeHangFile("hang-doomed-\(index).txt", age: 30 * 86_400)
        }
        // Not TBD's to delete: a user's own file, a subdirectory, and a
        // subdirectory that happens to match the name shape (the regular-file
        // test is what keeps it).
        let notes = hangStackBase.appendingPathComponent("notes.md")
        try Data("keep me".utf8).write(to: notes)
        try fm.setAttributes(
            [.modificationDate: clock.addingTimeInterval(-90 * 86_400)],
            ofItemAtPath: notes.path)
        let archive = hangStackBase.appendingPathComponent("archive", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        let dirNamedLikeAFile = hangStackBase.appendingPathComponent(
            "hang-not-a-file.txt", isDirectory: true)
        try fm.createDirectory(at: dirNamedLikeAFile, withIntermediateDirectories: true)

        let result = await makeGC(db: db).sweep()

        #expect(result.reaped == 5)
        #expect(fm.fileExists(atPath: notes.path))
        #expect(fm.fileExists(atPath: archive.path))
        #expect(fm.fileExists(atPath: dirNamedLikeAFile.path))
        #expect(try fileNames().sorted() == ["archive", "hang-not-a-file.txt", "notes.md"])
    }

    @Test("an entry whose resource values cannot be read is kept, never deleted")
    func unreadableEntriesAreKept() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCHangStacksEnabled(true)
        try makeHangFile("hang-doomed.txt", age: 30 * 86_400)
        // A dangling symlink named like a hang stack: the name passes the
        // whitelist, but every resource-value read on it fails. Absence of
        // evidence is not evidence of absence, so it must survive.
        let dangling = hangStackBase.appendingPathComponent("hang-dangling.txt")
        try fm.createSymbolicLink(
            at: dangling, withDestinationURL: sandbox.appendingPathComponent("gone.txt"))

        let result = await makeGC(db: db).sweep()

        #expect(result.reaped == 1)
        let names = try fileNames()
        #expect(names == ["hang-dangling.txt"])
    }

    // MARK: - Aggregation

    @Test("a 2,000-file sweep adds one plan line and zero reap records")
    func reportingIsAggregate() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCHangStacksEnabled(true)
        try makeTwoThousandFiles()
        let deltas = DeltaRecorder()

        let result = await makeGC(db: db, broadcast: { deltas.record($0) }).sweep()

        let lines = result.planned.filter { $0.hasPrefix("REAP hang-stacks ") }
        #expect(lines.count == 1, "one aggregate line, never one per file")
        // The RESOLVED base, which is what the collector enumerates and reaps.
        // `NSTemporaryDirectory()` hands back a `/var/folders/…` spelling whose
        // `/var` ancestor is a symlink, so the injected base and the swept
        // directory genuinely differ here — a plan line naming the injected
        // spelling would be naming a directory the reap never touched.
        let sweptPath = HangStackRetention.resolvedDirectory(hangStackBase).path
        #expect(lines.first == "REAP hang-stacks \(sweptPath) files=1000 bytes=32000")
        // No `ReapRecord`: a hang stack is not restorable and belongs to no
        // repo, and one row per file would make `reap_records` the new
        // unbounded table.
        #expect(try await db.reapRecords.list(repoPath: nil).isEmpty)
        // …and therefore nothing arms the record-keyed broadcast, even though
        // 1,000 files really were reclaimed.
        #expect(!deltas.recorded.contains { delta in
            if case .reapRecordsChanged = delta { return true }
            return false
        })
        #expect(result.reaped == 1000, "the files still count toward the reported total")
    }
}

/// Collects the deltas a sweep broadcasts, so a test can assert one was NOT
/// sent.
private final class DeltaRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func record(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    var recorded: [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}

/// Unit-level coverage of the collector's selection and ordering, with no
/// database and no sweep around it.
@Suite("HangStackCollector selection")
struct HangStackCollectorTests: ~Copyable {
    let fm = FileManager.default
    let sandbox: URL
    let base: URL
    let clock = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("hang-stack-collector-\(UUID().uuidString)", isDirectory: true)
        base = sandbox.appendingPathComponent("hang-stacks", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    deinit {
        try? fm.removeItem(at: sandbox)
    }

    @discardableResult
    private func makeFile(_ name: String, age: TimeInterval, bytes: Int = 10) throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data(repeating: 0x42, count: bytes).write(to: url)
        try fm.setAttributes(
            [.modificationDate: clock.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    @Test("a missing base directory is a no-op, not an error")
    func missingBaseIsNoOp() {
        let collector = HangStackCollector(
            base: sandbox.appendingPathComponent("never-created", isDirectory: true))

        let selected = collector.candidates(now: clock, graceSeconds: 3600)

        #expect(selected.isEmpty)
        #expect(collector.reap(selected) == (files: 0, bytes: 0))
    }

    @Test("grace is applied before either policy test")
    func graceRunsBeforeTheAgeTest() throws {
        // Every file here is far past `maxAge`; a grace window wider than their
        // age must still keep all of them, which is only true if grace removes
        // them from consideration BEFORE the age test rather than after it.
        for index in 0..<5 {
            try makeFile("hang-\(index).txt", age: 30 * 86_400)
        }
        let collector = HangStackCollector(base: base)

        #expect(collector.candidates(now: clock, graceSeconds: 60 * 86_400).isEmpty)
        #expect(collector.candidates(now: clock, graceSeconds: 3600).count == 5)
    }

    @Test("age selection is exclusive at exactly maxAge")
    func ageBoundaryIsExclusive() throws {
        try makeFile("hang-exactly.txt", age: HangStackRetention.maxAge)
        try makeFile("hang-past.txt", age: HangStackRetention.maxAge + 1)
        let collector = HangStackCollector(base: base)

        let selected = collector.candidates(now: clock, graceSeconds: 3600)

        #expect(selected.map(\.url.lastPathComponent) == ["hang-past.txt"])
    }

    @Test("selection is ordered oldest-last and carries the prefetched sizes")
    func selectionCarriesSizes() throws {
        try makeFile("hang-a.txt", age: 20 * 86_400, bytes: 7)
        try makeFile("hang-b.txt", age: 30 * 86_400, bytes: 11)
        let collector = HangStackCollector(base: base)

        let selected = collector.candidates(now: clock, graceSeconds: 3600)

        // Newest-first ranking, so the 20-day file precedes the 30-day one.
        #expect(selected.map(\.url.lastPathComponent) == ["hang-a.txt", "hang-b.txt"])
        #expect(selected.map(\.sizeBytes) == [7, 11])
        #expect(collector.reap(selected) == (files: 2, bytes: 18))
        #expect(try fm.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    @Test("a base spelled through a symlink still reaps its children")
    func symlinkedBaseStillReaps() throws {
        // The regression this pins: the enumeration hands back one spelling of
        // the directory and the injected base carries another (`/var` against
        // `/private/var`, a symlinked parent, a trailing slash). A raw string
        // prefix test then reads every anchored file as unanchored and the
        // collector silently reclaims nothing at all — selection looks healthy
        // and deletion is a no-op.
        try makeFile("hang-doomed.txt", age: 30 * 86_400, bytes: 4)
        let link = sandbox.appendingPathComponent("link-to-base", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: base)
        let collector = HangStackCollector(base: link)

        let selected = collector.candidates(now: clock, graceSeconds: 3600)
        #expect(selected.count == 1)
        #expect(collector.reap(selected) == (files: 1, bytes: 4))
        #expect(try fm.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    @Test("a trailing-slash base still reaps its children")
    func trailingSlashBaseStillReaps() throws {
        try makeFile("hang-doomed.txt", age: 30 * 86_400, bytes: 4)
        let withSlash = URL(fileURLWithPath: base.path + "/", isDirectory: true)
        let collector = HangStackCollector(base: withSlash)

        let selected = collector.candidates(now: clock, graceSeconds: 3600)
        #expect(collector.reap(selected) == (files: 1, bytes: 4))
        #expect(try fm.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    @Test("reap refuses a candidate in a nested subdirectory, not just a foreign one")
    func reapRefusesNestedCandidates() throws {
        let nested = base.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let inside = nested.appendingPathComponent("hang-nested.txt")
        try Data(repeating: 0x44, count: 3).write(to: inside)
        let collector = HangStackCollector(base: base)

        // Only a DIRECT child qualifies — `candidates()` never descends, so a
        // nested path can only arrive from a hand-built candidate.
        let result = collector.reap([
            HangStackCandidate(url: inside, modifiedAt: clock, sizeBytes: 3),
        ])

        #expect(result == (files: 0, bytes: 0))
        #expect(fm.fileExists(atPath: inside.path))
    }

    @Test("reap refuses a hand-built candidate whose name is not on the whitelist")
    func reapRefusesNonWhitelistedNames() throws {
        // Both shapes the directory legitimately holds and TBD does not own: a
        // user's own file, and a subdirectory. `candidates()` never selects
        // either, but `HangStackCandidate` is public, and `removeItem` on the
        // directory would take its contents with it.
        let notes = base.appendingPathComponent("notes.md")
        try Data("keep me".utf8).write(to: notes)
        let archive = base.appendingPathComponent("archive", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        let inside = archive.appendingPathComponent("sample.txt")
        try Data("keep me too".utf8).write(to: inside)
        let collector = HangStackCollector(base: base)

        let result = collector.reap([
            HangStackCandidate(url: notes, modifiedAt: clock, sizeBytes: 7),
            HangStackCandidate(url: archive, modifiedAt: clock, sizeBytes: 0),
        ])

        #expect(result == (files: 0, bytes: 0))
        #expect(fm.fileExists(atPath: notes.path))
        #expect(fm.fileExists(atPath: inside.path), "removeItem on a directory is recursive")
    }

    @Test("reap refuses a hand-built candidate that names a directory, whitelist or not")
    func reapRefusesDirectories() throws {
        // Named exactly like a hang stack, so the whitelist and the anchor both
        // pass and the regular-file check is the only thing standing between a
        // hand-built candidate and a recursive delete.
        let dirNamedLikeAFile = base.appendingPathComponent("hang-not-a-file.txt", isDirectory: true)
        try fm.createDirectory(at: dirNamedLikeAFile, withIntermediateDirectories: true)
        let inside = dirNamedLikeAFile.appendingPathComponent("sample.txt")
        try Data("keep me".utf8).write(to: inside)
        let collector = HangStackCollector(base: base)

        let result = collector.reap([
            HangStackCandidate(url: dirNamedLikeAFile, modifiedAt: clock, sizeBytes: 0),
        ])

        #expect(result == (files: 0, bytes: 0))
        #expect(fm.fileExists(atPath: dirNamedLikeAFile.path))
        #expect(fm.fileExists(atPath: inside.path), "removeItem on a directory is recursive")
    }

    @Test("reap refuses a candidate that does not resolve under the base")
    func reapRefusesUnanchoredCandidates() throws {
        let outside = sandbox.appendingPathComponent("hang-outside.txt")
        try Data(repeating: 0x43, count: 5).write(to: outside)
        let collector = HangStackCollector(base: base)

        let result = collector.reap([
            HangStackCandidate(url: outside, modifiedAt: clock, sizeBytes: 5),
        ])

        #expect(result == (files: 0, bytes: 0))
        #expect(fm.fileExists(atPath: outside.path), "an unanchored path is never deleted")
    }

    @Test("reap reports what it actually removed, not what it was handed")
    func reapReportsActualRemovals() throws {
        let present = try makeFile("hang-present.txt", age: 30 * 86_400, bytes: 9)
        let vanished = base.appendingPathComponent("hang-vanished.txt")
        let collector = HangStackCollector(base: base)

        let result = collector.reap([
            HangStackCandidate(url: present, modifiedAt: clock, sizeBytes: 9),
            HangStackCandidate(url: vanished, modifiedAt: clock, sizeBytes: 100),
        ])

        #expect(result == (files: 1, bytes: 9))
    }
}
