import SwiftUI
import TBDShared

struct BashCard: View {
    let id: String
    let inputJSON: String
    let inputTruncatedTo: Int?
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @State private var expanded = false
    @State private var fullResultText: String? = nil
    @State private var fullInputJSON: String? = nil
    @State private var containerExpanded = false
    @State private var commandContainerExpanded = false
    @EnvironmentObject var appState: AppState

    private struct Input: Decodable { let command: String; let description: String? }

    private static let decoder = JSONDecoder()

    private func decodeInput() -> Input? {
        guard let data = (fullInputJSON ?? inputJSON).data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(Input.self, from: data)
    }

    private func headerSummary(for parsed: Input?) -> String {
        if let desc = parsed?.description, !desc.isEmpty { return desc }
        if let cmd = parsed?.command {
            let trimmed = cmd.replacingOccurrences(of: "\n", with: " ")
            if trimmed.count > 60 {
                return "$(\(String(trimmed.prefix(60)))…)"
            }
            return "$(\(trimmed))"
        }
        return "…"
    }

    var body: some View {
        let parsedInput = decodeInput()
        return ActivityRowChrome(
            icon: "terminal",
            timestamp: timestamp,
            expanded: $expanded
        ) {
            HStack(spacing: 6) {
                Text("Bash")
                Text(headerSummary(for: parsedInput))
                    .lineLimit(1)
                if result?.isError == true {
                    Text("failed")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.red)
                }
            }
        } body: {
            VStack(alignment: .leading, spacing: 8) {
                if let cmd = parsedInput?.command {
                    ZStack(alignment: .topTrailing) {
                        ScrollView(.vertical) {
                            Text(cmd)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: commandContainerExpanded ? .infinity : 120)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        Button(action: { commandContainerExpanded.toggle() }) {
                            Image(systemName: commandContainerExpanded
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                                .padding(4)
                                .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .help(commandContainerExpanded ? "Collapse container" : "Expand container")
                    }
                }
                if let cap = inputTruncatedTo, fullInputJSON == nil, terminalID != nil {
                    TruncationFooter(truncatedTo: cap, currentLength: inputJSON.count) {
                        Task { await fetchFullInput() }
                    }
                }
                if let r = result {
                    ZStack(alignment: .topTrailing) {
                        ScrollView(.vertical) {
                            Text(fullResultText ?? r.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(r.isError ? .red.opacity(0.85) : .secondary)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: containerExpanded ? .infinity : 120)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        Button(action: { containerExpanded.toggle() }) {
                            Image(systemName: containerExpanded
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                                .padding(4)
                                .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .help(containerExpanded ? "Collapse container" : "Expand container")
                    }
                    if let cap = r.truncatedTo, fullResultText == nil, terminalID != nil {
                        TruncationFooter(truncatedTo: cap, currentLength: r.text.count) {
                            Task { await fetchFull() }
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Running…").font(.caption2).foregroundStyle(.tertiary)
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
}
