import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
import TBDShared

/// `terminal.send --verify`, and the verifier's one retry, on a holder-backed
/// row.
///
/// **The observation is transport-blind.** It reads the child's transcript
/// JSONL for the dispatch envelope the send delivered — never the rendered
/// screen, which this codebase forbids reading for state — so nothing about it
/// depends on there being a tmux pane to re-read. What the holder arm owed was
/// the two ends of that: arming the observation after a successful write, and
/// giving the verifier a way to re-deliver through the courier rather than
/// through `tmux.pasteText`.
///
/// Every test here that asserts a delivery or a holder-specific classification
/// discriminates against `origin/main`, where a `--verify` send to a holder row
/// was refused outright by `holderVerifyRefusal` and `redeliverVerifiedPayload`
/// had no holder branch at all — it fell through to the tmux body and pasted at
/// the empty pane id a holder row carries by construction.
@Suite("holder verified sends and the verifier's re-delivery")
struct HolderVerifiedSendTests {

    /// `ESC [ 2 0 0 ~` / `ESC [ 2 0 1 ~`, and the carriage return that submits.
    private static let pasteStart = Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])
    private static let pasteEnd = Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])
    private static let submitByte: UInt8 = 0x0d

    /// The expected bytes, assembled step by step rather than as a `+` chain:
    /// `Data`'s concatenation operators are generic over `Sequence`, and a
    /// four-term chain of them takes the type checker past its budget.
    private static func expected(body: String, wrapped: Bool, submit: Bool) -> Data {
        var data = Data()
        if !body.isEmpty {
            if wrapped { data.append(pasteStart) }
            data.append(Data(body.utf8))
            if wrapped { data.append(pasteEnd) }
        }
        if submit { data.append(submitByte) }
        return data
    }

    /// A child whose bracketed-paste mode the daemon's own live emulator has
    /// witnessed — so the composition obeys the flag rather than guessing.
    private static func reading(bracketedPaste: Bool) -> TerminalModeReading {
        TerminalModeReading(
            modes: TerminalScreen.ChildModes(
                bracketedPaste: bracketedPaste, applicationCursor: false,
                alternateScreen: false),
            modesObserved: true,
            source: TerminalScreen.Source.daemon,
            ageMilliseconds: 0)
    }

    // MARK: - Arming a verified send

    /// The happy path: flag on, verifier wired, a Claude holder row. The write
    /// happens, and the observation is armed with the composed body — envelope
    /// and text, before the paste markers that framed it, because the child's
    /// transcript records the message and not the control bytes.
    @Test("a verified send to a holder row is delivered and armed on the composed body")
    func aVerifiedHolderSendIsDeliveredAndArmed() async throws {
        let writes = HolderVerifyWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { writes.record($0) })
        try await harness.db.config.setDeliveryVerification(enabled: true)
        let armings = ArmingRecorder()
        harness.router.deliveryVerifier = armings
        let bracketing = Self.reading(bracketedPaste: true)
        harness.router.holderModeOracle = { _ in bracketing }

        let response = try await harness.send(
            TerminalSendParams(
                terminalID: harness.terminal.id, text: "status?", submit: true, verify: true),
            actor: .app)

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(writes.writes.count == 1)
        #expect(armings.armings.count == 1)
        let armed = try #require(armings.armings.first)
        #expect(armed.terminalID == harness.terminal.id)
        #expect(armed.sessionID == "sess-1")
        #expect(armed.submit)
        // The envelope rides inside the paste, so it is part of the payload the
        // transcript will carry — and the paste markers are not.
        #expect(armed.deliveredPayload.hasPrefix("<tbd-dispatch"))
        #expect(armed.deliveredPayload.hasSuffix("\nstatus?"))
        #expect(try #require(writes.writes.first)
            == Self.expected(body: armed.deliveredPayload, wrapped: true, submit: true))
    }

    /// The off branch of the same conditional: a send from a person's app that
    /// did not ask for verification arms nothing, even with the flag on and a
    /// verifier wired. Only the daemon's own rails get the default (below); a
    /// person or a script keeps opting in per send.
    @Test("a verify-less send to a holder row arms nothing")
    func aVerifylessHolderSendArmsNothing() async throws {
        let writes = HolderVerifyWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { writes.record($0) })
        try await harness.db.config.setDeliveryVerification(enabled: true)
        let armings = ArmingRecorder()
        harness.router.deliveryVerifier = armings

        let response = try await harness.send(
            TerminalSendParams(terminalID: harness.terminal.id, text: "status?", submit: true),
            actor: .app)

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(writes.writes.count == 1)
        #expect(armings.armings.isEmpty)
    }

    /// **The daemon's own rails arm verification by default — on holder only.**
    ///
    /// The rails are the senders whose silence costs hours: nobody is watching
    /// the screen when a desk nudges an agent at three in the morning, and the
    /// record is the only witness. So a rail's send to a holder-backed agent
    /// session is armed without `--verify` whenever the flag is on. A rail
    /// sending to a **tmux** session keeps today's per-send opt-in: that arm
    /// already delivers with explicit bracketing and a separate Enter, so it
    /// lacks the failure shape that motivates the default, and widening the
    /// soak to both transports at once widens the blast radius of any
    /// re-delivery bug to the whole fleet. Both halves are stated in
    /// `docs/specs/2026-09-05-child-as-contract-party-design.md`, "Delivery
    /// verification on holder sends" → "What changes".
    ///
    /// The asymmetry is the property, so both legs are asserted here.
    @Test("a daemon rail's send is armed by default on holder and not on tmux")
    func aDaemonRailSendIsArmedByDefaultOnHolderOnly() async throws {
        let writes = HolderVerifyWriteRecorder()
        let holder = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { writes.record($0) })
        try await holder.db.config.setDeliveryVerification(enabled: true)
        let holderArmings = ArmingRecorder()
        holder.router.deliveryVerifier = holderArmings
        let holderResponse = try await holder.send(
            TerminalSendParams(terminalID: holder.terminal.id, text: "nudge", submit: true),
            actor: .daemon(rail: "queued-prompt"))

        let tmux = try await SendHarness.make(transport: .tmux)
        try await tmux.db.config.setDeliveryVerification(enabled: true)
        let tmuxArmings = ArmingRecorder()
        tmux.router.deliveryVerifier = tmuxArmings
        let tmuxResponse = try await tmux.send(
            TerminalSendParams(terminalID: tmux.terminal.id, text: "nudge", submit: true),
            actor: .daemon(rail: "queued-prompt"))

        #expect(holderResponse.success, "error was: \(holderResponse.error ?? "none")")
        #expect(tmuxResponse.success, "error was: \(tmuxResponse.error ?? "none")")
        #expect(writes.writes.count == 1)
        #expect(tmux.tmux.pastedBodies.count == 1)
        // Armed on holder, on the same composed body an explicit `--verify`
        // would have armed.
        #expect(holderArmings.armings.count == 1)
        let armed = try #require(holderArmings.armings.first)
        #expect(armed.deliveredPayload.hasSuffix("\nnudge"))
        #expect(armed.terminalID == holder.terminal.id)
        // Not armed on tmux: the per-send opt-in stands there.
        #expect(tmuxArmings.armings.isEmpty)
    }

    /// **The default does not fire where nothing could be observed, and does not
    /// refuse there either.** A shell holder row is still served by the oracle
    /// — bare bytes — so a rail's send to one goes through unarmed rather than
    /// hitting the "only a Claude session can be observed" refusal, which is
    /// reachable only from an explicit `--verify`.
    @Test("a daemon rail's send to a holder shell row proceeds unarmed rather than refusing")
    func aDaemonRailSendToAHolderShellRowIsUnarmed() async throws {
        let writes = HolderVerifyWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, kind: .shell,
            holderDeliveryRecorder: { writes.record($0) })
        try await harness.db.config.setDeliveryVerification(enabled: true)
        let armings = ArmingRecorder()
        harness.router.deliveryVerifier = armings

        let response = try await harness.send(
            TerminalSendParams(terminalID: harness.terminal.id, text: "nudge", submit: true),
            actor: .daemon(rail: "queued-prompt"))

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(writes.writes == [Self.expected(body: "nudge", wrapped: false, submit: true)])
        #expect(armings.armings.isEmpty)
    }

    /// **The default never refuses.** Between the flag going on and the daemon
    /// restarting to wire a verifier, there is a window where the column says
    /// yes and there is nothing to arm. An explicit `--verify` is refused there
    /// — the caller asked for evidence and must not be handed a silence that
    /// reads like confirmation. A rail's ordinary send asked for nothing, so it
    /// is delivered unarmed instead: a supervision send that failed closed
    /// because supervision's own witness was not ready is the exact failure
    /// this design exists to prevent.
    @Test("a daemon rail's send is delivered unarmed when no verifier is wired")
    func aDaemonRailSendIsNotRefusedWithoutAWiredVerifier() async throws {
        let writes = HolderVerifyWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { writes.record($0) })
        try await harness.db.config.setDeliveryVerification(enabled: true)
        #expect(harness.router.deliveryVerifier == nil)

        let response = try await harness.send(
            TerminalSendParams(terminalID: harness.terminal.id, text: "nudge", submit: true),
            actor: .daemon(rail: "queued-prompt"))

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(!(response.error ?? "").contains("Restart the daemon"))
        #expect(writes.writes.count == 1)
    }

    /// And the flag is still the switch: with `delivery_verification_enabled`
    /// off — the shipped default — a rail's holder send arms nothing, so the
    /// default arming has an off branch and it is the shipped one.
    @Test("a daemon rail's holder send arms nothing while the flag is off")
    func aDaemonRailSendArmsNothingWithTheFlagOff() async throws {
        let writes = HolderVerifyWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { writes.record($0) })
        #expect(try await harness.db.config.get().deliveryVerificationEnabled == false)
        let armings = ArmingRecorder()
        harness.router.deliveryVerifier = armings

        let response = try await harness.send(
            TerminalSendParams(terminalID: harness.terminal.id, text: "nudge", submit: true),
            actor: .daemon(rail: "queued-prompt"))

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(writes.writes.count == 1)
        #expect(armings.armings.isEmpty)
    }

    // MARK: - The three states in which no observation could be produced

    /// A shell keeps no transcript, so there is nothing an observation could
    /// read. Refused by KIND, in the same words the tmux arm uses — the holder
    /// gate mirrors it rather than naming the transport.
    @Test("a verified send to a holder shell row is refused as unobservable, as on tmux")
    func aVerifiedHolderShellSendIsRefusedByKind() async throws {
        let writes = HolderVerifyWriteRecorder()
        let holder = try await SendHarness.make(
            transport: .holder, kind: .shell,
            holderDeliveryRecorder: { writes.record($0) })
        try await holder.db.config.setDeliveryVerification(enabled: true)
        holder.router.deliveryVerifier = ArmingRecorder()
        let holderResponse = try await holder.send(
            TerminalSendParams(
                terminalID: holder.terminal.id, text: "hi", submit: true, verify: true),
            actor: .app)

        let tmux = try await SendHarness.make(transport: .tmux, kind: .shell)
        try await tmux.db.config.setDeliveryVerification(enabled: true)
        tmux.router.deliveryVerifier = ArmingRecorder()
        let tmuxResponse = try await tmux.send(
            TerminalSendParams(
                terminalID: tmux.terminal.id, text: "hi", submit: true, verify: true),
            actor: .app)

        #expect(!holderResponse.success)
        #expect(!tmuxResponse.success)
        let message = try #require(holderResponse.error)
        #expect(message.contains("is a shell session"))
        #expect(message.contains("only be observed for a Claude session"))
        // The same refusal on both transports, differing only in the id it names.
        let holderNormalized = message.replacingOccurrences(
            of: holder.terminal.id.uuidString, with: "<id>")
        let tmuxNormalized = try #require(tmuxResponse.error).replacingOccurrences(
            of: tmux.terminal.id.uuidString, with: "<id>")
        #expect(holderNormalized == tmuxNormalized)
        #expect(writes.writes.isEmpty, "nothing may be written")
    }

    /// The flag is the second precondition, and it is refused rather than
    /// silently downgraded to an unverified send: a caller that asked for
    /// evidence is never answered with a silence that reads like confirmation.
    @Test("a verified send to a holder row is refused while the flag is off, as on tmux")
    func aVerifiedHolderSendIsRefusedWithTheFlagOff() async throws {
        let writes = HolderVerifyWriteRecorder()
        let holder = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { writes.record($0) })
        #expect(try await holder.db.config.get().deliveryVerificationEnabled == false)
        let holderResponse = try await holder.send(
            TerminalSendParams(
                terminalID: holder.terminal.id, text: "status?", submit: true, verify: true),
            actor: .app)

        let tmux = try await SendHarness.make(transport: .tmux)
        let tmuxResponse = try await tmux.send(
            TerminalSendParams(
                terminalID: tmux.terminal.id, text: "status?", submit: true, verify: true),
            actor: .app)

        #expect(!holderResponse.success)
        let message = try #require(holderResponse.error)
        #expect(message.contains("delivery verification is disabled"))
        #expect(message.contains("config.delivery_verification_enabled is off"))
        // On `origin/main` this named the transport instead.
        #expect(!message.contains("pty-holder"))
        #expect(message == (try #require(tmuxResponse.error)))
        #expect(writes.writes.isEmpty, "nothing may be written")
    }

    /// The flag and the machinery it enables are read at different times — the
    /// column per call, the verifier once at daemon start — so the window where
    /// the column says yes and nothing is wired refuses too, on both transports.
    @Test("a verified holder send is refused when the flag is on but no verifier is wired")
    func aVerifiedHolderSendIsRefusedWithoutAWiredVerifier() async throws {
        let writes = HolderVerifyWriteRecorder()
        let holder = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { writes.record($0) })
        try await holder.db.config.setDeliveryVerification(enabled: true)
        #expect(holder.router.deliveryVerifier == nil)
        let holderResponse = try await holder.send(
            TerminalSendParams(
                terminalID: holder.terminal.id, text: "status?", submit: true, verify: true),
            actor: .app)

        let tmux = try await SendHarness.make(transport: .tmux)
        try await tmux.db.config.setDeliveryVerification(enabled: true)
        let tmuxResponse = try await tmux.send(
            TerminalSendParams(
                terminalID: tmux.terminal.id, text: "status?", submit: true, verify: true),
            actor: .app)

        #expect(!holderResponse.success)
        let message = try #require(holderResponse.error)
        #expect(message.contains("Restart the daemon"))
        #expect(message == (try #require(tmuxResponse.error)))
        #expect(writes.writes.isEmpty, "nothing may be written")
    }

    // MARK: - The verifier's one re-delivery

    /// The retry re-injects through the same courier the first send used, and
    /// recomposes the paste wrapping from a FRESH mode reading rather than
    /// replaying the bytes the first send wrote — a minute has passed and the
    /// child's bracketed-paste mode can have flipped in it.
    ///
    /// `payload` is the composed body (envelope and text, before any marker), so
    /// it takes no second envelope.
    @Test("a holder retry re-injects through the courier, rewrapped for the child as it is now")
    func aHolderRetryReinjectsThroughTheCourier() async throws {
        let writes = HolderVerifyWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { writes.record($0) })
        let bracketing = Self.reading(bracketedPaste: true)
        harness.router.holderModeOracle = { _ in bracketing }
        let payload = "<tbd-dispatch id=\"a1\" from=\"app\"/>\nstatus?"

        let outcome = await harness.router.redeliverVerifiedPayload(
            terminalID: harness.terminal.id, sessionID: "sess-1",
            payload: payload, submit: true)

        #expect(outcome == .dispatched)
        #expect(writes.writes == [Self.expected(body: payload, wrapped: true, submit: true)])
        // Nothing reached tmux: the holder branch returns before that body.
        #expect(harness.tmux.pastedBodies.isEmpty)
        #expect(harness.tmux.sentKeys.isEmpty)
    }

    /// A child whose bracketing is off gets the same body bare — which is the
    /// whole reason the wrapping is recomputed rather than replayed.
    @Test("a holder retry composes bare for a child that wants no brackets")
    func aHolderRetryComposesBareForAChildWithoutBrackets() async throws {
        let writes = HolderVerifyWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { writes.record($0) })
        let bare = Self.reading(bracketedPaste: false)
        harness.router.holderModeOracle = { _ in bare }

        let outcome = await harness.router.redeliverVerifiedPayload(
            terminalID: harness.terminal.id, sessionID: "sess-1", payload: "hi", submit: true)

        #expect(outcome == .dispatched)
        #expect(writes.writes == [Self.expected(body: "hi", wrapped: false, submit: true)])
    }

    /// The eligibility that admitted the first send has to still hold for the
    /// second: a `recreateWindow` between the observation and the retry can turn
    /// an agent row into a shell while keeping its id, and the payload being held
    /// opens with an envelope a shell would run as a command line of its own.
    @Test("a holder retry to a row that is now a shell is not eligible")
    func aHolderRetryToAShellRowIsNotEligible() async throws {
        let writes = HolderVerifyWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, kind: .shell,
            holderDeliveryRecorder: { writes.record($0) })

        let outcome = await harness.router.redeliverVerifiedPayload(
            terminalID: harness.terminal.id, sessionID: nil, payload: "hi", submit: true)

        #expect(outcome == .refused(.notEligible))
        #expect(writes.writes.isEmpty)
    }

    /// No courier is no input path at all — the same condition
    /// `performHolderSend` turns into `holderInputUnavailable` and classifies as
    /// `.notEligible`. The retry classifies it the same way rather than as a
    /// transport failure it never attempted.
    ///
    /// Discriminates: on `origin/main` this fell through to the tmux body and
    /// answered `.dispatched` after pasting at the empty pane id.
    @Test("a holder retry with no courier is not eligible, and pastes nothing")
    func aHolderRetryWithNoCourierIsNotEligible() async throws {
        let harness = try await SendHarness.make(transport: .holder)
        #expect(harness.router.holderInjectionCourier == nil)

        let outcome = await harness.router.redeliverVerifiedPayload(
            terminalID: harness.terminal.id, sessionID: "sess-1", payload: "hi", submit: true)

        #expect(outcome == .refused(.notEligible))
        #expect(harness.tmux.pastedBodies.isEmpty)
    }

    /// A write the courier could not make is the transport, not a decision.
    @Test("a holder retry the courier cannot write is a transport failure")
    func aHolderRetryThatCannotBeWrittenIsATransportFailure() async throws {
        let harness = try await SendHarness.make(transport: .holder)
        harness.router.holderInjectionCourier = HolderInjectionCourier(
            sendFrame: { _ in },
            viewerAttachment: { _ in nil },
            writeDirectly: { _, _ in throw HolderRetryWriteFailure() })

        let outcome = await harness.router.redeliverVerifiedPayload(
            terminalID: harness.terminal.id, sessionID: "sess-1", payload: "hi", submit: true)

        #expect(outcome == .transportFailed)
    }

    /// A session id that no longer matches is a stranger, and the retry is the
    /// one send that must never reach one. Asserted on a holder row because the
    /// holder branch returns before the tmux body that used to be the only thing
    /// after this check.
    @Test("a holder retry to a rebound conversation is a target mismatch")
    func aHolderRetryToAReboundConversationIsRefused() async throws {
        let writes = HolderVerifyWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { writes.record($0) })

        let outcome = await harness.router.redeliverVerifiedPayload(
            terminalID: harness.terminal.id, sessionID: "someone-else", payload: "hi",
            submit: true)

        #expect(outcome == .refused(.targetMismatch))
        #expect(writes.writes.isEmpty)
    }

    /// **The retry arms nothing.** This call IS the verifier's retry; re-arming
    /// would make it observe its own re-delivery and retry that in turn.
    @Test("a holder retry arms no further verification")
    func aHolderRetryArmsNoFurtherVerification() async throws {
        let writes = HolderVerifyWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { writes.record($0) })
        try await harness.db.config.setDeliveryVerification(enabled: true)
        let armings = ArmingRecorder()
        harness.router.deliveryVerifier = armings

        let outcome = await harness.router.redeliverVerifiedPayload(
            terminalID: harness.terminal.id, sessionID: "sess-1", payload: "hi", submit: true)

        #expect(outcome == .dispatched)
        #expect(writes.writes.count == 1)
        #expect(armings.armings.isEmpty)
    }

    /// **Two payloads spliced into one composer is a transport bug**, and the
    /// retry is a second writer to the same pty. It queues in the terminal's own
    /// lane exactly as the tmux retry does — proven by holding the lane from
    /// outside and watching the retry write nothing until it is released.
    @Test("a holder retry queues behind the terminal's send lane")
    func aHolderRetryQueuesBehindTheLane() async throws {
        let writes = HolderVerifyWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { writes.record($0) })
        let gate = RetryLaneGate()

        // Occupy this terminal's lane the way an in-flight send would.
        async let laneHolder: Void = harness.router.terminalSendSerializer
            .run(terminalID: harness.terminal.id) { await gate.wait() }
        // Hang guard on the lane holder reaching the gate, bounded at the shared
        // saturated-pass budget rather than a literal: it is a structured child
        // on the cooperative pool, so one hop can cost tens of seconds.
        let deadline = ContinuousClock.now + TestDeadlines.saturatedPass
        while await !gate.hasEntered && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.hasEntered)

        async let outcome = harness.router.redeliverVerifiedPayload(
            terminalID: harness.terminal.id, sessionID: "sess-1", payload: "hi", submit: true)
        // Bounded window: with the lane held, the retry must write nothing.
        try await Task.sleep(for: .milliseconds(100))
        #expect(writes.writes.isEmpty, "a retry must not splice into another send's write")

        await gate.open()
        try await laneHolder
        #expect(await outcome == .dispatched)
        #expect(writes.writes.count == 1)
    }

    /// The tmux retry is untouched: it still consults the pane and pastes
    /// through tmux, then presses Enter as a separate act.
    @Test("a tmux retry still pastes through tmux")
    func aTmuxRetryStillPastesThroughTmux() async throws {
        let harness = try await SendHarness.make(transport: .tmux)

        let outcome = await harness.router.redeliverVerifiedPayload(
            terminalID: harness.terminal.id, sessionID: "sess-1", payload: "hi", submit: true)

        #expect(outcome == .dispatched)
        #expect(harness.tmux.pastedBodies == ["hi"])
        #expect(harness.tmux.sentKeys == ["Enter"])
    }
}

