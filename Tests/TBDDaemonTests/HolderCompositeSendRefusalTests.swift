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
