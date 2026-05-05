import SwiftUI
import TBDShared

/// "▶ Show N subagent activities" affordance + the indented expanded body
/// that recursively renders TranscriptItemsView with a depth indicator.
struct SubagentDisclosure: View {
    let subagent: Subagent
    let terminalID: UUID?
    let depth: Int

    @State private var expanded = false

    private var label: String {
        let count = subagent.items.count
        if let agentType = subagent.agentType {
            return "Show \(count) subagent \(count == 1 ? "activity" : "activities") · \(agentType)"
        }
        return "Show \(count) subagent \(count == 1 ? "activity" : "activities")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    Text(label)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(subagent.items.isEmpty)

            if expanded && !subagent.items.isEmpty {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 1)
                        .padding(.vertical, 4)
                    TranscriptItemsView(items: subagent.items, terminalID: terminalID, depth: depth + 1)
                        .padding(.leading, 23)
                }
            }
        }
    }
}
