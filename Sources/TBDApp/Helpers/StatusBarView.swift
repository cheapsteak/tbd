import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            Circle()
                .fill(appState.isConnected ? .green : .red)
                .frame(width: 8, height: 8)
            Text(appState.isConnected ? "tbdd connected" : "tbdd disconnected")
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
