import SwiftUI
import TBDShared

/// The card for an open tool permission dialog, answerable from the
/// transcript. Design: `docs/specs/2026-10-09-transcript-prompt-answer-design.md`,
/// "Permission card".
///
/// Height. The table measures a hosted row ONCE (see
/// `TranscriptStaticCardsKey`), so nothing here may grow after that: the
/// preview is a fixed-height box, the suggestion list comes from the
/// presentation, and every delivery state — the buttons, the deny-reason
/// field, the spinner, the answer, the error and Retry — shares one reserved
/// footer row of fixed height.
struct PermissionPromptCard: View {
    let presentation: PendingPromptPresentation
    let id: String
    let timestamp: Date?

    @Environment(AppState.self) private var appState
    /// Only the popover; it renders outside the row and never changes its height.
    @State private var showingFullInput = false

    static let previewLineBudget = 6
    static let previewHeight: CGFloat = 92
    static let footerHeight: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                titleRow
                PermissionPreviewBox(text: Self.previewText(for: presentation))
                if presentation.hasSuggestions {
                    PermissionSuggestionList(lines: presentation.suggestionLines)
                }
                PermissionFooterRow(presentation: presentation, controller: appState.promptAnswers)
                    .frame(height: Self.footerHeight, alignment: .leading)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: 52)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(Self.title(for: presentation))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let ts = timestamp {
                Text(ts.absoluteShort).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button("Show all") { showingFullInput = true }
                .buttonStyle(.link)
                .font(.caption)
                .popover(isPresented: $showingFullInput, arrowEdge: .bottom) {
                    PromptInputPopoverView(
                        title: presentation.toolName,
                        text: Self.fullInputText(for: presentation),
                        truncated: presentation.toolInputTruncated)
                }
        }
    }

    // MARK: - Text (pure)

    static func title(for presentation: PendingPromptPresentation) -> String {
        "Claude wants to use \(presentation.toolName)"
    }

    /// The preview, cut to `previewLineBudget` lines:
    /// - Bash: the command.
    /// - Write / Edit / MultiEdit: the path, then the first lines of the
    ///   content or the edit.
    /// - Anything else: compact sorted-key input JSON.
    static func previewText(for presentation: PendingPromptPresentation) -> String {
        let input = inputObject(presentation.toolInputJSON)
        let text: String
        switch presentation.toolName {
        case "Bash":
            text = (input?["command"] as? String) ?? compactJSON(presentation.toolInputJSON)
        case "Write", "Edit", "MultiEdit":
            text = fileEditPreview(input) ?? compactJSON(presentation.toolInputJSON)
        default:
            text = compactJSON(presentation.toolInputJSON)
        }
        return cut(text, toLines: previewLineBudget)
    }

    /// The popover's text: the whole input, pretty-printed with sorted keys.
    static func fullInputText(for presentation: PendingPromptPresentation) -> String {
        guard let json = presentation.toolInputJSON else { return missingInputText }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let pretty = String(data: data, encoding: .utf8) else {
            return json
        }
        return pretty
    }

    static let missingInputText = "(the provider did not send this tool's input)"

    private static func inputObject(_ json: String?) -> [String: Any]? {
        guard let json, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func fileEditPreview(_ input: [String: Any]?) -> String? {
        guard let input, let path = input["file_path"] as? String else { return nil }
        let body: String?
        if let content = input["content"] as? String {
            body = content
        } else if let newString = input["new_string"] as? String {
            body = newString
        } else if let edits = input["edits"] as? [[String: Any]] {
            body = edits.first?["new_string"] as? String
        } else {
            body = nil
        }
        guard let body, !body.isEmpty else { return path }
        return path + "\n" + body
    }

    static func compactJSON(_ json: String?) -> String {
        guard let json else { return missingInputText }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let compact = String(data: data, encoding: .utf8) else {
            return json
        }
        return compact
    }

    /// The first `limit` lines of `text`, with "…" when more followed.
    static func cut(_ text: String, toLines limit: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit else { return text }
        return lines.prefix(limit).joined(separator: "\n") + "…"
    }
}

