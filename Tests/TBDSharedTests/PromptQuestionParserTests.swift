import Foundation
import Testing
@testable import TBDShared

@Suite("PromptQuestionParser")
struct PromptQuestionParserTests {

    @Test func parsesAskUserQuestionInput() throws {
        let json = #"{"questions":[{"question":"Which environment?","header":"Env","options":[{"label":"staging","description":"the staging cluster"},{"label":"production"}]},{"question":"Which checks?","header":"Checks","multiSelect":true,"options":[{"label":"lint"},{"label":"tests"}]}]}"#
        let questions = try #require(PromptQuestionParser.questions(fromAskUserQuestionInput: json))
        #expect(questions == [
            PromptQuestion(
                text: "Which environment?", header: "Env", multiSelect: false,
                options: [
                    PromptQuestionOption(label: "staging", description: "the staging cluster"),
                    PromptQuestionOption(label: "production", description: nil),
                ]),
            PromptQuestion(
                text: "Which checks?", header: "Checks", multiSelect: true,
                options: [PromptQuestionOption(label: "lint"), PromptQuestionOption(label: "tests")]),
        ])
    }

    @Test func malformedJSONIsNil() {
        #expect(PromptQuestionParser.questions(fromAskUserQuestionInput: "{not json") == nil)
        #expect(PromptQuestionParser.questions(fromAskUserQuestionInput: #"{"command":"ls"}"#) == nil)
    }

    @Test func noQuestionsIsNil() {
        #expect(PromptQuestionParser.questions(fromAskUserQuestionInput: #"{"questions":[]}"#) == nil)
        #expect(PromptQuestionParser.questions(
            fromAskUserQuestionInput: #"{"questions":[{"header":"no text"}]}"#) == nil)
    }

    @Test func remoteItemsMapToTheSharedShape() {
        let items = [
            RemotePendingQuestionItem(
                prompt: "Which environment?", label: "Env", multi: true,
                options: [RemotePendingQuestionOption(label: "staging", description: "the staging cluster")]),
            RemotePendingQuestionItem(prompt: "Anything else?"),
        ]
        #expect(PromptQuestionParser.questions(fromRemote: items) == [
            PromptQuestion(
                text: "Which environment?", header: "Env", multiSelect: true,
                options: [PromptQuestionOption(label: "staging", description: "the staging cluster")]),
            PromptQuestion(text: "Anything else?", header: nil, multiSelect: false, options: []),
        ])
    }
}

/// The hash that pairs a `PermissionRequest` with its `PreToolUse` note.
@Suite("PromptInputHash")
struct PromptInputHashTests {

    @Test func keyOrderDoesNotChangeTheHash() {
        #expect(PromptInputHash.of(toolInputJSON: #"{"a":1,"b":"x"}"#)
                == PromptInputHash.of(toolInputJSON: #"{"b":"x","a":1}"#))
    }

    @Test func theObjectAndTextFormsAgree() throws {
        let json = #"{"command":"touch /w/a","description":"make a"}"#
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        #expect(PromptInputHash.of(toolInput: object) == PromptInputHash.of(toolInputJSON: json))
    }

    @Test func differentInputsHashDifferently() {
        #expect(PromptInputHash.of(toolInputJSON: #"{"command":"touch a"}"#)
                != PromptInputHash.of(toolInputJSON: #"{"command":"touch b"}"#))
    }

    @Test func aQuestionHashesItsQuestionsAlone() {
        let asked = #"{"questions":[{"question":"Q?","options":[{"label":"A"}]}]}"#
        let answered = #"{"answers":{"Q?":"A"},"questions":[{"question":"Q?","options":[{"label":"A"}]}]}"#
        #expect(PromptInputHash.of(toolName: "AskUserQuestion", toolInputJSON: asked)
                == PromptInputHash.of(toolName: "AskUserQuestion", toolInputJSON: answered))
        // Without the tool-aware subset the two differ: that is the bug.
        #expect(PromptInputHash.of(toolInputJSON: asked) != PromptInputHash.of(toolInputJSON: answered))
    }

    @Test func otherToolsHashTheWholeInput() {
        let a = #"{"command":"ls","answers":{"x":"1"}}"#
        let b = #"{"command":"ls"}"#
        #expect(PromptInputHash.of(toolName: "Bash", toolInputJSON: a)
                != PromptInputHash.of(toolName: "Bash", toolInputJSON: b))
        #expect(PromptInputHash.of(toolName: "Bash", toolInputJSON: b) == PromptInputHash.of(toolInputJSON: b))
    }

