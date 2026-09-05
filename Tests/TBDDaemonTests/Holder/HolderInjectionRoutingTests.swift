import Clocks
import Foundation
import TBDShared
import Testing

@testable import TBDDaemonLib
import TestSupport

/// The delivery rule for a daemon write into a holder-backed session:
/// **detached → write the pty directly; attached → inject through the app and
/// wait for its answer; no usable answer before the deadline → write anyway.**
///
/// Every deadline here runs on a `TestClock`, so nothing sleeps in real time.
/// The only real-time waits are `waitFor` polls for a frame to have reached the
/// harness — the scheduling handshake that `Tests/CLAUDE.md`'s clock-seam note
/// sanctions, because `Task { await courier.deliver(…) }` only *schedules* the
/// call.
///
/// `.clockDriven` at suite level: most of these tests await a value that a
/// broken courier would never produce, so each needs its own hang bound.
@Suite("HolderInjectionRouting", .clockDriven, .serialized)
struct HolderInjectionRoutingTests {

    // MARK: - Harness

    /// Stands in for the three things the courier reaches out to: the sidecar
    /// it puts frames on, the registry it asks who owns a pty, and the
    /// daemon's own descriptor for that pty.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var sentFrames: [Data] = []
        private var writes: [Data] = []

        /// Set to a generation to make the session read as viewer-owned.
        var attachment: UInt64?
        /// When set, `sendFrame` throws it — the sidecar being gone.
        var sendFrameError: Error?
        /// When set, `writeDirectly` throws it — the daemon holding no
        /// descriptor for the pty, which is its ordinary state while a viewer
        /// is attached.
        var directWriteError: Error?

        var frames: [Data] { lock.withLock { sentFrames } }
        var directWrites: [Data] { lock.withLock { writes } }

        /// Builds a courier on the **production** ack deadline: the
        /// `ackDeadline` argument is *omitted*, not passed, so
        /// `HolderInputTiming.injectionAckDeadline` is what the deadline tests
        /// below actually exercise. A harness default of its own would make
        /// those tests prove nothing about the shipped value.
        func makeCourier(clock: any Clock<Duration>) -> HolderInjectionCourier {
            HolderInjectionCourier(
                sendFrame: sendFrame,
                viewerAttachment: viewerAttachment,
                writeDirectly: writeDirectly,
                clock: clock)
        }

        /// For tests about something other than the deadline, which want a
        /// value chosen to make their own mechanism obvious.
        func makeCourier(
            ackDeadline: Duration, clock: any Clock<Duration>
        ) -> HolderInjectionCourier {
            HolderInjectionCourier(
                sendFrame: sendFrame,
                viewerAttachment: viewerAttachment,
                writeDirectly: writeDirectly,
                ackDeadline: ackDeadline,
                clock: clock)
        }

        private var sendFrame: @Sendable (Data) async throws -> Void {
            { [self] frame in
                if let sendFrameError { throw sendFrameError }
                lock.withLock { sentFrames.append(frame) }
            }
        }

        private var viewerAttachment: @Sendable (UUID) async -> UInt64? {
            { [self] _ in attachment }
        }

        private var writeDirectly: @Sendable (UUID, Data) async throws -> Void {
            { [self] _, bytes in
                if let directWriteError { throw directWriteError }
                lock.withLock { writes.append(bytes) }
            }
        }

        /// The injection the courier put on the wire, parsed back off it.
        /// Reading the real frame rather than a recorded tuple is what makes
        /// these tests cover the encoder as well as the routing.
        func decodeOnlyInjection() throws -> (header: SidecarInjectionHeader, bytes: Data) {
            let scanner = SidecarFrameScanner()
            let parsed = scanner.append(try #require(frames.first))
            let frame = try #require(parsed.first)
            #expect(SidecarFrameType(rawValue: frame.type) == .injection)
            return try SidecarFrameCodec.decodeInjection(payload: frame.payload)
        }
    }

