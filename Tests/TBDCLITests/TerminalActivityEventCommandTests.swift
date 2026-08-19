import Foundation
import Testing
@testable import TBDCLI

@Suite struct TerminalActivityEventCommandTests {
    @Test("hook payload parser extracts session identity")
    func parsesHookSessionIdentity() {
        let data = Data(
            #"{"session_id":"session-current","transcript_path":"/tmp/session.jsonl","hook_event_name":"PermissionRequest"}"#.utf8)

        #expect(TerminalActivityEventCommand.sessionID(fromHookPayload: data) == "session-current")
    }

    @Test("hook payload parser rejects absent, blank, and malformed identity")
    func rejectsInvalidHookSessionIdentity() {
        #expect(TerminalActivityEventCommand.sessionID(
            fromHookPayload: Data(#"{"hook_event_name":"PermissionRequest"}"#.utf8)) == nil)
        #expect(TerminalActivityEventCommand.sessionID(
            fromHookPayload: Data(#"{"session_id":""}"#.utf8)) == nil)
        #expect(TerminalActivityEventCommand.sessionID(
            fromHookPayload: Data("not-json".utf8)) == nil)
        let oversized = Data(
            (#"{"session_id":"session-current","padding":""#
                + String(repeating: "x", count: (1 << 20) + 1)
                + #""}"#).utf8)
        #expect(TerminalActivityEventCommand.sessionID(fromHookPayload: oversized) == nil)
    }

    @Test("hook stdin parsing is explicit")
    func hookStdinParsingIsExplicit() throws {
        let command = try TerminalActivityEventCommand.parse([
            "working", "--read-hook-payload"
        ])

        #expect(command.readHookPayload)
    }
}
