import Foundation
import TBDShared

// The render-side model of a pending prompt — a Claude Code question picker or
// permission dialog that is open and waiting — for both the local and the
// remote transcript pane. Design:
// `docs/specs/2026-10-09-transcript-prompt-answer-design.md`, "The cards".

/// Where an answer to a card goes.
enum PromptAnswerTarget: Hashable, Sendable {
    /// A local Claude terminal; answered over `prompt.answer`.
    case local(terminalID: UUID)
    /// A remote provider's session; answered over `remote.answer`.
    case remote(provider: String, sessionID: String)
}

/// Whether a card offers live controls.
enum PromptAnswerability: Hashable, Sendable {
    case answerable
    /// The card renders, read-only. `note` is "Attach to answer" for a remote
    /// provider that does not declare `answer`; nil otherwise (the flag is
    /// off), so the card reads exactly as today's.
    case readOnly(note: String?)

    static let attachToAnswerNote = "Attach to answer"

    var isAnswerable: Bool { self == .answerable }
}

/// Where a card is in its life, as the render model sees it.
///
/// Delivery progress — sending, failed, unknown outcome — is not here: it
/// belongs to whoever sends the answer, keyed by prompt id, so a row recycled
/// by the table never loses it and the row's measured height never depends on
/// it.
enum PromptCardPhase: Hashable, Sendable {
    /// The dialog is open.
    case open
    /// TBD delivered an answer; the card shows it until the tool result lands
    /// in the transcript or `PromptCardRetention`'s timeout passes.
    case answered(summary: String)
    /// The dialog closed without an answer from this card (the terminal
    /// answered it, or the session moved on). Held, read-only, for the same
    /// bounded time, so an appended card does not vanish before its row lands.
    case closed

    var isOpen: Bool { self == .open }
}

/// One pending prompt as a card renders it. Hashed into the owning node's
/// `contentVersion`, so a change here re-renders exactly that row.
struct PendingPromptPresentation: Hashable, Sendable {
    let promptID: String
    let kind: PendingPromptKind
    let toolUseID: String?
    let toolName: String
    /// Sorted-key `tool_input`; nil when a remote provider left it out.
    let toolInputJSON: String?
    /// The provider cut long strings, or left `tool_input` out, for size.
    let toolInputTruncated: Bool
    /// For `.question`; empty for `.permission`.
    let questions: [PromptQuestion]
    /// One line per "don't ask again" effect, for the permission card.
    let suggestionLines: [String]
    /// Whether "Yes, and don't ask again this session" is offered.
    let hasSuggestions: Bool
    let target: PromptAnswerTarget
    let answerability: PromptAnswerability
    /// Stable for the prompt's life: the appended row's timestamp, so it must
    /// never move between body evaluations.
    let createdAt: Date
    var phase: PromptCardPhase = .open

    /// Whether the card's controls are live: answerable and still open.
    var acceptsAnswer: Bool { answerability.isAnswerable && phase.isOpen }

    /// Whether the row renders as a prompt card (`PermissionPromptCard`, or
    /// `AskUserQuestionCard` in pending mode). A read-only prompt with no note
    /// — the flag is off — renders exactly as today's row instead.
    var rendersAsPromptCard: Bool { answerability != .readOnly(note: nil) }

    /// The tool name an appended row carries when a remote provider omitted it.
    static let unnamedQuestionTool = "AskUserQuestion"
    static let unnamedPermissionTool = "Permission"

    static func local(_ payload: PendingPromptPayload, terminalID: UUID,
                      flagOn: Bool) -> PendingPromptPresentation {
        PendingPromptPresentation(
            promptID: payload.id,
            kind: payload.kind,
            toolUseID: payload.toolUseID,
            toolName: payload.toolName,
            toolInputJSON: payload.toolInputJSON,
            toolInputTruncated: false,
            questions: payload.kind == .question
                ? PromptQuestionParser.questions(fromAskUserQuestionInput: payload.toolInputJSON) ?? []
                : [],
            suggestionLines: PermissionSuggestionSummary.lines(fromJSON: payload.suggestionsJSON),
            hasSuggestions: PermissionSuggestionSummary.sessionScoped(fromJSON: payload.suggestionsJSON) != nil,
            target: .local(terminalID: terminalID),
            answerability: flagOn ? .answerable : .readOnly(note: nil),
            createdAt: payload.createdAt)
    }

