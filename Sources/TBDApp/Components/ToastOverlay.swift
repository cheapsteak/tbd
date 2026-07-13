import SwiftUI

/// Renders `AppState.activeToast` as a bottom-right-anchored floating capsule.
/// Purely presentational: every interaction (hover, CTA, dismiss) is
/// forwarded to the AppState toast state machine (AppState+Toast.swift),
/// which owns the countdown task and all transitions.
struct ToastOverlay: View {
    @EnvironmentObject var appState: AppState

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
    @EnvironmentObject var appState: AppState
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            leadingIndicator
            Text(toast.message)
                .lineLimit(2)
            trailingControls
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
        .onHover { appState.toastHoverChanged($0) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch toast.style {
        case .progress:
            ProgressView().controlSize(.small)
        case .countdown, .action:
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch toast.style {
        case .countdown(let secondsRemaining):
            Text("in \(secondsRemaining)…")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .action(let ctaLabel):
            Button(ctaLabel) { appState.toastCTAAction?() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                appState.dismissToast()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        case .progress, .error:
            EmptyView()
        }
    }
}
