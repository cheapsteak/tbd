import MarkdownUI
import SwiftUI
import TBDShared

/// Overlay body for an Agent/Task tool call. Renders the subagent's
/// nested transcript inline; clicks inside the nested view push to the
/// coordinator's one-step back-stack instead of swapping the parent.
struct AgentCardBody: View {
    let id: String
    let inputJSON: String
    let inputTruncatedTo: Int?
    let result: ToolResult?
    let subagent: Subagent?
    let terminalID: UUID?

    @State private var fullResultText: String? = nil
    @State private var fullInputJSON: String? = nil
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator

    private struct Input: Decodable {
        let description: String?
        let prompt: String?
        let subagent_type: String?
    }
    private static let decoder = JSONDecoder()

    private func decodeInput() -> Input? {
        guard let data = (fullInputJSON ?? inputJSON).data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(Input.self, from: data)
    }

    var body: some View {
        let parsed = decodeInput()
        VStack(alignment: .leading, spacing: 12) {
            if let agentType = parsed?.subagent_type, !agentType.isEmpty {
                Text(agentType)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
            }
            if let prompt = parsed?.prompt, !prompt.isEmpty {
                Text("Prompt")
                    .font(.caption2).foregroundStyle(.tertiary).textCase(.uppercase)
                promptMarkdown(prompt)
                    .transcriptSelectableText()
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if let cap = inputTruncatedTo, fullInputJSON == nil, terminalID != nil {
                TruncationFooter(truncatedTo: cap, currentLength: inputJSON.count) {
                    Task { await fetchFullInput() }
                }
            }

            if let subagent, !subagent.items.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Subagent activity")
                    .font(.caption2).foregroundStyle(.tertiary).textCase(.uppercase)
                // terminalID intentionally nil: subagent items are embedded in
                // the parent toolCall's model, NOT indexed in the live transcript
                // store. Passing the parent terminalID would make the "Show full
                // output" buttons appear, but the daemon fetch path can't resolve
                // these IDs — see #129.
                TranscriptItemsView(items: subagent.items, terminalID: nil)
                    .environment(\.openTranscriptOverlay) { itemID in
                        overlayCoordinator.pushItem(itemID: itemID)
                    }
            }

            if let result {
                Divider().padding(.vertical, 4)
                Text("Result")
                    .font(.caption2).foregroundStyle(.tertiary).textCase(.uppercase)
                resultMarkdown(fullResultText ?? result.text)
                    .transcriptSelectableText()
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                if let cap = result.truncatedTo, fullResultText == nil, terminalID != nil {
                    TruncationFooter(truncatedTo: cap, currentLength: result.text.count) {
                        Task { await fetchFull() }
                    }
                }
            }
        }
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

    @ViewBuilder
    private func promptMarkdown(_ text: String) -> some View {
        Markdown(LocalFileLinker.linkify(text))
            .markdownTheme(.chatBubble)
            .environment(\.openURL, fileLinkOpenAction)
    }

    @ViewBuilder
    private func resultMarkdown(_ text: String) -> some View {
        Markdown(LocalFileLinker.linkify(text))
            .markdownTheme(.chatBubble)
            .environment(\.openURL, fileLinkOpenAction)
    }

    private var fileLinkOpenAction: OpenURLAction {
        OpenURLAction { url in
            if url.scheme == "tbd-file" {
                let p = (url.path as NSString).removingPercentEncoding ?? url.path
                overlayCoordinator.pushFile(path: p)
                return .handled
            }
            if url.isFileURL {
                overlayCoordinator.pushFile(path: url.path)
                return .handled
            }
            return .systemAction
        }
    }
}
