import SwiftUI
import TBDShared

struct ThinkingRow: View {
    let id: String
    let text: String
    let timestamp: Date?

    @Environment(\.openTranscriptOverlay) private var openTranscriptOverlay

    var body: some View {
        ActivityRowChrome(
            icon: "brain",
            timestamp: timestamp,
            onOpen: { openTranscriptOverlay?(id) }
        ) {
            HStack(spacing: 6) {
                Text("Thinking").italic()
            }
        }
    }
}
