import Clocks
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: pure render-model projections, plus `PromptCardRetention` driven on
// a `TestClock`. Design: docs/specs/2026-10-09-transcript-prompt-answer-design.md,
// "The cards".

enum PromptFixtures {
    static let when = Date(timeIntervalSince1970: 2_000)
    static let terminalID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")

    static let askInput =
        #"{"questions":[{"header":"Pick","multiSelect":false,"options":[{"description":"d","label":"A"},{"label":"B"}],"question":"Which?"}]}"#
    static let suggestions =
        #"[{"type":"addDirectories","directories":["/x"],"destination":"localSettings"},{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#

    static func permissionPayload(id: String = "p1", toolUseID: String? = "toolu_X",
                                  suggestionsJSON: String? = nil) -> PendingPromptPayload {
        PendingPromptPayload(
            id: id, kind: .permission, toolUseID: toolUseID, toolName: "Bash",
            toolInputJSON: #"{"command":"touch x"}"#, suggestionsJSON: suggestionsJSON,
            createdAt: when)
    }

    static func questionPayload(id: String = "q1", toolUseID: String? = "toolu_Q") -> PendingPromptPayload {
        PendingPromptPayload(
            id: id, kind: .question, toolUseID: toolUseID, toolName: "AskUserQuestion",
            toolInputJSON: askInput, suggestionsJSON: nil, createdAt: when)
    }

    static func local(_ payload: PendingPromptPayload, flagOn: Bool = true) -> PendingPromptPresentation {
        .local(payload, terminalID: terminalID, flagOn: flagOn)
    }

    static func toolCall(_ id: String, _ name: String = "Bash", input: String = #"{"command":"touch x"}"#,
                         result: ToolResult? = nil, timestamp: Date? = nil) -> TranscriptItem {
        .toolCall(id: id, name: name, inputJSON: input, inputTruncatedTo: nil,
                  result: result, subagent: nil, timestamp: timestamp)
    }

    static let done = ToolResult(text: "ok", truncatedTo: nil, isError: false)
}

@Suite("Pending prompt presentation")
struct PendingPromptPresentationTests {
    typealias Fix = PromptFixtures

    // MARK: - Answerability

    @Test func flagOffMakesLocalAndRemoteReadOnly() {
        let local = Fix.local(Fix.permissionPayload(), flagOn: false)
        #expect(local.answerability == .readOnly(note: nil))
        #expect(!local.acceptsAnswer)

        let remote = PendingPromptPresentation.remote(
            RemotePendingPrompt(id: "r1", kind: .permission, toolName: "Bash"),
            selection: Fix.selection, capabilities: [RemoteCapability.answer, "events"],
            flagOn: false, now: Fix.when)
        #expect(remote.answerability == .readOnly(note: nil))
    }

    @Test func localPromptWithTheFlagIsAnswerable() {
        let local = Fix.local(Fix.permissionPayload(), flagOn: true)
        #expect(local.answerability == .answerable)
        #expect(local.acceptsAnswer)
        #expect(local.target == .local(terminalID: Fix.terminalID))
    }

    @Test func remoteProviderWithoutAnswerIsReadOnlyWithAttachNote() {
        let remote = PendingPromptPresentation.remote(
            RemotePendingPrompt(id: "r1", kind: .permission, toolName: "Bash"),
            selection: Fix.selection, capabilities: ["events", "send-submit"],
            flagOn: true, now: Fix.when)
        #expect(remote.answerability == .readOnly(note: "Attach to answer"))
        #expect(!remote.acceptsAnswer)
    }

