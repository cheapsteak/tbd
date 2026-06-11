import AppKit
import SwiftUI
import TBDShared

private func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

struct WorktreeRowView: View {
    let worktree: Worktree
    var isMain: Bool = false
    var indentLevel: Int = 0
    var sectionRepoID: UUID? = nil
    @EnvironmentObject var appState: AppState
    @State private var isEditing = false
    @State private var isRowHovered: Bool = false

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
    private func rowIcons() -> some View {
        // Resolved through RowStatusIndicator so at most one indicator renders.
        // Add new indicators in RowStatusIndicator.resolve, never as stacked icons here.
        switch RowStatusIndicator.resolve(
            isPending: isPending && !isEditing,
            isWorking: hasWorkingTerminal,
            notification: notification,
            isSuspended: hasSuspendedTerminal,
            hasPRStatus: prPresentation != nil
        ) {
        case .pending:
            // Static dotted-circle sized to match the 12×12 PR status icon.
            Image(systemName: "circle.dotted")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
        case .working:
            // Static asterisk (echoes Claude's ✳ working glyph) sized to match the 12×12 PR status icon.
            // Light: terracotta #B05730 — readable on light sidebar (~#F1F1F1).
            // Dark:  Claude coral #D97757 — readable on dark sidebar (~#1E1E1E).
            Image(systemName: "asterisk")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(adaptive(
                    light: NSColor(srgbRed: 176 / 255, green: 87 / 255, blue: 48 / 255, alpha: 1),
                    dark: NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
                ))
                .frame(width: 12, height: 12)
        case .notificationBadge(let n):
            Circle()
                .fill(RowStatusIndicator.badgeColor(for: n))
                .frame(width: 8, height: 8)
        case .suspended:
            Image(systemName: "pause.circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .prStatus:
            if let presentation = prPresentation,
               let nsImage = loadIcon(presentation.iconName) {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(presentation.color)
            }
        case nil:
            EmptyView()
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            rowIcons()
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
                    if isPending {
                        Text("Creating worktree…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
        .help(isEditing ? "" : worktree.displayName)
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
}
