import SwiftUI
import TBDShared

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    private var selectedWorktreePath: String? {
        guard appState.selectedWorktreeIDs.count == 1,
              let id = appState.selectedWorktreeIDs.first,
              let worktree = appState.worktrees.values.flatMap({ $0 }).first(where: { $0.id == id }),
              !worktree.path.isEmpty else { return nil }
        return worktree.path
    }

    var body: some View {
        HStack {
            Circle()
                .fill(appState.isConnected ? .green : .red)
                .frame(width: 8, height: 8)
            Text(appState.isConnected ? "tbdd connected" : "tbdd disconnected")
            Spacer()
            if let path = selectedWorktreePath {
                OpenInEditorButton(path: path)
            }
            Text("v\(TBDConstants.version)")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
