import AppKit
import SwiftUI
import TBDShared

struct WorktreeRowView: View {
    /// Fixed height of one worktree row. Shared with `PinnedDockMetrics` so the
    /// dock's height arithmetic cannot silently drift from the row it measures.
    /// `nonisolated` because it is a plain constant, not UI state — without it,
    /// `WorktreeRowView`'s `View` conformance infers whole-type `@MainActor`
    /// isolation onto even this static constant, which a pure/testable
    /// `PinnedDockMetrics` cannot reference from a nonisolated context.
    nonisolated static let rowHeight: CGFloat = 28

    /// How far LEFT of the row's own leading edge the hover pin button is
    /// pushed, so it lands in the gutter rather than on the row's content.
    /// Matches the button's 20x20 hit target (`SectionHeaderPlusButton`): a
    /// full button width clears `leadingIcon()` exactly.
    private static let pinButtonGutter: CGFloat = 20

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

    /// The PR the row's leading indicator stands for: the worst-state binding,
    /// chosen by the same helper the toolbar icon uses. Reading
    /// `effectivePRBindings` (bindings when there are any, else the legacy
    /// `prStatuses` entry lifted into one synthetic binding) rather than either
    /// map directly is what keeps the sidebar dot and the toolbar icon from
    /// disagreeing about a worktree — one indicator, one selection rule, one
    /// source, including in the no-bindings-but-a-status case.
    private var indicatorBinding: PRBinding? {
        PRBindingPresentation.iconBinding(appState.effectivePRBindings(worktreeID: worktree.id))
    }

    private var prStatus: PRStatus? {
        indicatorBinding?.status
    }

    private var hasBoldNotification: Bool {
        RowStatusIndicator.shouldBoldName(notification)
    }

    private var prObservation: PRObservation? {
        appState.prObservations[worktree.id]
    }

    private var prPresentation: PRStatusPresentation? {
        guard !isMain else { return nil }
        return PRStatusPresentation.make(for: prStatus)
    }

    /// Tooltip for the "nobody could find out" indicator: shown only when there
    /// is no cached PR at all AND the last attempt came back `.undetermined`.
    /// Without it that row renders exactly like a row with no pull request,
    /// which is the collapse `PRObservation` exists to undo — a forge outage
    /// would look like a fleet with nothing open.
    ///
    /// `Date()` inside the body is deliberate rather than overlooked. The age it
    /// renders is the age of `prObservation`, and `AppState.prObservations` is
    /// republished on every poll — the observation's own `observedAt` advances
    /// each attempt, so the dictionary differs and this body re-evaluates on the
    /// same ~30 s cadence as the fact it is describing. That is already a coarse
    /// shared ticker, driven by the data rather than beside it, and it is far
    /// finer than `checkedLabel`'s five-minute buckets. **If that republication
    /// is ever made value-only, this string freezes and needs a real ticker.**
    private var prUnknownTooltip: String? {
        guard !isMain, prStatus == nil else { return nil }
        return PRFreshness.unknownIndicatorTooltip(prObservation, now: Date())
    }

    /// Any PARKED terminal — hibernated (authoritative) or legacy-suspended.
    /// Suspend merged into hibernate: both now show the calm moon indicator.
    private var hasParkedTerminal: Bool {
        let terminals = appState.terminals[worktree.id] ?? []
        return terminals.contains { $0.isParked }
    }

    private var hasWorkingTerminal: Bool {
        let terminals = appState.terminals[worktree.id] ?? []
        return Self.hasForegroundWork(in: terminals)
    }

    /// Whether one terminal has trustworthy foreground work to animate in the
    /// sidebar. Codex's hook state can remain latched after a turn ends, so its
    /// transcript-derived presentation state is authoritative here unless the
    /// hook reports that Codex is waiting for the user. Missing transcript
    /// evidence deliberately renders idle instead of preserving a false
    /// thinking indicator. Other terminal kinds retain their existing
    /// hook-backed behavior.
    nonisolated static func isForegroundWorking(_ terminal: Terminal) -> Bool {
        if terminal.isCodexTerminal {
            return terminal.activityStateSource != .terminalInterrupt
                && terminal.activityState != .waitingForUser
                && terminal.presentationActivityState == .working
        }
        return terminal.activityState == .working
    }