    @Test func remotePromptWithAnswerAndFlagIsAnswerable() {
        let remote = PendingPromptPresentation.remote(
            RemotePendingPrompt(id: "r1", kind: .permission, toolUseID: "toolu_R", toolName: "Bash",
                                toolInputJSON: #"{"command":"ls"}"#, toolInputTruncated: true),
            selection: Fix.selection, capabilities: [RemoteCapability.answer, "events"],
            flagOn: true, now: Fix.when)
        #expect(remote.answerability == .answerable)
        #expect(remote.target == .remote(provider: "acme", sessionID: "s1"))
        #expect(remote.toolInputTruncated)
        #expect(remote.createdAt == Fix.when)
        #expect(remote.seed.toolUseID == "toolu_R")
    }

    // MARK: - Content

    @Test func questionPromptCarriesParsedQuestions() {
        let local = Fix.local(Fix.questionPayload())
        #expect(local.kind == .question)
        #expect(local.questions.map(\.text) == ["Which?"])
        #expect(local.questions.first?.options.map(\.label) == ["A", "B"])

        let remote = PendingPromptPresentation.remote(
            RemotePendingPrompt(
                id: "r2", kind: .question,
                questions: [RemotePendingQuestionItem(
                    prompt: "Ship it?", label: "Ship", multi: true,
                    options: [RemotePendingQuestionOption(label: "Yes")])]),
            selection: Fix.selection, capabilities: [RemoteCapability.answer],
            flagOn: true, now: Fix.when)
        #expect(remote.questions == [PromptQuestion(
            text: "Ship it?", header: "Ship", multiSelect: true,
            options: [PromptQuestionOption(label: "Yes")])])
        #expect(remote.toolName == "AskUserQuestion")
        // No tool_input: the appended row's input re-encodes the questions, so
        // today's AskUserQuestion card can still draw them.
        let reparsed = PromptQuestionParser.questions(fromAskUserQuestionInput: remote.seed.toolInputJSON)
        #expect(reparsed == remote.questions)
    }

    @Test func permissionPromptCarriesSuggestionLines() {
        let with = Fix.local(Fix.permissionPayload(suggestionsJSON: Fix.suggestions))
        #expect(with.suggestionLines == ["adds directory /x", "switches to acceptEdits"])
        #expect(with.hasSuggestions)
        #expect(with.questions.isEmpty)

        let without = Fix.local(Fix.permissionPayload())
        #expect(without.suggestionLines.isEmpty)
        #expect(!without.hasSuggestions)
    }

    // MARK: - Render nodes

    @Test func pendingPromptChangesContentVersion() {
        let item = Fix.toolCall("toolu_X")
        let prompt = Fix.local(Fix.permissionPayload())
        let plain = transcriptRenderNodes(from: [item])
        let carded = transcriptRenderNodes(from: [item], pendingPrompts: ["toolu_X": prompt])
        let cardedAgain = transcriptRenderNodes(from: [item], pendingPrompts: ["toolu_X": prompt])
        #expect(plain[0].pendingPrompt == nil)
        #expect(carded[0].pendingPrompt == prompt)
        #expect(plain[0].contentVersion != carded[0].contentVersion)
        #expect(carded[0].contentVersion == cardedAgain[0].contentVersion)

        var answered = prompt
        answered.phase = .answered(summary: "Allowed")
        let answeredNode = transcriptRenderNodes(from: [item], pendingPrompts: ["toolu_X": answered])
        #expect(answeredNode[0].contentVersion != carded[0].contentVersion)
    }

    @Test func aCardedRowIsNeverHidden() {
        let item = Fix.toolCall("toolu_T", "TodoWrite", input: "{}")
        #expect(transcriptRenderNodes(from: [item]).isEmpty)
        let prompt = Fix.local(Fix.permissionPayload(toolUseID: "toolu_T"))
        #expect(transcriptRenderNodes(from: [item], pendingPrompts: ["toolu_T": prompt]).map(\.id) == ["toolu_T"])
    }

    @Test func noPromptsLeavesTheMergeAnIdentity() {
        let items: [TranscriptItem] = [.assistantText(id: "a", text: "a", timestamp: nil), Fix.toolCall("toolu_X")]
        let merged = PendingPromptMerge.apply(items: items, prompts: [])
        #expect(merged.items == items)
        #expect(merged.prompts.isEmpty)
        #expect(merged.settled.isEmpty)
    }

    /// With the flag off, prompts must not change the layout at all: no
    /// appended row, no lift-out of an activity group, no un-hidden row, no
    /// content-version change.
    @Test func flagOffPromptsLeaveThePresentationAsWithoutPrompts() {
        let items: [TranscriptItem] = [
            .assistantText(id: "a", text: "Working.", timestamp: nil),
            Fix.toolCall("toolu_R", "Read", input: #"{"file_path":"/x"}"#),
            Fix.toolCall("toolu_X"),
            Fix.toolCall("toolu_T", "TodoWrite", input: "{}"),
        ]
        let localPrompts = [
            Fix.local(Fix.permissionPayload(), flagOn: false),
            Fix.local(Fix.permissionPayload(id: "p2", toolUseID: "toolu_T"), flagOn: false),
            Fix.local(Fix.permissionPayload(id: "p3", toolUseID: nil), flagOn: false),
        ]
        let remotePrompts = [true, false].map { hasAnswer in
            PendingPromptPresentation.remote(
                RemotePendingPrompt(id: "r1", kind: .permission, toolUseID: "toolu_X", toolName: "Bash"),
                selection: Fix.selection,
                capabilities: hasAnswer ? [RemoteCapability.answer, "events"] : ["events"],
                flagOn: false, now: Fix.when)
        }
        let baseline = TranscriptPresentation.build(
            items: items, pendingPrompts: [:], memo: TranscriptPresentationMemo()).nodes

        for prompts in [localPrompts, remotePrompts] {
            let merged = PendingPromptMerge.apply(items: items, prompts: prompts)
            #expect(merged.items == items)
            #expect(merged.prompts.isEmpty)
            let nodes = TranscriptPresentation.build(
                items: merged.items, pendingPrompts: merged.prompts, memo: TranscriptPresentationMemo()).nodes
            #expect(nodes.map(\.id) == baseline.map(\.id))
            #expect(nodes.map(\.contentVersion) == baseline.map(\.contentVersion))
        }
    }

    /// With the flag on, a remote provider without `answer` still shows its
    /// read-only "Attach to answer" card in the transcript.
    @Test func flagOnRemoteWithoutAnswerStillCardsTheRow() {
        let remote = PendingPromptPresentation.remote(
            RemotePendingPrompt(id: "r1", kind: .permission, toolUseID: "toolu_X", toolName: "Bash"),
            selection: Fix.selection, capabilities: ["events"], flagOn: true, now: Fix.when)
        let merged = PendingPromptMerge.apply(items: [Fix.toolCall("toolu_X")], prompts: [remote])
        #expect(merged.prompts["toolu_X"]?.answerability == .readOnly(note: "Attach to answer"))
    }

    @Test @MainActor func appendedCardReplacedBySameIDRowIsNotARebuild() {
        let prompt = Fix.local(Fix.permissionPayload())
        let a: TranscriptItem = .assistantText(id: "a", text: "Running it.", timestamp: nil)

        let before = PendingPromptMerge.apply(items: [a], prompts: [prompt])
        #expect(before.items.map(\.id) == ["a", "toolu_X"])
        let beforeNodes = TranscriptPresentation.build(
            items: before.items, pendingPrompts: before.prompts, memo: TranscriptPresentationMemo()).nodes

        // The real row lands: same id, its own timestamp and input spelling.
        let real = Fix.toolCall("toolu_X", input: #"{ "command": "touch x" }"#, timestamp: Fix.when.addingTimeInterval(1))
        let after = PendingPromptMerge.apply(items: [a, real], prompts: [prompt])
        #expect(after.items.map(\.id) == ["a", "toolu_X"])
        let afterNodes = TranscriptPresentation.build(
            items: after.items, pendingPrompts: after.prompts, memo: TranscriptPresentationMemo()).nodes

        #expect(beforeNodes.map(\.id) == afterNodes.map(\.id))
        let step = TranscriptStreamPlan.step(previous: beforeNodes, next: afterNodes)
        #expect(step == .updateLast || step == .noop, "got \(step)")
        #expect(afterNodes.last?.pendingPrompt == prompt)
    }

    /// A provider that sends only `pending_question` projects to a prompt
    /// with no `tool_use_id`; the `AskUserQuestion` row already on disk is
    /// its card, not a second `prompt-<id>` copy.
    @Test func aRemoteQuestionWithoutToolUseIDCardsTheRowOnDisk() {
        let remote = PendingPromptPresentation.remote(
            RemotePendingPrompt(
                id: "rq", kind: .question,
                questions: [RemotePendingQuestionItem(
                    prompt: "Which?", label: "Pick", multi: false,
                    options: [RemotePendingQuestionOption(label: "A")])]),
            selection: Fix.selection, capabilities: [RemoteCapability.answer],
            flagOn: true, now: Fix.when)
        let items: [TranscriptItem] = [
            .assistantText(id: "a", text: "a", timestamp: nil),
            Fix.toolCall("toolu_Q", "AskUserQuestion", input: Fix.askInput),
        ]
        let merged = PendingPromptMerge.apply(items: items, prompts: [remote])
        #expect(merged.items == items)
        #expect(merged.prompts.keys.sorted() == ["toolu_Q"])
    }

    @Test func theAnsweredCardIsHeldUntilTheToolResult() {
        var answered = Fix.local(Fix.permissionPayload())
        answered.phase = .answered(summary: "Allowed")

        let pending = PendingPromptMerge.apply(items: [Fix.toolCall("toolu_X")], prompts: [answered])
        #expect(pending.prompts["toolu_X"]?.phase == .answered(summary: "Allowed"))
        #expect(pending.settled.isEmpty)

        let landed = PendingPromptMerge.apply(items: [Fix.toolCall("toolu_X", result: Fix.done)], prompts: [answered])
        #expect(landed.prompts.isEmpty, "the row renders as today's answered row once its result lands")
        #expect(landed.settled == ["p1"])
    }

    @Test @MainActor func mergeNeverWritesSessionTranscripts() throws {
        let suiteName = "TBDAppTests.PendingPromptMerge.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)
        let raw: [TranscriptItem] = [.assistantText(id: "a", text: "a", timestamp: nil)]
        state.sessionTranscripts["sid"] = raw
        state.pendingPrompts[Fix.terminalID] = [Fix.permissionPayload(), Fix.permissionPayload(id: "p2", toolUseID: nil)]

        let merged = PendingPromptMerge.local(
            items: state.sessionTranscripts["sid"] ?? [], appState: state, terminalID: Fix.terminalID)
        _ = TranscriptPresentation.build(
            items: merged.items, pendingPrompts: merged.prompts, memo: TranscriptPresentationMemo())

        #expect(merged.items.map(\.id) == ["a", "toolu_X", "prompt-p2"])
        #expect(state.sessionTranscripts["sid"] == raw, "appended cards must never enter the session cache")
        #expect(state.sessionTranscripts.count == 1)
    }

    @Test @MainActor func localLivePromptsFollowTheFlag() throws {
        let suiteName = "TBDAppTests.PendingPromptFlag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)
        state.pendingPrompts[Fix.terminalID] = [Fix.permissionPayload()]

        // No capabilities yet: read-only.
        #expect(PendingPromptMerge.livePrompts(appState: state, terminalID: Fix.terminalID)
            .map(\.answerability) == [.readOnly(note: nil)])

        var caps = DaemonCapabilitiesResult(controlModeEnabled: false)
        caps.transcriptPromptAnswerEnabled = true
        state.daemonCapabilities = caps
        #expect(PendingPromptMerge.livePrompts(appState: state, terminalID: Fix.terminalID)
            .map(\.answerability) == [.answerable])
    }

    @Test func seedIsOpenFollowsThePhase() {
        var card = Fix.local(Fix.questionPayload(toolUseID: nil))
        #expect(card.seed.isOpen)
        card.phase = .closed
        #expect(!card.seed.isOpen)
        card.phase = .answered(summary: "A")
        #expect(!card.seed.isOpen)
    }

    /// A held unpaired question whose row has its result renders no second
    /// card and is reported settled, so retention lets it go.
    @Test func heldUnpairedQuestionDoesNotDuplicateTheAnsweredRow() {
        var card = Fix.local(Fix.questionPayload(toolUseID: nil))
        card.phase = .closed
        let items = [Fix.toolCall("toolu_Q", "AskUserQuestion", input: Fix.askInput, result: Fix.done)]
        let merged = PendingPromptMerge.apply(items: items, prompts: [card])
        #expect(merged.items == items)
        #expect(merged.prompts.isEmpty)
        #expect(merged.settled == ["q1"])
    }

    @Test func firstSeenDatesHoldStill() {
        let dates = PromptFirstSeenDates(capacity: 2)
        let t0 = Date(timeIntervalSince1970: 10)
        #expect(dates.date(for: "a", now: t0) == t0)
        #expect(dates.date(for: "a", now: t0.addingTimeInterval(5)) == t0)
        _ = dates.date(for: "b", now: t0)
        _ = dates.date(for: "c", now: t0)
        // "a" was evicted, so it is re-stamped.
        #expect(dates.date(for: "a", now: t0.addingTimeInterval(9)) == t0.addingTimeInterval(9))
    }
}

