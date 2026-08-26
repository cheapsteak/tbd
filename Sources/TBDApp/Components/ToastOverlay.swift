import SwiftUI

/// Renders `AppState.activeToast` as a bottom-right-anchored floating capsule.
/// Purely presentational: it only reflects the current toast style. All
/// transitions and auto-dismiss timing are owned by the AppState toast state
/// machine (AppState+Toast.swift).
struct ToastOverlay: View {
    @Environment(AppState.self) var appState

    var body: some View {
        Group {
            if let toast = appState.activeToast {
                ToastCard(toast: toast)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: appState.activeToast)
    }
}

private struct ToastCard: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            leadingIndicator
            Text(toast.message)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .padding(.trailing, 16)
        .padding(.bottom, 34)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch toast.style {
        case .progress:
            ProgressView().controlSize(.small)
        case .notice:
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
        case .success:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
        }
    }
}