    /// The collection form used by the row and by pure presentation tests.
    nonisolated static func hasForegroundWork(in terminals: [Terminal]) -> Bool {
        terminals.contains(where: isForegroundWorking)
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

    /// Hover-only pin toggle in the gutter left of the row's content — the fast
    /// path for pinning, mirroring the trailing nested-worktree `+`. Rendered as
    /// an overlay so it floats above the row and consumes no layout width: row
    /// content must not shift when the pointer enters the row.
    ///
    /// The glyph reflects the STATE, not the action: hollow `pin` when
    /// unpinned, solid `pin.fill` when pinned. The `.help` text still names
    /// the action ("Pin to dock" / "Unpin from dock") so hovering resolves
    /// any ambiguity about what clicking will do. An earlier build used
    /// `pin` / `pin.slash` (action-shaped); the crossed-out slash read as
    /// ugly and cluttered at caption size in a dense sidebar. There is
    /// deliberately no persistent pinned-state glyph elsewhere on the row —
    /// a pinned worktree is by definition visible in the dock, so one would
    /// only cost row width.
    @ViewBuilder
    private func pinToggleButton() -> some View {
        let isPinned = worktree.pinnedAt != nil
        SectionHeaderPlusButton(
            systemImage: isPinned ? "pin.fill" : "pin",
            help: isPinned ? "Unpin from dock" : "Pin to dock",
            action: {
                let wtID = worktree.id
                Task { await appState.setPinned(worktreeID: wtID, pinned: !isPinned) }
            }
        )
        .accessibilityLabel(isPinned
            ? "Unpin \(worktree.displayName) from dock"
            : "Pin \(worktree.displayName) to dock")
    }

    /// Whether the leading pin toggle is on screen right now. Read by both the
    /// pin overlay and the hierarchy-guide-line overlay, which has to break the
    /// segment the button would otherwise be struck through by. A pinned
    /// worktree keeps the (solid) pin visible even without hover, so pinned
    /// state is persistent — only unpinned rows need the hover to reveal the
    /// (hollow) affordance.
    private var showsPinToggle: Bool {
        (isRowHovered || worktree.pinnedAt != nil) && !isMain && !worktree.isNightwatchDesk
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

    /// The leading-slot indicator for one row. Pure and `nonisolated` so the
    /// rule — in particular that a remote row still yields its PR badge when
    /// it has one — is unit-testable without an `AppState` or a view
    /// hierarchy, in the same spirit as `creatingSubtitle`.
    ///
    /// A `.remote` row is one whose `location` is not `.local`; that is the
    /// only thing read here, and nothing about this makes a remote row look
    /// local — `localPath` is never consulted.
    nonisolated static func leadingIndicator(
        worktree: Worktree,
        isPending: Bool,
        hasPRStatus: Bool,
        hasUndeterminedPR: Bool = false
    ) -> LeadingRowIndicator? {
        RowStatusIndicator.leading(
            isPending: isPending,
            hasPRStatus: hasPRStatus,
            isRemote: !worktree.location.isLocal,
            hasUndeterminedPR: hasUndeterminedPR
        )
    }

    @ViewBuilder
    private func leadingIcon() -> some View {
        switch Self.leadingIndicator(
            worktree: worktree,
            isPending: isPending && !isEditing,
            hasPRStatus: prPresentation != nil,
            hasUndeterminedPR: prUnknownTooltip != nil
        ) {
        case .prStatus:
            // The binding, not just its status, because the row names the
            // request in its own forge's vocabulary and only the binding
            // carries the host. `prStatus` IS `indicatorBinding?.status`, so
            // this cannot select a different request.
            if let presentation = prPresentation, let binding = indicatorBinding,
               let status = binding.status {
                // A queued PR describes itself by its queue position, not its
                // underlying (UNKNOWN→pending) check reason.
                let detail = presentation.badge.map { "in merge queue, position \($0)" }
                    ?? (status.reason ?? status.state.displayReason)
                // The cache never speaks without saying how old it is, and
                // never hides that its last re-read failed.
                let freshness = PRFreshness.clauses(
                    status: status, observation: prObservation, now: Date())
                let tooltip = ([binding.refLabel, detail] + freshness)
                    .joined(separator: " · ")
                Button(action: openPR) {
                    prGlyph(presentation)
                        .frame(width: 12, height: 12)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { isPRIconHovered = $0 }
                .accessibilityLabel(
                    "\(binding.refLabel): \(([detail] + freshness).joined(separator: ", "))")
                .anchorPreference(key: RowTooltipPreferenceKey.self, value: .bounds) { anchor in
                    isPRIconHovered ? RowTooltipPreference(text: tooltip, anchor: anchor) : nil
                }
            }
        case .prUnknown:
            if let tooltip = prUnknownTooltip {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                    .onHover { isPRIconHovered = $0 }
                    .accessibilityLabel(tooltip)
                    .anchorPreference(key: RowTooltipPreferenceKey.self, value: .bounds) { anchor in
                        isPRIconHovered ? RowTooltipPreference(text: tooltip, anchor: anchor) : nil
                    }
            }
        case .pending:
            Image(systemName: "circle.dotted")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
        case .remote:
            // A worktree row whose session lives on a provider backend rather
            // than in a checkout on this disk. Same glyph and same tertiary
            // "whisper" tint as `RemoteSectionView`'s row, deliberately: one
            // session must not read as two different things depending on
            // which surface it is shown from. `.remote` is the lowest-priority
            // leading indicator, so a remote lane with a PR still shows its PR
            // badge here — the badge is the louder, actionable fact and this
            // is a quiet statement of where the work is happening.
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.secondary.opacity(0.55))
                .frame(width: 12, height: 12)
                .help("Remote session")
        case nil:
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
        .frame(height: Self.rowHeight)
        // Scratch spaces have no repo-level `.missing` status to inherit, so a
        // missing directory is surfaced client-side with a per-row FS stat
        // (mirrors RepoSectionView dimming a `.missing` repo). The stat is an
        // autoclosure argument, so only un-promoted scratch rows pay it — not
        // every sidebar row on every body evaluation. Promoted rows are
        // excluded — promotion MOVES the folder, so their directory is expected
        // to be gone; see AppState.scratchRowIsDimmed.
        // The probe runs through `LocalWorktree`, so a row with no checkout on
        // this disk reports "does not exist" without ever calling `fileExists`
        // on an empty path.
        .opacity(AppState.scratchRowIsDimmed(
            worktree,
            directoryExists: LocalWorktree(worktree)
                .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
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
                        // The hovered pin button lands in this row's own indent
                        // gutter, which is exactly where the NEAREST ancestor's
                        // thread runs — drawing both put a line straight through
                        // the glyph. Break that one segment for the hovered row
                        // instead; the thread reads as interrupted by the
                        // control, not crossed out by it. Deeper ancestors sit
                        // further left and are untouched.
                        if !(showsPinToggle && depth == indentLevel - 1) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(width: 1)
                                .offset(x: CGFloat(depth) * 16 + 8)
                        }
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
        .overlay(alignment: .leading) {
            // The indent term is required: `.padding(.leading, indentLevel * 16)`
            // applies to the row's CONTENT, but this overlay anchors to the row's
            // outer edge — without it the button would sit at the same absolute x
            // on every row instead of tracking its own row's leading edge. The
            // guide-line overlay above compensates the same way.
            //
            // `-pinButtonGutter` then pushes the button OUT of the row content
            // into the gutter every sidebar/dock row reserves via
            // `.listRowInsets(leading: 12)`, so it never draws on top of
            // `leadingIcon()` (PR status / pending spinner) or the name — an
            // overlap the first cut shipped and that read as broken. The
            // overlay still consumes no layout width, so row content does not
            // shift when the pointer enters the row. Verified live that the List
            // does NOT clip here and the button stays hit-testable, at indent 0
            // and nested, in both the sidebar and the pinned dock.
            if showsPinToggle {
                pinToggleButton()
                    .offset(x: CGFloat(indentLevel) * 16 - Self.pinButtonGutter)
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

    /// Opens the PR the indicator is showing — the worst-state binding, so the
    /// click lands on the PR the glyph is describing rather than on whichever
    /// one happened to be bound first.
    private func openPR() {
        guard let binding = indicatorBinding, let url = URL(string: binding.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func updateNameTruncation(availableWidth: CGFloat) {
        let font = NSFont.systemFont(ofSize: 13, weight: hasBoldNotification ? .bold : .regular)
        let ideal = (worktree.displayName as NSString).size(withAttributes: [.font: font]).width
        let truncated = ideal > availableWidth + 0.5
        if truncated != isNameTruncated { isNameTruncated = truncated }
    }
}
