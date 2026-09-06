import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Shape validation for the parts payload. Every malformed combination is
/// rejected BEFORE a row exists, the line `RPCRouter+Actuation.swift` already
/// draws: a row must not be written for a request that was never about to be
/// dispatched.
@Suite("terminal.send parts shape")
struct TerminalSendPartsShapeTests {
    private let terminalID = UUID()

    @Test func aPartsPayloadValidates() throws {
        let shape = RPCRouter.validateSendShape(TerminalSendParams(
            terminalID: terminalID, submit: true,
            parts: [.text("look at "), .imagePath("/tmp/a.png")]))
        guard case .valid(.parts(let parts, let submit)) = shape else {
            Issue.record("expected a valid parts payload, got \(shape)")
            return
        }
        #expect(parts.count == 2)
        #expect(submit)
    }

    @Test func partsAndTextTogetherAreMalformed() {
        let shape = RPCRouter.validateSendShape(TerminalSendParams(
            terminalID: terminalID, text: "hi", parts: [.text("hi")]))
        guard case .malformed(let message) = shape else {
            Issue.record("expected malformed, got \(shape)")
            return
        }
        #expect(message.contains("exactly one payload"))
    }

    @Test func partsAndKeysTogetherAreMalformed() {
        let shape = RPCRouter.validateSendShape(TerminalSendParams(
            terminalID: terminalID, keys: "Escape", parts: [.text("hi")]))
        guard case .malformed = shape else {
            Issue.record("expected malformed, got \(shape)")
            return
        }
    }

    @Test func anEmptyPartsListIsMalformed() {
        let shape = RPCRouter.validateSendShape(TerminalSendParams(
            terminalID: terminalID, submit: true, parts: []))
        guard case .malformed(let message) = shape else {
            Issue.record("expected malformed, got \(shape)")
            return
        }
        #expect(message.contains("at least one"))
    }

    /// A parts payload that is nothing but empty text names no act: every part
    /// is skipped at delivery, so it would press Enter on a composer nobody
    /// typed into.
    @Test func partsThatAreAllEmptyTextAreMalformed() {
        let shape = RPCRouter.validateSendShape(TerminalSendParams(
            terminalID: terminalID, submit: true, parts: [.text(""), .text("  ")]))
        guard case .malformed = shape else {
            Issue.record("expected malformed, got \(shape)")
            return
        }
    }

    /// An image part must name an absolute path. A relative one would resolve
    /// against whatever directory the receiving session happens to be in.
    @Test func aRelativeImagePathIsMalformed() {
        let shape = RPCRouter.validateSendShape(TerminalSendParams(
            terminalID: terminalID, submit: true, parts: [.imagePath("a.png")]))
        guard case .malformed(let message) = shape else {
            Issue.record("expected malformed, got \(shape)")
            return
        }
        #expect(message.contains("absolute"))
    }

    /// `--verify` re-reads a pane for one delivered payload; a multi-part send
    /// has no single payload to look for. Refused rather than silently
    /// downgraded, per the never-answer-a-request-for-evidence-with-silence rule.
    @Test func verifyWithPartsIsMalformed() {
        let shape = RPCRouter.validateSendShape(TerminalSendParams(
            terminalID: terminalID, submit: true, verify: true, parts: [.text("hi")]))
        guard case .malformed(let message) = shape else {
            Issue.record("expected malformed, got \(shape)")
            return
        }
        #expect(message.contains("--verify"))
    }

    /// The old shapes are untouched. Without this the suite could go green on a
    /// validator that rejects everything.
    @Test func theExistingShapesStillValidate() {
        guard case .valid(.text) = RPCRouter.validateSendShape(
            TerminalSendParams(terminalID: terminalID, text: "hi", submit: true)) else {
            Issue.record("a plain text send must still validate")
            return
        }
        guard case .valid(.keys) = RPCRouter.validateSendShape(
            TerminalSendParams(terminalID: terminalID, keys: "Escape")) else {
            Issue.record("a keys send must still validate")
            return
        }
    }

    @Test func theRecordedMessageNamesEveryPart() {
        let payload = TerminalSendPayload.parts(
            [.text("look at "), .imagePath("/tmp/a.png")], submit: true)
        #expect(payload.recordedMessage.contains("look at "))
        #expect(payload.recordedMessage.contains("/tmp/a.png"))
        #expect(payload.recordedSubmit == true)
        #expect(payload.recordedVerify == nil)
        #expect(!payload.isVerifyArmed)
    }
}