/// What the courier was asked to write. Lock-guarded because `writeDirectly`
/// runs off the test's task.
private final class HolderVerifyWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [Data] = []
    var writes: [Data] { lock.withLock { _writes } }
    func record(_ bytes: Data) { lock.withLock { _writes.append(bytes) } }
}

/// A verifier that records what it was armed with and does nothing else, so a
/// test can assert the arming without a transcript, a clock or a retry.
private final class ArmingRecorder: DeliveryVerificationArming, @unchecked Sendable {
    struct Arming: Sendable {
        let actuationID: String
        let terminalID: UUID
        let sessionID: String?
        let deliveredPayload: String
        let submit: Bool
    }

    private let lock = NSLock()
    private var _armings: [Arming] = []
    var armings: [Arming] { lock.withLock { _armings } }

    func armVerification(
        actuationID: String, terminalID: UUID, sessionID: String?,
        deliveredPayload: String, submit: Bool
    ) async {
        let arming = Arming(
            actuationID: actuationID, terminalID: terminalID, sessionID: sessionID,
            deliveredPayload: deliveredPayload, submit: submit)
        lock.withLock { _armings.append(arming) }
    }
}

/// The failure a courier whose direct write cannot land reports.
private struct HolderRetryWriteFailure: Error {}

/// A one-shot gate a test can open from the outside.
private actor RetryLaneGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entered = false

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    var hasEntered: Bool { entered }
}
