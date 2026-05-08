import Foundation
import Testing

@testable import TBDApp

@Suite("AskUserQuestionParser")
struct AskUserQuestionParserTests {
    // MARK: - parseAnswers

    @Test func parses_single_question_answer_pair() {
        let text = #"User has answered your questions: "Which shape of reflection should we commit to for Phase 1?"="C". You can now continue with the user's answers in mind."#
        let parsed = AskUserQuestionParser.parseAnswers(from: text)
        #expect(parsed.count == 1)
        #expect(parsed.first?.question == "Which shape of reflection should we commit to for Phase 1?")
        #expect(parsed.first?.answer == "C")
    }

    @Test func parses_multiple_question_answer_pairs() {
        let text = #"User has answered your questions: "Q1 text"="A1". "Q2 text"="A2". You can now continue with the user's answers in mind."#
        let parsed = AskUserQuestionParser.parseAnswers(from: text)
        #expect(parsed.count == 2)
        #expect(parsed[0].question == "Q1 text")
        #expect(parsed[0].answer == "A1")
        #expect(parsed[1].question == "Q2 text")
        #expect(parsed[1].answer == "A2")
    }

    @Test func returns_empty_for_unrecognized_text() {
        let parsed = AskUserQuestionParser.parseAnswers(from: "totally unrelated text")
        #expect(parsed.isEmpty)
    }
}

@Suite("AskUserQuestionParser.match")
struct AskUserQuestionMatchTests {
    private let options: [AskUserQuestionCard.Option] = [
        .init(label: "A. Always reflect, one retry (Recommended)", description: nil),
        .init(label: "B. Gated reflect, one retry", description: nil),
        .init(label: "C. Loop until satisfied or budget", description: nil),
        .init(label: "D. Defer reflection to Phase 2", description: nil),
    ]

    @Test func letter_shorthand_matches() {
        let m = AskUserQuestionParser.match(answer: "C", options: options, multiSelect: false)
        #expect(m.selectedIndices == [2])
        #expect(m.freeformAnswer == nil)
    }

    @Test func full_label_matches() {
        let answer = "C. Loop until satisfied or budget"
        let m = AskUserQuestionParser.match(answer: answer, options: options, multiSelect: false)
        #expect(m.selectedIndices == [2])
        #expect(m.freeformAnswer == nil)
    }

    @Test func freeform_answer_returns_no_match_with_text() {
        let answer = "explain to me semantically the differences between these options with some handholding"
        let m = AskUserQuestionParser.match(answer: answer, options: options, multiSelect: false)
        #expect(m.selectedIndices.isEmpty)
        #expect(m.freeformAnswer == answer)
    }

    @Test func multi_select_comma_separated_matches_each() {
        let m = AskUserQuestionParser.match(answer: "A, C", options: options, multiSelect: true)
        #expect(m.selectedIndices == [0, 2])
        #expect(m.freeformAnswer == nil)
    }

    @Test func nil_answer_returns_empty_match() {
        let m = AskUserQuestionParser.match(answer: nil, options: options, multiSelect: false)
        #expect(m.selectedIndices.isEmpty)
        #expect(m.freeformAnswer == nil)
    }

    // The spec mentions matching the full label for an option without a
    // leading-letter prefix. Verify we still match plain labels.
    @Test func plain_label_without_letter_prefix_matches() {
        let opts: [AskUserQuestionCard.Option] = [
            .init(label: "Retry count cap (e.g., max 2 follow-up cycles) (Recommended)", description: nil),
            .init(label: "No cap", description: nil),
        ]
        let answer = "Retry count cap (e.g., max 2 follow-up cycles) (Recommended)"
        let m = AskUserQuestionParser.match(answer: answer, options: opts, multiSelect: false)
        #expect(m.selectedIndices == [0])
    }
}
