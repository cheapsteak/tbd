import SwiftUI

/// Non-interactive single-row summary of a subagent's activity. Replaces
/// the prior expandable `SubagentDisclosure` (which forced a nested
/// `ForEach` inside the transcript pane's outer `ForEach`, contributing
/// to the `_ViewList_Group.estimatedCount` recursion in issue #129). A
/// future pop-out viewer will let users inspect subagent activity in
/// detail without inlining a recursive transcript.
struct SubagentSummaryRow: View {
    let count: Int
    let agentType: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.2")
            if let agentType {
                Text("\(count) subagent \(count == 1 ? "activity" : "activities") · \(agentType)")
            } else {
                Text("\(count) subagent \(count == 1 ? "activity" : "activities")")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.leading, 32)
    }
}
