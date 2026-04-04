import SwiftUI
import TBDShared

struct ConductorSuggestionBar: View {
    @EnvironmentObject var appState: AppState
    let suggestion: ConductorSuggestion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 12))

            Text(suggestion.worktreeName)
                .fontWeight(.medium)
                .font(.caption)

            if let label = suggestion.label {
                Text("— \(label)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Spacer()

            Button("Go") {
                navigateToSuggestion()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                appState.conductorSuggestion = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func navigateToSuggestion() {
        appState.selectedWorktreeIDs = [suggestion.worktreeID]
        appState.conductorSuggestion = nil
    }
}
