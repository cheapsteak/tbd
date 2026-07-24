import Foundation

// MARK: - Toast state machine
//
// One toast at a time. All transitions run on the main actor. Transient
// toasts (notice/error) auto-dismiss after ~4 ticks; the dismiss task is
// owned here (not by the view) so it fires even if the overlay view rebuilds.
// `toastTickDuration` is the injectable clock seam for tests.
extension AppState {

    /// Show `toast`, replacing any current one and cancelling its dismiss task.
    @MainActor
    func showToast(_ toast: Toast) {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        activeToast = toast
    }

    @MainActor
    func dismissToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        activeToast = nil
    }

    /// Show a transient toast that auto-dismisses after ~4 ticks
    /// (~4s in production, milliseconds under test).
    @MainActor
    func showTransientToast(_ message: String, style: Toast.Style) {
        showToast(Toast(id: UUID(), message: message, style: style))
        let toastID = activeToast?.id
        let delay = toastTickDuration * 4
        toastDismissTask = Task { @MainActor [weak self] in
            // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  let self, self.activeToast?.id == toastID else { return }
            self.dismissToast()
        }
    }

    /// Show an error toast that auto-dismisses.
    @MainActor
    func showErrorToast(_ message: String) {
        showTransientToast(message, style: .error)
    }
}
