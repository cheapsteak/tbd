import SwiftUI
import TBDShared

/// A thinking summary's row: the brain glyph, "Thinking", then the summary on
/// one line. The transcript shows thinking only while the session mod streams
/// it (`isProvisional`); a provisional row offers no overlay, because it leaves
/// once the JSONL confirms it.
struct ThinkingRow: View {
    let id: String
    let text: String
    let timestamp: Date?
    var isProvisional: Bool = false

    @Environment(\.openTranscriptOverlay) private var openTranscriptOverlay

    var body: some View {
        ActivityRowChrome(
            icon: "brain",
            timestamp: timestamp,
            onOpen: {
                if !isProvisional { openTranscriptOverlay?(id) }
            }
        ) {
            HStack(spacing: 6) {
                Text("Thinking").italic()
                if !text.isEmpty {
                    Text(text.split(whereSeparator: \.isNewline).joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if isProvisional {
                    Text("streaming")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