    /// `now` must be stable for the prompt's life (the remote contract carries
    /// no timestamp); the remote pane passes the instant it first saw the id.
    static func remote(_ prompt: RemotePendingPrompt, selection: RemoteSessionSelection,
                       capabilities: [String], flagOn: Bool,
                       now: Date) -> PendingPromptPresentation {
        let questions: [PromptQuestion]
        if let items = prompt.questions, !items.isEmpty {
            questions = PromptQuestionParser.questions(fromRemote: items)
        } else if prompt.kind == .question, let json = prompt.toolInputJSON {
            questions = PromptQuestionParser.questions(fromAskUserQuestionInput: json) ?? []
        } else {
            questions = []
        }
        let toolName = prompt.toolName.flatMap { $0.isEmpty ? nil : $0 }
            ?? (prompt.kind == .question ? unnamedQuestionTool : unnamedPermissionTool)
        return PendingPromptPresentation(
            promptID: prompt.id,
            kind: prompt.kind,
            toolUseID: prompt.toolUseID,
            toolName: toolName,
            toolInputJSON: prompt.toolInputJSON,
            toolInputTruncated: prompt.toolInputTruncated,
            questions: questions,
            suggestionLines: PermissionSuggestionSummary.lines(fromJSON: prompt.suggestionsJSON),
            hasSuggestions: PermissionSuggestionSummary.sessionScoped(fromJSON: prompt.suggestionsJSON) != nil,
            target: .remote(provider: selection.provider, sessionID: selection.sessionID),
            answerability: remoteAnswerability(capabilities: capabilities, flagOn: flagOn),
            createdAt: now)
    }

    /// Flag off → read-only as today. Flag on but no `answer` verb → read-only
    /// with "Attach to answer". Both → answerable.
    static func remoteAnswerability(capabilities: [String], flagOn: Bool) -> PromptAnswerability {
        guard flagOn else { return .readOnly(note: nil) }
        guard capabilities.contains(RemoteCapability.answer) else {
            return .readOnly(note: PromptAnswerability.attachToAnswerNote)
        }
        return .answerable
    }

    var seed: PromptCardSeed {
        PromptCardSeed(
            promptID: promptID,
            toolUseID: toolUseID,
            kind: kind,
            toolName: toolName,
            // An appended question row is drawn by today's AskUserQuestion
            // card, which reads `questions` from this JSON; a remote prompt
            // without `tool_input` gets the questions re-encoded.
            toolInputJSON: toolInputJSON ?? Self.questionsInputJSON(questions) ?? "{}",
            timestamp: createdAt)
    }