    @Test func theHashIsSHA256Hex() {
        let hash = PromptInputHash.of(toolInputJSON: "{}")
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { "0123456789abcdef".contains($0) })
    }
}

/// Wire shapes of the prompt RPCs and the new delta.
@Suite("Prompt RPC wire")
struct PromptRPCWireTests {

    @Test func methodNames() {
        #expect(RPCMethod.promptNote == "prompt.note")
        #expect(RPCMethod.promptRegister == "prompt.register")
        #expect(RPCMethod.promptAwait == "prompt.await")
        #expect(RPCMethod.promptAnswer == "prompt.answer")
        #expect(RPCMethod.remoteAnswer == "remote.answer")
    }

    @Test func registerResultRoundTrips() throws {
        for result in [PromptRegisterResult.registered(promptID: "p-1"),
                       .registered(promptID: "p-2", toolUseID: "toolu_1"), .disabled] {
            let decoded = try JSONDecoder().decode(PromptRegisterResult.self, from: JSONEncoder().encode(result))
            #expect(decoded == result)
        }
    }

    /// An older daemon's reply carries no `toolUseID`; it must still decode.
    @Test func registerResultWithoutToolUseIDDecodes() throws {
        let decoded = try JSONDecoder().decode(
            PromptRegisterResult.self, from: Data(#"{"registered":{"promptID":"p-1"}}"#.utf8))
        #expect(decoded == .registered(promptID: "p-1", toolUseID: nil))
    }

    @Test func awaitResultRoundTrips() throws {
        for result in [PromptAwaitResult.answered(hookOutput: #"{"a":1}"#), .resolvedElsewhere] {
            let decoded = try JSONDecoder().decode(PromptAwaitResult.self, from: JSONEncoder().encode(result))
            #expect(decoded == result)
        }
    }

    @Test func answerParamsCarryTheAnswer() throws {
        let params = PromptAnswerParams(
            terminalID: UUID(), promptID: "p-1", answer: .permission(decision: .deny, message: "no"))
        let decoded = try JSONDecoder().decode(PromptAnswerParams.self, from: JSONEncoder().encode(params))
        #expect(decoded.terminalID == params.terminalID)
        #expect(decoded.promptID == "p-1")
        #expect(decoded.answer == .permission(decision: .deny, message: "no"))

        let remote = RemoteAnswerParams(
            provider: "acme", sessionID: "s-1", promptID: "p-1",
            answer: .question(answers: ["Which environment?": "staging"]))
        let decodedRemote = try JSONDecoder().decode(RemoteAnswerParams.self, from: JSONEncoder().encode(remote))
        #expect(decodedRemote.answer == remote.answer)
        #expect(decodedRemote.sessionID == "s-1")
    }

    @Test func registerParamsDefaultTheReconnectFields() throws {
        let params = PromptRegisterParams(
            terminalID: UUID(), sessionID: "s", toolName: "Bash", toolInputJSON: "{}",
            suggestionsJSON: nil, inputHash: "h")
        let decoded = try JSONDecoder().decode(PromptRegisterParams.self, from: JSONEncoder().encode(params))
        #expect(decoded.knownPromptID == nil)
        #expect(decoded.knownToolUseID == nil)
        #expect(decoded.inputHash == "h")
    }

    @Test func theDeltaRoundTrips() throws {
        let prompt = PendingPromptPayload(
            id: "p-1", kind: .permission, toolUseID: "toolu_01", toolName: "Bash",
            toolInputJSON: #"{"command":"ls"}"#, suggestionsJSON: nil,
            createdAt: Date(timeIntervalSince1970: 1000))
        let delta = StateDelta.terminalPendingPromptsChanged(TerminalPendingPromptsDelta(
            terminalID: UUID(), captures: [], prompts: [prompt], revision: 7))
        let decoded = try JSONDecoder().decode(StateDelta.self, from: JSONEncoder().encode(delta))
        guard case .terminalPendingPromptsChanged(let d) = decoded,
              case .terminalPendingPromptsChanged(let original) = delta else {
            Issue.record("decoded as the wrong case")
            return
        }
        #expect(d == original)
    }
}
