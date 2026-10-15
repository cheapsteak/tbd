import Foundation
import Testing
@testable import TBDCLI
import TBDShared

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

    @Test("process incarnation parser accepts only a valid environment UUID")
    func parsesProcessIncarnationIdentity() {
        let incarnationID = UUID()

        #expect(TerminalActivityEventCommand.sessionIncarnationID(environment: [
            "TBD_TERMINAL_INCARNATION_ID": incarnationID.uuidString,
        ]) == incarnationID)
        #expect(TerminalActivityEventCommand.sessionIncarnationID(environment: [:]) == nil)
        #expect(TerminalActivityEventCommand.sessionIncarnationID(environment: [
            "TBD_TERMINAL_INCARNATION_ID": "",
        ]) == nil)
        #expect(TerminalActivityEventCommand.sessionIncarnationID(environment: [
            "TBD_TERMINAL_INCARNATION_ID": "not-a-uuid",
        ]) == nil)
    }

    @Test("hook stdin parsing is explicit")
    func hookStdinParsingIsExplicit() throws {
        let command = try TerminalActivityEventCommand.parse([
            "working", "--read-hook-payload"
        ])

        #expect(command.readHookPayload)
    }

    @Test("session-title flag is explicit and off by default")
    func sessionTitleFlagIsExplicit() throws {
        #expect(try TerminalActivityEventCommand.parse(["working"]).sessionTitle == false)
        #expect(try TerminalActivityEventCommand.parse(["working", "--session-title"]).sessionTitle)
    }

    @Test("a title becomes valid UserPromptSubmit hook output")
    func titleBecomesHookOutput() throws {
        let title = #"Acme "checkout" \ flow · 2"#
        let output = try #require(TerminalActivityEventCommand.hookOutput(sessionTitle: title))

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(Array(object.keys) == ["hookSpecificOutput"])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(specific.count == 2)
        #expect(specific["hookEventName"] as? String == "UserPromptSubmit")
        #expect(specific["sessionTitle"] as? String == title)
        #expect(!output.contains("\n"))
    }

    @Test("no title, or an empty one, prints nothing")
    func noTitleNoOutput() {
        #expect(TerminalActivityEventCommand.hookOutput(sessionTitle: nil) == nil)
        #expect(TerminalActivityEventCommand.hookOutput(sessionTitle: "") == nil)
    }

    @Test("the title is read from a result, and absent from an empty success or a failure")
    func titleFromResponse() throws {
        let titled = try RPCResponse(result: TerminalActivityEventResult(sessionTitle: "acme"))
        #expect(TerminalActivityEventCommand.title(from: titled) == "acme")

        let untitled = try RPCResponse(result: TerminalActivityEventResult(sessionTitle: nil))
        #expect(TerminalActivityEventCommand.title(from: untitled) == nil)

        // An older daemon answers with an empty success.
        #expect(TerminalActivityEventCommand.title(from: .ok()) == nil)
        #expect(TerminalActivityEventCommand.title(from: RPCResponse(error: "boom")) == nil)
    }

    @Test("hook payload reader stops after detecting one byte over the limit")
    func hookPayloadReaderStopsAtOverflowBoundary() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-activity-hook-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x61, count: (1 << 20) + 512).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let payload = TerminalActivityEventCommand.readBoundedHookPayload(from: handle)

        #expect(payload == nil)
        #expect(try handle.offset() == UInt64((1 << 20) + 1))
    }
}
