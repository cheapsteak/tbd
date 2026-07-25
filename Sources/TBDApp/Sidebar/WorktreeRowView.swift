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
    @StateObject private var newChildMenu = HoverMenuModel()

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
        RowStatusIndicator.shouldBoldName(notification)
    }

    private var prPresentation: PRStatusPresentation? {
        guard !isMain else { return nil }
        return PRStatusPresentation.make(for: prStatus)
    }

    /// Any PARKED terminal — hibernated (authoritative) or legacy-suspended.
    /// Suspend merged into hibernate: both now show the calm moon indicator.
    private var hasParkedTerminal: Bool {
        let terminals = appState.terminals[worktree.id] ?? []
        return terminals.contains { $0.isParked }
    }

    private var hasWorkingTerminal: Bool {
        let terminals = appState.terminals[worktree.id] ?? []
        return terminals.contains { $0.activityState == .working }
    }

    @ViewBuilder
    private func nestedPlusButton(repoID: UUID) -> some View {
        // No tooltip — hover opens the profile picker menu, which a tooltip
        // would render on top of.
        SectionHeaderPlusButton(action: { handleNestedPlus(repoID: repoID) })
        .accessibilityLabel("New nested worktree under \(worktree.displayName)")
        .onHover { newChildMenu.triggerHover($0) }
        .background(
            FloatingMenuAnchor(
                isPresented: newChildMenu.isOpen,
                content: WorktreeProfilePickerView(
                    repoID: repoID,
                    parentWorktreeID: worktree.id,
                    highlightDefaultProfile: newChildMenu.isTriggerHovered,
                    onClose: { newChildMenu.closeNow() }
                )
                .environmentObject(appState)
                .background(.ultraThickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onHover { newChildMenu.menuHover($0) }
            )
        )
        .padding(.trailing, 4)
    }

    private func handleNestedPlus(repoID: UUID) {
        switch HoverMenuModel.plusOutcome(optionHeld: NSEvent.modifierFlags.contains(.option)) {
        case .openMenu:
            newChildMenu.openImmediately()
        case .createDefault:
            newChildMenu.closeNow()
            appState.createWorktree(repoID: repoID, parentWorktreeID: worktree.id)
        }
    }

    @ViewBuilder
    private func leadingIcon() -> some View {
        switch RowStatusIndicator.leading(
            isPending: isPending && !isEditing,
            hasPRStatus: prPresentation != nil
        ) {
        case .prStatus:
            if let presentation = prPresentation, let status = prStatus {
                // A queued PR describes itself by its queue position, not its
                // underlying (UNKNOWN→pending) check reason.
                let detail = presentation.badge.map { "in merge queue, position \($0)" }
                    ?? (status.reason ?? status.state.displayReason)
                Button(action: openPR) {
                    prGlyph(presentation)
                        .frame(width: 12, height: 12)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { isPRIconHovered = $0 }
                .accessibilityLabel("PR #\(status.number): \(detail)")
                .anchorPreference(key: RowTooltipPreferenceKey.self, value: .bounds) { anchor in
                    isPRIconHovered
                        ? RowTooltipPreference(text: "PR #\(status.number) · \(detail)", anchor: anchor)
                        : nil
                }
            }
        case .pending:
            Image(systemName: "circle.dotted")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
        case .remote, nil:
            // `.remote` never occurs here — local rows never pass
            // `isRemote: true` — but the switch must stay exhaustive over
            // `LeadingRowIndicator?`.
            EmptyView()
        }
    }

    /// The leading PR glyph. `.asset` is a bundled monochrome SVG tinted with
    /// the status color; `.emoji` (the merge-queue bus) is full-color and must
    /// NOT be tinted — so it drops `.renderingMode(.template)`/`.foregroundStyle`
    /// and, when queued, bakes its position badge via the shared `busImage`.
    @ViewBuilder
    private func prGlyph(_ presentation: PRStatusPresentation) -> some View {
        switch presentation.glyph {
        case .asset(let name):
            if let nsImage = Self.loadIcon(name) {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(presentation.color)
            }
        case .emoji:
            Image(nsImage: PRStatusPresentation.busImage(position: presentation.badge, side: 12))
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
        }
    }

    @ViewBuilder
    private func suffixIcon() -> some View {
        switch RowStatusIndicator.suffix(
            notification: notification,
            isWorking: hasWorkingTerminal,
            // Suspend retired: every parked session funnels to the moon.
            isSuspended: false,
            isHibernated: hasParkedTerminal
        ) {
        case .working:
            TypingDotsView(color: SuffixRowIndicator.working.color)
                .frame(width: 14, height: 12)
                .padding(.leading, -3)
                .offset(y: 2)
                .help(Self.suffixHelp(.working))
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
        case .working:    return "Agent is working"
        case .suspended:  return "Suspended"
        case .hibernated: return "Hibernating — wakes on focus"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            leadingIcon()
            RenameableLabel(
                text: worktree.displayName,
                isEditing: $isEditing,
                onCommit: { newName in
                    // renameWorktree applies the optimistic local update
                    // itself (scratch-aware, before its RPC) — no caller-side
                    // pre-apply, or the rename would be applied twice.
                    Task {
                        await appState.renameWorktree(id: worktree.id, displayName: newName)
                    }
                },
                onStartEditing: { appState.isRenamingWorktree = true },
                onStopEditing: { appState.isRenamingWorktree = false }
            ) {
                VStack(alignment: .leading, spacing: -2) {
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
                    if let promotedID = worktree.promotedToRepoID,
                       let name = appState.repoName(for: promotedID) {
                        Text("→ promoted to \(name)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            suffixIcon()
            if let sectionRepoID, sectionRepoID != worktree.repoID,
               let rid = worktree.repoID,
               let homeRepo = appState.repoName(for: rid) {
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
        // Scratch spaces have no repo-level `.missing` status to inherit, so a
        // missing directory is surfaced client-side with a per-row FS stat
        // (mirrors RepoSectionView dimming a `.missing` repo). The stat is an
        // autoclosure argument, so only un-promoted scratch rows pay it — not
        // every sidebar row on every body evaluation. Promoted rows are
        // excluded — promotion MOVES the folder, so their directory is expected
        // to be gone; see AppState.scratchRowIsDimmed.
        .opacity(AppState.scratchRowIsDimmed(
            worktree, directoryExists: FileManager.default.fileExists(atPath: worktree.path)
        ) ? 0.5 : 1.0)
        // The worktree-row hover surface is intentionally reserved: per-session
        // account facts and switching live in the tab bar, and this hover is
        // earmarked for the planned recency-biased work summary
        // (see tbd-redesign-direction). No `.hoverCard` here for now.
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
            if HoverMenuModel.shouldShowPlus(hovered: isRowHovered, menuOpen: newChildMenu.isOpen),
               !isMain,
               let repoID = worktree.repoID {
                nestedPlusButton(repoID: repoID)
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
    /// blocking pre-session hook is what the user is waiting on.
    static func creatingSubtitle(hasPreSessionTerminal: Bool) -> String {
        hasPreSessionTerminal ? "Running setup…" : "Creating worktree…"
    }

    func startRename() {
        guard !isMain else { return }
        isEditing = true
    }

    /// Cache for sidebar PR status icons, keyed by icon name. The returned
    /// NSImage must be identity-stable across body evaluations:
    /// `Image(nsImage:)` diffs by object identity, so a fresh instance per
    /// render made every row's icon layer rebuild at once whenever an
    /// AppState-wide @Published reassignment re-evaluated all rows (visible
    /// mass flicker). Also skips the disk I/O (`Bundle.module.url` +
    /// `NSImage(contentsOf:)`) per evaluation. MainActor confinement
    /// (SwiftUI body runs on main) makes this safe without locks.
    @MainActor
    private static var iconCache: [String: NSImage] = [:]

    @MainActor
    static func loadIcon(_ name: String) -> NSImage? {
        if let cached = iconCache[name] { return cached }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        iconCache[name] = image
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
