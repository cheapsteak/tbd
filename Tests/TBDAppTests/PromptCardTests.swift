import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

// Tier 1: the prompt cards' routing and their one measured height. The table
// measures a hosted row ONCE (`TableTranscriptView.measuredHeight`), so a card
// whose delivery state changed its height would overlap the next row. Measured
// like `TranscriptCardAttachmentTests.tallAskMeasuresFullHeight`: the row root
// the table hosts, `.fixedSize`, `TranscriptCardSizing.fittingHeight`.

@MainActor
@Suite("Prompt cards")
struct PromptCardTests {
    typealias Fix = PromptFixtures

    static let twoQuestionInput = #"""
    {"questions":[{"header":"Pick","multiSelect":false,"options":[{"description":"A long description that goes on and on about the trade-offs of this option, long enough to wrap past two lines at the card's width so the line limit is what holds the height still.","label":"A"},{"label":"B"}],"question":"Which?"},{"multiSelect":true,"options":[{"label":"X"},{"description":"short","label":"Y"}],"question":"Features?"}]}
    """#

    static let suggestions =
        #"[{"type":"addDirectories","directories":["/x"],"destination":"localSettings"}]"#

    private func withAppState<T>(_ body: (AppState) throws -> T) throws -> T {
        let suiteName = "prompt-card-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)
        appState.promptAnswers = PromptAnswerController(
            local: { _, _, _ in PromptAnswerResult(outcome: .delivered) },
            remote: { _, _, _, _ in PromptAnswerResult(outcome: .delivered) })
        return try body(appState)
    }

    private func node(_ prompt: PendingPromptPresentation, name: String, input: String) -> TranscriptRenderNode {
        let id = prompt.toolUseID ?? "prompt-\(prompt.promptID)"
        return TranscriptRenderNode(
            id: id,
            kind: .toolCall(id: id, name: name, inputJSON: input, inputTruncatedTo: nil,
                            result: nil, timestamp: Fix.when),
            badgeUsage: nil,
            pendingPrompt: prompt)
    }

    private func height(of node: TranscriptRenderNode, appState: AppState) -> CGFloat {
        let card = AnyView(
            SelectableTranscriptRow(node: node, terminalID: nil)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.transcriptStaticCards, true)
                .environment(\.openTranscriptOverlay, { _ in })
                .environment(appState)
        )
        let host = NSHostingView(rootView: card)
        return TranscriptCardSizing.fittingHeight(
            of: host, width: TranscriptCardSizing.width(forLineFragmentWidth: 680))
    }

    private var questionPrompt: PendingPromptPresentation {
        Fix.local(PendingPromptPayload(
            id: "q1", kind: .question, toolUseID: "toolu_Q", toolName: "AskUserQuestion",
            toolInputJSON: Self.twoQuestionInput, suggestionsJSON: nil, createdAt: Fix.when))
    }

    private var permissionPrompt: PendingPromptPresentation {
        Fix.local(Fix.permissionPayload(suggestionsJSON: Self.suggestions))
    }

    private static let states: [PromptAnswerController.CardState] = [
        .waiting, .sending, .answered(summary: "A; X, Y"), .answeredElsewhere,
        .failed(message: "the prompt's hook is reconnecting; try again", retryable: true),
        .unknownOutcome,
    ]

    // MARK: - Height

    @Test func questionCardHeightIsTheSameInEveryState() throws {
        try withAppState { appState in
            let prompt = questionPrompt
            #expect(prompt.questions.count == 2)
            let row = node(prompt, name: "AskUserQuestion", input: Self.twoQuestionInput)
            var heights: [CGFloat] = []
            for state in Self.states {
                appState.promptAnswers.setStateForTesting(state, for: prompt.promptID)
                heights.append(height(of: row, appState: appState))
            }
            // A draft with every kind of choice made, Other typed in.
            appState.promptAnswers.setStateForTesting(.waiting, for: prompt.promptID)
            appState.promptAnswers.updateDraft(for: prompt.promptID) { draft in
                draft.choose("A", in: prompt.questions[0])
                draft.setOtherText("something", in: prompt.questions[1])
            }
            heights.append(height(of: row, appState: appState))
            // The card held after delivery, from retention.
            var answered = prompt
            answered.phase = .answered(summary: "A; something")
            heights.append(height(of: node(answered, name: "AskUserQuestion", input: Self.twoQuestionInput),
                                  appState: appState))

            let first = try #require(heights.first)
            #expect(first > 100, "the interactive card should measure its questions, got \(first)")
            for (index, value) in heights.enumerated() {
                #expect(abs(value - first) < 0.5, "height \(index) is \(value), expected \(first)")
            }
        }
    }

    @Test func permissionCardHeightIsTheSameWithTheDenyFieldOpen() throws {
        try withAppState { appState in
            let prompt = permissionPrompt
            #expect(prompt.hasSuggestions)
            let row = node(prompt, name: "Bash", input: #"{"command":"touch x"}"#)
            var heights: [CGFloat] = [height(of: row, appState: appState)]
            appState.promptAnswers.updateDraft(for: prompt.promptID) {
                $0.denyReasonOpen = true
                $0.denyReason = "too risky"
            }
            heights.append(height(of: row, appState: appState))
            for state in Self.states {
                appState.promptAnswers.setStateForTesting(state, for: prompt.promptID)
                heights.append(height(of: row, appState: appState))
            }
            var closed = prompt
            closed.phase = .closed
            heights.append(height(of: node(closed, name: "Bash", input: #"{"command":"touch x"}"#),
                                  appState: appState))

            let first = try #require(heights.first)
            #expect(first > 100, "the permission card should measure its preview, got \(first)")
            for (index, value) in heights.enumerated() {
                #expect(abs(value - first) < 0.5, "height \(index) is \(value), expected \(first)")
            }
        }
    }

    @Test func permissionCardHeightDoesNotDependOnTheCommandLength() throws {
        try withAppState { appState in
            let short = Fix.local(Fix.permissionPayload())
            let longCommand = (1...20).map { "echo line \($0)" }.joined(separator: "\n")
            let longInput = try #require(String(
                data: JSONSerialization.data(withJSONObject: ["command": longCommand], options: [.sortedKeys]),
                encoding: .utf8))
            let long = Fix.local(PendingPromptPayload(
                id: "p2", kind: .permission, toolUseID: "toolu_L", toolName: "Bash",
                toolInputJSON: longInput, suggestionsJSON: nil, createdAt: Fix.when))
            let shortHeight = height(of: node(short, name: "Bash", input: #"{"command":"touch x"}"#),
                                     appState: appState)
            let longHeight = height(of: node(long, name: "Bash", input: longInput), appState: appState)
            #expect(abs(shortHeight - longHeight) < 0.5, "the preview box is fixed: \(shortHeight) vs \(longHeight)")
        }
    }

    // MARK: - Routing

    @Test func answerablePermissionIsAHostedCardNotAnActivityRow() {
        let row = node(permissionPrompt, name: "Bash", input: #"{"command":"touch x"}"#)
        #expect(ActivityRowFormatter.presentation(for: row) == nil)
        #expect(permissionPrompt.rendersAsPromptCard)
    }

    @Test func flagOffPermissionStaysTodaysActivityRow() {
        let readOnly = Fix.local(Fix.permissionPayload(), flagOn: false)
        #expect(!readOnly.rendersAsPromptCard)
        let row = node(readOnly, name: "Bash", input: #"{"command":"touch x"}"#)
        #expect(ActivityRowFormatter.presentation(for: row) != nil)
    }

    @Test func readOnlyRemoteCardShowsAttachToAnswer() {
        let remote = PendingPromptPresentation.remote(
            RemotePendingPrompt(id: "r1", kind: .permission, toolName: "Bash",
                                toolInputJSON: #"{"command":"touch x"}"#),
            selection: Fix.selection, capabilities: ["events"], flagOn: true, now: Fix.when)
        #expect(remote.answerability == .readOnly(note: "Attach to answer"))
        #expect(remote.rendersAsPromptCard, "a noted read-only prompt renders as a card to carry its note")
        #expect(PromptCardFooter.resolve(remote, state: .waiting) == .readOnly(note: "Attach to answer"))
    }

    // MARK: - Preview text

    @Test func bashPreviewIsTheCommandCutToSixLines() {
        let command = (1...8).map { "line\($0)" }.joined(separator: "\n")
        let prompt = PendingPromptPresentation.remote(
            RemotePendingPrompt(id: "r1", kind: .permission, toolName: "Bash",
                                toolInputJSON: Self.json(["command": command])),
            selection: Fix.selection, capabilities: [RemoteCapability.answer], flagOn: true, now: Fix.when)
        #expect(PermissionPromptCard.previewText(for: prompt)
                == (1...6).map { "line\($0)" }.joined(separator: "\n") + "…")
    }

    @Test func writePreviewIsThePathThenTheContent() {
        let prompt = PendingPromptPresentation.remote(
            RemotePendingPrompt(id: "r1", kind: .permission, toolName: "Write",
                                toolInputJSON: Self.json(["file_path": "/tmp/a.txt", "content": "hello\nworld"])),
            selection: Fix.selection, capabilities: [RemoteCapability.answer], flagOn: true, now: Fix.when)
        #expect(PermissionPromptCard.previewText(for: prompt) == "/tmp/a.txt\nhello\nworld")
    }

    @Test func otherToolPreviewIsCompactSortedJSON() {
        let prompt = PendingPromptPresentation.remote(
            RemotePendingPrompt(id: "r1", kind: .permission, toolName: "WebFetch",
                                toolInputJSON: #"{ "url" : "https://example.com/x", "prompt" : "p" }"#),
            selection: Fix.selection, capabilities: [RemoteCapability.answer], flagOn: true, now: Fix.when)
        #expect(PermissionPromptCard.previewText(for: prompt) == #"{"prompt":"p","url":"https://example.com/x"}"#)
    }

    @Test func missingInputSaysSo() {
        let prompt = PendingPromptPresentation.remote(
            RemotePendingPrompt(id: "r1", kind: .permission, toolName: "Bash", toolInputTruncated: true),
            selection: Fix.selection, capabilities: [RemoteCapability.answer], flagOn: true, now: Fix.when)
        #expect(PermissionPromptCard.previewText(for: prompt) == PermissionPromptCard.missingInputText)
        #expect(PermissionPromptCard.fullInputText(for: prompt) == PermissionPromptCard.missingInputText)
    }

    private static func json(_ object: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
