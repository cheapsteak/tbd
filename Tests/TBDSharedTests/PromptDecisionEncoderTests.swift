import Foundation
import Testing
@testable import TBDShared

/// Pins `PromptDecisionEncoder` to the decision shapes measured against the
/// real Claude Code TUI (design 2026-10-09, "Facts this design rests on").
/// Compared as parsed dictionaries, never as strings: key order is not part of
/// the contract.
@Suite("PromptDecisionEncoder")
struct PromptDecisionEncoderTests {
    private let askInput = #"{"questions":[{"header":"Env","multiSelect":false,"options":[{"label":"staging"},{"label":"production"}],"question":"Which environment?"},{"header":"Checks","multiSelect":true,"options":[{"label":"lint"},{"label":"tests"}],"question":"Which checks?"}]}"#

    private func decision(_ answer: PromptAnswer, _ kind: PendingPromptKind, input: String = "{}",
                          suggestions: String? = nil) throws -> NSDictionary {
        NSDictionary(dictionary: try PromptDecisionEncoder.decisionObject(
            answer: answer, kind: kind, toolInputJSON: input, suggestionsJSON: suggestions))
    }

    @Test func questionCarriesOriginalQuestionsAndAnswers() throws {
        let d = try decision(
            .question(answers: ["Which environment?": "staging", "Which checks?": "lint, tests"]),
            .question, input: askInput)
        #expect(d["behavior"] as? String == "allow")
        let updated = try #require(d["updatedInput"] as? [String: Any])
        let original = try #require(try JSONSerialization.jsonObject(with: Data(askInput.utf8)) as? [String: Any])
        #expect(NSArray(array: updated["questions"] as? [Any] ?? [])
                == NSArray(array: original["questions"] as? [Any] ?? []))
        #expect(updated["answers"] as? [String: String]
                == ["Which environment?": "staging", "Which checks?": "lint, tests"])
        #expect(Set(updated.keys) == ["questions", "answers"])
    }

    @Test func freeTextIsAcceptedAsAValue() throws {
        let d = try decision(
            .question(answers: ["Which environment?": "a canary box", "Which checks?": "lint"]),
            .question, input: askInput)
        #expect((d["updatedInput"] as? [String: Any])?["answers"] as? [String: String]
                == ["Which environment?": "a canary box", "Which checks?": "lint"])
    }

    @Test func anUnansweredQuestionIsRefusedNotDropped() {
        #expect(throws: PromptAnswerValidation.missingAnswer(question: "Which checks?")) {
            _ = try PromptDecisionEncoder.decisionObject(
                answer: .question(answers: ["Which environment?": "staging"]),
                kind: .question, toolInputJSON: askInput, suggestionsJSON: nil)
        }
    }

    @Test func allowIsBare() throws {
        #expect(try decision(.permission(decision: .allow, message: nil), .permission) == ["behavior": "allow"])
    }

    @Test func allowIgnoresAMessage() throws {
        #expect(try decision(.permission(decision: .allow, message: "why"), .permission) == ["behavior": "allow"])
    }

    @Test func allowAlwaysForcesSessionDestination() throws {
        let s = #"[{"type":"addDirectories","directories":["/w"],"destination":"localSettings"},{"type":"setMode","mode":"acceptEdits","destination":"userSettings"}]"#
        let d = try decision(.permission(decision: .allowAlways, message: nil), .permission, suggestions: s)
        #expect(d["behavior"] as? String == "allow")
        let perms = try #require(d["updatedPermissions"] as? [[String: Any]])
        #expect(perms.count == 2)
        #expect(perms.allSatisfy { $0["destination"] as? String == "session" })
        #expect(perms[0]["type"] as? String == "addDirectories")
        #expect(perms[0]["directories"] as? [String] == ["/w"])
        #expect(perms[1]["type"] as? String == "setMode")
        #expect(perms[1]["mode"] as? String == "acceptEdits")
    }

    @Test func denyCarriesMessageAndNeverInterrupts() throws {
        let d = try decision(.permission(decision: .deny, message: "use the staging box"), .permission)
        #expect(d == ["behavior": "deny", "message": "use the staging box"])
    }

    @Test func denyWithoutMessageUsesTheDefault() throws {
        for message in [nil, "", "  "] as [String?] {
            let d = try decision(.permission(decision: .deny, message: message), .permission)
            #expect(d == ["behavior": "deny", "message": "The user declined this from TBD."])
            #expect(d["interrupt"] == nil)
        }
        #expect(PromptDecisionEncoder.defaultDenyMessage == "The user declined this from TBD.")
    }

    @Test func hookOutputWrapsTheDecision() throws {
        let out = try PromptDecisionEncoder.hookOutput(
            answer: .permission(decision: .allow, message: nil), kind: .permission,
            toolInputJSON: "{}", suggestionsJSON: nil)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(Set(root.keys) == ["hookSpecificOutput"])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(Set(specific.keys) == ["hookEventName", "decision"])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect(NSDictionary(dictionary: specific["decision"] as? [String: Any] ?? [:]) == ["behavior": "allow"])
        #expect(!out.contains("\n"), "one line: the hook prints it verbatim")
    }

    @Test func hookOutputStaysOneLineWhenTheMessageHasNewlines() throws {
        let out = try PromptDecisionEncoder.hookOutput(
            answer: .permission(decision: .deny, message: "first\nsecond"), kind: .permission,
            toolInputJSON: "{}", suggestionsJSON: nil)
        #expect(!out.contains("\n"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let decision = (root["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["message"] as? String == "first\nsecond")
    }

    @Test func allowAlwaysWithoutSuggestionsIsRefused() {
        #expect(throws: PromptAnswerValidation.allowAlwaysWithoutSuggestions) {
            _ = try PromptDecisionEncoder.decisionObject(
                answer: .permission(decision: .allowAlways, message: nil), kind: .permission,
                toolInputJSON: "{}", suggestionsJSON: nil)
        }
        #expect(throws: PromptAnswerValidation.allowAlwaysWithoutSuggestions) {
            _ = try PromptDecisionEncoder.hookOutput(
                answer: .permission(decision: .allowAlways, message: nil), kind: .permission,
                toolInputJSON: "{}", suggestionsJSON: "[]")
        }
    }

    @Test func aKindMismatchIsRefused() {
        #expect(throws: PromptAnswerValidation.kindMismatch) {
            _ = try PromptDecisionEncoder.decisionObject(
                answer: .permission(decision: .allow, message: nil), kind: .question,
                toolInputJSON: askInput, suggestionsJSON: nil)
        }
    }
}
