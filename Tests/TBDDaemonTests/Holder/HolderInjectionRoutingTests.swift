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

        func makeCourier(
            ackDeadline: Duration = .seconds(5), clock: any Clock<Duration>
        ) -> HolderInjectionCourier {
            HolderInjectionCourier(
                sendFrame: { [self] frame in
                    if let sendFrameError { throw sendFrameError }
                    lock.withLock { sentFrames.append(frame) }
                },
                viewerAttachment: { [self] _ in attachment },
                writeDirectly: { [self] _, bytes in
                    if let directWriteError { throw directWriteError }
                    lock.withLock { writes.append(bytes) }
                },
                ackDeadline: ackDeadline,
                clock: clock)
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
    @Test("A missing ack falls back to a direct write")
    func missingAckFallsBackToADirectWrite() async throws {
        let harness = Harness()
        harness.attachment = 7
        let clock = TestClock<Duration>()
        let courier = harness.makeCourier(ackDeadline: .seconds(5), clock: clock)

        let delivery = Task { await courier.deliver(terminalID: UUID(), bytes: Data("prompt".utf8)) }
        try await waitFor("the injection frame to reach the sidecar") { harness.frames.count == 1 }

        await clock.advanceWhenSuspended(by: .seconds(5))

        #expect(await delivery.value == .daemonWrote(.ackDeadlineElapsed))
        #expect(harness.directWrites == [Data("prompt".utf8)],
                "an unanswered injection must still reach the child")
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
        let courier = harness.makeCourier(ackDeadline: .seconds(5), clock: TestClock())

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
        let courier = harness.makeCourier(ackDeadline: .seconds(5), clock: clock)

        let delivery = Task { await courier.deliver(terminalID: UUID(), bytes: Data("prompt".utf8)) }
        try await waitFor("the injection frame to reach the sidecar") { harness.frames.count == 1 }
        let injection = try harness.decodeOnlyInjection()

        await clock.advanceWhenSuspended(by: .seconds(5))
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

    /// The honest statement of a gap this task does not close: while a viewer
    /// owns the pty the daemon has released its reader and closed its
    /// descriptor, so there is nothing for the fail-open branch to write to.
    /// Nothing is lost *silently* — the caller is told, and
    /// `performHolderSend` records a transport failure — but the fallback is
    /// not yet a write. This test is what will fail, loudly and by name, when
    /// the daemon keeps a write-only dup across an attach.
    @Test("With no descriptor and no viewer answer, nothing is written and the caller is told")
    func fallbackWithNoDaemonDescriptorReportsFailure() async throws {
        let harness = Harness()
        harness.attachment = 7
        harness.directWriteError = NoDescriptor()
        let clock = TestClock<Duration>()
        let courier = harness.makeCourier(ackDeadline: .seconds(5), clock: clock)

        let delivery = Task { await courier.deliver(terminalID: UUID(), bytes: Data("prompt".utf8)) }
        try await waitFor("the injection frame to reach the sidecar") { harness.frames.count == 1 }
        await clock.advanceWhenSuspended(by: .seconds(5))

        guard case .notDelivered(let reason) = await delivery.value else {
            Issue.record("expected a reported failure, not a silent drop")
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

    /// The forward-compat seam the new cases rely on: a peer that has never
    /// heard of type 4 or 5 must skip the frame and keep reading, not desync.
    @Test("An unknown frame type does not desync the scanner")
    func unknownFrameTypeIsSkippedNotDesynced() {
        let scanner = SidecarFrameScanner()
        let frames = scanner.append(
            SidecarFrameCodec.encode(type: .injection, payload: Data([0x01, 0x02]))
                + SidecarFrameCodec.encode(type: .fdVend, payload: Data([0x03])))

        #expect(frames.count == 2)
        #expect(!scanner.isDesynced)
    }
}