    private struct NoDescriptor: Error {}
    private struct SidecarGone: Error {}

    /// What the courier was supposed to answer, and what it answered.
    ///
    /// An `Error` rather than a string so `Issue.record` puts it on the
    /// primary failure line — `Issue.record(String)` demotes the message to a
    /// trailing line CI summaries drop, and the delivery it actually returned
    /// is the whole finding.
    private struct UnexpectedDelivery: Error, CustomStringConvertible {
        let expected: String
        let actual: HolderInjectionCourier.Delivery

        var description: String {
            "the courier must report \(expected), reported \(actual)"
        }
    }

    // MARK: - The four the plan names, plus the one it conflates away

    @Test("A detached holder session is written directly")
    func detachedSessionIsWrittenDirectly() async throws {
        let harness = Harness()
        harness.attachment = nil
        let courier = harness.makeCourier(clock: TestClock())

        let outcome = await courier.deliver(
            terminalID: UUID(), bytes: Data("echo hi\r".utf8))

        #expect(outcome == .daemonWrote(.detached))
        #expect(harness.directWrites == [Data("echo hi\r".utf8)])
        #expect(harness.frames.isEmpty, "a detached session must not go near the app")
    }

    @Test("An attached holder session is injected through the app")
    func attachedSessionIsInjectedThroughTheApp() async throws {
        let harness = Harness()
        harness.attachment = 7
        let courier = harness.makeCourier(clock: TestClock())
        let terminalID = UUID()

        let delivery = Task { await courier.deliver(terminalID: terminalID, bytes: Data("hi\r".utf8)) }
        try await waitFor("the injection frame to reach the sidecar") { harness.frames.count == 1 }

        let injection = try harness.decodeOnlyInjection()
        #expect(injection.header.terminalID == terminalID,
                "the frame must carry its own target, so the app can verify it")
        #expect(injection.bytes == Data("hi\r".utf8))

        courier.acknowledge(
            SidecarInjectionAck(injectionID: injection.header.injectionID, written: true))

