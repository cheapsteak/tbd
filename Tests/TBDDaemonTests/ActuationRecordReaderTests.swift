import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — real filesystem, no clocks, no subprocesses.
///
/// Every test injects its own log path rather than touching `TBD_HOME`, matching
/// `ActuationLogTests`.
@Suite("Actuation record reader")
struct ActuationRecordReaderTests {

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: iso))
    }

    private func sendRow(message: String) -> ActuationRow {
        var row = ActuationRow(actor: .app, kind: .send)
        row.method = ActuationSurface.terminalSend.method
        row.message = message
        row.submit = true
        return row
    }

    @Test("the record reads back as rows, request and outcome alike")
    func readsWhatTheWriterWrote() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)

        let requestID = try await log.appendRequest(sendRow(message: "please rebase onto main"))
        await log.appendOutcome(confirms: requestID, result: .dispatched)

        let rows = ActuationRecordReader(activePath: path).readRows()
        #expect(rows.count == 2)
        #expect(rows.first?.id == requestID)
        #expect(rows.first?.message == "please rebase onto main")
        #expect(rows.last?.confirms == requestID)
        #expect(rows.last?.result == .synchronous(.dispatched))
    }

    @Test("a crash-left fragment costs its own line and nothing else")
    func skipsUnparseableLinesWithoutBlindingTheReplay() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)

        _ = try await log.appendRequest(sendRow(message: "first"))
        // The two shapes a torn write leaves behind: a truncated JSON object,
        // and bytes that are not valid JSON at all.
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"actor":{"kind":"app"},"kind":"se"# .utf8))
        try handle.write(contentsOf: Data("\nnot json at all\n".utf8))
        try handle.close()
        _ = try await log.appendRequest(sendRow(message: "second"))

        let rows = ActuationRecordReader(activePath: path).readRows()
        #expect(rows.count == 2)
        #expect(rows.map { $0.message } == ["first", "second"])
    }

    @Test("rotated segments concatenate in name order, then the active file")
    func concatenatesRotatedSegmentsInOrder() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let dates = TestDateSource(try date("2026-08-04T12:00:00Z"))
        let log = ActuationLog(path: path, now: dates.provider)

        _ = try await log.appendRequest(sendRow(message: "day one"))
        dates.now = try date("2026-08-05T12:00:00Z")
        _ = try await log.appendRequest(sendRow(message: "day two"))
        dates.now = try date("2026-08-06T12:00:00Z")
        _ = try await log.appendRequest(sendRow(message: "day three"))

        let reader = ActuationRecordReader(activePath: path)
        #expect(reader.segmentPaths().map { ($0 as NSString).lastPathComponent } == [
            "actuations-2026-08-04.jsonl", "actuations-2026-08-05.jsonl", "actuations.jsonl",
        ])
        #expect(reader.readRows().map { $0.message } == ["day one", "day two", "day three"])
    }

    @Test("a record with nothing in it yet reads as no rows, not as a failure")
    func absentRecordReadsEmpty() {
        let reader = ActuationRecordReader(
            activePath: "/nonexistent-\(UUID().uuidString)/actuations.jsonl")
        #expect(reader.segmentPaths().isEmpty)
        #expect(reader.readRows().isEmpty)
    }

    @Test("reader and query-time rule compose over a record written by the daemon")
    func readsAndAssessesARealRecord() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let stamped = try date("2026-08-05T14:00:00Z")
        let log = ActuationLog(path: path, now: { stamped })

        var armed = sendRow(message: "please rebase onto main")
        armed.verify = true
        let armedID = try await log.appendRequest(armed)
        // Dispatched and nothing more: the exact shape that must still read as
        // unconfirmed once the acknowledgement window closes.
        await log.appendOutcome(confirms: armedID, result: .dispatched)
        _ = try await log.appendRequest(sendRow(message: "no verification asked for"))

        let rows = ActuationRecordReader(activePath: path).readRows()
        let statuses = DeliveryRecord.statuses(in: rows, now: try date("2026-08-05T14:05:00Z"))
        #expect(statuses.count == 1)
        #expect(statuses.first?.request.id == armedID)
        #expect(statuses.first?.status == .unconfirmed)
    }
}

