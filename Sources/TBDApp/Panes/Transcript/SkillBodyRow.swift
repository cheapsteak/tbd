import SwiftUI
import TBDShared

/// Activity row for a Claude Code skill body injection. Shows up between
/// the user's slash-command bubble and Claude's response when a skill is
/// loaded. The full body is collapsed by default; expand to read it.
struct SkillBodyRow: View {
    let id: String
    let text: String
    let timestamp: Date?

    @State private var expanded = false

    private var skillName: String {
        // First line is "Base directory for this skill: <path>".
        // Take the last path component as the skill name.
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let prefix = "Base directory for this skill:"
        guard firstLine.hasPrefix(prefix) else { return "skill" }
        let path = firstLine.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        let lastComponent = (path as NSString).lastPathComponent
        return lastComponent.isEmpty ? "skill" : lastComponent
    }

    var body: some View {
        ActivityRowChrome(
            icon: "sparkles",
            timestamp: timestamp,
            expanded: $expanded
        ) {
            HStack(spacing: 6) {
                Text("Skill")
                    .foregroundStyle(.primary)
                Text("·").foregroundStyle(.quaternary)
                Text(skillName)
                    .foregroundStyle(.secondary)
            }
        } body: {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
