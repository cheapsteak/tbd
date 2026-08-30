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

    private func recordOneHang(_ writer: HangStackWriter) -> URL? {
        writer.recordHangStart(stallMs: 500, snapshot: .empty, frames: [])
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
        writer.recordHangRecovery(totalStallMs: 500)

        #expect(fm.fileExists(atPath: written.path))
        #expect(try names().count == HangStackRetention.maxFiles + 1)
    }

    @Test("mirrored flag off after being on: disarming stops the trim")
    func capCanBeDisarmed() throws {
        try fillToCap()
        let writer = HangStackWriter(baseDir: baseDir)
        writer.setRetentionEnabled(true)
        writer.setRetentionEnabled(false)

        _ = recordOneHang(writer)
        writer.recordHangRecovery(totalStallMs: 500)

        #expect(try names().count == HangStackRetention.maxFiles + 1)
    }

    @Test("mirrored flag on: the directory is trimmed to maxFiles after a write")
    func capOnTrimsToMaxFiles() throws {
        try fillToCap()
        let writer = HangStackWriter(baseDir: baseDir)
        writer.setRetentionEnabled(true)

        let written = try #require(recordOneHang(writer))
        writer.recordHangRecovery(totalStallMs: 500)

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

        _ = recordOneHang(writer)
        writer.recordHangRecovery(totalStallMs: 500)

        #expect(fm.fileExists(atPath: ancient.path))
        #expect(fm.fileExists(atPath: notes.path))
    }
}
