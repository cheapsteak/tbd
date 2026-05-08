import SwiftUI
import TBDShared

/// Curated renderer for the `AskUserQuestion` tool — Claude's multiple-choice
/// clarifying-question prompt. Renders each question as an assistant-styled
/// chat block paired with the user's answer as a user-styled chat bubble.
/// The question bubble itself is the disclosure trigger: tapping it expands
/// to reveal the options that were available, with the picked one
/// highlighted. The answer bubble is a plain static user bubble.
struct AskUserQuestionCard: View {
    let id: String
    let inputJSON: String
    let inputTruncatedTo: Int?
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @State private var fullResultText: String? = nil
    @State private var fullInputJSON: String? = nil
    @EnvironmentObject var appState: AppState

    // MARK: - Decoded input shape

    struct Option: Decodable, Equatable {
        let label: String
        let description: String?
    }

    struct Question: Decodable, Equatable {
        let question: String
        let header: String?
        let multiSelect: Bool?
        let options: [Option]
    }

    private struct Input: Decodable {
        let questions: [Question]
    }

    private static let decoder = JSONDecoder()

    private func decodeInput() -> Input? {
        guard let data = (fullInputJSON ?? inputJSON).data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(Input.self, from: data)
    }

    private var resultText: String? {
        if let full = fullResultText { return full }
        return result?.text
    }

    /// Derive the chat-bubble text for one answered question from a
    /// pre-computed match. Returns nil when there's no answer yet (or
    /// nothing parsed for this question).
    /// - Selected options → ordered labels joined with newlines.
    /// - Free-form (no match) → match.freeformAnswer ?? raw answer.
    static func bubbleText(
        from match: AskUserQuestionParser.Match?,
        options: [Option],
        rawAnswer: String?
    ) -> String? {
        guard let match else { return nil }
        guard let raw = rawAnswer, !raw.isEmpty else { return nil }
        if !match.selectedIndices.isEmpty {
            let ordered = match.selectedIndices.sorted()
            let labels = ordered.compactMap { idx -> String? in
                guard idx < options.count else { return nil }
                return options[idx].label
            }
            return labels.joined(separator: "\n")
        }
        return match.freeformAnswer ?? raw
    }

