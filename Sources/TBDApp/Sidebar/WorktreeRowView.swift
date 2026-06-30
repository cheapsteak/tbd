import AppKit
import SwiftUI
import TBDShared

struct WorktreeRowView: View {
    let worktree: Worktree
    var isMain: Bool = false
    var indentLevel: Int = 0
    var sectionRepoID: UUID? = nil
    @EnvironmentObject var appState: AppState
    @State private var isEditing = false
    @State private var isRowHovered: Bool = false
    @State private var isPRIconHovered: Bool = false
    @State private var isNameTruncated = false

    private var isPending: Bool {
        worktree.status == .creating
    }

    private var notification: NotificationType? {
        appState.unreadByWorktree[worktree.id]?.type
    }

    private var prStatus: PRStatus? {
        appState.prStatuses[worktree.id]
    }

    private var hasBoldNotification: Bool {
        if let n = notification {
            return n == .responseComplete
        }
        return false
    }

    private var prPresentation: PRStatusPresentation? {
        guard !isMain else { return nil }
        return PRStatusPresentation.make(for: prStatus)
    }

    private var hasSuspendedTerminal: Bool {
        let terminals = appState.terminals[worktree.id] ?? []
        return terminals.contains { $0.suspendedAt != nil }
    }

    private var hasWorkingTerminal: Bool {
        let terminals = appState.terminals[worktree.id] ?? []
        return terminals.contains { $0.activityState == .working }
    }

    @ViewBuilder
    private func leadingIcon() -> some View {
        switch RowStatusIndicator.leading(
            isPending: isPending && !isEditing,
            hasPRStatus: prPresentation != nil
        ) {
        case .prStatus:
            if let presentation = prPresentation,
               let nsImage = loadIcon(presentation.iconName),
               let status = prStatus {
                let reasonText = status.reason ?? status.state.displayReason
                Button(action: openPR) {
                    Image(nsImage: nsImage)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                        .foregroundStyle(presentation.color)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { isPRIconHovered = $0 }
                .accessibilityLabel("PR #\(status.number): \(reasonText)")
                .anchorPreference(key: RowTooltipPreferenceKey.self, value: .bounds) { anchor in
                    isPRIconHovered
                        ? RowTooltipPreference(text: "PR #\(status.number) · \(reasonText)", anchor: anchor)
                        : nil
                }
            }
        case .pending:
            Image(systemName: "circle.dotted")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func suffixIcon() -> some View {
        switch RowStatusIndicator.suffix(
            notification: notification,
            isWorking: hasWorkingTerminal,
            isSuspended: hasSuspendedTerminal
        ) {
        case .working:
            TypingDotsView(color: SuffixRowIndicator.working.color)
                .frame(width: 14, height: 12)
                .padding(.leading, -3)
                .offset(y: 2)
                .help("Agent is working")
        case let indicator?:
            if let symbol = indicator.systemImage {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(indicator.color)
                    .frame(width: 12, height: 12)
                    .help(Self.suffixHelp(indicator))
            }
        case nil:
            EmptyView()
        }
    }

    private static func suffixHelp(_ indicator: SuffixRowIndicator) -> String {
        switch indicator {
        case .error:     return "Error"
        case .attention: return "Needs your attention"
        case .working:   return "Agent is working"
        case .suspended: return "Suspended"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            leadingIcon()
            RenameableLabel(
                text: worktree.displayName,
                isEditing: $isEditing,
                onCommit: { newName in
                    // Optimistic local update so the UI reflects the new name before the RPC returns
                    for repoID in appState.worktrees.keys {
                        if let idx = appState.worktrees[repoID]?.firstIndex(where: { $0.id == worktree.id }) {
                            appState.worktrees[repoID]?[idx].displayName = newName
                        }
                    }
                    Task {
                        await appState.renameWorktree(id: worktree.id, displayName: newName)
                    }
                },
                onStartEditing: { appState.isRenamingWorktree = true },
                onStopEditing: { appState.isRenamingWorktree = false }
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(worktree.displayName)
                        .font(.system(size: 13))
                        .fontWeight(hasBoldNotification ? .bold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { updateNameTruncation(availableWidth: proxy.size.width) }
                                    .onChange(of: proxy.size.width) { _, w in updateNameTruncation(availableWidth: w) }
                                    .onChange(of: worktree.displayName) { _, _ in updateNameTruncation(availableWidth: proxy.size.width) }
                            }
                        )
                        .anchorPreference(key: RowTooltipPreferenceKey.self, value: .bounds) { anchor in
                            (isRowHovered && !isPRIconHovered && isNameTruncated && !isEditing)
                                ? RowTooltipPreference(text: worktree.displayName, anchor: anchor)
                                : nil
                        }
                    if isPending {
                        Text(Self.creatingSubtitle(
                            hasPreSessionTerminal: appState.hasPreSessionTerminal(worktreeID: worktree.id)
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            suffixIcon()
            if let sectionRepoID, sectionRepoID != worktree.repoID,
               let homeRepo = appState.repoName(for: worktree.repoID) {
                let short = homeRepo.count > 5 ? String(homeRepo.prefix(5)) + "…" : homeRepo
                Text("(\(short))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(homeRepo)
            }
        }
        .padding(.leading, CGFloat(indentLevel) * 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(appState.selectedWorktreeIDs.contains(worktree.id) ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        // Hierarchy guide lines: one 1pt vertical at each ancestor depth.
        // Each line sits at `depth * 16 + 8` from the row's leading edge so
        // segments butt up against neighboring nested rows into a continuous
        // thread down the parent's gutter.
        .overlay(alignment: .leading) {
            if indentLevel > 0 {
                ZStack(alignment: .leading) {
                    ForEach(0..<indentLevel, id: \.self) { depth in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 1)
                            .offset(x: CGFloat(depth) * 16 + 8)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if isRowHovered && !isMain {
                Button(action: {
                    let parentID = worktree.id
                    let repoID = worktree.repoID
                    appState.createWorktree(repoID: repoID, parentWorktreeID: parentID)
                }) {
                    Image(systemName: "plus")
                        .font(.caption)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(HoverPressButtonStyle())
                .help("New nested worktree")
                .padding(.trailing, 4)
            }
        }
        .onHover { isRowHovered = $0 }
        .contextMenu {
            SidebarContextMenu(worktree: worktree, onRename: startRename)
        }
        .onChange(of: appState.editingWorktreeID) { _, newID in
            if newID == worktree.id {
                startRename()
                appState.editingWorktreeID = nil
            }
        }
    }

    /// Subtitle under the name while the worktree is `.creating`. A visible
    /// pre-session hook terminal means the git checkout is done and the
    /// blocking setup hook is what the user is waiting on.
    static func creatingSubtitle(hasPreSessionTerminal: Bool) -> String {
        hasPreSessionTerminal ? "Running setup…" : "Creating worktree…"
    }

    func startRename() {
        guard !isMain else { return }
        isEditing = true
    }

    private func loadIcon(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }

    private func openPR() {
        guard let prStatus = prStatus, let url = URL(string: prStatus.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func updateNameTruncation(availableWidth: CGFloat) {
        let font = NSFont.systemFont(ofSize: 13, weight: hasBoldNotification ? .bold : .regular)
        let ideal = (worktree.displayName as NSString).size(withAttributes: [.font: font]).width
        let truncated = ideal > availableWidth + 0.5
        if truncated != isNameTruncated { isNameTruncated = truncated }
    }
}
