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
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
                Text("Main conversation")
                    .font(.callout)
            }
        }
        .onTapGesture { appState.historyThreadPath[worktreeID] = [] }
    }

    private func threadRow(_ thread: SessionThread) -> some View {
        rowChrome(isSelected: selectedID == thread.id) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                    Text(thread.description ?? "(no description)")
                        .font(.callout)
                        .lineLimit(2)
                }
                HStack(spacing: 4) {
                    if let agentType = thread.agentType, !agentType.isEmpty {
                        Text(agentType)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Text("\(thread.itemCount) events")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if thread.isError {
                        Text("error")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.red.opacity(0.2))
                            .clipShape(Capsule())
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .onTapGesture { appState.historyThreadPath[worktreeID] = [thread.id] }
    }

    @ViewBuilder
    private func rowChrome<Content: View>(isSelected: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}
