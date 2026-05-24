import SwiftUI
import TBDShared

/// Header-only activity row for a Claude Code skill body injection. Click
/// opens the overlay with the full body (see #129).
struct SkillBodyRow: View {
    let id: String
    let text: String
    let timestamp: Date?

    @Environment(\.openTranscriptOverlay) private var openTranscriptOverlay

    private var skillName: String {
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
            onOpen: { openTranscriptOverlay?(id) }
        ) {
            HStack(spacing: 6) {
                Text("Skill")
                    .foregroundStyle(.primary)
                Text("·").foregroundStyle(.quaternary)
                Text(skillName)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
