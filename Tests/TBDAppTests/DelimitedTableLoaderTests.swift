import Foundation
import Testing
import TestSupport
@testable import TBDApp

/// Tier 2: real files in a scratch directory.
@Suite("DelimitedTableLoader")
struct DelimitedTableLoaderTests {
    /// A fresh directory under the temporary directory; the caller removes it.
    private static func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadedTable(_ load: DelimitedTableLoad) throws -> DelimitedTable {
        let found: DelimitedTable?
        if case .loaded(.table(let t)) = load { found = t } else { found = nil }
        return try #require(found, "expected a loaded table, got \(load)")
    }

    @Test("a CSV file loads as a table")
    func loadsACsvFile() throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.csv")
        try Data("a,b\n1,2\n".utf8).write(to: file)
        let t = try loadedTable(DelimitedTableLoader.load(path: file.path))
        #expect(t.titles == ["a", "b"])
        #expect(t.rows == [["1", "2"]])
        #expect(t.stoppedAtLimit == false)
    }

    @Test("a TSV path splits on tabs")
    func tsvPathUsesTab() throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.tsv")
        try Data("a\tb\n1\t2".utf8).write(to: file)
        let t = try loadedTable(DelimitedTableLoader.load(path: file.path))
        #expect(t.titles == ["a", "b"])
        #expect(t.rows == [["1", "2"]])
    }

    /// 14 bytes against a 10-byte limit: the first 10 end after "222\n", and
    /// the row the cut may have split ("222") is dropped.
    @Test("the byte limit cuts the file and drops its last row")
    func byteLimitCutsAndDropsLastRow() throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.csv")
        let contents = Data("a\n111\n222\n333\n".utf8)
        try #require(contents.count == 14)
        try contents.write(to: file)
        let t = try loadedTable(DelimitedTableLoader.load(path: file.path, byteLimit: 10))
        #expect(t.titles == ["a"])
        #expect(t.rows == [["111"]])
        #expect(t.stoppedAtLimit == true)
    }

    @Test("a missing file is unreadable")
    func missingFileIsUnreadable() throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing.csv")
        #expect(DelimitedTableLoader.load(path: missing.path) == .unreadable)
    }

    @Test("a directory is unreadable")
    func directoryIsUnreadable() throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("folder.csv", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(DelimitedTableLoader.load(path: folder.path) == .unreadable)
    }

    // MARK: - FIFO

    /// What the probe thread reported, read from the test's poll.
    private final class TableLoadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _started = false
        private var _result: DelimitedTableLoad?

        var started: Bool { lock.withLock { _started } }
        var result: DelimitedTableLoad? { lock.withLock { _result } }

        func markStarted() { lock.withLock { _started = true } }
        func finish(_ value: DelimitedTableLoad) { lock.withLock { _result = value } }
    }

    /// Runs the load on a dedicated thread, so a load that blocks in
    /// `open(2)` parks that thread rather than the cooperative pool.
    private static func startLoadThread(path: String, into probe: TableLoadProbe) -> Thread {
        let worker = Thread {
            probe.markStarted()
            probe.finish(DelimitedTableLoader.load(path: path))
        }
        worker.name = "fifo-table-load-probe"
        worker.start()
        return worker
    }

    /// What the bounded wait observed when it expired. Thrown so the
    /// diagnostic lands on the CI summary's primary failure line.
    private struct LoadDidNotReturn: Error, CustomStringConvertible {
        let started: Bool
        let elapsed: Duration
        var description: String {
            started
                ? "the table load started but had not returned after \(elapsed) — it blocked " +
                  "opening a FIFO, so the regular-file check is gone"
                : "the table load thread never got to run within \(elapsed) — a scheduling " +
                  "starvation, not a blocked open"
        }
    }

    /// `open(2)` on a FIFO with no writer never returns, so a loader that
    /// opened one would leave the table preview loading forever. The load runs
    /// on a dedicated thread behind a bounded wait, so a regression fails this
    /// test instead of hanging the suite; if it does block, the test opens the
    /// write end to release the stuck opener. The bound is a hang guard, not
    /// the assertion: a blocked `open(2)` never returns, so any finite
    /// deadline tells the two outcomes apart.
    @Test("a FIFO is unreadable, and loading it does not block")
    func fifoIsUnreadableWithoutBlocking() async throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("pipe.csv").path
        try #require(mkfifo(path, 0o600) == 0,
                     Comment(rawValue: "mkfifo failed: \(String(cString: strerror(errno)))"))

        let probe = TableLoadProbe()
        let started = ContinuousClock.now
        _ = Self.startLoadThread(path: path, into: probe)

        let outcome = await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(20)
        ) { @Sendable in
            probe.result != nil
        }
        if outcome == .timedOut {
            let didStart = probe.started
            // Release a stuck `open(2)` so the worker thread is not leaked in a
            // permanently blocking syscall, then report what was observed.
            let writeEnd = open(path, O_WRONLY | O_NONBLOCK)
            if writeEnd >= 0 { close(writeEnd) }
            Issue.record(LoadDidNotReturn(started: didStart, elapsed: ContinuousClock.now - started))
            return
        }
        guard outcome == .satisfied else { return }
        let result = probe.result
        #expect(result == .unreadable)
    }
}