// MARK: - Preview

private struct PermissionPreviewBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(PermissionPromptCard.previewLineBudget)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(height: PermissionPromptCard.previewHeight, alignment: .topLeading)
            .clipped()
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct PermissionSuggestionList: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("“Don't ask again this session” also:")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text("• \(line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(line)
            }
        }
    }
}

// MARK: - Footer

private struct PermissionFooterRow: View {
    let presentation: PendingPromptPresentation
    let controller: PromptAnswerController

    var body: some View {
        let footer = PromptCardFooter.resolve(
            presentation, state: controller.state(for: presentation.promptID))
        if footer == .controls {
            if controller.draft(for: presentation.promptID).denyReasonOpen {
                PermissionDenyRow(presentation: presentation, controller: controller)
            } else {
                PermissionButtonsRow(presentation: presentation, controller: controller)
            }
        } else {
            PromptCardStatusRow(footer: footer) {
                Task { await controller.retry(presentation) }
            }
        }
    }
}

private struct PermissionButtonsRow: View {
    let presentation: PendingPromptPresentation
    let controller: PromptAnswerController

    var body: some View {
        HStack(spacing: 6) {
            Button("Allow") { send(.allow) }
                .buttonStyle(.borderedProminent)
            if presentation.hasSuggestions {
                Button("Yes, and don't ask again this session") { send(.allowForSession) }
            }
            Button("Deny…") {
                controller.updateDraft(for: presentation.promptID) { $0.denyReasonOpen = true }
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .lineLimit(1)
    }

    private func send(_ choice: PromptAnswerController.PermissionChoice) {
        let answer = PromptAnswerController.permissionAnswer(choice)
        Task { await controller.submit(presentation, answer: answer) }
    }
}

private struct PermissionDenyRow: View {
    let presentation: PendingPromptPresentation
    let controller: PromptAnswerController

    private var reason: Binding<String> {
        let promptID = presentation.promptID
        return Binding(
            get: { controller.draft(for: promptID).denyReason },
            set: { value in controller.updateDraft(for: promptID) { $0.denyReason = value } })
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Tell Claude why (optional)", text: reason)
                .textFieldStyle(.roundedBorder)
                .onSubmit(deny)
            Button("Deny", action: deny)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            Button("Cancel") {
                controller.updateDraft(for: presentation.promptID) { $0.denyReasonOpen = false }
            }
        }
        .controlSize(.small)
    }

    private func deny() {
        let answer = PromptAnswerController.permissionAnswer(
            .deny, denyReason: controller.draft(for: presentation.promptID).denyReason)
        Task { await controller.submit(presentation, answer: answer) }
    }
}

/// Every non-control footer state, shared by both prompt cards. One line, so
/// it fits the reserved footer row whatever the state.
struct PromptCardStatusRow: View {
    let footer: PromptCardFooter
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            content
            Spacer(minLength: 0)
        }
        .font(.caption)
        .lineLimit(1)
    }

    @ViewBuilder private var content: some View {
        switch footer {
        case .controls:
            EmptyView()
        case .sending:
            ProgressView().controlSize(.small)
            Text("Sending…").foregroundStyle(.secondary)
        case .answered(let summary):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(summary).foregroundStyle(.secondary).help(summary)
        case .answeredElsewhere:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            Text(PromptCardFooter.answeredElsewhereText).foregroundStyle(.secondary)
        case .failed(let message, let retryable):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).foregroundStyle(.red).help(message)
            if retryable { retryButton }
        case .unknownOutcome:
            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
            Text(PromptCardFooter.unknownOutcomeText).foregroundStyle(.secondary)
            retryButton
        case .readOnly(let note):
            if let note {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(note).foregroundStyle(.secondary)
            }
        }
    }

    private var retryButton: some View {
        Button("Retry", action: onRetry)
            .controlSize(.small)
    }
}
