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
        let messages = [
            ChatMessage(role: .user, text: "hello", timestamp: Date()),
            ChatMessage(role: .assistant, text: "hi there", timestamp: Date()),
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
}