    /// `{"questions":[…]}` in `AskUserQuestion`'s `tool_input` shape, or nil
    /// when there are none.
    static func questionsInputJSON(_ questions: [PromptQuestion]) -> String? {
        guard !questions.isEmpty else { return nil }
        let object: [String: Any] = ["questions": questions.map { question -> [String: Any] in
            var entry: [String: Any] = [
                "question": question.text,
                "multiSelect": question.multiSelect,
                "options": question.options.map { option -> [String: Any] in
                    var o: [String: Any] = ["label": option.label]
                    if let description = option.description { o["description"] = description }
                    return o
                },
            ]
            if let header = question.header { entry["header"] = header }
            return entry
        }]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// What the panes call: merge the pending prompts into the transcript, and
/// hand back the item-id → presentation map `TranscriptPresentation.build`
/// needs.
///
/// View-time only. The result is never written into
/// `AppState.sessionTranscripts`, so an appended card never reaches the
/// session cache, the overlay's item lookup, or any window bookkeeping.
enum PendingPromptMerge {
    struct Merged: Equatable {
        let items: [TranscriptItem]
        /// Transcript item id → the card that row renders.
        let prompts: [String: PendingPromptPresentation]
        /// Prompts whose tool result is already on disk.
        let settled: Set<String>

        /// The row id of an open card whose controls are live, or nil. The
        /// composer's hint shows exactly while this is non-nil: flag off, or a
        /// remote provider without `answer`, make every card read-only.
        var answerableCardItemID: String? {
            prompts.filter { $0.value.acceptsAnswer }.keys.sorted().first
        }
    }

    static func apply(items: [TranscriptItem],
                      prompts: [PendingPromptPresentation]) -> Merged {
        guard !prompts.isEmpty else { return Merged(items: items, prompts: [:], settled: []) }
        let result = PendingPromptMerger.merge(items: items, seeds: prompts.map(\.seed))
        var byPromptID: [String: PendingPromptPresentation] = [:]
        for prompt in prompts where byPromptID[prompt.promptID] == nil {
            byPromptID[prompt.promptID] = prompt
        }
        let map = result.cardItemIDs.compactMapValues { byPromptID[$0] }
        return Merged(items: result.items, prompts: map, settled: result.settledPromptIDs)
    }

    /// The open prompts of a local terminal, as cards.
    @MainActor
    static func livePrompts(appState: AppState, terminalID: UUID) -> [PendingPromptPresentation] {
        let flagOn = appState.transcriptPromptAnswerEnabled
        return (appState.pendingPrompts[terminalID] ?? []).map {
            PendingPromptPresentation.local($0, terminalID: terminalID, flagOn: flagOn)
        }
    }

    /// The open prompt of a remote session, as a card: its effective pending
    /// prompt, and only while the provider reports `waiting_input`.
    @MainActor
    static func livePrompts(appState: AppState, selection: RemoteSessionSelection,
                            firstSeen: PromptFirstSeenDates,
                            now: Date = Date()) -> [PendingPromptPresentation] {
        guard let payload = appState.remoteSessionPayload(for: selection),
              payload.agentState == .waitingInput,
              let prompt = payload.effectivePendingPrompt else { return [] }
        return [.remote(
            prompt, selection: selection,
            capabilities: appState.remoteProviderCapabilities(for: selection),
            flagOn: appState.transcriptPromptAnswerEnabled,
            now: firstSeen.date(for: prompt.id, now: now))]
    }

    /// Live prompts for `terminalID` plus the ones `PromptCardRetention` is
    /// still holding, merged into `items`.
    @MainActor
    static func local(items: [TranscriptItem], appState: AppState,
                      terminalID: UUID) -> Merged {
        let cards = appState.promptCardRetention.cards(
            live: livePrompts(appState: appState, terminalID: terminalID),
            for: .local(terminalID: terminalID))
        return apply(items: items, prompts: cards)
    }
}

/// The instant the remote pane first saw each prompt id, so a remote card's
/// `createdAt` — which the contract does not carry — holds still across body
/// evaluations and never churns the row's content version.
///
/// A reference type held in `@State`, like the panes' presentation memo:
/// recording a date is bookkeeping, not view state, and must be legal inside a
/// body evaluation. Bounded: it keeps only the most recent ids.
final class PromptFirstSeenDates {
    private var dates: [String: Date] = [:]
    private var order: [String] = []
    private let capacity: Int

    init(capacity: Int = 16) {
        self.capacity = capacity
    }

    func date(for promptID: String, now: Date) -> Date {
        if let known = dates[promptID] { return known }
        dates[promptID] = now
        order.append(promptID)
        if order.count > capacity {
            dates.removeValue(forKey: order.removeFirst())
        }
        return now
    }
}

/// A request to bring one transcript row into view. The token changes on every
/// request, so asking for the same row twice scrolls twice.
struct TranscriptScrollRequest: Equatable {
    let itemID: String
    let token: Int

    /// The request that follows `current`, for `itemID`.
    static func next(after current: TranscriptScrollRequest?, itemID: String) -> TranscriptScrollRequest {
        TranscriptScrollRequest(itemID: itemID, token: (current?.token ?? 0) &+ 1)
    }
}
