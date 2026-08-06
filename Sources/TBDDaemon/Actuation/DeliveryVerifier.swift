import Foundation
import TBDShared
import os

private let verifierLogger = Logger(subsystem: "com.tbd.daemon", category: "delivery-verification")

// MARK: - The observation's inputs

/// The two machine facts the observation reads about a session (§12): where its
/// transcript lives, and what state it is in.
///
/// A value type rather than the `Terminal` row so the mapping cannot start
/// consulting fields §12 does not license — the observation is deliberately
/// two facts wide.
struct TerminalDeliveryFacts: Sendable, Equatable {
    /// `terminals.transcriptPath`. `nil` when the session never reported one,
    /// which is an *undetermined* observation, never a non-delivery.
    let transcriptPath: String?
    let activityState: TerminalActivityState
}

/// Everything the observation reads from outside itself.
///
/// Narrow on purpose: with the transcript tail and the session state behind one
/// injected seam, §12's four-result mapping is a tier-1 test with no database,
/// no filesystem and no daemon — and a fake that *counts* reads can prove that
/// a send which never armed verification costs no transcript read at all.
protocol DeliveryObservationSource: Sendable {
    /// The session's facts, or `nil` when the terminal row is gone.
    func facts(forTerminal terminalID: UUID) async -> TerminalDeliveryFacts?

    /// A bounded window off the **end** of the transcript, or `nil` when the
    /// file cannot be read.
    ///
    /// Bounded, never a full parse: §3 forbids paying for a whole transcript on
    /// a path that runs once a minute per verified send, and the envelope this
    /// looks for was written seconds ago, so the tail is where it is. An empty
    /// but readable file answers with empty data — readable-and-absent, which
    /// is evidence; unreadable answers `nil`, which is not.
    func transcriptTail(atPath path: String, maxBytes: Int) async -> Data?
}

/// The production source: the terminal row from the database, the tail straight
/// off the file.
struct DatabaseDeliveryObservationSource: DeliveryObservationSource {
    let db: TBDDatabase

    func facts(forTerminal terminalID: UUID) async -> TerminalDeliveryFacts? {
        guard let terminal = try? await db.terminals.get(id: terminalID) else { return nil }
        return TerminalDeliveryFacts(
            transcriptPath: terminal.transcriptPath,
            activityState: terminal.activityState)
    }

    func transcriptTail(atPath path: String, maxBytes: Int) async -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        guard size > 0 else { return Data() }
        let window = UInt64(max(maxBytes, 0))
        try? handle.seek(toOffset: size > window ? size - window : 0)
        return (try? handle.readToEnd()) ?? Data()
    }
}

// MARK: - What one observation established

/// One observation's finding: the result §12 names, plus what the observation
/// could not establish (or found instead), which rides the outcome row's
/// free-text slot.
struct DeliveryObservation: Sendable, Equatable {
    let result: ObservedResult
    let detail: String?

    init(_ result: ObservedResult, detail: String? = nil) {
        self.result = result
        self.detail = detail
    }
}

// MARK: - The verifier

