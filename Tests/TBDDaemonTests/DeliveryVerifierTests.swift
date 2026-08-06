import Clocks
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Fakes

/// The observation's two inputs, scripted one round at a time.
///
/// `facts` is called exactly once per observation and is what advances the
/// script, so round N's answer is deterministic no matter when the cycle's task
/// actually runs. It also counts every transcript read, which is how "a send
/// that never armed verification costs no transcript read" is proven rather
/// than asserted.
private final class ScriptedObservationSource: DeliveryObservationSource, @unchecked Sendable {
    struct Answer: Sendable {
        var transcriptPath: String? = "/tmp/transcript.jsonl"
        var activityState: TerminalActivityState = .idle
        /// `nil` stands for an unreadable transcript.
        var tail: Data? = Data()
        /// Which conversation currently occupies the terminal. A round whose
        /// value differs from the armed one stands for a `/clear` or an account
        /// swap between dispatch and re-check.
        var sessionID: String?

        static func envelope(
            for id: String, state: TerminalActivityState, escaped: Bool = false
        ) -> Answer {
            let tag = escaped
                ? "{\"content\":\"<tbd-dispatch id=\\\"\(id)\\\" from=\\\"anonymous\\\"/>\"}"
                : "<tbd-dispatch id=\"\(id)\" from=\"anonymous\"/>"
            return Answer(activityState: state, tail: Data(tag.utf8))
        }

        static func silence(state: TerminalActivityState) -> Answer {
            Answer(activityState: state, tail: Data("{\"type\":\"summary\"}\n".utf8))
        }
    }

    private let lock = NSLock()
    private var answers: [Answer?]
    private var round = 0
    private var _factsCalls = 0
    private var _tailReads = 0
    private var _requestedWindows: [Int] = []

    init(_ answers: [Answer?]) {
        self.answers = answers
    }

    /// Re-script the fake after construction. The envelope needle is composed
    /// from the act's id, and the log mints that id only once the harness
    /// exists — so a test that wants "the envelope IS there" has to say so
    /// after seeding.
    func scriptEnvelope(for id: String, state: TerminalActivityState) {
        lock.withLock {
            answers = [Answer.envelope(for: id, state: state)]
            round = 0
        }
    }

    var factsCalls: Int { lock.withLock { _factsCalls } }
    var tailReads: Int { lock.withLock { _tailReads } }
    var requestedWindows: [Int] { lock.withLock { _requestedWindows } }

    private func currentAnswer() -> Answer? {
        answers[min(round, answers.count - 1)]
    }

    func facts(forTerminal terminalID: UUID) async -> TerminalDeliveryFacts? {
        lock.withLock {
            _factsCalls += 1
            let answer = currentAnswer()
            round += 1
            return answer.map {
                TerminalDeliveryFacts(
                    transcriptPath: $0.transcriptPath, activityState: $0.activityState,
                    sessionID: $0.sessionID)
            }
        }
    }

    func transcriptTail(atPath path: String, maxBytes: Int) async -> Data? {
        lock.withLock {
            _tailReads += 1
            _requestedWindows.append(maxBytes)
            // `facts` already advanced past this round's answer.
            return answers[min(max(round - 1, 0), answers.count - 1)]?.tail
        }
    }
}

/// Counts re-deliveries and answers each with a scripted outcome. "No third
/// send, ever" is a count on this, not a claim about a log line.
private final class RedeliveryRecorder: @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let terminalID: UUID
        let payload: String
        let submit: Bool
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let outcome: ActuationOutcome

    init(answering outcome: ActuationOutcome = .dispatched) {
        self.outcome = outcome
    }

    var calls: [Call] { lock.withLock { _calls } }

    var seam: @Sendable (UUID, String, Bool) async -> ActuationOutcome {
        { [self] terminalID, payload, submit in
            lock.withLock {
                _calls.append(Call(terminalID: terminalID, payload: payload, submit: submit))
            }
            return outcome
        }
    }
}

// MARK: - Awaiting an armed cycle without hanging on it

/// One-shot, thread-safe "the cycle finished".
private final class CycleCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isDone: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}

