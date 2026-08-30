import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Both branches of `HangStackWriter`'s write-time retention cap. Every writer
/// here is constructed with an injected `baseDir` at a temp directory, so
/// nothing in this suite can see (or delete from) the developer's real
/// `~/Library/Logs/TBD/hang-stacks`.
@Suite("HangStackWriter write-time retention cap")
struct HangStackWriterRetentionTests: ~Copyable {
    let fm = FileManager.default
    let sandbox: URL
    let baseDir: URL

    init() {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("hang-stack-writer-\(UUID().uuidString)", isDirectory: true)
        baseDir = sandbox.appendingPathComponent("hang-stacks", isDirectory: true)
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    deinit {
        try? fm.removeItem(at: sandbox)
    }

    /// `maxFiles` pre-existing hang stacks, aged so their newest-first order is
    /// total and every one of them is older than anything the writer will add.
    private func fillToCap() throws {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<HangStackRetention.maxFiles {
            let url = baseDir.appendingPathComponent(
                "hang-existing-\(String(format: "%04d", index)).txt")
            try Data(repeating: 0x41, count: 8).write(to: url)
            try fm.setAttributes(
                [.modificationDate: anchor.addingTimeInterval(-Double(index) * 60)],
                ofItemAtPath: url.path)
        }
    }

    /// Records one hang and settles the writer: the recovery marker, then the
    /// trim barrier.
    ///
    /// The trim is dispatched ASYNCHRONOUSLY onto the writer's own serial queue
    /// — it must never run on the watchdog's tick queue, where it would delay
    /// the recovery tick and inflate the `totalStallMs` it is writing down — so
    /// every assertion about the directory sits behind `waitForPendingTrims()`.
    /// That is a barrier on a serial queue rather than a sleep: it returns
    /// exactly when the dispatched trim has finished.
    @discardableResult
    private func recordOneHang(_ writer: HangStackWriter) -> URL? {
        let url = writer.recordHangStart(stallMs: 500, snapshot: .empty, frames: [])
        writer.recordHangRecovery(totalStallMs: 500)
        writer.waitForPendingTrims()
        return url
    }

    private func names() throws -> [String] {
        try fm.contentsOfDirectory(atPath: baseDir.path)
    }

    @Test("mirrored flag off: the directory grows, untouched by the writer")
    func capOffLeavesTheDirectoryAlone() throws {
        try fillToCap()
        let writer = HangStackWriter(baseDir: baseDir)
        // Never armed — the default, and the state the app stays in whenever
        // the daemon is unreachable.

        let written = try #require(recordOneHang(writer))

        #expect(fm.fileExists(atPath: written.path))
        #expect(try names().count == HangStackRetention.maxFiles + 1)
    }

    @Test("mirrored flag off after being on: disarming stops the trim")
    func capCanBeDisarmed() throws {
        try fillToCap()
        let writer = HangStackWriter(baseDir: baseDir)
        writer.setRetentionEnabled(true)
        writer.setRetentionEnabled(false)

        recordOneHang(writer)

        #expect(try names().count == HangStackRetention.maxFiles + 1)
    }

    @Test("mirrored flag on: the directory is trimmed to maxFiles after a write")
    func capOnTrimsToMaxFiles() throws {
        try fillToCap()
        let writer = HangStackWriter(baseDir: baseDir)
        writer.setRetentionEnabled(true)

        let written = try #require(recordOneHang(writer))

        let survivors = try names().sorted()
        #expect(survivors.count == HangStackRetention.maxFiles)
        // The file just written is the newest, so it always survives…
        #expect(fm.fileExists(atPath: written.path))
        // …and the one dropped is the oldest, never an arbitrary one.
        #expect(!survivors.contains("hang-existing-0999.txt"))
        #expect(survivors.contains("hang-existing-0000.txt"))
    }

    @Test("the cap is count-only and whitelisted: age and foreign files are the sweep's business")
    func capIgnoresAgeAndForeignFiles() throws {
        let writer = HangStackWriter(baseDir: baseDir)
        writer.setRetentionEnabled(true)
        // Far past the sweep's `maxAge`, but well inside the count cap: the
        // writer must leave it, because the age half of the policy belongs to
        // the daemon.
        let ancient = baseDir.appendingPathComponent("hang-ancient.txt")
        try Data(repeating: 0x41, count: 8).write(to: ancient)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: ancient.path)
        let notes = baseDir.appendingPathComponent("notes.md")
        try Data("keep me".utf8).write(to: notes)

        recordOneHang(writer)

        #expect(fm.fileExists(atPath: ancient.path))
        #expect(fm.fileExists(atPath: notes.path))
    }

