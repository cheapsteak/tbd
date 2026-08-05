import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — real filesystem, plus the writer's `write`/`fsync` seam.
///
/// One property, and it is the one a reader cannot recover from if it breaks:
/// after a recovered append the row is in the file **exactly once**, and it
/// parses. A retry that rewrites a line whose bytes already landed duplicates
/// an actuation that happened once; a retry that appends after a half-written
/// line fuses two rows into one unparseable one. Neither state can be
/// provoked by filesystem setup — no `chmod` makes `fsync` fail or a `write`
/// return short — so the failures are injected through the seam.
@Suite("Actuation log recovery")
struct ActuationLogRetryTests {

    // MARK: - Fixture

    /// Counts seam calls and decides which of them fails. A class with a lock
    /// rather than an actor: the seam is a synchronous closure.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func makePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
    }

    private func contents(at path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Every line that parses as a JSON object, in order. Lines that do not
    /// parse — the isolated fragment a partial write leaves — are skipped,
    /// exactly as a line-oriented reader would skip them.
    private func parsedRows(at path: String) -> [[String: Any]] {
        contents(at: path)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
    }

    private func sendRow() -> ActuationRow {
        var row = ActuationRow(actor: .app, kind: .send)
        row.method = ActuationSurface.terminalSend.method
        row.target = ActuationTarget(
            worktree: "1B7E2C90-88AA-4F60-B1D0-9E8F7A6B5C4D",
            terminal: "6D40F3A1-2B14-4E14-9C4A-0F1D2E3A4B5C")
        row.message = "please rebase onto main"
        row.submit = true
        return row
    }

    // MARK: - fsync failed after a complete write

    @Test("a failed flush is re-flushed, never rewritten — the row lands once")
    func failedFsyncFlushesRatherThanDuplicating() async throws {
        let path = try makePath()
        let counter = CallCounter()
        let log = ActuationLog(path: path, syscalls: ActuationLogSyscalls(
            write: { descriptor, buffer, count in
                Foundation.write(descriptor, buffer, count)
            },
            fsync: { descriptor in
                if counter.next() == 1 {
                    errno = EIO
                    return -1
                }
                return Foundation.fsync(descriptor)
            }))

        let id = try await log.appendRequest(sendRow())

        let rows = parsedRows(at: path)
        #expect(rows.count == 1, "the recovery must flush the existing bytes, not append them again")
        #expect(rows.first?["id"] as? String == id)
        // Exactly two flushes: the one that failed, and the recovery's.
        #expect(counter.count == 2)
    }

    @Test("a flush that fails onto a file replaced under us re-appends, still exactly once")
    func failedFsyncOnAReplacedFileReAppends() async throws {
        let path = try makePath()
        let counter = CallCounter()
        let log = ActuationLog(path: path, syscalls: ActuationLogSyscalls(
            write: { descriptor, buffer, count in
                Foundation.write(descriptor, buffer, count)
            },
            fsync: { descriptor in
                if counter.next() == 1 {
                    // A cleanup script / external rotation took the file the
                    // bytes went into. The persisted-bytes assumption is void:
                    // the row now exists nowhere a reader will look.
                    try? FileManager.default.removeItem(atPath: path)
                    errno = EIO
                    return -1
                }
                return Foundation.fsync(descriptor)
            }))

        let id = try await log.appendRequest(sendRow())

        let rows = parsedRows(at: path)
        #expect(rows.count == 1, "a fresh inode cannot duplicate — the row must be re-appended")
        #expect(rows.first?["id"] as? String == id)
    }

    @Test("a flush that never succeeds still fails closed")
    func permanentlyFailingFsyncRefusesTheAct() async throws {
        let path = try makePath()
        let log = ActuationLog(path: path, syscalls: ActuationLogSyscalls(
            write: { descriptor, buffer, count in
                Foundation.write(descriptor, buffer, count)
            },
            fsync: { _ in
                errno = EIO
                return -1
            }))

        await #expect(throws: ActuationLogUnwritable.self) {
            _ = try await log.appendRequest(self.sendRow())
        }
    }

    // MARK: - write failed

    @Test("a half-written line is isolated, and the retried row parses on its own line")
    func partialWriteIsolatesTheFragment() async throws {
        let path = try makePath()
        let counter = CallCounter()
        let log = ActuationLog(path: path, syscalls: ActuationLogSyscalls(
            write: { descriptor, buffer, count in
                switch counter.next() {
                case 1:
                    // Half the line reaches the file...
                    return Foundation.write(descriptor, buffer, count / 2)
                case 2:
                    // ...and the loop's continuation fails, so the line is
                    // left half-written on disk.
                    errno = EIO
                    return -1
                default:
                    return Foundation.write(descriptor, buffer, count)
                }
            },
            fsync: { descriptor in Foundation.fsync(descriptor) }))

        let id = try await log.appendRequest(sendRow())

        let lines = contents(at: path).split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2, "the fragment must terminate as a line of its own")
        // The fragment is junk a reader skips; the row is intact and appears once.
        #expect(
            (try? JSONSerialization.jsonObject(with: Data(lines[0].utf8))) == nil,
            "the fragment must not be fused with the retried row")
        let rows = parsedRows(at: path)
        #expect(rows.count == 1)
        #expect(rows.first?["id"] as? String == id)
    }

    @Test("a write that failed on its first byte retries plainly, with no stray blank line")
    func writeThatWroteNothingRetriesPlainly() async throws {
        let path = try makePath()
        let counter = CallCounter()
        let log = ActuationLog(path: path, syscalls: ActuationLogSyscalls(
            write: { descriptor, buffer, count in
                if counter.next() == 1 {
                    errno = EIO
                    return -1
                }
                return Foundation.write(descriptor, buffer, count)
            },
            fsync: { descriptor in Foundation.fsync(descriptor) }))

        let id = try await log.appendRequest(sendRow())

        let raw = contents(at: path)
        #expect(!raw.hasPrefix("\n"), "nothing was written, so nothing needs isolating")
        let rows = parsedRows(at: path)
        #expect(rows.count == 1)
        #expect(rows.first?["id"] as? String == id)
    }

    // MARK: - Outcome rows take the same recovery

    @Test("a recovered outcome row is also written exactly once")
    func outcomeRowRecoversWithoutDuplicating() async throws {
        let path = try makePath()
        let counter = CallCounter()
        let log = ActuationLog(path: path, syscalls: ActuationLogSyscalls(
            write: { descriptor, buffer, count in
                Foundation.write(descriptor, buffer, count)
            },
            fsync: { descriptor in
                // Let the request row through; fail the outcome row's flush.
                if counter.next() == 2 {
                    errno = EIO
                    return -1
                }
                return Foundation.fsync(descriptor)
            }))

        let requestID = try await log.appendRequest(sendRow())
        await log.appendOutcome(confirms: requestID, result: .dispatched)

        let rows = parsedRows(at: path)
        #expect(rows.count == 2)
        let outcomes = rows.filter { $0["kind"] as? String == "outcome" }
        #expect(outcomes.count == 1)
        #expect(outcomes.first?["confirms"] as? String == requestID)
    }
}