private struct DeliveryCycleUnfinished: Error, CustomStringConvertible {
    let timeout: Swift.Duration
    let observed: String
    var description: String {
        "the armed re-check cycle had not finished after \(timeout) — it took a branch this "
            + "test never advanced the clock for, so it is parked on a virtual sleep nobody "
            + "will advance. Observed: \(observed)"
    }
}

/// Await every armed re-check, bounded by a real deadline.
///
/// `DeliveryVerifier.awaitPendingObservations()` waits on the cycle's task, and
/// a cycle that took a branch the test did not advance the clock for waits
/// **forever** — the virtual-time hang `Tests/CLAUDE.md` names, which
/// `.clockDriven` is documented not to catch reliably when the work sits in a
/// detached task. Racing it against a real deadline turns "this guard stopped
/// holding" from an infinite hang into a named failure that says what the cycle
/// did instead. Bounded polling with a deadline, per assertion-hygiene rule 3;
/// the diagnostic is a thrown `Error` so it reaches the CI summary, per rule 4.
///
/// On timeout the waiting task is left parked deliberately: nothing awaits it,
/// so the test fails and the run proceeds.
func awaitDeliveryCycle(
    _ verifier: DeliveryVerifier,
    timeout: Swift.Duration = .seconds(30),
    observed: @escaping @Sendable () -> String = { "nothing recorded" },
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let completion = CycleCompletion()
    Task.detached {
        await verifier.awaitPendingObservations()
        completion.set()
    }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if completion.isDone { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record(
        DeliveryCycleUnfinished(timeout: timeout, observed: observed()),
        sourceLocation: sourceLocation)
}

// MARK: - Suite

/// Tier 2 — a real (temp-directory) actuation log and a `TestClock`. No tmux,
/// no database, no network: the observation's two machine facts arrive through
/// an injected source, so §12's four-result mapping and the retry ladder are
/// exercised in-process. The mapping tests themselves touch nothing but the
/// fake (tier 1); the ladder tests write real rows so the join can be read back
/// the way any later reader will read it.
@Suite("delivery verification: the observation, the retry, and the replay", .clockDriven)
struct DeliveryVerifierTests {

    // MARK: - Fixture

    private struct Harness {
        let verifier: DeliveryVerifier
        let clock: TestClock<Duration>
        let source: ScriptedObservationSource
        let redeliveries: RedeliveryRecorder
        let logPath: String
        let observedAt: Date
    }

    /// 2023-11-14T22:13:20Z — the same fixed, obviously-synthetic instant
    /// `TestDateSource` defaults to.
    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeHarness(
        answers: [ScriptedObservationSource.Answer?],
        retryOutcome: ActuationOutcome = .dispatched,
        now: Date = DeliveryVerifierTests.fixedNow,
        logNow: Date? = nil
    ) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-delivery-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logPath = directory.appendingPathComponent("actuations.jsonl").path
        let stamp = logNow ?? now
        let log = ActuationLog(path: logPath, now: { stamp })
        let source = ScriptedObservationSource(answers)
        let redeliveries = RedeliveryRecorder(answering: retryOutcome)
        let clock = TestClock()
        return Harness(
            verifier: DeliveryVerifier(
                log: log, source: source, redeliver: redeliveries.seam,
                now: { now }, clock: clock),
            clock: clock, source: source, redeliveries: redeliveries,
            logPath: logPath, observedAt: now)
    }

    private func rows(at path: String) throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    private func results(at path: String) throws -> [String] {
        try rows(at: path).compactMap { $0["result"] as? String }
    }

    private static let terminal = UUID()

    // MARK: - The four results

    @Test("envelope found while the session is working — landed and acting")
    func landedAndActing() async throws {
        let harness = try makeHarness(answers: [.envelope(for: "a3f1b2c3d4e5", state: .working)])
        let observation = await harness.verifier.observe(
            actuationID: "a3f1b2c3d4e5", terminalID: Self.terminal)
        #expect(observation == DeliveryObservation(.landedAndActing))
    }

    @Test("envelope found while the session is blocked again — landed but still blocked")
    func landedButStillBlocked() async throws {
        for state in [TerminalActivityState.idle, .waitingForUser] {
            let harness = try makeHarness(answers: [.envelope(for: "a3f1b2c3d4e5", state: state)])
            let observation = await harness.verifier.observe(
                actuationID: "a3f1b2c3d4e5", terminalID: Self.terminal)
            #expect(observation.result == .landedButStillBlocked)
        }
    }

    /// The only positive evidence of non-delivery §12 accepts: readable
    /// transcript, absent envelope, and a session verifiably not mid-turn.
    @Test("envelope absent while the session is verifiably not mid-turn — not landed")
    func notLanded() async throws {
        for state in [TerminalActivityState.idle, .waitingForUser] {
            let harness = try makeHarness(answers: [.silence(state: state)])
            let observation = await harness.verifier.observe(
                actuationID: "a3f1b2c3d4e5", terminalID: Self.terminal)
            #expect(observation.result == .notLanded)
            #expect(observation.detail?.contains(state.rawValue) == true)
        }
    }

    /// Every way the observation can fail to establish anything. Each carries a
    /// detail, because an anomaly that does not say what was missing is not an
    /// anomaly anyone can act on.
    @Test("the five ways an observation establishes nothing — undetermined")
    func undetermined() async throws {
        let id = "a3f1b2c3d4e5"
        let cases: [(String, ScriptedObservationSource.Answer?)] = [
            ("terminal row gone", nil),
            ("no transcript path", .init(transcriptPath: nil, activityState: .idle)),
            ("transcript unreadable", .init(activityState: .idle, tail: nil)),
            ("session state unknown, envelope absent", .silence(state: .unknown)),
            ("session mid-turn, envelope absent", .silence(state: .working)),
            ("envelope found, session state unknown", .envelope(for: id, state: .unknown)),
        ]
        for (name, answer) in cases {
            let harness = try makeHarness(answers: [answer])
            let observation = await harness.verifier.observe(
                actuationID: id, terminalID: Self.terminal)
            #expect(observation.result == .undetermined, "\(name)")
            #expect(observation.detail?.isEmpty == false, "\(name)")
        }
    }

    /// A full parse of a long transcript on every re-check is the performance
    /// trap §3 forbids. Asserted as the literal window AND the constant, so a
    /// mutated constant cannot drag the assertion along with it.
    @Test("the observation reads a bounded tail window, never the whole file")
    func boundedTailRead() async throws {
        let harness = try makeHarness(answers: [.silence(state: .idle)])
        _ = await harness.verifier.observe(
            actuationID: "a3f1b2c3d4e5", terminalID: Self.terminal)
        #expect(harness.source.requestedWindows == [65_536])
        #expect(DeliveryVerifier.tailWindowBytes == 65_536)
    }

    // MARK: - The envelope search survives JSON escaping

    /// The transcript is JSONL, so the envelope's quotes are part of a JSON
    /// string value and reach the file as `\"`. Both spellings are composed
    /// from the id — asserted here as whole strings, so a needle that drifted
    /// from what the send path pastes goes red.
    @Test("both needles are composed from the row id, raw and JSON-escaped")
    func needlesAreComposedFromTheRowID() {
        #expect(DeliveryVerifier.needles(forActuationID: "a3f1b2c3d4e5") == [
            "tbd-dispatch id=\"a3f1b2c3d4e5\"",
            "tbd-dispatch id=\\\"a3f1b2c3d4e5\\\"",
        ])
        // The raw needle is a substring of exactly what `terminal.send` pastes.
        let envelope = RPCRouter.dispatchEnvelope(id: "a3f1b2c3d4e5", from: "anonymous")
        #expect(envelope.contains("tbd-dispatch id=\"a3f1b2c3d4e5\""))
    }

    /// A realistic transcript line: the envelope inside a JSON-encoded message
    /// body, escaped by the encoder rather than by hand — a hand-written
    /// fixture that got the escaping wrong would measure a fallback path and
    /// yield a real-looking wrong answer.
    @Test("the envelope is found in a realistic JSONL transcript, and joins on the row id")
    func envelopeFoundInRealisticJSONL() throws {
        let id = "a3f1b2c3d4e5"
        let envelope = RPCRouter.dispatchEnvelope(id: id, from: "supervisor:acme-web")
        struct Line: Encodable { let type: String; let content: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var jsonl = Data()
        jsonl.append(try encoder.encode(Line(type: "summary", content: "earlier turn")))
        jsonl.append(0x0A)
        jsonl.append(try encoder.encode(
            Line(type: "user", content: envelope + "\nrebase onto main")))
        jsonl.append(0x0A)

        // The encoder really did escape the quotes — the raw needle is absent
        // from the file, so this fixture can only be matched by the escaped one.
        let text = String(decoding: jsonl, as: UTF8.self)
        #expect(text.contains("tbd-dispatch id=\\\"\(id)\\\""))
        #expect(!text.contains("tbd-dispatch id=\"\(id)\""))

        #expect(DeliveryVerifier.envelopeAppears(actuationID: id, inTail: jsonl))
        // And it joins on THIS row id: a sibling act's envelope is not this one.
        #expect(!DeliveryVerifier.envelopeAppears(actuationID: "ffffffffffff", inTail: jsonl))
    }

    /// The raw spelling still has to match — a transcript that stores the
    /// message unescaped (or a tail read straddling a plain-text adapter) must
    /// not read as non-delivery.
    @Test("the envelope is found unescaped too")
    func envelopeFoundUnescaped() {
        let id = "a3f1b2c3d4e5"
        let raw = Data(RPCRouter.dispatchEnvelope(id: id, from: "anonymous").utf8)
        #expect(DeliveryVerifier.envelopeAppears(actuationID: id, inTail: raw))
    }

    // MARK: - The retry, and only one

    /// not-landed → one retry → not-landed → stop. The ladder is written to the
    /// record in order, every rung confirming the same request id, and the send
    /// count is a literal 1: there is no third send on any branch, ever.
    @Test("a not-landed observation retries exactly once, then writes the anomaly")
    func retryOnceThenAnomaly() async throws {
        let id = "a3f1b2c3d4e5"
        let harness = try makeHarness(answers: [
            .silence(state: .idle),
            .silence(state: .idle),
        ])
        await harness.verifier.armVerification(
            actuationID: id, terminalID: Self.terminal, sessionID: nil,
            deliveredPayload: "<tbd-dispatch id=\"\(id)\" from=\"anonymous\"/>\nstatus?",
            submit: true)
        await harness.clock.advanceWhenSuspended(by: .seconds(60))
        await harness.clock.advanceWhenSuspended(by: .seconds(60))
        await awaitDeliveryCycle(harness.verifier, observed: {
            "\((try? results(at: harness.logPath)) ?? []) rows, "
                + "\(harness.redeliveries.calls.count) re-deliveries"
        })

        #expect(try results(at: harness.logPath)
            == ["not-landed", "dispatched", "not-landed"])
        #expect(try rows(at: harness.logPath).allSatisfy { $0["confirms"] as? String == id })
        // Exactly one re-delivery — spelled as a literal, and re-delivering the
        // identical bytes under the identical envelope id.
        #expect(harness.redeliveries.calls.count == 1)
        #expect(harness.redeliveries.calls.first?.payload
            == "<tbd-dispatch id=\"\(id)\" from=\"anonymous\"/>\nstatus?")
        #expect(harness.redeliveries.calls.first?.terminalID == Self.terminal)
        #expect(harness.redeliveries.calls.first?.submit == true)
        // Two re-checks, and only two.
        #expect(harness.source.tailReads == 2)
        // The anomaly's durable half: the last observed row names what was missing.
        let last = try #require(try rows(at: harness.logPath).last)
        #expect((last["error"] as? String)?.isEmpty == false)
        #expect(last["observedAt"] as? String != nil)
    }

    @Test("a retry that lands is recorded as landed, and nothing further is sent")
    func retryThatLands() async throws {
        let id = "a3f1b2c3d4e5"
        let harness = try makeHarness(answers: [
            .silence(state: .idle),
            .envelope(for: id, state: .working),
        ])
        await harness.verifier.armVerification(
            actuationID: id, terminalID: Self.terminal, sessionID: nil, deliveredPayload: "x", submit: true)
        await harness.clock.advanceWhenSuspended(by: .seconds(60))
        await harness.clock.advanceWhenSuspended(by: .seconds(60))
        await awaitDeliveryCycle(harness.verifier, observed: {
            "\((try? results(at: harness.logPath)) ?? []) rows, "
                + "\(harness.redeliveries.calls.count) re-deliveries"
        })

        #expect(try results(at: harness.logPath)
            == ["not-landed", "dispatched", "landed-and-acting"])
        #expect(harness.redeliveries.calls.count == 1)
    }

    /// §12 argues this one directly: retrying into uncertainty risks
    /// double-instructing an agent that DID receive the first copy, and a
    /// message to an agent running with permissions bypassed is arbitrary
    /// instruction injection — so delivering it twice is not a neutral event.
    @Test("an undetermined observation is never retried, and never re-checked")
    func undeterminedNeverRetried() async throws {
        let harness = try makeHarness(answers: [.silence(state: .unknown)])
        await harness.verifier.armVerification(
            actuationID: "a3f1b2c3d4e5", terminalID: Self.terminal, sessionID: nil,
            deliveredPayload: "x", submit: true)
        await harness.clock.advanceWhenSuspended(by: .seconds(60))
        await awaitDeliveryCycle(harness.verifier, observed: {
            "\((try? results(at: harness.logPath)) ?? []) rows, "
                + "\(harness.redeliveries.calls.count) re-deliveries"
        })

        #expect(harness.redeliveries.calls.isEmpty)
        #expect(harness.redeliveries.calls.count == 0)
        #expect(try results(at: harness.logPath) == ["undetermined"])
        #expect(harness.source.tailReads == 1)
    }

    /// `/clear` between dispatch and re-check rebinds the terminal to a new,
    /// empty conversation without disturbing its pane — so the pane
    /// consultation, which compares pane ids, sees nothing wrong. Reading on
    /// would find no envelope in a transcript that never had one, call that
    /// `not-landed`, and retry the payload into an unrelated conversation:
    /// arbitrary instruction injection through the one door the pane check does
    /// not cover. The observation could not be made about the session that was
    /// addressed, which is exactly what `undetermined` means — and undetermined
    /// is never retried.
    @Test("a session rebound between dispatch and re-check is undetermined, and never retried")
    func rebindingTheSessionBlocksTheRetry() async throws {
        let id = "a3f1b2c3d4e5"
        // The transcript even *contains* a plausible absence — the point is that
        // the daemon refuses to reason from it at all.
        var rebound = ScriptedObservationSource.Answer.silence(state: .idle)
        rebound.sessionID = "session-after-clear"
        let harness = try makeHarness(answers: [rebound])
        await harness.verifier.armVerification(
            actuationID: id, terminalID: Self.terminal, sessionID: "session-at-dispatch",
            deliveredPayload: "<tbd-dispatch id=\"\(id)\" from=\"anonymous\"/>\nstatus?",
            submit: true)
        await harness.clock.advanceWhenSuspended(by: .seconds(60))
        await awaitDeliveryCycle(harness.verifier, observed: {
            "\((try? results(at: harness.logPath)) ?? []) rows, "
                + "\(harness.redeliveries.calls.count) re-deliveries"
        })

        #expect(try results(at: harness.logPath) == ["undetermined"])
        #expect(harness.redeliveries.calls.isEmpty)
        let row = try #require(try rows(at: harness.logPath).last)
        #expect((row["error"] as? String)?.contains("rebound") == true)
    }

    /// The same terminal, the same session: the guard must not fire on the
    /// ordinary case, or every verified send would degrade to undetermined.
    @Test("an unchanged session observes normally")
    func matchingSessionObservesNormally() async throws {
        let id = "a3f1b2c3d4e5"
        var answer = ScriptedObservationSource.Answer.envelope(for: id, state: .working)
        answer.sessionID = "session-at-dispatch"
        let harness = try makeHarness(answers: [answer])
        await harness.verifier.armVerification(
            actuationID: id, terminalID: Self.terminal, sessionID: "session-at-dispatch",
            deliveredPayload: "x", submit: true)
        await harness.clock.advanceWhenSuspended(by: .seconds(60))
        await awaitDeliveryCycle(harness.verifier, observed: {
            "\((try? results(at: harness.logPath)) ?? []) rows"
        })

        #expect(try results(at: harness.logPath) == ["landed-and-acting"])
        #expect(harness.redeliveries.calls.isEmpty)
    }

    /// A retry the daemon declined is not "the payload failed" — the record has
    /// to be able to say a stale coordinate was refused, and it confirms the
    /// ORIGINAL request id rather than opening a second one.
    @Test("a refused retry is recorded as refused, against the original request id")
    func refusedRetryIsClassified() async throws {
        let id = "a3f1b2c3d4e5"
        let harness = try makeHarness(
            answers: [.silence(state: .idle)], retryOutcome: .refused(.targetMismatch))
        await harness.verifier.armVerification(
            actuationID: id, terminalID: Self.terminal, sessionID: nil, deliveredPayload: "x", submit: true)
        await harness.clock.advanceWhenSuspended(by: .seconds(60))
        await awaitDeliveryCycle(harness.verifier, observed: {
            "\((try? results(at: harness.logPath)) ?? []) rows, "
                + "\(harness.redeliveries.calls.count) re-deliveries"
        })

        let written = try rows(at: harness.logPath)
        #expect(written.allSatisfy { $0["confirms"] as? String == id })
        // Two rows, and deliberately not a third. The refusal is a SYNCHRONOUS
        // fact about the re-delivery, and the `not-landed` observation before it
        // already stands on real evidence — so nothing here observed anything,
        // and an observation row would claim a look that never happened.
        #expect(try results(at: harness.logPath) == ["not-landed", "refused"])
        #expect(written.contains { $0["reason"] as? String == "target-mismatch" })
        // A retry that never reached the pane is not re-checked — and is not
        // sent a second time either.
        #expect(harness.redeliveries.calls.count == 1)
        #expect(harness.source.tailReads == 1)
    }

    @Test("a transport-failed retry is recorded as transport-failed")
    func transportFailedRetryIsClassified() async throws {
        let harness = try makeHarness(
            answers: [.silence(state: .idle)], retryOutcome: .transportFailed)
        await harness.verifier.armVerification(
            actuationID: "a3f1b2c3d4e5", terminalID: Self.terminal, sessionID: nil,
            deliveredPayload: "x", submit: true)
        await harness.clock.advanceWhenSuspended(by: .seconds(60))
        await awaitDeliveryCycle(harness.verifier, observed: {
            "\((try? results(at: harness.logPath)) ?? []) rows, "
                + "\(harness.redeliveries.calls.count) re-deliveries"
        })

        // As above: the transport failure is synchronous, so it closes the
        // cycle without a second observation row.
        #expect(try results(at: harness.logPath) == ["not-landed", "transport-failed"])
        #expect(harness.redeliveries.calls.count == 1)
        #expect(harness.source.tailReads == 1)
    }

    /// A retry that dispatched leaves no `error` on its outcome row.
    ///
    /// A row reading `dispatched` with a populated error field reads as a
    /// failure to anything querying the record. The `not-landed` observation
    /// sitting between the two dispatches is what says why there are two.
    @Test("a dispatched retry's outcome row carries no error text")
    func dispatchedRetryCarriesNoError() async throws {
        let id = "a3f1b2c3d4e5"
        let harness = try makeHarness(answers: [
            .silence(state: .idle),
            .envelope(for: id, state: .working),
        ])
        await harness.verifier.armVerification(
            actuationID: id, terminalID: Self.terminal, sessionID: nil, deliveredPayload: "x", submit: true)
        await harness.clock.advanceWhenSuspended(by: .seconds(60))
        await harness.clock.advanceWhenSuspended(by: .seconds(60))
        await awaitDeliveryCycle(harness.verifier, observed: {
            "\((try? results(at: harness.logPath)) ?? []) rows, "
                + "\(harness.redeliveries.calls.count) re-deliveries"
        })

        let written = try rows(at: harness.logPath)
        let dispatched = try #require(written.first { $0["result"] as? String == "dispatched" })
        #expect(dispatched["error"] == nil)
    }

    // MARK: - The startup replay

    /// A daemon that died mid-flight: the act renders `unconfirmed` by the
    /// query-time rule, and the replay performs the observation late — writing
    /// the outcome the timer would have written, and re-delivering nothing.
    @Test("a restart mid-flight renders unconfirmed, and the replay observes it late")
    func startupReplayObservesLate() async throws {
        let dispatchedAt = Self.fixedNow
        let bootedAt = dispatchedAt.addingTimeInterval(600)
        let harness = try makeHarness(
            answers: [.silence(state: .idle)], now: bootedAt, logNow: dispatchedAt)
        let log = ActuationLog(path: harness.logPath, now: { dispatchedAt })
        var request = ActuationRow(actor: .anonymous, kind: .send)
        request.method = RPCMethod.terminalSend
        request.target = .local(worktree: UUID(), terminal: Self.terminal)
        request.message = "status?"
        request.submit = true
        request.verify = true
        let id = try await log.appendRequest(request)
        await log.appendOutcome(confirms: id, result: .dispatched)

        // The query-time rule, first: past its deadline with no OBSERVED
        // outcome, a dispatched act is unconfirmed — that is the replay's work
        // list, and it is a pure function over the same rows.
        let parsed = ActuationRecordReader(activePath: harness.logPath)
            .rows(inFileAt: harness.logPath)
        let statuses = DeliveryRecord.statuses(in: parsed, now: bootedAt)
        #expect(statuses.count == 1)
        #expect(statuses.first?.status == .unconfirmed)

        await harness.verifier.replayMissedObservations(activeSegmentPath: harness.logPath)

        // `undetermined`, not `not-landed`: a replayed act can be arbitrarily
        // old, so a bounded tail that finds nothing proves nothing. See
        // `replayNeverAssertsNonDelivery`.
        #expect(try results(at: harness.logPath) == ["dispatched", "undetermined"])
        let observation = try #require(try rows(at: harness.logPath).last)
        #expect(observation["confirms"] as? String == id)
        // §12 leaves repair to playbook judgment, and a payload whose premise
        // is an unbounded interval old is the stale-premise send §3 forbids.
        #expect(harness.redeliveries.calls.isEmpty)
    }

    /// The live timer still owns an act inside its deadline. Replaying it would
    /// observe a payload that may not have reached the transcript yet.
    @Test("the replay leaves acts still awaiting their deadline alone")
    func startupReplaySkipsAwaitingActs() async throws {
        let dispatchedAt = Self.fixedNow
        let harness = try makeHarness(
            answers: [.silence(state: .idle)],
            now: dispatchedAt.addingTimeInterval(10), logNow: dispatchedAt)
        let log = ActuationLog(path: harness.logPath, now: { dispatchedAt })
        var request = ActuationRow(actor: .anonymous, kind: .send)
        request.target = .local(worktree: UUID(), terminal: Self.terminal)
        request.verify = true
        let id = try await log.appendRequest(request)
        await log.appendOutcome(confirms: id, result: .dispatched)

        await harness.verifier.replayMissedObservations(activeSegmentPath: harness.logPath)

        #expect(try results(at: harness.logPath) == ["dispatched"])
        #expect(harness.source.factsCalls == 0)
    }

    /// An act that never armed verification is owed no observation at all.
    @Test("the replay ignores sends that never armed verification")
    func startupReplayIgnoresUnverifiedSends() async throws {
        let dispatchedAt = Self.fixedNow
        let harness = try makeHarness(
            answers: [.silence(state: .idle)],
            now: dispatchedAt.addingTimeInterval(600), logNow: dispatchedAt)
        let log = ActuationLog(path: harness.logPath, now: { dispatchedAt })
        var request = ActuationRow(actor: .anonymous, kind: .send)
        request.target = .local(worktree: UUID(), terminal: Self.terminal)
        let id = try await log.appendRequest(request)
        await log.appendOutcome(confirms: id, result: .dispatched)

        await harness.verifier.replayMissedObservations(activeSegmentPath: harness.logPath)
        #expect(try results(at: harness.logPath) == ["dispatched"])
        #expect(harness.source.factsCalls == 0)
    }

    /// The replay can confirm a landing but must never assert a non-delivery.
    ///
    /// The 64 KiB tail is sound for the one-minute re-check because nothing can
    /// push a just-pasted envelope out of it without the session being
    /// `.working`. A replayed act has no such bound — it can be a day old, and
    /// real transcripts here run to megabytes — so the same absence proves
    /// nothing, while `activityState` is still whatever it was when the daemon
    /// died. Claiming `not-landed` from that would manufacture a loud
    /// non-delivery verdict about a payload that very likely landed.
    @Test("a replayed observation reads an absent envelope as undetermined, never not-landed")
    func replayNeverAssertsNonDelivery() async throws {
        let dispatchedAt = Self.fixedNow
        let bootedAt = dispatchedAt.addingTimeInterval(86_400)
        let harness = try makeHarness(
            answers: [.silence(state: .idle)], now: bootedAt, logNow: dispatchedAt)
        let actID = try await seedVerifiedDispatch(harness, dispatchedAt: dispatchedAt)

        await harness.verifier.replayMissedObservations(activeSegmentPath: harness.logPath)

        // The live timer would have called this not-landed and retried; the
        // replay may not, and re-delivers nothing either way.
        #expect(try results(at: harness.logPath) == ["dispatched", "undetermined"])
        #expect(harness.redeliveries.calls.isEmpty)
        let row = try #require(try rows(at: harness.logPath).last)
        #expect(row["confirms"] as? String == actID)
        #expect((row["error"] as? String)?.contains("absence is not evidence") == true)
    }

    /// Finding the envelope late is still positive evidence — the replay is
    /// only barred from concluding the negative.
    @Test("a replayed observation still confirms a landing when the envelope is there")
    func replayStillConfirmsALanding() async throws {
        let dispatchedAt = Self.fixedNow
        let bootedAt = dispatchedAt.addingTimeInterval(86_400)
        let harness = try makeHarness(
            answers: [.silence(state: .idle)], now: bootedAt, logNow: dispatchedAt)
        let actID = try await seedVerifiedDispatch(harness, dispatchedAt: dispatchedAt)
        harness.source.scriptEnvelope(for: actID, state: .working)

        await harness.verifier.replayMissedObservations(activeSegmentPath: harness.logPath)

        #expect(try results(at: harness.logPath) == ["dispatched", "landed-and-acting"])
        #expect(harness.redeliveries.calls.isEmpty)
    }

    /// A verified send whose observation never ran — the replay's work list.
    @discardableResult
    private func seedVerifiedDispatch(
        _ harness: Harness, dispatchedAt: Date
    ) async throws -> String {
        let log = ActuationLog(path: harness.logPath, now: { dispatchedAt })
        var request = ActuationRow(actor: .anonymous, kind: .send)
        request.method = RPCMethod.terminalSend
        request.target = .local(worktree: UUID(), terminal: Self.terminal)
        request.message = "status?"
        request.submit = true
        request.verify = true
        let id = try await log.appendRequest(request)
        await log.appendOutcome(confirms: id, result: .dispatched)
        return id
    }

    /// The replay's window is the active segment. An act from a rotated day is
    /// one whose transcript may have rolled over, and a late read buys only a
    /// more precise word for something the query-time rule already renders
    /// honestly — so the writer's own daily rotation bounds both the read and
    /// the work, with no new threshold to pick.
    @Test("the replay reads only the active segment, never rotated ones")
    func startupReplayReadsOnlyTheActiveSegment() async throws {
        let dispatchedAt = Self.fixedNow
        let harness = try makeHarness(
            answers: [.silence(state: .idle)],
            now: dispatchedAt.addingTimeInterval(600), logNow: dispatchedAt)
        let directory = (harness.logPath as NSString).deletingLastPathComponent
        let rotatedPath = (directory as NSString).appendingPathComponent("actuations-2023-11-13.jsonl")
        let rotated = ActuationLog(path: rotatedPath, now: { dispatchedAt })
        var request = ActuationRow(actor: .anonymous, kind: .send)
        request.target = .local(worktree: UUID(), terminal: Self.terminal)
        request.verify = true
        let id = try await rotated.appendRequest(request)
        await rotated.appendOutcome(confirms: id, result: .dispatched)

        await harness.verifier.replayMissedObservations(activeSegmentPath: harness.logPath)

        #expect(harness.source.factsCalls == 0)
        #expect(try rows(at: harness.logPath).isEmpty)
        // The rotated segment is untouched: two rows in, two rows out.
        #expect(try rows(at: rotatedPath).count == 2)
    }
}
