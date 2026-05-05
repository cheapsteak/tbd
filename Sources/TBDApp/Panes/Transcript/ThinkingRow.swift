import SwiftUI
import TBDShared

struct ThinkingRow: View {
    let id: String
    let text: String
    let timestamp: Date?

    @State private var expanded = false

    var body: some View {
        ActivityRowChrome(
            icon: "brain",
            timestamp: timestamp,
            expanded: $expanded
        ) {
            HStack(spacing: 6) {
                Text("Thinking").italic()
            }
        } body: {
            Text(text)
                .font(.caption2)
                .italic()
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
        }
    }
}
