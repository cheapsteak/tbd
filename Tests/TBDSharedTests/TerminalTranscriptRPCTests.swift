import Foundation
import Testing
import TBDShared

@Suite("terminal.transcript RPC types")
struct TerminalTranscriptRPCTests {
    @Test func method_constant() {
        #expect(RPCMethod.terminalTranscript == "terminal.transcript")
    }

    @Test func params_codable_roundtrip() throws {
        let original = TerminalTranscriptParams(terminalID: UUID())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalTranscriptParams.self, from: data)
        #expect(decoded.terminalID == original.terminalID)
    }

    @Test func result_codable_roundtrip_with_messages() throws {
        let messages: [TranscriptItem] = [
            .userPrompt(id: "u1", text: "hello", timestamp: Date()),
            .assistantText(id: "a1", text: "hi there", timestamp: Date()),
        ]
        let original = TerminalTranscriptResult(messages: messages, sessionID: "abc-123")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalTranscriptResult.self, from: data)
        #expect(decoded.messages.count == 2)
        #expect(decoded.sessionID == "abc-123")
    }

    @Test func result_codable_roundtrip_nil_session() throws {
        let original = TerminalTranscriptResult(messages: [], sessionID: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalTranscriptResult.self, from: data)
        #expect(decoded.messages.isEmpty)
        #expect(decoded.sessionID == nil)
    }

    @Test func fullBody_method_constant() {
        #expect(RPCMethod.terminalTranscriptItemFullBody == "terminal.transcriptItemFullBody")
    }

    @Test func fullBody_params_codable_roundtrip() throws {
        let original = TerminalTranscriptItemFullBodyParams(terminalID: UUID(), itemID: "toolu_abc")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalTranscriptItemFullBodyParams.self, from: data)
        #expect(decoded.terminalID == original.terminalID)
        #expect(decoded.itemID == "toolu_abc")
        #expect(decoded.includeBody, "the body is included unless a caller opts out")
    }

    @Test func fullBody_params_roundtrip_metadata_only() throws {
        let original = TerminalTranscriptItemFullBodyParams(
            terminalID: UUID(), itemID: "att-acme", includeBody: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalTranscriptItemFullBodyParams.self, from: data)
        #expect(!decoded.includeBody)
    }

    /// A client predating the field omits it entirely — the daemon must decode
    /// it as the body-carrying request it used to be.
    @Test func fullBody_params_decode_without_includeBody_key_defaults_to_true() throws {
        let id = UUID()
        let json = Data(#"{"terminalID":"\#(id.uuidString)","itemID":"toolu_legacy"}"#.utf8)
        let decoded = try JSONDecoder().decode(TerminalTranscriptItemFullBodyParams.self, from: json)
        #expect(decoded.terminalID == id)
        #expect(decoded.itemID == "toolu_legacy")
        #expect(decoded.includeBody)
    }

    @Test func fullBody_result_codable_roundtrip() throws {
        let original = TerminalTranscriptItemFullBodyResult(text: "complete content")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalTranscriptItemFullBodyResult.self, from: data)
        #expect(decoded.text == "complete content")
        #expect(decoded.attachment == nil)
    }

    @Test func fullBody_result_carries_injection_metadata() throws {
        let original = TerminalTranscriptItemFullBodyResult(
            text: "injected",
            attachment: TranscriptAttachmentMetadata(
                hookName: "PostToolUse:Read", exitCode: 0, durationMs: 12,
                path: "/srv/acme-prod/.github/CLAUDE.md", triggeredBy: "Read deploy.yml"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalTranscriptItemFullBodyResult.self, from: data)
        #expect(decoded.attachment == original.attachment)
        #expect(decoded.attachment?.stderr == nil)
    }

    @Test func attachment_metadata_isEmpty_only_when_every_field_absent() {
        #expect(TranscriptAttachmentMetadata().isEmpty)
        #expect(!TranscriptAttachmentMetadata(exitCode: 0).isEmpty)
        #expect(!TranscriptAttachmentMetadata(triggeredBy: "Read a.swift").isEmpty)
    }

    /// A daemon predating the field omits it entirely — the app must still decode.
    @Test func fullBody_result_decodes_without_attachment_key() throws {
        let json = Data(#"{"text":"legacy daemon"}"#.utf8)
        let decoded = try JSONDecoder().decode(TerminalTranscriptItemFullBodyResult.self, from: json)
        #expect(decoded.text == "legacy daemon")
        #expect(decoded.attachment == nil)
    }
}
