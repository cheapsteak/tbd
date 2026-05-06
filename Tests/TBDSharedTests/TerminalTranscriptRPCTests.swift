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
    }

    @Test func fullBody_result_codable_roundtrip() throws {
        let original = TerminalTranscriptItemFullBodyResult(text: "complete content")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalTranscriptItemFullBodyResult.self, from: data)
        #expect(decoded.text == "complete content")
    }
}
