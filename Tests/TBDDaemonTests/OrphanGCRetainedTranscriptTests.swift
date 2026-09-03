import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

// Nested under TBDHomeSerialized: the retained-transcript leg walks
// `TBDConstants.retainedTranscriptsDir`, which resolves from the process-global
// TBD_HOME and has no injection seam of its own — the path helper that names a
// receipt's file resolves the same variable, and the two must agree. See
// TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {

/// Tier 2: a real `~/tbd/transcripts` tree under a temp `TBD_HOME`, plus an
/// in-memory database. The scratchpad base, the profile base, the holders base
/// and the clock are all injected; no process is spawned and no production path
/// outside the temp home is touched.
@Suite("OrphanGC reclaims retained transcripts")
struct OrphanGCRetainedTranscriptTests {
    private let fm = FileManager.default
    /// The sweep's fixed reading of now. Every fixture's age is expressed
    /// against it, so nothing here depends on wall-clock time.
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let provider = "agentbox"

    /// Restores the displaced `TBD_HOME` rather than unsetting it —
    /// `scripts/test.sh` exports one for the whole run, and `unsetenv` would
    /// hand every concurrently running suite the developer's real `~/tbd`.
    private func isolateTBDHome() -> (URL, () -> Void) {
        let home = fm.temporaryDirectory
            .appendingPathComponent("tbd-gc-rt-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        let prior = setTBDHome(home.path)
        // `FileManager.default` rather than the suite's `fm`, so the returned
        // closure captures two locals and never `self`.
        return (home, {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: home)
        })
    }

    private func makeGC(db: TBDDatabase, home: URL) -> OrphanGC {
        let fixed = clock
        return OrphanGC(
            db: db, git: GitManager(),
            broadcast: { _ in },
            liveCWDsProvider: { [] },
            scratchpadBase: home.appendingPathComponent("s", isDirectory: true),
            now: { fixed },
            profileDirBase: home.appendingPathComponent("p", isDirectory: true),
            holdersBase: home.appendingPathComponent("h", isDirectory: true)
        )
    }

    /// Writes a JSONL file at the canonical path for `(provider, key)` and
    /// backdates it, so the grace window has elapsed against this suite's fixed
    /// clock unless the caller asks otherwise.
    @discardableResult
    private func writeTranscript(key: String, age: TimeInterval = 86_400) -> String {
        let url = TBDConstants.retainedTranscriptPath(provider: provider, key: key)
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data(#"{"type":"user"}"#.utf8))
        backdate(url.path, age: age)
        return url.path
    }

    private func backdate(_ path: String, age: TimeInterval) {
        let stamp = clock.addingTimeInterval(-age)
        try? fm.setAttributes(
            [.creationDate: stamp, .modificationDate: stamp], ofItemAtPath: path)
    }

    /// Canonicalizes a path exactly as the retained-transcript leg's own
    /// `REAP`/`KEEP` lines do, through the same `DeletionQueueCollector`
    /// helper `OrphanGC` reports paths through. On macOS, `NSTemporaryDirectory()`
    /// (and everything derived from it, including `TBD_HOME` here) reads
    /// `/var/...`, but `/var` is itself a symlink to `/private/var` — so a
    /// path built from raw string composition and the equivalent path as it
    /// comes back out of a filesystem walk disagree on that prefix unless
    /// both go through the same resolver. Comparing a hand-built expectation
    /// against `result.planned` without this would either fail outright, or
    /// — worse — silently never match and pass a negative assertion for the
    /// wrong reason.
    private func canonical(_ path: String) -> String {
        DeletionQueueCollector(git: GitManager()).resolvedPath(path)
    }

    private func receipt(
        key: String, expiresAt: Date? = nil, localPath: String? = nil
    ) -> RetainedTranscript {
        RetainedTranscript(
            provider: provider, key: key, expiresAt: expiresAt, bytes: 15,
            localPath: localPath, createdAt: clock.addingTimeInterval(-86_400))
    }

    // MARK: - The gate

    /// **The discriminating sweep test.** A transcript file no row references —
    /// the residue of an `import` whose `create` then failed — is gone from disk
    /// after one sweep with the flag on.
    @Test func aSweepWithTheFlagOnUnlinksAnUnreferencedTranscript() async throws {
        let (home, cleanUp) = isolateTBDHome()
        defer { cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRetainedTranscriptsEnabled(true)
        let path = writeTranscript(key: "orphaned-key")

        let result = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: path) == false, "\(path) survived the sweep")
        #expect(result.planned.contains("REAP retained-transcript \(canonical(path))"))
        #expect(result.reaped >= 1)
    }

