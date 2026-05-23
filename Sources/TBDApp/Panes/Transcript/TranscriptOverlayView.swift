import SwiftUI
import TBDShared

/// Renders the click-to-open overlay for a transcript row. Hosted by both
/// the terminal-pane `.overlay { … }` (primary location) and the
/// window-root fallback `.overlay { … }`. Looks up its item by
/// `(terminalID, itemID)` from the live transcript store in AppState.
///
/// Safe to use real `ScrollView` here: this view is rendered *outside*
/// the transcript pane's LazyVStack — no `_FlexFrameLayout`/
/// `ScrollViewLayoutComputer` measure-then-clamp trap. See issue #129.
struct TranscriptOverlayView: View {
    let frame: TranscriptOverlayFrame
    let hasBack: Bool
    let onBack: () -> Void
    let onClose: () -> Void

    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                bodyContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if hasBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Back")
            }
            // Per-card icon/title resolution is added during the migration
            // phase. For now we surface the raw item ID so unmigrated cards
            // remain visible during incremental rollout.
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Transcript item \(frame.itemID)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let item = lookupItem() {
            switch item {
            case .toolCall(let toolID, let name, let inputJSON, let inputTruncatedTo, let toolResult, _, _, _) where name == "Bash":
                BashCardBody(
                    id: toolID,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    result: toolResult,
                    terminalID: frame.terminalID
                )
            case .toolCall(let toolID, let name, let inputJSON, let inputTruncatedTo, _, _, _, _) where name == "Write":
                WriteCardBody(
                    id: toolID,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    terminalID: frame.terminalID
                )
            default:
                Text(String(describing: item))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else {
            Text("Item not found.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// Look up the active transcript item by terminal + item ID.
    ///
    /// AppState stores transcripts keyed by `claudeSessionID` (a String),
    /// not directly by `terminalID`. The lookup resolves:
    ///   terminalID (UUID) → Terminal.claudeSessionID (String?)
    ///   → appState.sessionTranscripts[sessionID] → [TranscriptItem]
    ///   → first(where: { $0.id == frame.itemID })
    ///
    /// Returns nil if the terminal isn't found, has no active session,
    /// the session isn't in the transcript store, or the item has been
    /// removed.
    private func lookupItem() -> TranscriptItem? {
        guard let terminal = appState.terminals.values
            .flatMap({ $0 })
            .first(where: { $0.id == frame.terminalID }),
              let sessionID = terminal.claudeSessionID,
              let items = appState.sessionTranscripts[sessionID]
        else { return nil }
        return items.first(where: { $0.id == frame.itemID })
    }
}
