import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — real filesystem, no clocks, no subprocesses.
///
/// Every test injects its own log path into `ActuationLog(path:)` rather than
/// touching `TBD_HOME`: the seam exists precisely so this suite never needs the
/// process-global env, which only `TBDHomeSerialized` may mutate.
@Suite("Actuation log writer")
struct ActuationLogTests {

    // MARK: - Fixture

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Every JSON object in a file, in order.
    private func rows(at path: String) throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                return try #require(object as? [String: Any])
            }
    }

    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: iso))
    }

    private func sendRow(message: String = "please rebase onto main") -> ActuationRow {
        var row = ActuationRow(actor: .app, kind: .send)
        row.method = ActuationSurface.terminalSend.method
        row.target = ActuationTarget(
            worktree: "1B7E2C90-88AA-4F60-B1D0-9E8F7A6B5C4D",
            terminal: "6D40F3A1-2B14-4E14-9C4A-0F1D2E3A4B5C")
        row.message = message
        row.submit = true
        return row
    }

    // MARK: - IDs

    @Test("ids are 12 lowercase base36 characters and do not repeat")
    func idFormatAndUniqueness() {
        var seen = Set<String>()
        for _ in 0..<500 {
            let id = ActuationLog.mintID()
            #expect(id.count == 12)
            #expect(id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) })
            #expect(id.allSatisfy { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0) })
            seen.insert(id)
        }
        #expect(seen.count == 500)
    }

    // MARK: - Envelope

    @Test("a request row is one line carrying the envelope plus its body, and nothing else")
    func requestRowShape() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path, now: { Date(timeIntervalSince1970: 1_770_300_131.482) })

        let id = try await log.appendRequest(sendRow())

        let written = try rows(at: path)
        #expect(written.count == 1)
        let row = try #require(written.first)
        // Whitelist: exactly the keys this shape is allowed to carry.
        #expect(Set(row.keys) == ["actor", "id", "kind", "message", "method", "submit", "target", "ts"])
        #expect(row["id"] as? String == id)
        #expect(row["kind"] as? String == "send")
        #expect(row["method"] as? String == "terminal.send")
        #expect(row["message"] as? String == "please rebase onto main")
        #expect(row["submit"] as? Bool == true)
        let actor = try #require(row["actor"] as? [String: Any])
        #expect(Set(actor.keys) == ["kind"])
        #expect(actor["kind"] as? String == "app")
        let target = try #require(row["target"] as? [String: Any])
        #expect(Set(target.keys) == ["terminal", "worktree"])
        // ISO8601 UTC with millisecond precision — a log needs sub-second ordering.
        let ts = try #require(row["ts"] as? String)
        #expect(ts.hasSuffix("Z"))
        #expect(ts.contains("."))
        #expect(ts.count == "2026-08-05T14:02:11.482Z".count)
    }

    @Test("an outcome row confirms its request and is written by the daemon")
    func outcomeRowShape() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)

        let requestID = try await log.appendRequest(sendRow())
        await log.appendOutcome(confirms: requestID, result: .dispatched)

        let written = try rows(at: path)
        #expect(written.count == 2)
        let outcome = try #require(written.last)
        #expect(Set(outcome.keys) == ["actor", "confirms", "id", "kind", "result", "ts"])
        #expect(outcome["kind"] as? String == "outcome")
        #expect(outcome["confirms"] as? String == requestID)
        #expect(outcome["result"] as? String == "dispatched")
        #expect(outcome["id"] as? String != requestID)
        let actor = try #require(outcome["actor"] as? [String: Any])
        #expect(actor["kind"] as? String == "daemon")
    }

    @Test("a failed outcome carries its result and the error text")
    func outcomeCarriesFailureDetail() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)

        let requestID = try await log.appendRequest(sendRow())
        await log.appendOutcome(confirms: requestID, result: .transportFailed, error: "tmux exited 1")

        let outcome = try #require(try rows(at: path).last)
        #expect(outcome["result"] as? String == "transport-failed")
        #expect(outcome["error"] as? String == "tmux exited 1")
    }

    @Test("no row ever claims the message landed")
    func neverClaimsLanded() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)
        let requestID = try await log.appendRequest(sendRow())
        for result in [ActuationOutcome.dispatched, .refused(.noop), .transportFailed] {
            await log.appendOutcome(confirms: requestID, result: result)
        }
        let results = try rows(at: path).compactMap { $0["result"] as? String }
        #expect(Set(results) == ["dispatched", "refused", "transport-failed"])
    }

    // MARK: - Why a refusal refused

    @Test("a refused outcome names a closed reason beside the human-facing detail")
    func refusedOutcomeCarriesItsReason() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)

        let requestID = try await log.appendRequest(sendRow())
        await log.appendOutcome(
            confirms: requestID, result: .refused(.notEligible), error: "Not hibernatable")

        let outcome = try #require(try rows(at: path).last)
        // Whitelist: exactly the keys a refused outcome is allowed to carry.
        #expect(Set(outcome.keys)
            == ["actor", "confirms", "error", "id", "kind", "reason", "result", "ts"])
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "not-eligible")
        // The detail stays exactly as the daemon phrased it for a human.
        #expect(outcome["error"] as? String == "Not hibernatable")
    }

    @Test("only refusals carry a reason — a dispatch and a transport failure carry none")
    func onlyRefusalsCarryAReason() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)

        let requestID = try await log.appendRequest(sendRow())
        await log.appendOutcome(confirms: requestID, result: .dispatched)
        await log.appendOutcome(confirms: requestID, result: .transportFailed, error: "tmux exited 1")
        await log.appendOutcome(confirms: requestID, result: .refused(.inFlight))

        let outcomes = try rows(at: path).filter { $0["kind"] as? String == "outcome" }
        #expect(outcomes.count == 3)
        let reasoned = outcomes.filter { $0["reason"] != nil }
        #expect(reasoned.count == 1)
        #expect(reasoned.first?["result"] as? String == "refused")
        #expect(reasoned.first?["reason"] as? String == "in-flight")
    }

    @Test("the refusal vocabulary is closed, and every name is query-shaped")
    func refusedReasonVocabulary() {
        #expect(Set(RefusedReason.allCases.map(\.rawValue))
            == ["noop", "not-found", "not-eligible", "in-flight", "target-mismatch"])
    }

    @Test("park and wake results classify onto the vocabulary, no-ops apart from declines")
    func parkAndWakeClassification() {
        #expect(ActuationOutcome.classify(HibernateResult.ok) == .dispatched)
        #expect(ActuationOutcome.classify(HibernateResult.alreadyHibernated) == .refused(.noop))
        #expect(ActuationOutcome.classify(HibernateResult.notEligible(reason: "running"))
            == .refused(.notEligible))
        #expect(ActuationOutcome.classify(HibernateResult.notFound) == .refused(.notFound))

        #expect(ActuationOutcome.classify(WakeResult.ok) == .dispatched)
        #expect(ActuationOutcome.classify(WakeResult.respawnFailed(reason: "tmux")) == .transportFailed)
        #expect(ActuationOutcome.classify(WakeResult.notHibernated) == .refused(.noop))
        #expect(ActuationOutcome.classify(WakeResult.inFlight) == .refused(.inFlight))
        #expect(ActuationOutcome.classify(WakeResult.notFound) == .refused(.notFound))
        #expect(ActuationOutcome.classify(WakeResult.worktreeMissing(path: "/tmp/acme"))
            == .refused(.notFound))
        #expect(ActuationOutcome.classify(WakeResult.noSessionID) == .refused(.notEligible))
        #expect(ActuationOutcome.classify(WakeResult.profileMissing(profileID: UUID()))
            == .refused(.notEligible))
    }

    // MARK: - Rotation

    @Test("the first append of a new UTC day moves the previous segment aside")
    func rotatesAcrossMidnight() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let dates = TestDateSource(try date("2026-08-05T23:59:59Z"))
        let log = ActuationLog(path: path, now: dates.provider)

        _ = try await log.appendRequest(sendRow(message: "before midnight"))
        dates.now = try date("2026-08-06T00:00:01Z")
        _ = try await log.appendRequest(sendRow(message: "after midnight"))

        // The active file holds only the new day's row…
        let active = try rows(at: path)
        #expect(active.count == 1)
        #expect(active.first?["message"] as? String == "after midnight")

        // …and the segment is stamped with the UTC date of its LAST row.
        let segment = directory.appendingPathComponent("actuations-2026-08-05.jsonl").path
        let rotated = try rows(at: segment)
        #expect(rotated.count == 1)
        #expect(rotated.first?["message"] as? String == "before midnight")

        // No header, footer, or marker row is ever written.
        #expect(rotated.allSatisfy { $0["kind"] as? String == "send" })
    }

    @Test("appends within one UTC day never rotate")
    func doesNotRotateWithinADay() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let dates = TestDateSource(try date("2026-08-05T00:00:01Z"))
        let log = ActuationLog(path: path, now: dates.provider)

        _ = try await log.appendRequest(sendRow(message: "early"))
        dates.now = try date("2026-08-05T23:59:58Z")
        _ = try await log.appendRequest(sendRow(message: "late"))

        #expect(try rows(at: path).count == 2)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(siblings == ["actuations.jsonl"])
    }

    @Test("a fresh writer learns the segment's day from the rows already on disk")
    func segmentDayReadBackFromExistingFile() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let firstDay = try date("2026-08-05T12:00:00Z")
        let first = ActuationLog(path: path, now: { firstDay })
        _ = try await first.appendRequest(sendRow(message: "yesterday"))

        // A daemon restart: a brand-new writer over the same file, next day.
        let secondDay = try date("2026-08-06T09:00:00Z")
        let second = ActuationLog(path: path, now: { secondDay })
        _ = try await second.appendRequest(sendRow(message: "today"))

        #expect(try rows(at: path).count == 1)
        let rotated = try rows(
            at: directory.appendingPathComponent("actuations-2026-08-05.jsonl").path)
        #expect(rotated.first?["message"] as? String == "yesterday")
    }

    @Test("a name collision takes a numeric suffix rather than concatenating")
    func rotationCollisionTakesNumericSuffix() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let collision = directory.appendingPathComponent("actuations-2026-08-05.jsonl")
        try Data("{}\n".utf8).write(to: collision)

        let dates = TestDateSource(try date("2026-08-05T10:00:00Z"))
        let log = ActuationLog(path: path, now: dates.provider)
        _ = try await log.appendRequest(sendRow(message: "day one"))
        dates.now = try date("2026-08-06T10:00:00Z")
        _ = try await log.appendRequest(sendRow(message: "day two"))

        // The pre-existing segment is untouched…
        #expect(try String(contentsOf: collision, encoding: .utf8) == "{}\n")
        // …and the new one landed beside it under a suffixed name.
        let suffixed = try rows(
            at: directory.appendingPathComponent("actuations-2026-08-05-1.jsonl").path)
        #expect(suffixed.first?["message"] as? String == "day one")
    }

    // MARK: - Fail-closed

    @Test("an unwritable log throws a self-explaining error naming the path and the recovery")
    func unwritablePathThrowsSelfExplainingError() async throws {
        let directory = try Self.makeDirectory()
        // A path whose parent is a FILE: neither the mkdir nor the open can work.
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let path = blocker.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)

        await #expect(throws: ActuationLogUnwritable.self) {
            _ = try await log.appendRequest(sendRow())
        }

        do {
            _ = try await log.appendRequest(sendRow())
            Issue.record("expected the append to refuse")
        } catch let failure as ActuationLogUnwritable {
            #expect(failure.path == path)
            // Self-explaining: the full path, and what to do about it.
            #expect(failure.description.contains(path))
            #expect(failure.description.contains("actuation log"))
            #expect(failure.description.contains("refused"))
            #expect(failure.description.contains("TBD will recreate it"))
            // The RPC router surfaces errors with "\(error)" — the message has
            // to survive that, not just `localizedDescription`.
            #expect("\(failure)" == failure.description)
        }
    }

    @Test("an outcome append never throws, even when the log is unwritable")
    func outcomeAppendNeverFailsClosed() async throws {
        let directory = try Self.makeDirectory()
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let log = ActuationLog(path: blocker.appendingPathComponent("actuations.jsonl").path)

        // The act already ran; refusing retroactively is impossible.
        await log.appendOutcome(confirms: "k7m2q9w4x1p8", result: .dispatched)
    }

    @Test("a file removed between appends is noticed and recreated by the reopen-retry")
    func reopenRetryRecoversAfterFileRemoval() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)

        _ = try await log.appendRequest(sendRow(message: "first"))
        // Someone moved the whole directory aside. The still-open descriptor
        // would happily accept writes into the unlinked inode — the retry has
        // to notice and recreate the file at the path instead.
        try FileManager.default.removeItem(at: directory)

        _ = try await log.appendRequest(sendRow(message: "second"))

        let written = try rows(at: path)
        #expect(written.count == 1)
        #expect(written.first?["message"] as? String == "second")
    }

    @Test("a file replaced by a different file between appends is followed, not written past")
    func replacedFileIsFollowed() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)

        _ = try await log.appendRequest(sendRow(message: "first"))
        // An external rotation: the segment is moved aside and a fresh file
        // takes its place at the same path.
        try FileManager.default.moveItem(
            atPath: path, toPath: directory.appendingPathComponent("archived.jsonl").path)
        FileManager.default.createFile(atPath: path, contents: Data())

        _ = try await log.appendRequest(sendRow(message: "second"))

        #expect(try rows(at: path).map { $0["message"] as? String } == ["second"])
        let archived = try rows(at: directory.appendingPathComponent("archived.jsonl").path)
        #expect(archived.map { $0["message"] as? String } == ["first"])
    }
}
