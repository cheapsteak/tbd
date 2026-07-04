import AppKit
import SwiftUI
import TBDShared

/// Pinned sidebar section for repo-less scratch spaces (`Worktree.isScratch`).
/// Modeled on `RepoSectionView`: a header row with a hover `+` to create a new
/// scratch space, followed by the scratch worktree rows.
struct ScratchSectionView: View {
    @EnvironmentObject var appState: AppState
    @State private var isHeaderHovered = false
    @State private var showingScratchInstructions = false

    var body: some View {
        HStack(spacing: 4) {
            Text("Scratch")
                .font(.headline)
                .foregroundStyle(appState.selectedScratchSection ? .primary : .secondary)
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
        .onHover { isHeaderHovered = $0 }
        .contextMenu {
            Button("Edit Scratch Instructions…") {
                showingScratchInstructions = true
            }
        }
        .sheet(isPresented: $showingScratchInstructions) {
            ScratchInstructionsView().environmentObject(appState)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: -2, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)

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
            .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 4, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }

        ForEach(appState.scratchWorktrees) { wt in
            WorktreeRowView(worktree: wt)   // sectionRepoID nil → no (repo) suffix; repo affordances vanish
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .tag(wt.id)
        }
    }
}