/// Tier 1 — pure function over parsed rows. No daemon, no filesystem, no clock.
///
/// This is the point of §12's query-time rule being a query: the whole delivery
/// vocabulary is decidable from the record plus a `now`.
@Suite("Query-time delivery status")
struct DeliveryRecordTests {

    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: iso))
    }

    private func request(
        id: String,
        ts: String = "2026-08-05T14:00:00Z",
        verify: Bool? = true
    ) -> ActuationRow {
        var row = ActuationRow(actor: .app, kind: .send)
        row.id = id
        row.ts = ts
        row.method = ActuationSurface.terminalSend.method
        row.message = "please rebase onto main"
        row.submit = true
        row.verify = verify
        return row
    }

    private func outcome(id: String, confirms: String, result: RecordedResult) -> ActuationRow {
        var row = ActuationRow(actor: .daemon(), kind: .outcome)
        row.id = id
        row.ts = "2026-08-05T14:00:01Z"
        row.confirms = confirms
        row.result = result
        return row
    }

    @Test("the deadline is the one §13 compiles")
    func acknowledgementDeadlineIsSixtySeconds() {
        #expect(DeliveryRecord.acknowledgementDeadline == 60)
    }

    @Test("an armed act past its deadline with no observation renders unconfirmed")
    func unconfirmedPastTheDeadline() throws {
        let rows = [request(id: "a1")]
        let statuses = DeliveryRecord.statuses(
            in: rows, now: try date("2026-08-05T14:01:01Z"))
        #expect(statuses.map { $0.status } == [.unconfirmed])
        #expect(statuses.first?.request.id == "a1")
    }

    @Test("inside the acknowledgement window nothing is owed yet")
    func awaitingObservationInsideTheWindow() throws {
        let statuses = DeliveryRecord.statuses(
            in: [request(id: "a1")], now: try date("2026-08-05T14:00:59Z"))
        #expect(statuses.map { $0.status } == [.awaitingObservation])
    }

    @Test("an observed outcome answers the question, whatever it found")
    func observedOutcomeSettlesTheAct() throws {
        let now = try date("2026-08-05T14:10:00Z")
        for result in ObservedResult.allCases {
            let rows = [
                request(id: "a1"),
                outcome(id: "a2", confirms: "a1", result: .observed(result)),
            ]
            #expect(DeliveryRecord.statuses(in: rows, now: now).map { $0.status }
                == [.observed(result)])
        }
    }

    @Test("a merely-dispatched act still renders unconfirmed past its deadline")
    func synchronousDispatchDoesNotConfirmDelivery() throws {
        // The load-bearing case. `dispatched` is the second rung of the ladder:
        // the transport accepted the payload. That is exactly the claim
        // `terminal.send` once made truthfully-looking for hours into a dead
        // pane, so it must not be allowed to answer the delivery question.
        let rows = [
            request(id: "a1"),
            outcome(id: "a2", confirms: "a1", result: .synchronous(.dispatched)),
        ]
        let statuses = DeliveryRecord.statuses(
            in: rows, now: try date("2026-08-05T14:01:01Z"))
        #expect(statuses.map { $0.status } == [.unconfirmed])
    }

    @Test("no synchronous result confirms delivery, and neither does an unknown name")
    func onlyObservedResultsConfirm() throws {
        let now = try date("2026-08-05T14:10:00Z")
        let nonAnswers: [RecordedResult] = [
            .synchronous(.dispatched),
            .unrecognized("landed-and-hibernating"),
        ]
        for result in nonAnswers {
            let rows = [request(id: "a1"), outcome(id: "a2", confirms: "a1", result: result)]
            #expect(DeliveryRecord.statuses(in: rows, now: now).map { $0.status } == [.unconfirmed])
        }
    }

    /// An act the transport never accepted is settled by that answer alone.
    ///
    /// `verify == true` on the request row says the caller *asked* for an
    /// observation — the row is written before the flag check and before the
    /// pane consultation, so a refused send carries the flag too. Nothing was
    /// typed, so nothing can have landed and no observation is owed. Rendering
    /// it `unconfirmed` would put it on the startup replay's work list, and the
    /// replay would write a landing verdict about a payload that never reached
    /// a pane.
    @Test("a send the transport never accepted is owed no observation")
    func refusedSendsAreSettledNotUnconfirmed() throws {
        let now = try date("2026-08-05T14:10:00Z")
        for result in [RecordedResult.synchronous(.refused), .synchronous(.transportFailed)] {
            let rows = [request(id: "a1"), outcome(id: "a2", confirms: "a1", result: result)]
            #expect(DeliveryRecord.statuses(in: rows, now: now).isEmpty)
        }
    }

    /// A dispatch anywhere in an act's outcomes outranks a later refusal — that
    /// can only be the single retry failing after a real first delivery, and
    /// the act genuinely did reach a pane once.
    @Test("a failed retry after a real dispatch leaves the act still owed an observation")
    func dispatchOutranksALaterRefusal() throws {
        let rows = [
            request(id: "a1"),
            outcome(id: "a2", confirms: "a1", result: .synchronous(.dispatched)),
            outcome(id: "a3", confirms: "a1", result: .synchronous(.refused)),
        ]
        let statuses = DeliveryRecord.statuses(
            in: rows, now: try date("2026-08-05T14:10:00Z"))
        #expect(statuses.map { $0.status } == [.unconfirmed])
    }

    /// A restart between the retry's dispatch and its own re-check.
    ///
    /// The retry shares the original act's id, so the ladder is
    /// `dispatched → not-landed → dispatched`, all on one id, with the second
    /// observation never written. Reading "the newest observed row" alone would
    /// leave the stale `not-landed` standing as the act's final word — settled,
    /// so the startup replay skips it and the retry is never observed at all. A
    /// delivery after the last observation is a delivery still owed one.
    @Test("a retry dispatched after the last observation is still owed one")
    func aDeliveryAfterTheLastObservationIsStillOwed() throws {
        let rows = [
            request(id: "a1"),
            outcome(id: "a2", confirms: "a1", result: .synchronous(.dispatched)),
            outcome(id: "a3", confirms: "a1", result: .observed(.notLanded)),
            outcome(id: "a4", confirms: "a1", result: .synchronous(.dispatched)),
        ]
        let statuses = DeliveryRecord.statuses(
            in: rows, now: try date("2026-08-05T14:10:00Z"))
        #expect(statuses.map { $0.status } == [.unconfirmed])
    }

    /// The same ladder, completed: the retry's own observation lands, and the
    /// act is settled by it rather than by the stale first one.
    @Test("a completed retry ladder settles on the final observation")
    func aCompletedRetryLadderSettlesOnTheFinalObservation() throws {
        let rows = [
            request(id: "a1"),
            outcome(id: "a2", confirms: "a1", result: .synchronous(.dispatched)),
            outcome(id: "a3", confirms: "a1", result: .observed(.notLanded)),
            outcome(id: "a4", confirms: "a1", result: .synchronous(.dispatched)),
            outcome(id: "a5", confirms: "a1", result: .observed(.landedAndActing)),
        ]
        let statuses = DeliveryRecord.statuses(
            in: rows, now: try date("2026-08-05T14:10:00Z"))
        #expect(statuses.map { $0.status } == [.observed(.landedAndActing)])
    }

    @Test("an act that never armed verification is owed no observation at all")
    func unverifiedActsAreNotAssessed() throws {
        let now = try date("2026-08-06T00:00:00Z")
        #expect(DeliveryRecord.statuses(in: [request(id: "a1", verify: nil)], now: now).isEmpty)
        #expect(DeliveryRecord.statuses(in: [request(id: "a1", verify: false)], now: now).isEmpty)
    }

    @Test("the ladder's last observation is the one that stands")
    func lastObservationWins() throws {
        let rows = [
            request(id: "a1"),
            outcome(id: "a2", confirms: "a1", result: .synchronous(.dispatched)),
            outcome(id: "a3", confirms: "a1", result: .observed(.notLanded)),
            outcome(id: "a4", confirms: "a1", result: .synchronous(.dispatched)),
            outcome(id: "a5", confirms: "a1", result: .observed(.landedAndActing)),
        ]
        let statuses = DeliveryRecord.statuses(
            in: rows, now: try date("2026-08-05T14:10:00Z"))
        #expect(statuses.map { $0.status } == [.observed(.landedAndActing)])
    }

    @Test("an outcome confirming a different act does not answer for this one")
    func outcomesJoinOnTheRequestID() throws {
        let rows = [
            request(id: "a1"),
            request(id: "b1"),
            outcome(id: "a2", confirms: "b1", result: .observed(.landedAndActing)),
        ]
        let statuses = DeliveryRecord.statuses(
            in: rows, now: try date("2026-08-05T14:01:01Z"))
        #expect(statuses.map { $0.request.id } == ["a1", "b1"])
        #expect(statuses.map { $0.status } == [.unconfirmed, .observed(.landedAndActing)])
    }

    @Test("a timestamp that cannot be read fails closed, never toward landed")
    func unreadableTimestampRendersUnconfirmed() throws {
        let statuses = DeliveryRecord.statuses(
            in: [request(id: "a1", ts: "not a timestamp")],
            now: try date("2026-08-05T14:00:00Z"))
        #expect(statuses.map { $0.status } == [.unconfirmed])
    }

    @Test("the deadline is measured from the row's own stamp, fractional seconds included")
    func deadlineIsMeasuredFromTheRowStamp() throws {
        let rows = [request(id: "a1", ts: "2026-08-05T14:00:00.500Z")]
        #expect(DeliveryRecord.statuses(in: rows, now: try date("2026-08-05T14:01:00Z"))
            .map { $0.status } == [.awaitingObservation])
        #expect(DeliveryRecord.statuses(in: rows, now: try date("2026-08-05T14:01:01Z"))
            .map { $0.status } == [.unconfirmed])
    }

}