    var body: some View {
        let parsedInput = decodeInput()
        let parsedAnswers = resultText.map(AskUserQuestionParser.parseAnswers) ?? []
        return VStack(alignment: .leading, spacing: 4) {
            if let questions = parsedInput?.questions, !questions.isEmpty {
                ForEach(Array(questions.enumerated()), id: \.offset) { idx, q in
                    let answer = parsedAnswers.first(where: { $0.question == q.question })?.answer
                    let match: AskUserQuestionParser.Match? = (result == nil)
                        ? nil
                        : AskUserQuestionParser.match(
                            answer: answer,
                            options: q.options,
                            multiSelect: q.multiSelect ?? false
                        )
                    QuestionBubble(
                        question: q,
                        timestamp: timestamp,
                        selectedIndices: match?.selectedIndices ?? []
                    )
                    AnswerSlot(
                        match: match,
                        rawAnswer: answer,
                        options: q.options,
                        pendingAnswer: result == nil,
                        timestamp: timestamp,
                        bubbleID: "\(self.id)#answer\(idx)"
                    )
                }
                // If we got a result back but the parser produced nothing
                // (e.g. Claude Code changed the canonical prefix), surface
                // the raw text once so the user can still see what came back.
                if result != nil, parsedAnswers.isEmpty {
                    ChatBubbleView(
                        item: .userPrompt(
                            id: "\(self.id)#raw-result",
                            text: resultText ?? "",
                            timestamp: timestamp
                        )
                    )
                }
            } else {
                // Couldn't decode — fall back to raw JSON in a minimal block.
                fallbackQuestionBlock
            }

            if let cap = inputTruncatedTo, fullInputJSON == nil, terminalID != nil {
                TruncationFooter(truncatedTo: cap, currentLength: inputJSON.count) {
                    Task { await fetchFullInput() }
                }
                .padding(.horizontal, 12)
            }
            if let r = result, let cap = r.truncatedTo, fullResultText == nil, terminalID != nil {
                TruncationFooter(truncatedTo: cap, currentLength: r.text.count) {
                    Task { await fetchFull() }
                }
                .padding(.horizontal, 12)
            }
            if result?.isError == true {
                HStack(spacing: 0) {
                    Spacer(minLength: 52)
                    Text("error")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private var fallbackQuestionBlock: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                roleHeaderClaude
                Text(fullInputJSON ?? inputJSON)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 52)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var roleHeaderClaude: some View {
        HStack(spacing: 4) {
            Text("Claude asked").font(.caption2).foregroundStyle(.tertiary)
            if let ts = timestamp {
                Text("·").foregroundStyle(.quaternary).font(.caption2)
                Text(ts.absoluteShort).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }

    private func fetchFull() async {
        guard let terminalID else { return }
        if let r = try? await appState.daemonClient.terminalTranscriptItemFullBody(terminalID: terminalID, itemID: id) {
            await MainActor.run { fullResultText = r.text }
        }
    }

    private func fetchFullInput() async {
        guard let terminalID else { return }
        if let r = try? await appState.daemonClient.terminalTranscriptItemFullBody(terminalID: terminalID, itemID: "\(id)#input") {
            await MainActor.run { fullInputJSON = r.text }
        }
    }
}

// MARK: - Question bubble (assistant-styled, left-aligned)

private struct QuestionBubble: View {
    let question: AskUserQuestionCard.Question
    let timestamp: Date?
    let selectedIndices: Set<Int>

    @State private var expanded = false

    private var hasHeader: Bool {
        if let h = question.header, !h.isEmpty, h != question.question {
            return true
        }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                roleHeader
                Button {
                    expanded.toggle()
                } label: {
                    bubbleBody
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 52)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var roleHeader: some View {
        HStack(spacing: 4) {
            Text("Claude asked").font(.caption2).foregroundStyle(.tertiary)
            if let ts = timestamp {
                Text("·").foregroundStyle(.quaternary).font(.caption2)
                Text(ts.absoluteShort).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var chevron: some View {
        Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var bubbleBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasHeader, let h = question.header {
                HStack(spacing: 4) {
                    Text(h)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    chevron
                }
                Text(question.question)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // No header — pin the chevron to the trailing edge on the
                // same row as the question text. The text will wrap naturally
                // and the chevron sits to the right of the last fragment.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(question.question)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    chevron
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { idx, option in
                        OptionRow(option: option, selected: selectedIndices.contains(idx))
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Answer slot — either a static user bubble or a "waiting" placeholder

private struct AnswerSlot: View {
    let match: AskUserQuestionParser.Match?
    let rawAnswer: String?
    let options: [AskUserQuestionCard.Option]
    /// True while the tool result hasn't arrived yet. When false but
    /// `match`/`rawAnswer` produce no bubble text, render nothing rather
    /// than spinning forever — the parent card surfaces the raw result
    /// text once at the bottom in that case.
    let pendingAnswer: Bool
    let timestamp: Date?
    let bubbleID: String

    var body: some View {
        let text = AskUserQuestionCard.bubbleText(
            from: match,
            options: options,
            rawAnswer: rawAnswer
        )
        if let text {
            ChatBubbleView(
                item: .userPrompt(id: bubbleID, text: text, timestamp: timestamp)
            )
        } else if pendingAnswer {
            WaitingForResponseRow()
        } else {
            EmptyView()
        }
    }
}

private struct WaitingForResponseRow: View {
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 52)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for response…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Option row

private struct OptionRow: View {
    let option: AskUserQuestionCard.Option
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.callout)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(option.label)
                        .font(.callout)
                        .foregroundStyle(selected ? .primary : .secondary)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                if let desc = option.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }
}

// MARK: - Parser / matcher (kept internal so tests can exercise it)

/// Parses the result.text emitted by Claude after the user answers an
/// AskUserQuestion tool call, and matches answer strings to the original
/// option list. Internal so unit tests can exercise the logic without
/// rendering the SwiftUI view.
enum AskUserQuestionParser {
    struct ParsedAnswer: Equatable {
        let question: String
        let answer: String
    }

    /// Outcome of matching one user answer string against the question's
    /// option list.
    struct Match: Equatable {
        /// Indices of options the user selected. Empty if the answer was
        /// free-form (or the answer is nil / didn't match).
        let selectedIndices: Set<Int>
        /// The raw free-form text to display when no option matched. Nil if
        /// we matched at least one option, or if there's no answer yet.
        let freeformAnswer: String?

        static let empty = Match(selectedIndices: [], freeformAnswer: nil)
    }

    /// Parse the canonical result.text format:
    ///   `User has answered your questions: "Q1"="A1". "Q2"="A2". You can now…`
    /// Tolerant: degrades to an empty array if the prefix or pattern doesn't
    /// match rather than throwing.
    static func parseAnswers(from text: String) -> [ParsedAnswer] {
        // Find the colon that ends the prefix; everything after is Q="A" pairs.
        // We accept either "questions:" or "question:" to be tolerant.
        let body: Substring
        if let range = text.range(of: "User has answered your question") {
            // Skip past the first ":" after that range.
            if let colon = text[range.upperBound...].firstIndex(of: ":") {
                body = text[text.index(after: colon)...]
            } else {
                body = text[range.upperBound...]
            }
        } else {
            body = Substring(text)
        }

        // Scan for "<q>"="<a>" pairs. Straight quotes only. We don't try to
        // honour escaped quotes — Claude doesn't escape inside the result text
        // and a forgiving best-effort scan is the design intent.
        var results: [ParsedAnswer] = []
        var idx = body.startIndex
        while idx < body.endIndex {
            // Find next opening quote.
            guard let qStart = body[idx...].firstIndex(of: "\"") else { break }
            let afterQStart = body.index(after: qStart)
            guard afterQStart < body.endIndex,
                  let qEnd = body[afterQStart...].firstIndex(of: "\"") else { break }
            let questionStr = String(body[afterQStart..<qEnd])

            // Expect `="` after the closing quote.
            let afterQEnd = body.index(after: qEnd)
            guard afterQEnd < body.endIndex, body[afterQEnd] == "=" else {
                idx = afterQEnd
                continue
            }
            let afterEq = body.index(after: afterQEnd)
            guard afterEq < body.endIndex, body[afterEq] == "\"" else {
                idx = afterEq
                continue
            }
            let aStart = body.index(after: afterEq)
            guard aStart <= body.endIndex,
                  let aEnd = body[aStart...].firstIndex(of: "\"") else { break }
            let answerStr = String(body[aStart..<aEnd])
            results.append(ParsedAnswer(question: questionStr, answer: answerStr))
            idx = body.index(after: aEnd)
        }
        return results
    }

    /// Match an answer string against an option list.
    static func match(answer: String?, options: [AskUserQuestionCard.Option], multiSelect: Bool) -> Match {
        guard let raw = answer, !raw.isEmpty else { return .empty }

        // For multi-select, split on commas; for single-select, treat the
        // whole string as one answer. We also try the whole-string match for
        // multi-select first, in case the answer is genuinely a single label
        // that happens to contain a comma.
        let candidates: [String]
        if multiSelect {
            // Try whole match first; if it works, great. Otherwise split.
            if matchSingle(answer: raw, options: options) != nil {
                candidates = [raw]
            } else {
                candidates = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        } else {
            candidates = [raw]
        }

        var indices = Set<Int>()
        for cand in candidates {
            if let i = matchSingle(answer: cand, options: options) {
                indices.insert(i)
            }
        }
        if indices.isEmpty {
            return Match(selectedIndices: [], freeformAnswer: raw)
        }
        return Match(selectedIndices: indices, freeformAnswer: nil)
    }

    /// Match a single answer token against the options. Returns the matched
    /// option index or nil.
    private static func matchSingle(answer: String, options: [AskUserQuestionCard.Option]) -> Int? {
        let trimmed = answer.trimmingCharacters(in: .whitespaces)
        // 1. Exact label match.
        if let i = options.firstIndex(where: { $0.label == trimmed }) {
            return i
        }
        // 2. Letter-shorthand: short answer (≤4 chars) and a label starts with
        //    "<answer>. " or "<answer>:". Case-insensitive so a lowercase
        //    "c" still matches "C. Loop until satisfied or budget".
        if trimmed.count <= 4 {
            let lowered = trimmed.lowercased()
            if let i = options.firstIndex(where: { opt in
                let lowerLabel = opt.label.lowercased()
                return lowerLabel.hasPrefix("\(lowered). ") || lowerLabel.hasPrefix("\(lowered):")
            }) {
                return i
            }
        }
        return nil
    }
}