    /// The off branch of the gate — the state every install ships in. The same
    /// fixture the test above reaps is left completely alone, and the sweep does
    /// not even plan it.
    @Test func aSweepWithTheFlagOffTouchesNothing() async throws {
        let (home, cleanUp) = isolateTBDHome()
        defer { cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().gcRetainedTranscriptsEnabled == false,
                "the shipped default must be off")
        let path = writeTranscript(key: "orphaned-key")
        try await db.retainedTranscripts.insert(
            receipt(key: "stale-key", expiresAt: clock.addingTimeInterval(-3_600)))

        let result = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: path), "\(path) was swept with the flag off")
        #expect(try await db.retainedTranscripts.find(provider: provider, key: "stale-key") != nil,
                "an expired row was dropped with the flag off")
        #expect(result.planned.contains { $0.contains("retained-transcript") } == false)
    }

    /// An explicit `false` is the same as never having chosen, for behavior.
    @Test func anExplicitOptOutTouchesNothing() async throws {
        let (home, cleanUp) = isolateTBDHome()
        defer { cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRetainedTranscriptsEnabled(false)
        let path = writeTranscript(key: "orphaned-key")

        _ = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: path))
    }

    /// The GC master switch is read on top of the leg's flag: both must be on.
    @Test func theMasterSwitchStillGovernsTheLeg() async throws {
        let (home, cleanUp) = isolateTBDHome()
        defer { cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRetainedTranscriptsEnabled(true)
        try await db.config.setGCEnabled(false)
        let path = writeTranscript(key: "orphaned-key")
        try await db.retainedTranscripts.insert(
            receipt(key: "stale-key", expiresAt: clock.addingTimeInterval(-3_600)))

        _ = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: path))
        #expect(try await db.retainedTranscripts.find(provider: provider, key: "stale-key") != nil)
    }

    /// `dryRun` bypasses the flag, exactly as it bypasses `gcEnabled`: someone
    /// deciding whether to turn a default-off flag on needs to see what it would
    /// reclaim first. It plans both halves and changes neither.
    @Test func aDryRunPlansWithTheFlagOffAndChangesNothing() async throws {
        let (home, cleanUp) = isolateTBDHome()
        defer { cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        let path = writeTranscript(key: "orphaned-key")
        try await db.retainedTranscripts.insert(
            receipt(key: "stale-key", expiresAt: clock.addingTimeInterval(-3_600)))

        let result = await makeGC(db: db, home: home).sweep(dryRun: true)

        #expect(result.planned.contains("REAP retained-transcript \(canonical(path))"))
        #expect(result.planned.contains("REAP retained-transcript-row \(provider)/stale-key"))
        #expect(result.reaped == 0)
        #expect(fm.fileExists(atPath: path), "a dry run must never touch disk")
        #expect(try await db.retainedTranscripts.find(provider: provider, key: "stale-key") != nil,
                "a dry run must never touch the database")
    }

    // MARK: - What it must never reclaim

    /// The keep case that matters most: a file a live row references is not
    /// residue, and unlinking it would destroy the only local copy of a
    /// conversation.
    @Test func aReferencedTranscriptSurvivesTheSweep() async throws {
        let (home, cleanUp) = isolateTBDHome()
        defer { cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRetainedTranscriptsEnabled(true)
        let kept = writeTranscript(key: "referenced-key")
        let orphan = writeTranscript(key: "orphaned-key")
        try await db.retainedTranscripts.insert(
            receipt(key: "referenced-key", expiresAt: clock.addingTimeInterval(86_400)))

        let result = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: kept), "a referenced transcript was unlinked")
        #expect(result.planned.contains("REAP retained-transcript \(canonical(kept))") == false)
        #expect(fm.fileExists(atPath: orphan) == false,
                "the unreferenced sibling proves the sweep ran at all")
    }

    /// A row that records a local path outside the canonical layout still
    /// protects that file: both readings are referenced, never just one.
    @Test func aRowThatRecordsItsOwnLocalPathKeepsThatFile() async throws {
        let (home, cleanUp) = isolateTBDHome()
        defer { cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRetainedTranscriptsEnabled(true)
        // A file filed under one key, recorded as the local path of another.
        let moved = writeTranscript(key: "moved-file")
        try await db.retainedTranscripts.insert(
            receipt(key: "other-key", localPath: moved))

        _ = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: moved),
                "a file named by a row's local_path must never be unlinked")
    }

    /// **A row with no stated expiry is never reclaimed.** Absence means the
    /// provider made no claim, not that a claim lapsed — and the key lives in
    /// that row and nowhere else, so dropping it strands the blob forever.
    @Test func aRowWithNoStatedExpiryIsNeverDropped() async throws {
        let (home, cleanUp) = isolateTBDHome()
        defer { cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRetainedTranscriptsEnabled(true)
        try await db.retainedTranscripts.insert(receipt(key: "no-claim-key"))
        try await db.retainedTranscripts.insert(
            receipt(key: "stale-key", expiresAt: clock.addingTimeInterval(-3_600)))

        let result = await makeGC(db: db, home: home).sweep()

        #expect(
            try await db.retainedTranscripts.find(provider: provider, key: "no-claim-key") != nil,
            "an absent expires_at is no claim, never a lapsed one")
        #expect(
            result.planned.contains("REAP retained-transcript-row \(provider)/no-claim-key")
                == false)
        #expect(
            try await db.retainedTranscripts.find(provider: provider, key: "stale-key") == nil,
            "the expired sibling proves the leg ran at all")
    }

    /// A file younger than `gcGraceSeconds` is kept even with no row pointing at
    /// it: `recall` writes the file before it records the path, so a sweep
    /// landing inside that window would otherwise unlink an arriving transcript.
    @Test func aYoungUnreferencedFileIsKeptByTheGraceWindow() async throws {
        let (home, cleanUp) = isolateTBDHome()
        defer { cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRetainedTranscriptsEnabled(true)
        let young = writeTranscript(key: "just-arrived", age: 5)

        let result = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: young))
        #expect(result.planned.contains("KEEP grace \(canonical(young))"))
    }

    /// Only `<base>/<provider>/<key>.jsonl` is a candidate. Anything else in the
    /// tree is left alone rather than judged by a rule that never considered it.
    @Test func aFileThatIsNotATranscriptIsLeftAlone() async throws {
        let (home, cleanUp) = isolateTBDHome()
        defer { cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRetainedTranscriptsEnabled(true)
        let orphan = writeTranscript(key: "orphaned-key")
        let notes = URL(fileURLWithPath: orphan)
            .deletingLastPathComponent().appendingPathComponent("notes.txt").path
        fm.createFile(atPath: notes, contents: Data("hand-written\n".utf8))
        backdate(notes, age: 86_400)
        let topLevel = TBDConstants.retainedTranscriptsDir
            .appendingPathComponent("README.md").path
        fm.createFile(atPath: topLevel, contents: Data("hand-written\n".utf8))
        backdate(topLevel, age: 86_400)

        let result = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: notes))
        #expect(fm.fileExists(atPath: topLevel))
        #expect(result.planned.contains { $0.contains(notes) } == false)
        #expect(result.planned.contains { $0.contains(topLevel) } == false)
        #expect(fm.fileExists(atPath: orphan) == false,
                "the real candidate proves the sweep ran at all")
    }

    // MARK: - Expiry

    /// One pass reclaims both halves: the expired row goes, and the file it had
    /// been protecting goes with it.
    @Test func anExpiredRowIsDroppedAndItsFileWithIt() async throws {
        let (home, cleanUp) = isolateTBDHome()
        defer { cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRetainedTranscriptsEnabled(true)
        let path = writeTranscript(key: "stale-key")
        try await db.retainedTranscripts.insert(
            receipt(key: "stale-key", expiresAt: clock.addingTimeInterval(-3_600)))

        let result = await makeGC(db: db, home: home).sweep()

        #expect(try await db.retainedTranscripts.find(provider: provider, key: "stale-key") == nil)
        #expect(fm.fileExists(atPath: path) == false)
        #expect(result.planned.contains("REAP retained-transcript-row \(provider)/stale-key"))
        #expect(result.planned.contains("REAP retained-transcript \(canonical(path))"))
        #expect(result.reaped >= 2, "the row and the file are both reclaimed")
    }

    /// A receipt whose expiry is still ahead keeps both its row and its file.
    @Test func anUnexpiredRowKeepsItsRowAndItsFile() async throws {
        let (home, cleanUp) = isolateTBDHome()
        defer { cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRetainedTranscriptsEnabled(true)
        let path = writeTranscript(key: "fresh-key")
        try await db.retainedTranscripts.insert(
            receipt(key: "fresh-key", expiresAt: clock.addingTimeInterval(3_600)))

        _ = await makeGC(db: db, home: home).sweep()

        #expect(try await db.retainedTranscripts.find(provider: provider, key: "fresh-key") != nil)
        #expect(fm.fileExists(atPath: path))
    }
}
}
