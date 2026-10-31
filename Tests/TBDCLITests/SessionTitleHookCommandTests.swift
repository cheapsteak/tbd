import Foundation
import Testing
@testable import TBDCLI
import TBDShared

@Suite struct SessionTitleHookCommandTests {
    @Test("a title becomes exactly the UserPromptSubmit hook output")
    func hookOutputEncodesTheTitle() {
        let output = SessionTitleHookCommand.hookOutput(sessionTitle: #"Acme "checkout" \ flow · 2"#)

        #expect(output == #"{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"Acme \"checkout\" \\ flow · 2"}}"#)
    }

    @Test("no title, an empty one, an empty success or a failure prints nothing")
    func noTitlePrintsNothing() throws {
        #expect(SessionTitleHookCommand.hookOutput(sessionTitle: nil) == nil)
        #expect(SessionTitleHookCommand.hookOutput(sessionTitle: "") == nil)

        let untitled = try RPCResponse(result: TerminalSessionTitleResult(sessionTitle: nil))
        #expect(SessionTitleHookCommand.title(from: untitled) == nil)
        // An unknown terminal answers with an empty success.
        #expect(SessionTitleHookCommand.title(from: .ok()) == nil)
        #expect(SessionTitleHookCommand.title(from: RPCResponse(error: "boom")) == nil)

        let titled = try RPCResponse(result: TerminalSessionTitleResult(sessionTitle: "acme"))
        #expect(SessionTitleHookCommand.title(from: titled) == "acme")
    }

    @Test("the incarnation is read only from a valid environment UUID")
    func parsesTheIncarnation() {
        let incarnationID = UUID()

        #expect(SessionTitleHookCommand.sessionIncarnationID(environment: [
            "TBD_TERMINAL_INCARNATION_ID": incarnationID.uuidString,
        ]) == incarnationID)
        #expect(SessionTitleHookCommand.sessionIncarnationID(environment: [:]) == nil)
        #expect(SessionTitleHookCommand.sessionIncarnationID(environment: [
            "TBD_TERMINAL_INCARNATION_ID": "not-a-uuid",
        ]) == nil)
    }

    @Test("tbd hooks session-title parses to the session-title command")
    func hooksParsesSessionTitle() throws {
        #expect(try TBDCommand.parseAsRoot(["hooks", "session-title"]) is SessionTitleHookCommand)
    }
}
