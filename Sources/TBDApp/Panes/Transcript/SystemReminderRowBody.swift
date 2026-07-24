import SwiftUI
import TBDShared

/// Overlay body for a `.systemReminder` item (non-skillBody kinds).
///
/// Injected-context rows (CLAUDE.md bodies, hook output) are capped at
/// `TranscriptParser.bodyCharCap` like any other body, so this offers the same
/// "Show full output" fetch the tool cards do. Only truncated items
/// (`truncatedTo != nil`) get the affordance — short reminders never make the
/// round-trip.
struct SystemReminderRowBody: View {
    let id: String
    let text: String
    let truncatedTo: Int?
    let terminalID: UUID?

    @State private var fullText: String? = nil
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fullText ?? text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .transcriptSelectableText()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let cap = truncatedTo, fullText == nil, terminalID != nil {
                TruncationFooter(truncatedTo: cap, currentLength: text.count) {
                    Task { await fetchFull() }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fetchFull() async {
        guard let terminalID else { return }
        if let r = try? await appState.daemonClient.terminalTranscriptItemFullBody(terminalID: terminalID, itemID: id) {
            await MainActor.run { fullText = r.text }
        }
    }
}