    // MARK: - Which flag arms it

    @Test("the GC master switch masters the write-time cap too")
    func gcEnabledOffDisarmsTheCap() throws {
        try fillToCap()
        let writer = HangStackWriter(baseDir: baseDir)
        // The state a user reaches by soaking the phase flag on and then
        // turning GC off in Settings. The daemon's own phase stops there, and
        // the app's half must stop with it — reading `gcHangStacksEnabled`
        // alone would leave the writer deleting after the master switch said
        // no.
        writer.setRetentionEnabled(HangStackWriter.retentionArmed(
            for: Config(gcEnabled: false, gcHangStacksEnabled: true)))

        recordOneHang(writer)

        #expect(try names().count == HangStackRetention.maxFiles + 1)
    }

    @Test("both flags on is the only combination that arms the cap")
    func bothFlagsOnArmsTheCap() throws {
        try fillToCap()
        let writer = HangStackWriter(baseDir: baseDir)
        writer.setRetentionEnabled(HangStackWriter.retentionArmed(
            for: Config(gcEnabled: true, gcHangStacksEnabled: true)))

        recordOneHang(writer)

        // Without this arm the case above would pass against a writer that
        // never trims at all, for reasons having nothing to do with the flags.
        #expect(try names().count == HangStackRetention.maxFiles)
    }

    @Test("resolution is the conjunction, in every combination")
    func retentionArmedIsTheConjunction() {
        #expect(!HangStackWriter.retentionArmed(
            for: Config(gcEnabled: false, gcHangStacksEnabled: false)))
        #expect(!HangStackWriter.retentionArmed(
            for: Config(gcEnabled: false, gcHangStacksEnabled: true)))
        #expect(!HangStackWriter.retentionArmed(
            for: Config(gcEnabled: true, gcHangStacksEnabled: false)))
        #expect(HangStackWriter.retentionArmed(
            for: Config(gcEnabled: true, gcHangStacksEnabled: true)))
    }

    // MARK: - The base as it is spelled

    @Test("a base spelled through a symlink is still trimmed")
    func symlinkedBaseIsStillTrimmed() throws {
        // The regression this pins, and the half of it that shipped untested:
        // `FileManager.contentsOfDirectory(at:)` yields NOTHING for a URL that
        // is itself a symlink to a directory, so a writer handed such a base
        // enumerates an empty directory, never reaches the cap, and silently
        // trims nothing — a failure indistinguishable from a healthy trim over
        // a small directory. Every other case here builds its base under
        // `NSTemporaryDirectory()`, where only the `/var` ancestor is a
        // symlink and the leaf is real, so none of them can see it.
        try fillToCap()
        let link = sandbox.appendingPathComponent("link-to-base", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: baseDir)
        let writer = HangStackWriter(baseDir: link)
        writer.setRetentionEnabled(true)

        let written = try #require(recordOneHang(writer))

        // Counted through the REAL directory, so the assertion cannot be
        // satisfied by the same symlink confusion it is testing for.
        #expect(try names().count == HangStackRetention.maxFiles)
        #expect(fm.fileExists(atPath: written.path))
    }
}
