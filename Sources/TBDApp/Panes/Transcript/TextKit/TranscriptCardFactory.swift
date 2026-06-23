import SwiftUI
import TBDShared

/// Maps `TranscriptRenderNode` values to hosted SwiftUI card views for the
/// TextKit2 document layer. Cards that are non-interactive (chat bubbles,
/// subagent summaries) return nil from `card(for:context:)` and render via
/// the attributed-string text pipeline instead. (#129)
@MainActor
enum TranscriptCardFactory {

    // MARK: - Public API

    /// Returns true when this node requires a hosted `NSHostingView` attachment
    /// rather than flowing as attributed-string text.
    static func isInteractive(_ node: TranscriptRenderNode) -> Bool {
        switch node.kind {
        case .chatBubble, .subagentSummary:
            return false
        case .systemReminder, .skillBody, .toolCall:
            return true
        }
    }

    /// Builds the appropriate card view for `node`, wrapped with the
    /// environment keys it needs. Returns nil for non-interactive nodes (chat
    /// bubbles, subagent summaries) and for `AskUserQuestion` when
    /// `context.appState` is nil (the card requires `@EnvironmentObject
    /// AppState` to fetch truncated bodies).
    static func card(
        for node: TranscriptRenderNode,
        context: TranscriptCardContext
    ) -> AnyView? {
        switch node.kind {
        case .chatBubble, .subagentSummary:
            return nil

        case .systemReminder(let id, let kind, let text, let timestamp):
            return wrap(
                SystemReminderRow(id: id, kind: kind, text: text, timestamp: timestamp),
                context: context
            )

        case .skillBody(let id, let text, let timestamp):
            return wrap(
                SkillBodyRow(id: id, text: text, timestamp: timestamp),
                context: context
            )

        case .toolCall(let id, let name, let inputJSON, let inputTruncatedTo, let result, let timestamp):
            return toolCard(
                id: id,
                name: name,
                inputJSON: inputJSON,
                inputTruncatedTo: inputTruncatedTo,
                result: result,
                timestamp: timestamp,
                context: context
            )
        }
    }

    // MARK: - Private helpers

    /// Injects the two transcript environment keys that card views read via
    /// `@Environment`. Called for every non-chat-bubble node kind.
    private static func wrap<V: View>(_ view: V, context: TranscriptCardContext) -> AnyView {
        AnyView(
            view
                .environment(\.openTranscriptOverlay, context.openTranscriptOverlay)
                .environment(\.navigateToThread, context.navigateToThread)
        )
    }

    /// Dispatches a `.toolCall` node to the correct typed card, mirroring the
    /// `TranscriptRow.toolCard` switch. Returns nil only for `AskUserQuestion`
    /// when `context.appState` is nil (the card requires `@EnvironmentObject
    /// AppState` to fetch truncated tool bodies from the daemon).
    private static func toolCard(
        id: String,
        name: String,
        inputJSON: String,
        inputTruncatedTo: Int?,
        result: ToolResult?,
        timestamp: Date?,
        context: TranscriptCardContext
    ) -> AnyView? {
        let terminalID = context.terminalID
        switch name {
        case "Read":
            return wrap(
                ReadCard(
                    id: id,
                    inputJSON: inputJSON,
                    result: result,
                    timestamp: timestamp,
                    terminalID: terminalID
                ),
                context: context
            )
        case "Edit", "MultiEdit":
            return wrap(
                EditCard(
                    id: id,
                    name: name,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    result: result,
                    timestamp: timestamp,
                    terminalID: terminalID
                ),
                context: context
            )
        case "Write":
            return wrap(
                WriteCard(
                    id: id,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    result: result,
                    timestamp: timestamp,
                    terminalID: terminalID
                ),
                context: context
            )
        case "Bash":
            return wrap(
                BashCard(
                    id: id,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    result: result,
                    timestamp: timestamp,
                    terminalID: terminalID
                ),
                context: context
            )
        case "Grep":
            return wrap(
                GrepCard(
                    id: id,
                    inputJSON: inputJSON,
                    result: result,
                    timestamp: timestamp,
                    terminalID: terminalID
                ),
                context: context
            )
        case "Glob":
            return wrap(
                GlobCard(
                    id: id,
                    inputJSON: inputJSON,
                    result: result,
                    timestamp: timestamp,
                    terminalID: terminalID
                ),
                context: context
            )
        case "Task", "Agent":
            return wrap(
                AgentCard(
                    id: id,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    result: result,
                    timestamp: timestamp,
                    terminalID: terminalID
                ),
                context: context
            )
        case "AskUserQuestion":
            guard let appState = context.appState else { return nil }
            return AnyView(
                AskUserQuestionCard(
                    id: id,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    result: result,
                    timestamp: timestamp,
                    terminalID: terminalID,
                    // The TextKit2 transcript reserves card height from a single
                    // measurement, so the card must not grow after first render.
                    staticHeight: true
                )
                .environmentObject(appState)
                .environment(\.openTranscriptOverlay, context.openTranscriptOverlay)
                .environment(\.navigateToThread, context.navigateToThread)
            )
        default:
            return wrap(
                GenericToolCard(
                    id: id,
                    name: name,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    result: result,
                    timestamp: timestamp,
                    terminalID: terminalID
                ),
                context: context
            )
        }
    }
}