/// The one-minute re-check, the single evidence-bounded retry, and the startup
/// replay — the third rung of the record's claims ladder (design §12).
///
/// **Armed state is in memory, deliberately.** §7 keeps these timers
/// non-durable *because* everything they encode derives from the durable
/// record: an actuation row's timestamp fixes its observation deadline, and the
/// envelope is durable in the transcript. So a restart costs cadence, never
/// data — the acts whose timers died render `unconfirmed` by
/// `DeliveryRecord.statuses`, and `replayMissedObservations` performs those
/// observations late.
///
/// **It calls no tmux primitive.** Re-delivery arrives as a closure supplied by
/// `RPCRouter`, whose implementation reuses the send path's own
/// consult-then-paste code inside the file the actuation audit already covers.
/// That keeps `.swiftlint.yml`'s `actuation_primitive_allowlist` untouched and
/// makes the retry a counted fake in tests.
actor DeliveryVerifier: DeliveryVerificationArming {
    /// How much of the transcript's end one observation reads.
    ///
    /// 64 KiB is the same window `ActuationLog` tails its own segment with, and
    /// the reason is the same: it bounds the read without needing a parse. The
    /// envelope was pasted within the last minute, so anything that could push
    /// it out of this window is a session that generated 64 KiB of transcript
    /// since — which, by the mapping below, is a session that is `.working`,
    /// and an absent envelope there is `undetermined`, never `not-landed`.
    static let tailWindowBytes = 64 * 1024

    private let log: ActuationLog
    private let source: any DeliveryObservationSource
    /// Re-delivers an identical payload under its identical envelope id, and
    /// reports what the transport did — so a refused or transport-failed retry
    /// is classified honestly instead of collapsing into "the payload failed".
    private let redeliver: @Sendable (UUID, String, Bool) async -> ActuationOutcome
    private let deadline: Duration
    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>

    /// The armed re-checks, keyed by the actuation id they will confirm. In
    /// memory only (§7); an entry is removed when its cycle ends.
    private var pending: [String: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - deadline: how long after dispatch the observation runs. Defaults to
    ///     the one place this repo spells the number (§13's compiled-numbers
    ///     table, via `DeliveryRecord.acknowledgementDeadline`) — injectable so
    ///     a test crosses it in one advance rather than sixty.
    ///   - now: the `observedAt` stamp. `Date` is data, so it comes through the
    ///     date seam, never off the clock.
    ///   - clock: the re-check timer. Existential, last, defaulted, per the
    ///     repo rule (`Tests/CLAUDE.md`, "Clock and date seams").
    init(
        log: ActuationLog,
        source: any DeliveryObservationSource,
        redeliver: @escaping @Sendable (UUID, String, Bool) async -> ActuationOutcome,
        deadline: Duration = .seconds(DeliveryRecord.acknowledgementDeadline),
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.log = log
        self.source = source
        self.redeliver = redeliver
        self.deadline = deadline
        self.now = now
        self.clock = clock
    }

    // MARK: - Arming

    func armVerification(
        actuationID: String,
        terminalID: UUID,
        deliveredPayload: String,
        submit: Bool
    ) async {
        let armed = ArmedDelivery(
            actuationID: actuationID, terminalID: terminalID,
            payload: deliveredPayload, submit: submit)
        // Detached from the caller's send: the RPC response is the caller's
        // synchronous result and must not wait a minute for an observation.
        pending[actuationID] = Task { [self] in
            await runReCheckCycle(armed)
            forget(actuationID: actuationID)
        }
    }

    /// The armed payload, exactly as it reached the pane. The envelope's id
    /// *is* `actuationID`, so a retry of these bytes still joins on the
    /// original row and opens no second request row.
    private struct ArmedDelivery: Sendable {
        let actuationID: String
        let terminalID: UUID
        let payload: String
        let submit: Bool
    }

    private func forget(actuationID: String) {
        pending[actuationID] = nil
    }

    /// Await every armed re-check still in flight.
    ///
    /// For tests, which drive the clock and then need the cycle's writes to
    /// have landed before they read the record. Production never waits on
    /// these — that is the whole point of arming them.
    func awaitPendingObservations() async {
        for task in pending.values { await task.value }
    }

    // MARK: - The cycle: observe, retry at most once, observe again

    private func runReCheckCycle(_ armed: ArmedDelivery) async {
        try? await clock.sleep(for: deadline)
        let first = await observe(actuationID: armed.actuationID, terminalID: armed.terminalID)
        await record(first, confirming: armed.actuationID)

        // `undetermined` is NEVER retried, and the reason is not caution about
        // wasted work: retrying into uncertainty risks double-instructing an
        // agent that DID receive the first copy, and a message to an agent
        // running with permissions bypassed is arbitrary instruction injection
        // (§3) — so delivering it twice is not a neutral event. Only positive
        // evidence of non-delivery licenses a second send.
        guard first.result == .notLanded else {
            if first.result == .undetermined { announceAnomaly(first, confirming: armed) }
            return
        }

        // The single evidence-bounded retry: the identical payload under the
        // identical envelope id, so it is the same actuation-level intent and
        // shares the original request row (`ActuationSurface`'s boundary rule).
        // Its own synchronous result is still a fact about that act, so it gets
        // an outcome row confirming the same id.
        let retry = await redeliver(armed.terminalID, armed.payload, armed.submit)
        // `error` stays nil when the retry dispatched. A row reading
        // `dispatched` with a populated error field reads as a failure to
        // anything querying the record, and the second dispatch needs no
        // annotation to be legible: the `not-landed` observation sitting
        // between the two dispatches is what says why there are two.
        await log.appendOutcome(
            confirms: armed.actuationID, result: retry,
            error: retry == .dispatched
                ? nil
                : "single evidence-bounded re-delivery after a not-landed observation")
        guard retry == .dispatched else {
            // The re-delivery never reached the pane. Its synchronous outcome
            // row above records exactly that, and the first re-check's
            // `not-landed` already stands on real evidence — so there is
            // nothing left to *observe* here, and writing a second observation
            // row would claim a look that never happened. That is the whole
            // point of keeping `ObservedResult` out of `ActuationResult`: a
            // synchronous fact must not be able to wear an observed result's
            // clothes, least of all in the code that owns the distinction.
            announceAnomaly(
                first, confirming: armed,
                note: "re-delivery did not reach the pane (\(retry.result.rawValue)"
                    + (retry.reason.map { ": \($0.rawValue)" } ?? "") + ")")
            return
        }

        try? await clock.sleep(for: deadline)
        let second = await observe(actuationID: armed.actuationID, terminalID: armed.terminalID)
        await record(second, confirming: armed.actuationID)
        // Two silent failures indicate a structural problem with the session,
        // and a third send without evidence would risk duplicate-message bugs.
        // There is no third send, on any branch, ever.
        if second.result != .landedAndActing && second.result != .landedButStillBlocked {
            announceAnomaly(second, confirming: armed)
        }
    }

    // MARK: - The observation

    /// §12's four results, from two machine facts and nothing else.
    ///
    /// Never a pane read: screen text is a display surface, not an API (root
    /// `CLAUDE.md`, "No TUI screen-scraping"). The transcript is the machine
    /// interface, and the envelope reaches it without the agent cooperating in
    /// anything.
    func observe(actuationID: String, terminalID: UUID) async -> DeliveryObservation {
        guard let facts = await source.facts(forTerminal: terminalID) else {
            return DeliveryObservation(
                .undetermined,
                detail: "terminal \(terminalID.uuidString) is gone — no session left to observe")
        }
        guard let path = facts.transcriptPath, !path.isEmpty else {
            return DeliveryObservation(
                .undetermined,
                detail: "no transcript path recorded for terminal \(terminalID.uuidString)")
        }
        guard let tail = await source.transcriptTail(
            atPath: path, maxBytes: Self.tailWindowBytes) else {
            return DeliveryObservation(
                .undetermined, detail: "transcript unreadable at \(path)")
        }

        let found = Self.envelopeAppears(actuationID: actuationID, inTail: tail)
        switch (found, facts.activityState) {
        case (true, .working):
            return DeliveryObservation(.landedAndActing)
        case (true, .idle), (true, .waitingForUser):
            return DeliveryObservation(.landedButStillBlocked)
        case (true, .unknown):
            // Half an observation is not an observation: the payload is in the
            // conversation but nothing can be said about what the session did
            // with it. Safe to leave here precisely because undetermined is
            // never retried.
            return DeliveryObservation(
                .undetermined,
                detail: "envelope found in the transcript, but the session state is unknown")
        case (false, .idle), (false, .waitingForUser):
            // The only positive evidence of non-delivery §12 accepts: the
            // transcript is readable, the envelope is absent, and the session
            // is verifiably not mid-turn.
            return DeliveryObservation(
                .notLanded,
                detail: "no dispatch envelope in the transcript tail and the session is "
                    + "\(facts.activityState.rawValue) — verifiably not mid-turn")
        case (false, .working):
            // Absence while mid-turn proves nothing: the harness may not have
            // written the line yet. No positive evidence, so no retry.
            return DeliveryObservation(
                .undetermined,
                detail: "no dispatch envelope in the transcript tail, but the session is "
                    + "mid-turn — not verifiably non-delivery")
        case (false, .unknown):
            return DeliveryObservation(
                .undetermined,
                detail: "no dispatch envelope in the transcript tail and the session state "
                    + "is unknown")
        }
    }

    /// Whether the dispatch envelope for `actuationID` appears in the tail.
    ///
    /// **Both spellings count.** The transcript is JSONL and the envelope's
    /// quotes are part of a JSON string value, so the line on disk carries
    /// `id=\"a3f1\"`, not `id="a3f1"`. Searching only the raw form would find
    /// nothing in a real transcript and report `not-landed` for every delivered
    /// payload; searching only the escaped form would miss a transcript format
    /// that quotes differently. Both needles are composed from the id, so
    /// neither can drift from the string the send path actually pastes.
    ///
    /// Matched on **bytes**, not on a decoded string: a fixed-size window off
    /// the end of a file can begin in the middle of a multi-byte character, and
    /// a failable `String` conversion would then throw the whole window away
    /// and report an absent envelope — a not-landed verdict manufactured by the
    /// reader. The needles are ASCII, so a byte search is exact.
    static func envelopeAppears(actuationID: String, inTail tail: Data) -> Bool {
        needles(forActuationID: actuationID).contains { tail.range(of: Data($0.utf8)) != nil }
    }

    /// The two spellings of the envelope's identifying attribute. Tests assert
    /// on these composed strings rather than on a predicate's verdict, so a
    /// needle that stopped matching what `dispatchEnvelope` writes goes red.
    static func needles(forActuationID id: String) -> [String] {
        [
            "tbd-dispatch id=\"\(id)\"",
            "tbd-dispatch id=\\\"\(id)\\\"",
        ]
    }

    // MARK: - Recording, and the anomaly

    private func record(
        _ observation: DeliveryObservation, confirming actuationID: String
    ) async {
        await log.appendObservation(
            confirms: actuationID, result: observation.result,
            observedAt: now(), detail: observation.detail)
    }

    /// The anomaly, in the two halves it has until the ledger exists (§7 builds
    /// no supervision storage yet): the observed outcome row — already written
    /// by `record`, carrying the detail — and a loud `.fault` line. When the
    /// ledger slice lands its `anomaly` line joins these; the row is the
    /// durable half either way.
    /// `note` carries something the log line should say that the *record* must
    /// not — a failed re-delivery, whose synchronous outcome row already stands
    /// on its own. Diagnostics may narrate; the record may only attest.
    private func announceAnomaly(
        _ observation: DeliveryObservation,
        confirming armed: ArmedDelivery,
        note: String? = nil
    ) {
        verifierLogger.fault(
            """
            delivery anomaly: act \(armed.actuationID, privacy: .public) to terminal \
            \(armed.terminalID.uuidString, privacy: .public) observed \
            \(observation.result.rawValue, privacy: .public) — \
            \(observation.detail ?? "no detail", privacy: .public)\
            \(note.map { "; \($0)" } ?? "", privacy: .public)
            """)
    }

    // MARK: - The startup replay

    /// Perform, late, the observations whose timers died with the last daemon.
    ///
    /// **Reads only the active segment.** An act older than
    /// `actuations.jsonl`'s current day is one whose transcript may have rolled
    /// over, and re-delivery is forbidden here anyway, so a late read buys only
    /// a more precise word for something the query-time rule already renders
    /// honestly. The writer's own daily rotation therefore bounds both the read
    /// and the work, with no new threshold to pick.
    ///
    /// **It never re-delivers.** §12 puts "what to *do* about an unconfirmed
    /// act — re-send, journal, shrug" in playbook judgment, never compiled
    /// repair, and a payload whose premise is an unbounded interval old is
    /// exactly the stale-premise send §3 forbids. So a replayed `not-landed`
    /// records the outcome and the anomaly, and stops.
    ///
    /// `.awaitingObservation` acts are left alone: their deadline has not
    /// passed, so nothing is owed yet.
    func replayMissedObservations(activeSegmentPath: String) async {
        let reader = ActuationRecordReader(activePath: activeSegmentPath)
        let rows = reader.rows(inFileAt: activeSegmentPath)
        let unconfirmed = DeliveryRecord.statuses(in: rows, now: now())
            .filter { $0.status == .unconfirmed }
        guard !unconfirmed.isEmpty else { return }
        verifierLogger.info(
            """
            startup replay: \(unconfirmed.count, privacy: .public) verified send(s) in the \
            active segment are past their acknowledgement deadline with no observation
            """)
        for assessment in unconfirmed {
            guard let terminalRaw = assessment.request.target?.terminal,
                  let terminalID = UUID(uuidString: terminalRaw) else {
                let observation = DeliveryObservation(
                    .undetermined,
                    detail: "the request row names no local terminal to observe")
                await record(observation, confirming: assessment.request.id)
                verifierLogger.fault(
                    """
                    delivery anomaly: act \(assessment.request.id, privacy: .public) observed \
                    undetermined at startup — \(observation.detail ?? "", privacy: .public)
                    """)
                continue
            }
            let observation = await observe(
                actuationID: assessment.request.id, terminalID: terminalID)
            await record(observation, confirming: assessment.request.id)
            if observation.result != .landedAndActing
                && observation.result != .landedButStillBlocked {
                verifierLogger.fault(
                    """
                    delivery anomaly: act \(assessment.request.id, privacy: .public) to terminal \
                    \(terminalID.uuidString, privacy: .public) observed late at startup as \
                    \(observation.result.rawValue, privacy: .public) — \
                    \(observation.detail ?? "no detail", privacy: .public); not re-delivered \
                    (§12 leaves repair to playbook judgment)
                    """)
            }
        }
    }
}
