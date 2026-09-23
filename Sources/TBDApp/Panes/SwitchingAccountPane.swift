import SwiftUI
import TBDShared

// MARK: - SwitchingAccount

/// A terminal whose account "Switch account" is changing in place, for as long
/// as the `terminal.swapProfile` RPC is in flight.
///
/// On the pty-holder transport that RPC parks the row, re-homes it and wakes it
/// again, and each half broadcasts a hibernation delta. Without this record the
/// pane reads those flips as an ordinary park and wake: it rebuilds into the
/// hibernated placeholder, banner and all, and then rebuilds again into a fresh
/// attach. With it, the pane keeps what it was showing under a caption naming
/// the destination, and rebuilds once, when the wake lands.
struct SwitchingAccount: Equatable, Sendable {
    /// The destination profile's name, or nil for the ambient account (and for
    /// a profile the app has not loaded, which it cannot name).
    let profileName: String?

    /// What the pane says while the switch runs.
    var caption: String {
        if let profileName { return "Switching account to \(profileName)…" }
        return "Switching account…"
    }
}

// MARK: - TerminalPanePresentation

/// Pure decisions behind a terminal pane's identity and its parked chrome, so
/// each branch — switching or not — is unit-testable without mounting a
/// terminal view (same pattern as `ParkedPaneWakeModel`).
enum TerminalPanePresentation {
    /// The SwiftUI identity of the terminal view, which is what decides when
    /// it is torn down and rebuilt.
    ///
    /// An ordinary pane includes the parked state, so it rebuilds on every
    /// flip: into the frozen placeholder on a park, into a fresh attach on a
    /// wake. A switching pane leaves the parked state out and reads as awake,
    /// so neither setting the record nor the swap's park rebuilds it, and the
    /// view it already had keeps showing the session's last frame. What
    /// rebuilds it is `attachEpoch`, which `AppState` advances once per
    /// successful switch — on the wake's delta, or on the swap's reply when
    /// nothing advanced it first (see `applySwitchedTerminalWake`) — and which
    /// stays advanced after the record clears, so clearing it does not rebuild
    /// the pane a second time.
    static func identity(
        for terminal: Terminal, switching: SwitchingAccount?, attachEpoch: Int
    ) -> String {
        let parked = switching == nil ? terminal.isParked : false
        return "\(terminal.id)-\(terminal.tmuxWindowID)-\(parked)-\(attachEpoch)"
    }

    /// The notice composed into a parked pane's frozen snapshot, or nil.
    ///
    /// A switching pane gets none: the row is parked only as a step of the
    /// switch, and a "Hibernated" notice telling the user how to reattach
    /// would describe a state the swap is about to leave by itself. The
    /// caption says what is happening instead.
    static func parkedNoticeMessage(
        for terminal: Terminal, switching: SwitchingAccount?
    ) -> String? {
        guard terminal.isParked, switching == nil else { return nil }
        return HibernatedBannerModel.message(for: terminal.hibernateReason)
    }

    /// Whether the pane gets the full-surface click-to-wake layer. Never while
    /// switching: the swap wakes the row itself, and a click would only race
    /// it for a claim the swap already holds.
    static func showsWakeOverlay(
        for terminal: Terminal?, switching: SwitchingAccount?
    ) -> Bool {
        switching == nil && ParkedPaneWakeModel.showsWakeOverlay(for: terminal)
    }

    /// The caption over the pane, or nil. Shown only while the switch has the
    /// row parked: before the park the session is still live and painting, and
    /// after the wake the fresh attach is the news.
    static func switchingCaption(
        for terminal: Terminal?, switching: SwitchingAccount?
    ) -> String? {
        guard let switching, terminal?.isParked == true else { return nil }
        return switching.caption
    }
}

// MARK: - SwitchingAccountCaptionOverlay

/// The "Switching account to …" caption laid over a terminal pane while an
/// in-place account switch has its row parked. Draws nothing otherwise.
struct SwitchingAccountCaptionOverlay: View {
    static let accessibilityID = "terminal-switching-account-caption"

    let terminal: Terminal?
    let switching: SwitchingAccount?

    var body: some View {
        if let caption = TerminalPanePresentation.switchingCaption(
            for: terminal, switching: switching) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(caption)
            }
            .font(.callout)
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(caption)
            .accessibilityIdentifier(Self.accessibilityID)
        }
    }
}
