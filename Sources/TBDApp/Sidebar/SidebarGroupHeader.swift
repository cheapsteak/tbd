import SwiftUI

struct SidebarGroupHeader: View {
    let id: SidebarGroupID
    let title: String
    let summary: SidebarRemoteGroups.Summary?

    init(id: SidebarGroupID, title: String, summary: SidebarRemoteGroups.Summary? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
    }
    @Environment(AppState.self) private var appState

    var body: some View {
        let expanded = appState.expandedSidebarGroups.contains(id)
        Button {
            appState.toggleSidebarGroup(id)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    if let summary {
                        Text(summary.text).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 2)
                if let attention = summary?.attention {
                    Image(systemName: attention == .error ? "exclamationmark.octagon.fill" : "hand.raised.fill")
                        .foregroundStyle(attention == .error ? Color.red : Color.orange)
                        .help("A remote session needs attention")
                } else if summary?.hasUncertainty == true {
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                        .help("Some remote session state is unknown or no longer reported")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary.map { "\(title), \($0.text)" } ?? title)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(expanded ? "Collapse this group" : "Expand this group")
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
