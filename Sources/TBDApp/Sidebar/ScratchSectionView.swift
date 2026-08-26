import AppKit
import SwiftUI
import TBDShared

/// Pinned sidebar section for repo-less scratch spaces (`Worktree.isScratch`).
/// Modeled on `RepoSectionView`: a header row with a disclosure chevron and a
/// hover `+` to create a new scratch space, followed by the scratch worktree
/// rows when the section is expanded.
struct ScratchSectionView: View {
    @Environment(AppState.self) var appState
    @State private var isHeaderHovered = false
    @State private var isChevronHovered = false
    @State private var showingScratchInstructions = false
    /// Whether the pads below the header are showing. App-side state, unlike a
    /// project's daemon-owned `Repo.expanded` — see
    /// `AppState.scratchSectionExpandedKey`.
    @AppStorage(AppState.scratchSectionExpandedKey)
    private var isExpanded: Bool = AppState.scratchSectionExpandedDefault
    /// Which side of the title this section's chevron sits on, and with it
    /// where every sidebar title and row sits. Shared with the project rows so
    /// the two sections cannot disagree — see `SidebarHeaderMetrics`.
    @AppStorage(AppState.chevronBeforeProjectNameKey)
    private var chevronBeforeProjectName: Bool = AppState.chevronBeforeProjectNameDefault

    private var chevronButton: some View {
        SectionDisclosureChevron(
            isExpanded: isExpanded,
            beforeTitle: chevronBeforeProjectName,
            // The `+` on this row is gated on plain hover rather than
            // `HoverMenuModel` (this section has no profile picker to hold
            // itself open), so that is the gate the chevron shares.
            isMounted: SidebarHeaderMetrics.chevronMounted(
                beforeTitle: chevronBeforeProjectName, revealed: isHeaderHovered),
            accessibilityLabel: isExpanded
                ? "Collapse \(AppState.scratchSectionLabel)"
                : "Expand \(AppState.scratchSectionLabel)",
            onHoverChange: { isChevronHovered = $0 },
            toggle: { isExpanded.toggle() }
        )
    }

    /// Insets for the rows under the title, tracking the title's own column —
    /// the same helper the project sections use, so a scratch pad and a
    /// worktree land in one column.
    private var childRowInsets: EdgeInsets {
        EdgeInsets(
            top: 0,
            leading: SidebarHeaderMetrics.childRowLeadingInset(
                chevronBeforeProjectName: chevronBeforeProjectName),
            bottom: 0,
            trailing: 0)
    }

    var body: some View {
        HStack(spacing: SidebarHeaderMetrics.headerSpacing) {
            if chevronBeforeProjectName {
                chevronButton
            }
            Text(AppState.scratchSectionLabel)
                .font(.headline)
                .foregroundStyle(appState.selectedScratchSection ? .primary : .secondary)
                // Claw back the chevron square's slack when it leads the
                // title, exactly as a project name does.
                .padding(.leading, chevronBeforeProjectName
                         ? SidebarHeaderMetrics.nameLeadingClawback : 0)
            if !chevronBeforeProjectName {
                chevronButton
            }
            Spacer()
            if isHeaderHovered {
                SectionHeaderPlusButton(help: "New scratch space", action: { appState.createScratch() })
            }
        }
        .background(Color.white.opacity(0.0001))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectScratchSection()
        }
        .onHover { hovering in
            isHeaderHovered = hovering
            // Trailing the title — the default — the chevron is torn down by
            // this same gate,
            // so its own `onHover(false)` may never arrive — without this the
            // pads would stay dimmed at 0.7 forever.
            if !hovering { isChevronHovered = false }
        }
        .contextMenu {
            // Ungated, unlike the chevron when it trails the title — the
            // keyboard-reachable path to the same action. See
            // `SectionDisclosureChevron`.
            Button(isExpanded ? "Collapse" : "Expand") {
                isExpanded.toggle()
            }
            Button("Edit Scratch Instructions…") {
                showingScratchInstructions = true
            }
        }
        .sheet(isPresented: $showingScratchInstructions) {
            ScratchInstructionsView().environment(appState)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: SidebarHeaderMetrics.headerRowLeadingInset,
                                  bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)

        if isExpanded {
            expandedContent
        }
    }

    /// The pads themselves, plus the create-your-first-one CTA that stands in
    /// for them while there are none.
    @ViewBuilder
    private var expandedContent: some View {
        if appState.scratchWorktrees.isEmpty {
            Button {
                appState.createScratch()
            } label: {
                Text("Click to create scratch space")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            // The CTA stands where a pad row would, plus the 2pt it has always
            // carried to sit optically under the header.
            .listRowInsets(EdgeInsets(
                top: 2, leading: childRowInsets.leading + 2, bottom: 4, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }

        ForEach(appState.scratchWorktrees) { wt in
            WorktreeRowView(worktree: wt)   // sectionRepoID nil → no (repo) suffix; repo affordances vanish
                .frame(maxWidth: .infinity, alignment: .leading)
                // Dimmed while the chevron is hovered, as a project's rows
                // are — the gesture is about to hide them.
                .opacity(isChevronHovered ? 0.7 : 1.0)
                .listRowInsets(childRowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .tag(wt.id)
        }
    }
}