@MainActor
@Suite("Prompt card retention", .clockDriven, .serialized)
struct PromptCardRetentionTests {
    typealias Fix = PromptFixtures
    static let retainFor: Duration = .seconds(30)
    static let target = PromptAnswerTarget.local(terminalID: PromptFixtures.terminalID)

    private func waitUntilReleased(_ retention: PromptCardRetention) async -> PollOutcome {
        await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { retention.heldCount == 0 }
        }
    }

    @Test func anAnsweredCardShowsItsAnswerWhileLiveAndAfterItCloses() {
        let retention = PromptCardRetention(retainFor: Self.retainFor, clock: TestClock())
        let prompt = Fix.local(Fix.permissionPayload())
        retention.observe(live: [prompt], for: Self.target)
        retention.markAnswered(prompt, summary: "Allowed")

        // The daemon has not cleared it yet.
        #expect(retention.cards(live: [prompt], for: Self.target).map(\.phase) == [.answered(summary: "Allowed")])
        // The daemon cleared it; the tool result has not landed.
        retention.observe(live: [], for: Self.target)
        let held = retention.cards(live: [], for: Self.target)
        #expect(held.map(\.promptID) == ["p1"])
        #expect(held.map(\.phase) == [.answered(summary: "Allowed")])
        #expect(!held[0].acceptsAnswer)
    }

    @Test func settleDropsTheHeldCardWhenTheToolResultLands() {
        let retention = PromptCardRetention(retainFor: Self.retainFor, clock: TestClock())
        let prompt = Fix.local(Fix.permissionPayload())
        retention.markAnswered(prompt, summary: "Allowed")

        let merged = PendingPromptMerge.apply(
            items: [Fix.toolCall("toolu_X", result: Fix.done)],
            prompts: retention.cards(live: [], for: Self.target))
        retention.settle(merged.settled)
        #expect(retention.heldCount == 0)
        #expect(retention.cards(live: [], for: Self.target).isEmpty)
    }

    @Test func aPromptThatClosesElsewhereIsHeldReadOnly() {
        let retention = PromptCardRetention(retainFor: Self.retainFor, clock: TestClock())
        let prompt = Fix.local(Fix.permissionPayload())
        retention.observe(live: [prompt], for: Self.target)
        #expect(retention.heldCount == 0, "an open prompt is shown live, not held")
        retention.observe(live: [], for: Self.target)
        #expect(retention.cards(live: [], for: Self.target).map(\.phase) == [.closed])
        // Another target's cards are untouched by this one.
        #expect(retention.cards(live: [], for: .remote(provider: "acme", sessionID: "s1")).isEmpty)
    }

    @Test func aClosedPromptThatComesBackIsOpenAgain() {
        let retention = PromptCardRetention(retainFor: Self.retainFor, clock: TestClock())
        let prompt = Fix.local(Fix.permissionPayload())
        retention.observe(live: [prompt], for: Self.target)
        retention.observe(live: [], for: Self.target)
        #expect(retention.heldPhase(for: "p1") == .closed)

        // The same id is live again: the dialog is open, so the card is too.
        retention.observe(live: [prompt], for: Self.target)
        #expect(retention.heldPhase(for: "p1") == nil)
        let shown = retention.cards(live: [prompt], for: Self.target)
        #expect(shown.map(\.phase) == [.open])
        #expect(shown.first?.acceptsAnswer == true)
    }

    @Test func anAnsweredHoldSurvivesThePromptBeingLiveAgain() {
        let retention = PromptCardRetention(retainFor: Self.retainFor, clock: TestClock())
        let prompt = Fix.local(Fix.permissionPayload())
        retention.observe(live: [prompt], for: Self.target)
        retention.markAnswered(prompt, summary: "Allowed")
        retention.observe(live: [], for: Self.target)
        retention.observe(live: [prompt], for: Self.target)
        #expect(retention.heldPhase(for: "p1") == .answered(summary: "Allowed"))
    }

    @Test func theFallbackCardRetiresOnTheTimeout() async {
        let clock = TestClock()
        let retention = PromptCardRetention(retainFor: Self.retainFor, clock: clock)
        let prompt = Fix.local(Fix.permissionPayload(id: "p9", toolUseID: nil))
        retention.observe(live: [prompt], for: Self.target)
        retention.observe(live: [], for: Self.target)

        let held = PendingPromptMerge.apply(items: [], prompts: retention.cards(live: [], for: Self.target))
        #expect(held.items.map(\.id) == ["prompt-p9"])
        #expect(held.settled.isEmpty, "no row can ever settle an unpaired prompt")

        await clock.advanceWhenSuspended(by: Self.retainFor)
        #expect(await waitUntilReleased(retention) == .satisfied)
        let after = PendingPromptMerge.apply(items: [], prompts: retention.cards(live: [], for: Self.target))
        #expect(after.items.isEmpty)
    }

    /// A card retired on the timeout is never settled, so retention reports
    /// it for the answer controller to drop its drafts and state.
    @Test func aTimeoutRetirementIsReported() async {
        let clock = TestClock()
        let retention = PromptCardRetention(retainFor: Self.retainFor, clock: clock)
        var retired: [String] = []
        retention.onRetire = { retired.append($0) }
        let prompt = Fix.local(Fix.permissionPayload(id: "p9", toolUseID: nil))
        retention.observe(live: [prompt], for: Self.target)
        retention.observe(live: [], for: Self.target)
        #expect(retired.isEmpty)

        await clock.advanceWhenSuspended(by: Self.retainFor)
        #expect(await waitUntilReleased(retention) == .satisfied)
        #expect(retired == ["p9"])
    }

    @Test func aSettledCardIsNotReportedAsRetired() {
        let retention = PromptCardRetention(retainFor: Self.retainFor, clock: TestClock())
        var retired: [String] = []
        retention.onRetire = { retired.append($0) }
        retention.markAnswered(Fix.local(Fix.permissionPayload()), summary: "Allowed")
        retention.settle(["p1"])
        #expect(retired.isEmpty, "settled prompts are forgotten by the pane's own settle path")
    }

    @Test func anAnsweredCardWhoseResultNeverComesRetiresOnTheTimeout() async {
        let clock = TestClock()
        let retention = PromptCardRetention(retainFor: Self.retainFor, clock: clock)
        retention.markAnswered(Fix.local(Fix.permissionPayload()), summary: "Denied")
        #expect(retention.heldPhase(for: "p1") == .answered(summary: "Denied"))

        await clock.advanceWhenSuspended(by: Self.retainFor)
        #expect(await waitUntilReleased(retention) == .satisfied)
        #expect(retention.heldPhase(for: "p1") == nil)
    }
}
