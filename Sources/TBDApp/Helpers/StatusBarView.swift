import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    private var activeWorktreeCount: Int {
        appState.worktrees.values.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        HStack {
            Circle()
                .fill(appState.isConnected ? .green : .red)
                .frame(width: 8, height: 8)
            Text(appState.isConnected ? "tbdd connected" : "tbdd disconnected")
            Spacer()
            Text("\(activeWorktreeCount) active worktree\(activeWorktreeCount == 1 ? "" : "s")")
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
