import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — real filesystem for the writer's half, pure in-process for the
/// vocabulary's and the envelope label's. No clocks, no subprocesses.
///
/// Every test injects its own log path into `ActuationLog(path:)` rather than
/// touching `TBD_HOME`, matching `ActuationLogTests`.
@Suite("Observed outcomes and the recorded-result vocabulary")
struct ActuationObservationTests {

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
        row.verify = true
        return row
    }

    private func roundTrip(_ row: ActuationRow) throws -> ActuationRow {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try JSONDecoder().decode(ActuationRow.self, from: encoder.encode(row))
    }

    // MARK: - The two vocabularies through one wire field

    @Test("the observed vocabulary is closed, and every name is query-shaped")
    func observedResultVocabulary() {
        #expect(Set(ObservedResult.allCases.map(\.rawValue)) == [
            "landed-and-acting", "landed-but-still-blocked", "not-landed", "undetermined",
        ])
    }

    @Test("both vocabularies code as the one `result` string and decode back to their own case")
    func recordedResultRoundTripsThroughASingleString() throws {
        let synchronous: [ActuationResult] = [.dispatched, .refused, .transportFailed]
        for result in synchronous {
            var row = ActuationRow(actor: .daemon(), kind: .outcome)
            row.result = .synchronous(result)
            let encoded = try JSONEncoder().encode(row)
            let object = try #require(
                try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            // One field, one plain string — no discriminator, no nesting.
            #expect(object["result"] as? String == result.rawValue)
            #expect(try roundTrip(row).result == .synchronous(result))
        }

        for result in ObservedResult.allCases {
            var row = ActuationRow(actor: .daemon(), kind: .outcome)
            row.result = .observed(result)
            let encoded = try JSONEncoder().encode(row)
            let object = try #require(
                try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(object["result"] as? String == result.rawValue)
            #expect(try roundTrip(row).result == .observed(result))
        }
    }

    @Test("a name neither vocabulary knows is carried through verbatim, not rejected")
    func unrecognizedResultPreservesItsRawValue() throws {
        // The row a newer daemon might write, met by today's reader.
        let line = #"{"actor":{"kind":"daemon"},"id":"a1","kind":"outcome","result":"landed-and-hibernating","ts":"2026-08-05T14:02:11.482Z"}"#

        let row = try JSONDecoder().decode(ActuationRow.self, from: Data(line.utf8))
        #expect(row.result == .unrecognized("landed-and-hibernating"))
        // And it must not have been mistaken for an observation.
        #expect(row.result?.observed == nil)
        // Re-encoding says exactly what the file said.
        #expect(try roundTrip(row).result == .unrecognized("landed-and-hibernating"))
    }

    @Test("a row written before the observed rung existed still decodes")
    func legacyOutcomeRowStillDecodes() throws {
        let line = #"{"actor":{"kind":"daemon"},"confirms":"a1","id":"a2","kind":"outcome","reason":"not-eligible","result":"refused","ts":"2026-08-05T14:02:11.482Z"}"#

        let row = try JSONDecoder().decode(ActuationRow.self, from: Data(line.utf8))
        #expect(row.result == .synchronous(.refused))
        #expect(row.reason == .notEligible)
        #expect(row.observedAt == nil)
        #expect(row.verify == nil)
    }

    // MARK: - The second door

    @Test("an observation row carries the observed result and when the facts were read")
    func observationRowShape() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let stamped = try date("2026-08-05T14:02:11Z").addingTimeInterval(0.482)
        let log = ActuationLog(path: path, now: { stamped })

        let requestID = try await log.appendRequest(sendRow())
        await log.appendObservation(
            confirms: requestID,
            result: .landedAndActing,
            observedAt: try date("2026-08-05T14:02:09Z"))

        let written = try rows(at: path)
        #expect(written.count == 2)
        let observation = try #require(written.last)
        // Whitelist: exactly the keys an observation row is allowed to carry.
        #expect(Set(observation.keys)
            == ["actor", "confirms", "id", "kind", "observedAt", "result", "ts"])
        #expect(observation["kind"] as? String == "outcome")
        #expect(observation["confirms"] as? String == requestID)
        #expect(observation["result"] as? String == "landed-and-acting")
        #expect(observation["observedAt"] as? String == "2026-08-05T14:02:09.000Z")
        // `observedAt` is when the facts were read; `ts` is when the row was
        // written, and the two are deliberately not the same moment.
        #expect(observation["ts"] as? String == "2026-08-05T14:02:11.482Z")
        let actor = try #require(observation["actor"] as? [String: Any])
        #expect(actor["kind"] as? String == "daemon")
    }

    @Test("an undetermined observation names what could not be established")
    func observationCarriesItsDetail() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)

        let requestID = try await log.appendRequest(sendRow())
        await log.appendObservation(
            confirms: requestID,
            result: .undetermined,
            observedAt: try date("2026-08-05T14:02:09Z"),
            detail: "no transcript path recorded for this terminal")

        let observation = try #require(try rows(at: path).last)
        #expect(observation["result"] as? String == "undetermined")
        #expect(observation["error"] as? String == "no transcript path recorded for this terminal")
    }

    @Test("the request row records that the caller armed verification")
    func requestRowCarriesVerify() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)

        _ = try await log.appendRequest(sendRow())
        var unverified = sendRow()
        unverified.verify = nil
        _ = try await log.appendRequest(unverified)

        let written = try rows(at: path)
        #expect(written.first?["verify"] as? Bool == true)
        // Absent, not `false`: a send that never asked for confirmation is owed
        // no observation, and the record says so by saying nothing.
        #expect(written.last?["verify"] == nil)
    }

    @Test("one request row legitimately carries the whole claims ladder")
    func oneRequestCarriesSeveralOutcomes() async throws {
        let directory = try Self.makeDirectory()
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let log = ActuationLog(path: path)

        // dispatched → not-landed → dispatched (the single retry, same envelope
        // id, no second request row) → landed-and-acting.
        let requestID = try await log.appendRequest(sendRow())
        await log.appendOutcome(confirms: requestID, result: .dispatched)
        await log.appendObservation(
            confirms: requestID, result: .notLanded,
            observedAt: try date("2026-08-05T14:03:09Z"))
        await log.appendOutcome(confirms: requestID, result: .dispatched)
        await log.appendObservation(
            confirms: requestID, result: .landedAndActing,
            observedAt: try date("2026-08-05T14:04:09Z"))

        let record = ActuationRecordReader(activePath: path).readRows()
        #expect(record.count == 5)
        // Exactly one request row, and every outcome joins onto it.
        let requests = record.filter { $0.kind != .outcome }
        #expect(requests.count == 1)
        let outcomes = record.filter { $0.kind == .outcome }
        #expect(outcomes.count == 4)
        #expect(outcomes.allSatisfy { $0.confirms == requestID })
        #expect(outcomes.map { $0.result } == [
            .synchronous(.dispatched),
            .observed(.notLanded),
            .synchronous(.dispatched),
            .observed(.landedAndActing),
        ])
        // Only the observed rows say when they looked.
        #expect(outcomes.compactMap { $0.observedAt }.count == 2)
    }

    // MARK: - The envelope's `from`

    @Test("each actor kind names itself, qualified only where it has a sub-identity")
    func dispatchLabelPerKind() {
        #expect(ActuationActor.anonymous.dispatchLabel == "anonymous")
        #expect(ActuationActor.app.dispatchLabel == "app")
        #expect(ActuationActor.daemon().dispatchLabel == "daemon")
        #expect(ActuationActor.daemon(rail: "limit-resume").dispatchLabel == "daemon:limit-resume")
        // A session says plainly `session`: the row already carries its UUIDs,
        // and the envelope is attribution a human reads, not a join key.
        let session = ActuationActor.session(
            worktree: "1B7E2C90-88AA-4F60-B1D0-9E8F7A6B5C4D", terminal: nil)
        #expect(session?.dispatchLabel == "session")
        #expect(ActuationActor(kind: ActuationActor.Kind.supervisor).dispatchLabel == "supervisor")
        #expect(ActuationActor(kind: ActuationActor.Kind.supervisor, project: "acme-web")
            .dispatchLabel == "supervisor:acme-web")
        // A rail on a non-daemon actor is not that kind's sub-identity.
        #expect(ActuationActor(kind: ActuationActor.Kind.app, rail: "limit-resume")
            .dispatchLabel == "app")
    }

    @Test("a label can neither close the envelope tag nor open a second attribute")
    func dispatchLabelCannotEscapeTheEnvelope() {
        let hostile = ActuationActor.daemon(rail: #"x" onload="evil"/><tbd-dispatch id="b"#)
        let label = hostile.dispatchLabel

        // Whitelist, not blacklist: the label is spelled in this alphabet and
        // nothing else, so the characters nobody thought of are excluded too.
        let allowed = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        #expect(label.allSatisfy { allowed.contains($0) })
        #expect(label == #"daemon:x__onload__evil____tbd-dispatch_id__b"#)

        // Composed into the envelope the dispatch path writes, the tag still
        // has exactly one attribute pair beyond the id.
        let envelope = #"<tbd-dispatch id="a3f1b2c3d4e5" from="\#(label)"/>"#
        #expect(envelope.filter { $0 == "\"" }.count == 4)
        #expect(envelope.filter { $0 == "<" }.count == 1)
        #expect(envelope.filter { $0 == ">" }.count == 1)
    }

    @Test("a non-ASCII or whitespace label is replaced, never passed through")
    func dispatchLabelReplacesEverythingOutsideTheAlphabet() {
        #expect(ActuationActor.daemon(rail: "night watch").dispatchLabel == "daemon:night_watch")
        #expect(ActuationActor.daemon(rail: "rail\nid").dispatchLabel == "daemon:rail_id")
        #expect(ActuationActor.daemon(rail: "réveil").dispatchLabel == "daemon:r_veil")
        // Sanitizing to nothing is not possible, but supplying nothing is:
        // an empty qualifier leaves the bare kind rather than a dangling colon.
        #expect(ActuationActor.daemon(rail: "").dispatchLabel == "daemon")
        #expect(ActuationActor(kind: "").dispatchLabel == "unknown")
    }

    @Test("a runaway qualifier is capped rather than shoved onto the reader's first screen")
    func dispatchLabelIsCapped() {
        let label = ActuationActor.daemon(rail: String(repeating: "r", count: 500)).dispatchLabel
        #expect(label.count == ActuationActor.dispatchLabelLimit)
        #expect(label.hasPrefix("daemon:rrr"))
    }
}
