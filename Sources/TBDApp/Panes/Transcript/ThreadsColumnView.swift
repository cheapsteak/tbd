import SwiftUI
import TBDShared

/// Middle column of the 3-pane History layout: lists the Main conversation
/// plus each subagent thread. Selecting a row sets the worktree's drill path
/// (`[]` for Main, `[thread.id]` for a subagent). Random-access index over the
/// flat `sessionThreads(from:)` list.
struct ThreadsColumnView: View {
    let worktreeID: UUID
    let threads: [SessionThread]
    @EnvironmentObject var appState: AppState

    private var path: [String] {
        appState.historyThreadPath[worktreeID] ?? []
    }

    /// Selected row id: the FIRST path element (column shows top-level
    /// selection even when drilled deeper via in-transcript cards), or nil = Main.
    private var selectedID: String? { path.first }

    var body: some View {
        List {
            mainRow
            ForEach(threads) { thread in
                threadRow(thread)
            }
        }
        .listStyle(.plain)
    }

    private var mainRow: some View {
        rowChrome(isSelected: selectedID == nil) {
            Text("Main conversation")
                .font(.callout)
        }
        .onTapGesture { appState.historyThreadPath[worktreeID] = [] }
    }

    private func threadRow(_ thread: SessionThread) -> some View {
        rowChrome(isSelected: selectedID == thread.id) {
            label(for: thread)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .onTapGesture { appState.historyThreadPath[worktreeID] = [thread.id] }
    }

    /// A single inline run of plain text: the agent name (de-emphasized) at the
    /// start, then the description, then a subtle error marker. No icon, badge,
    /// or event count — the column reads as a list of labels.
    private func label(for thread: SessionThread) -> Text {
        var text = Text("")
        if let agentType = thread.agentType, !agentType.isEmpty {
            text = Text("\(agentType) ").foregroundColor(.secondary)
        }
        text = text + Text(thread.description ?? "(no description)")
        if thread.isError {
            text = text + Text("  error").foregroundColor(.red)
        }
        return text
    }

    @ViewBuilder
    private func rowChrome<Content: View>(isSelected: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}