        #expect(await delivery.value == .viewerWrote)
        #expect(harness.directWrites.isEmpty,
                "the app said it wrote the bytes, so the daemon must not write them again")
    }

    /// Fail-open, and the branch that can deliver twice. It is meant to.
    /// Also the upper half of the pin on the production deadline: the courier
    /// is default-constructed and the clock advanced by exactly
    /// `HolderInputTiming.injectionAckDeadline`, so a shipped deadline *longer*
    /// than that constant leaves the delivery unresolved and this test hangs
    /// out to the suite's `.clockDriven` bound instead of passing.
    /// `deadlineIsNotReachedEarly` below is the other half. Together they say
    /// the shipped deadline IS the shared constant, which is what makes
    /// `HolderInputTimingTests`' ordering assertion bind this code.
    @Test("A missing ack falls back to a direct write")
    func missingAckFallsBackToADirectWrite() async throws {
        let harness = Harness()
        harness.attachment = 7
        let clock = TestClock<Duration>()
        let courier = harness.makeCourier(clock: clock)

        let delivery = Task { await courier.deliver(terminalID: UUID(), bytes: Data("prompt".utf8)) }
        try await waitFor("the injection frame to reach the sidecar") { harness.frames.count == 1 }

        await clock.advanceWhenSuspended(by: HolderInputTiming.injectionAckDeadline)

        #expect(await delivery.value == .daemonWrote(.ackDeadlineElapsed))
        #expect(harness.directWrites == [Data("prompt".utf8)],
                "an unanswered injection must still reach the child")
    }

    /// The half of the deadline pin that catches the drift direction that is
    /// actually dangerous: a deadline **shorter** than
    /// `HolderInputTiming.injectionAckDeadline`.
    ///
    /// The app parks an injection that arrives mid-paste for
    /// `HolderInputTiming.pasteHoldBound` and answers when the paste closes. If
    /// the daemon gave up first, every parked injection would be written by the
    /// daemon straight into the open paste, between its `ESC[200~`/`ESC[201~`
    /// markers — the harm the app-side hold exists to prevent, made systematic.
    /// `HolderInputTimingTests` asserts the ordering of the two constants; this
    /// asserts the courier actually waits the one it is given.
    ///
    /// An absence, asserted positively: virtual time stops one instant short of
    /// the deadline and the app answers there. A courier that had already given
    /// up would report `.daemonWrote(.ackDeadlineElapsed)` and count the ack as
    /// late, so both readings discriminate — neither can pass by accident.
    @Test("The ack deadline is not reached early")
    func deadlineIsNotReachedEarly() async throws {
        let harness = Harness()
        harness.attachment = 7
        let clock = TestClock<Duration>()
        let courier = harness.makeCourier(clock: clock)

        let delivery = Task { await courier.deliver(terminalID: UUID(), bytes: Data("prompt".utf8)) }
        try await waitFor("the injection frame to reach the sidecar") { harness.frames.count == 1 }
        let injection = try harness.decodeOnlyInjection()

        await clock.advanceWhenSuspended(
            by: HolderInputTiming.injectionAckDeadline - .milliseconds(1))
        courier.acknowledge(
            SidecarInjectionAck(injectionID: injection.header.injectionID, written: true))

        #expect(await delivery.value == .viewerWrote)
        #expect(await courier.lateAcksObserved == 0,
                "the courier gave up before its deadline, so the app's answer arrived late")
        #expect(harness.directWrites.isEmpty,
                "an injection the app acknowledged must not also be written by the daemon")
    }

    /// The plan has only the missing-ack test, and the two are different
    /// mechanisms: this one never waits. An explicit `written: false` is
    /// *trustworthy* — the app reports every refusal it can know synchronously
    /// — so acting on it immediately is what turns a dead panel into a
    /// one-frame delay instead of a five-second one. A courier that merely
    /// logged the `false` would pass the missing-ack test unchanged.
    @Test("An explicit written:false ack falls back to a direct write")
    func explicitlyUnwrittenAckFallsBackToADirectWrite() async throws {
        let harness = Harness()
        harness.attachment = 7
        // A clock that is never advanced: if this path waited for the deadline
        // instead of acting on the ack, the test would hang out to
        // `.clockDriven` rather than pass for the wrong reason.
        let courier = harness.makeCourier(clock: TestClock())

        let delivery = Task { await courier.deliver(terminalID: UUID(), bytes: Data("prompt".utf8)) }
        try await waitFor("the injection frame to reach the sidecar") { harness.frames.count == 1 }
        let injection = try harness.decodeOnlyInjection()

        courier.acknowledge(
            SidecarInjectionAck(injectionID: injection.header.injectionID, written: false))

        #expect(await delivery.value == .daemonWrote(.viewerReportedNothingWritten))
        #expect(harness.directWrites == [Data("prompt".utf8)])
    }

    /// Pins the duplicate as **intended**. The only correct handling of "we may
    /// have written twice" is to let both land visibly, so a late ack must not
    /// retract, dedupe or re-resolve anything — it is counted and dropped.
    @Test("A slow ack that arrives after the fallback is not suppressed")
    func lateAckIsObservedAndNotSuppressed() async throws {
        let harness = Harness()
        harness.attachment = 7
        let clock = TestClock<Duration>()
        let courier = harness.makeCourier(clock: clock)

        let delivery = Task { await courier.deliver(terminalID: UUID(), bytes: Data("prompt".utf8)) }
        try await waitFor("the injection frame to reach the sidecar") { harness.frames.count == 1 }
        let injection = try harness.decodeOnlyInjection()

        await clock.advanceWhenSuspended(by: HolderInputTiming.injectionAckDeadline)
        #expect(await delivery.value == .daemonWrote(.ackDeadlineElapsed))
        #expect(harness.directWrites.count == 1)

        // …and only now does the app's answer arrive, saying it wrote the bytes
        // too. The session has them twice, and that is the accepted cost.
        courier.acknowledge(
            SidecarInjectionAck(injectionID: injection.header.injectionID, written: true))
        try await waitFor("the late ack to be recorded") { await courier.lateAcksObserved == 1 }

        #expect(harness.directWrites.count == 1,
                "a late ack must not cause a second write either")
        #expect(await courier.lateAcksObserved == 1)
    }

    // MARK: - The sidecar's own failures

    @Test("An injection that cannot reach the app is written directly, without waiting")
    func undeliverableFrameFallsBackImmediately() async throws {
        let harness = Harness()
        harness.attachment = 7
        harness.sendFrameError = SidecarGone()
        // Never advanced: reaching the deadline for a frame that was never sent
        // would be five wasted seconds on every send to a dead sidecar.
        let courier = harness.makeCourier(clock: TestClock())

        let outcome = await courier.deliver(terminalID: UUID(), bytes: Data("prompt".utf8))

        #expect(outcome == .daemonWrote(.viewerFrameUndeliverable))
        #expect(harness.directWrites == [Data("prompt".utf8)])
    }

    /// What this pins is narrower than the gap it describes: **a
    /// `writeDirectly` failure is propagated as `.notDelivered`, with a reason
    /// the caller can read, rather than swallowed**. The harness injects its
    /// own throwing `writeDirectly`, so the daemon's real descriptor ownership
    /// is not under test here and this test stays green whatever that
    /// ownership becomes — it is not a tripwire for the gap.
    ///
    /// The gap itself: once a viewer has acknowledged an attach the daemon has
    /// released its reader and closed its descriptor, so the fail-open branch
    /// has nothing to write to. Nothing is lost *silently* — the caller is
    /// told and `performHolderSend` records a transport failure — but the
    /// fallback is not yet a write.
    ///
    /// **`Daemon.swift`'s `writeDirectly` closure is covered by no test.** The
    /// registry-level fact it rests on — an acknowledged attach leaves the
    /// daemon with no reader for that session — is pinned live, in
    /// `HolderAttachHandoffTests` ("the daemon kept a reader for a session it
    /// no longer reads"). That is the assertion a write-only dup across an
    /// attach would have to be reconciled with; it is not this one.
    @Test("With no descriptor and no viewer answer, nothing is written and the caller is told")
    func fallbackWithNoDaemonDescriptorReportsFailure() async throws {
        let harness = Harness()
        harness.attachment = 7
        harness.directWriteError = NoDescriptor()
        let clock = TestClock<Duration>()
        let courier = harness.makeCourier(clock: clock)

        let delivery = Task { await courier.deliver(terminalID: UUID(), bytes: Data("prompt".utf8)) }
        try await waitFor("the injection frame to reach the sidecar") { harness.frames.count == 1 }
        await clock.advanceWhenSuspended(by: HolderInputTiming.injectionAckDeadline)

        guard case .notDelivered(let reason) = await delivery.value else {
            Issue.record(
                UnexpectedDelivery(
                    expected: "a reported failure, not a silent drop",
                    actual: await delivery.value))
            return
        }
        #expect(reason.contains("nothing was typed"))
        #expect(harness.directWrites.isEmpty)
    }

    // MARK: - The wire format

    @Test("An injection frame and its ack round-trip")
    func injectionFramesRoundTrip() throws {
        let header = SidecarInjectionHeader(terminalID: UUID(), injectionID: UUID())
        let bytes = Data("<tbd-dispatch id=\"a\" from=\"b\"/>\nhello\r".utf8)
        let scanner = SidecarFrameScanner()

        let frames = scanner.append(
            try SidecarFrameCodec.encodeInjection(header: header, bytes: bytes)
                + SidecarFrameCodec.encodeInjectionAck(
                    SidecarInjectionAck(injectionID: header.injectionID, written: true)))

        #expect(frames.count == 2)
        #expect(SidecarFrameType(rawValue: frames[0].type) == .injection)
        let decoded = try SidecarFrameCodec.decodeInjection(payload: frames[0].payload)
        #expect(decoded.header == header)
        #expect(decoded.bytes == bytes)
        #expect(SidecarFrameType(rawValue: frames[1].type) == .injectionAck)
        let ack = try SidecarFrameCodec.decodeInjectionAck(payload: frames[1].payload)
        #expect(ack == SidecarInjectionAck(injectionID: header.injectionID, written: true))
    }

    /// The framing half of the forward-compat seam: an unknown type byte is
    /// **returned to the caller**, not swallowed and not read as corruption,
    /// so the receive loop is what gets to decide about it.
    ///
    /// A hand-built raw byte, because the enum is exactly what a peer from the
    /// future does not have — and because encoding two *known* types asserts
    /// nothing here at all: `append` never reads the type byte, so the scanner
    /// is type-agnostic by construction. The other half, the loop that skips
    /// the frame and keeps reading, is pinned in
    /// `HolderInjectionDeliveryTests.unknownFrameTypeIsSkippedByTheReceiveLoop`
    /// — it lives in `FDSidecarClient.receiveLoop` and
    /// `FDVendingServer.startReceiveThread`, and no scanner-level test can
    /// reach it.
    @Test("An unknown frame type is handed back by the scanner rather than desyncing it")
    func unknownFrameTypeIsReturnedNotDesynced() {
        let scanner = SidecarFrameScanner()
        // [UInt32 LE length = 1 + payload][type 99][payload]
        var wire = Data([0x03, 0x00, 0x00, 0x00, 99, 0x01, 0x02])
        wire += SidecarFrameCodec.encode(type: .injection, payload: Data([0x03]))

        let frames = scanner.append(wire)

        #expect(frames.count == 2)
        #expect(frames.first?.type == 99,
                "an unknown type must reach the caller, which is what decides to skip it")
        #expect(frames.first?.payload == Data([0x01, 0x02]))
        #expect(!scanner.isDesynced)
    }

    /// The cap the injection path had none of. Over it, nothing is framed and
    /// nothing is written: a frame past the app scanner's 4 MiB hard cap is
    /// read there as corruption and closes the sidecar, which takes every
    /// pane's control-mode input with it.
    ///
    /// The at-cap control on the same path is what makes the refusal evidence
    /// rather than a panel that refuses everything.
    @Test("An injection past the frame cap is refused, and one at the cap is not")
    func oversizeInjectionIsRefusedAtTheCap() async throws {
        let harness = Harness()
        harness.attachment = 7
        let courier = harness.makeCourier(clock: TestClock())
        let overCap = Data(
            repeating: 0x61, count: HolderInjectionCourier.maxInjectionBytes + 1)

        let outcome = await courier.deliver(terminalID: UUID(), bytes: overCap)

        guard case .notDelivered(let reason) = outcome else {
            Issue.record(
                UnexpectedDelivery(expected: "a refusal naming the cap", actual: outcome))
            return
        }
        #expect(reason.contains("nothing was typed"))
        #expect(harness.frames.isEmpty, "an over-cap payload must never reach the sidecar")
        #expect(harness.directWrites.isEmpty)

        // At the cap, the same call frames and sends as usual.
        let atCap = Data(repeating: 0x61, count: HolderInjectionCourier.maxInjectionBytes)
        let delivery = Task { await courier.deliver(terminalID: UUID(), bytes: atCap) }
        try await waitFor("the at-cap injection to reach the sidecar") {
            harness.frames.count == 1
        }
        let injection = try harness.decodeOnlyInjection()
        courier.acknowledge(
            SidecarInjectionAck(injectionID: injection.header.injectionID, written: true))
        #expect(await delivery.value == .viewerWrote)
    }
}
