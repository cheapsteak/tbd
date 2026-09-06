import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Until bracketed-paste wrapping lands on the holder arm (PR #816), a
/// multi-line or multi-part message to a holder-backed session is refused BY
/// NAME rather than delivered and silently lost.
///
/// The measurement behind it, against 2.1.261 under a real pty: a single
/// unwrapped write of 63 bytes submits, and a write of 64 bytes or more does not
/// — the tokenizer splits control bytes into key events only while the pending
/// chunk is under 64 bytes, so past that the carriage return is swallowed into
/// the text and the whole string sits unsent in Claude's composer. Several
/// deliveries instead of one would reopen the at-least-once and routing
/// questions that one delivery avoids, so refusing is the honest answer.
@Suite("holder composite send refusal")
struct HolderCompositeSendRefusalTests {

    @Test func aPartsSendToAHolderRowIsRefused() async throws {
        let harness = try await SendHarness.make(transport: .holder)
        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [.text("a"), .imagePath("/tmp/a.png")]),
            actor: .app)

        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("pty-holder"))
        #expect(error.contains("more than one part"))
    }

    @Test func aMultiLineTextSendToAHolderRowIsRefused() async throws {
        let harness = try await SendHarness.make(transport: .holder)
        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, text: "line one\nline two", submit: true),
            actor: .app)

        #expect(!response.success)
        #expect(try #require(response.error).contains("newline"))
    }

    /// A single-part, single-line message is exactly what the holder arm can
    /// carry today, and must still go through. Without this the suite could be
    /// green on a refusal that rejects every holder send.
    @Test func aSingleLineTextSendToAHolderRowIsNotRefused() async throws {
        let harness = try await SendHarness.make(transport: .holder)
        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, text: "hello", submit: true),
            actor: .app)
        // A test daemon wires no injection courier, so this reaches the holder
        // arm's own "no input path" refusal rather than succeeding — which is
        // the point: it got PAST this rail.
        let error = response.error ?? ""
        #expect(!error.contains("more than one part"))
        #expect(!error.contains("newline"))
    }

    /// A single-part `.parts` payload is exactly the remainder that reaches
    /// `performHolderSend`'s `.parts` arm once the composite gate above has
    /// turned away anything bigger — and Fix round 1's ruling is that a single
    /// text part is delivered the same way `--text` delivers a body. Modeled on
    /// `aSingleLineTextSendToAHolderRowIsNotRefused`: SendHarness wires a real
    /// (test-only) injection courier here, so this asserts the exact bytes
    /// delivered rather than only "got past the gate".
    @Test func aSinglePartTextSendToAHolderRowIsNotRefused() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { recorder.record($0) })
        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true, parts: [.text("hello")]),
            actor: .app)

        let error = response.error ?? ""
        #expect(!error.contains("more than one part"))
        #expect(!error.contains("newline"))
        #expect(!error.contains("parts"))
        #expect(response.success, "error was: \(error)")
        // `actor: .app` against a `.claude` row carries the dispatch envelope,
        // exactly as the `.text` arm's body would — this single-part `.parts`
        // send is deliberately delivered the same way, envelope included.
        #expect(recorder.writes.count == 1)
        let body = String(bytes: try #require(recorder.writes.first), encoding: .utf8) ?? ""
        #expect(body.hasPrefix("<tbd-dispatch"))
        #expect(body.hasSuffix("\nhello\r"))
    }

    /// Same as above for a single image part: delivered as the bare quoted
    /// path — `RPCRouter.quotedImagePath` — the same bytes the tmux arm pastes.
    @Test func aSingleImagePartSendToAHolderRowIsNotRefused() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { recorder.record($0) })
        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true, parts: [.imagePath("/tmp/a.png")]),
            actor: .app)

        let error = response.error ?? ""
        #expect(!error.contains("more than one part"))
        #expect(!error.contains("newline"))
        #expect(!error.contains("parts"))
        #expect(response.success, "error was: \(error)")
        // Same reasoning as the text case: a single-part `.parts` send is
        // delivered exactly as the `.text` arm delivers a body, envelope
        // included — unlike the tmux arm, which never envelopes an image part.
        #expect(recorder.writes.count == 1)
        let body = String(bytes: try #require(recorder.writes.first), encoding: .utf8) ?? ""
        #expect(body.hasPrefix("<tbd-dispatch"))
        #expect(body.hasSuffix("\n'/tmp/a.png'\r"))
    }

    /// A tmux row is untouched by any of it.
    @Test func aTmuxRowStillAcceptsMultiLineAndParts() async throws {
        let harness = try await SendHarness.make(transport: .tmux)
        let multiline = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, text: "line one\nline two", submit: true),
            actor: .app)
        #expect(multiline.success, "error was: \(multiline.error ?? "none")")

        let parts = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [.text("a"), .imagePath("/tmp/a.png")]),
            actor: .app)
        #expect(parts.success, "error was: \(parts.error ?? "none")")
    }
}

/// Collects the bytes `SendHarness`'s stubbed `HolderInjectionCourier` was
/// asked to write, when a test passes `holderDeliveryRecorder`. A lock-guarded
/// class, matching `SendHarness.TmuxDouble`, because the courier's
/// `writeDirectly` closure runs off the test's task.
private final class HolderWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [Data] = []
    var writes: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _writes
    }
    func record(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        _writes.append(bytes)
    }
}
