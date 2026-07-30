import SwiftUI
import TBDShared

/// A remote-session `attach`: `<exec> [args...] attach <id>` spawned on a
/// plain PTY by the shared `LocalPTYTerminalRepresentable` host — no tmux
/// window-recreate, hibernation, or control-mode machinery, since a
/// provider's `attach` is just "exec me and get out of the way"
/// (`docs/remote-provider-contract.md` § `attach`). This type contributes
/// the two things that ARE attach-specific: the argv and the environment.
///
/// Per the contract, pane exit means the viewer detached — it never means
/// the remote session died (only `list`/`events` are authoritative about
/// that). This view itself no longer renders the "Detached" overlay: since
/// attach is now mounted across MULTIPLE sessions at once by
/// `RemoteAttachPager` (bounded keep-alive, see `RemoteAttachLifecycle`),
/// the decision of "should this still be mounted at all" has to survive
/// this view's own instance being torn down and recreated (a detached
/// session that ages out of the keep-alive cap gets a BRAND NEW instance
/// when the user comes back to it) — so detach state lives on `AppState`
/// instead (`AppState.explicitlyDetachedRemoteSessions`, written via
/// `onDetached` below) and the overlay/Reattach UI is rendered by
/// `RemoteSessionDetailView`, which persists across that churn. This view
/// is now just the bare terminal host plus one pure classification helper.
struct RemoteAttachTerminalView: View {
    let provider: RemoteProviderConfig
    let sessionID: String
    /// Called once when the local attach process ends, for any reason
    /// (clean exit, crash, unreachable host). Never implies the remote
    /// session died — only that this local viewer process stopped.
    let onDetached: (Int32?) -> Void
    @EnvironmentObject var appearance: AppearanceSettings

    /// Whether the local `attach` process ended in the UNEXPECTED class —
    /// a transport failure (unreachable host, dropped connection, crashed
    /// shim) rather than the user detaching.
    ///
    /// This is a projection of the three-way `RemoteAttachExitClass`, not a
    /// "non-zero means bad" test: an AUTH-class exit (exit 4 — the provider
    /// can't authenticate) is deliberately NOT unexpected here, because
    /// retrying was never the problem and framing it as a surprise session
    /// exit sends the user to the wrong remedy. That case gets its own CTA
    /// (`RemoteProviderAuthPresentation`). `nil` (no exit code available) is
    /// also not unexpected: there's nothing here to confidently call a
    /// failure.
    ///
    /// Either way the session itself is unaffected — only the caller's
    /// framing (title/icon) should change, never the "keeps running
    /// remotely" contract line.
    static func isUnexpectedExit(exitCode: Int32?) -> Bool {
        RemoteAttachExitClass.classify(exitCode: exitCode) == .unexpected
    }

    var body: some View {
        LocalPTYTerminalRepresentable(
            argv: provider.argv + ["attach", sessionID],
            environment: Self.attachEnvironment(),
            appearance: appearance,
            onExit: onDetached
        )
    }

    /// The child environment for a provider `attach`.
    ///
    /// Strips TMUX/TMUX_PANE like `TerminalPanelView.makeViewerEnvironment`
    /// does — the provider may itself exec tmux on the far side, and a
    /// nested-attach guard failure there is the same failure mode a nested
    /// LOCAL tmux attach hits.
    ///
    /// `docs/remote-provider-contract.md` normatively requires
    /// `TBD_CONTRACT_VERSION` on EVERY invocation — `ProviderRunner` and
    /// `ProviderEventsSupervisor` both set it, and this is the third (and
    /// only app-side) spawn site. Without it, a provider that branches on
    /// the contract version (the document's own version-negotiation
    /// mechanism) would see a different answer for `attach` than for every
    /// other verb. It is deliberately NOT set by the other user of
    /// `LocalPTYTerminalRepresentable` (the remediation terminal), which
    /// runs an opaque user-facing command rather than a contract verb.
    static func attachEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = TerminalPanelView.makeViewerEnvironment(base: base)
        env["TBD_CONTRACT_VERSION"] = "1"
        return env
    }
}
