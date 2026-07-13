import Foundation

// MARK: - Toast state machine
//
// One toast at a time. All transitions run on the main actor. The countdown
// is owned here (not by the view) so expiry fires even if the overlay view
// rebuilds. `toastTickDuration` is the injectable clock seam for tests.
extension AppState {

    /// Show `toast`, replacing any current one and cancelling its countdown.
    @MainActor
    func showToast(_ toast: Toast) {
        toastCountdownTask?.cancel()
        toastCountdownTask = nil
        toastCTAAction = nil
        activeToast = toast
    }

    @MainActor
    func dismissToast() {
        toastCountdownTask?.cancel()
        toastCountdownTask = nil
        toastCTAAction = nil
        activeToast = nil
    }

    /// Start a `seconds`→1 countdown on the active toast. When it reaches
    /// zero the toast is dismissed and `onExpiry` runs. Cancelled by hover
    /// (`toastHoverChanged`), dismissal, or a replacing toast.
    @MainActor
    func startToastCountdown(
        seconds: Int = 5, onExpiry: @escaping @MainActor () -> Void
    ) {
        toastCountdownTask?.cancel()
        guard var toast = activeToast else { return }
        toast.style = .countdown(secondsRemaining: seconds)
        activeToast = toast
        let toastID = toast.id
        let tick = toastTickDuration
        toastCountdownTask = Task { @MainActor [weak self] in
            for remaining in stride(from: seconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled,
                      let self, self.activeToast?.id == toastID else { return }
                if remaining > 0 {
                    self.activeToast?.style = .countdown(secondsRemaining: remaining)
                }
            }
            guard !Task.isCancelled, let self,
                  self.activeToast?.id == toastID else { return }
            self.dismissToast()
            onExpiry()
        }
    }

    /// Pointer entered/left the toast. Entering during a countdown cancels it
    /// permanently (no resume on exit — decided in spec) and swaps in the CTA.
    @MainActor
    func toastHoverChanged(_ hovering: Bool) {
        guard hovering, case .countdown = activeToast?.style else { return }
        toastCountdownTask?.cancel()
        toastCountdownTask = nil
        activeToast?.style = .action(ctaLabel: "Go to archive entry")
    }

    /// Show an error toast that auto-dismisses after ~4 ticks
    /// (~4s in production, milliseconds under test).
    @MainActor
    func showErrorToast(_ message: String) {
        showToast(Toast(id: UUID(), message: message, style: .error))
        let toastID = activeToast?.id
        let delay = toastTickDuration * 4
        toastCountdownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  let self, self.activeToast?.id == toastID else { return }
            self.dismissToast()
        }
    }
}
