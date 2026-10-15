import Foundation
import Testing
@testable import TBDShared

/// The answer payload both delivery paths share: its validation against a
/// prompt, and its exact wire shape.
@Suite("PromptAnswer validation and wire shape")
struct PromptAnswerValidationTests {
    private let questions = [
        PromptQuestion(text: "Which environment?", header: "Env",
                       options: [PromptQuestionOption(label: "staging"), PromptQuestionOption(label: "production")]),
        PromptQuestion(text: "Which checks?", header: "Checks", multiSelect: true,
                       options: [PromptQuestionOption(label: "lint"), PromptQuestionOption(label: "tests")]),
    ]

    // MARK: - Validation

    @Test func aQuestionAnswerForAPermissionPromptIsAKindMismatch() {
        #expect(throws: PromptAnswerValidation.kindMismatch) {
            try PromptAnswer.question(answers: ["Which environment?": "staging"])
                .validate(kind: .permission, questions: [], hasSuggestions: false)
        }
    }

    @Test func aPermissionAnswerForAQuestionPromptIsAKindMismatch() {
        #expect(throws: PromptAnswerValidation.kindMismatch) {
            try PromptAnswer.permission(decision: .allow, message: nil)
                .validate(kind: .question, questions: questions, hasSuggestions: false)
        }
    }

    @Test func anUnansweredQuestionIsMissing() {
        #expect(throws: PromptAnswerValidation.missingAnswer(question: "Which checks?")) {
            try PromptAnswer.question(answers: ["Which environment?": "staging"])
                .validate(kind: .question, questions: questions, hasSuggestions: false)
        }
    }

    @Test func anEmptyValueCountsAsMissing() {
        #expect(throws: PromptAnswerValidation.missingAnswer(question: "Which environment?")) {
            try PromptAnswer.question(answers: ["Which environment?": "  ", "Which checks?": "lint"])
                .validate(kind: .question, questions: questions, hasSuggestions: false)
        }
    }

    @Test func anAnswerToAQuestionThePromptLacksIsUnknown() {
        #expect(throws: PromptAnswerValidation.unknownQuestion("Which region?")) {
            try PromptAnswer.question(answers: [
                "Which environment?": "staging", "Which checks?": "lint", "Which region?": "east",
            ]).validate(kind: .question, questions: questions, hasSuggestions: false)
        }
    }

    @Test func allowAlwaysWithoutSuggestionsIsRefused() {
        #expect(throws: PromptAnswerValidation.allowAlwaysWithoutSuggestions) {
            try PromptAnswer.permission(decision: .allowAlways, message: nil)
                .validate(kind: .permission, questions: [], hasSuggestions: false)
        }
    }

    @Test func validAnswersPass() throws {
        try PromptAnswer.question(answers: ["Which environment?": "staging", "Which checks?": "lint, tests"])
            .validate(kind: .question, questions: questions, hasSuggestions: false)
        try PromptAnswer.permission(decision: .allowAlways, message: nil)
            .validate(kind: .permission, questions: [], hasSuggestions: true)
        try PromptAnswer.permission(decision: .allow, message: nil)
            .validate(kind: .permission, questions: [], hasSuggestions: false)
        try PromptAnswer.permission(decision: .deny, message: "no")
            .validate(kind: .permission, questions: [], hasSuggestions: false)
    }

    @Test func messagesCarryTheContractCode() {
        let all: [PromptAnswerValidation] = [
            .kindMismatch, .missingAnswer(question: "q"), .unknownQuestion("q"), .allowAlwaysWithoutSuggestions,
        ]
        #expect(all.allSatisfy { $0.message.hasPrefix("invalid_params: ") })
    }

    // MARK: - Wire shape

    private func jsonObject(_ answer: PromptAnswer) throws -> NSDictionary {
        let data = try JSONEncoder().encode(answer)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test func aQuestionAnswerEncodesToTheContractShape() throws {
        let answer = PromptAnswer.question(answers: ["Which environment?": "staging"])
        #expect(try jsonObject(answer) == ["kind": "question", "answers": ["Which environment?": "staging"]])
        let decoded = try JSONDecoder().decode(PromptAnswer.self, from: JSONEncoder().encode(answer))
        #expect(decoded == answer)
    }

    @Test func aPermissionAnswerOmitsANilMessage() throws {
        let answer = PromptAnswer.permission(decision: .allowAlways, message: nil)
        #expect(try jsonObject(answer) == ["kind": "permission", "decision": "allow_always"])
        let decoded = try JSONDecoder().decode(PromptAnswer.self, from: JSONEncoder().encode(answer))
        #expect(decoded == answer)
    }

    @Test func aDenyCarriesItsMessage() throws {
        let answer = PromptAnswer.permission(decision: .deny, message: "not now")
        #expect(try jsonObject(answer) == ["kind": "permission", "decision": "deny", "message": "not now"])
        let decoded = try JSONDecoder().decode(PromptAnswer.self, from: JSONEncoder().encode(answer))
        #expect(decoded == answer)
    }

    @Test func theContractShapeDecodes() throws {
        let json = #"{"kind":"permission","decision":"allow"}"#
        #expect(try JSONDecoder().decode(PromptAnswer.self, from: Data(json.utf8))
                == .permission(decision: .allow, message: nil))
    }

    @Test func anUnknownKindDoesNotDecode() {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(PromptAnswer.self, from: Data(#"{"kind":"mystery"}"#.utf8))
        }
    }

    @Test func anUnknownOutcomeReadsAsUnknown() throws {
        let decoded = try JSONDecoder().decode(
            PromptAnswerResult.self, from: Data(#"{"outcome":"something_new"}"#.utf8))
        #expect(decoded.outcome == .unknown)
        let known = try JSONDecoder().decode(
            PromptAnswerResult.self, from: Data(#"{"outcome":"already_resolved"}"#.utf8))
        #expect(known.outcome == .alreadyResolved)
    }
}
