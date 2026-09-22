import Foundation
import TBDShared

/// The pure presentation model behind the provider-authentication CTA: what
/// to say, what to call the action, and which command (if any) to offer to
/// run. No SwiftUI — the two surfaces that render it (the session detail
/// pane and the sidebar provider header's popover) share this one decision
/// so they can never disagree about what a given provider status means.
///
/// Everything vendor-specific belongs to the PROVIDER, not to TBD: the
/// message and the remediation are whatever the provider emitted in its
/// error object (`docs/remote-provider-contract.md` § Error model), rendered
/// verbatim. TBD's own strings are deliberately generic — they describe the
/// contract-level condition ("this provider can't authenticate"), never a
/// particular backend, credential system, or login flow. `remediation` is
/// opaque: it gets displayed and, on request, executed as text — never
/// parsed, split, or rewritten.
struct RemoteProviderAuthPresentation: Equatable {
    /// How the provider is named to the user: its REGISTRY key, which is
    /// unique by construction, falling back to `describe.name` and then to
    /// the caller's own fallback. The remedy a user has to run is scoped to
    /// the registered entry, and two registrations of the same provider kind
    /// share a `describe.name` that cannot say which one needs
    /// re-authenticating — see `RemoteProviderIdentityPresentation`.
    let providerName: String
    /// The explanatory line. The provider's `errorMessage` when it supplied
    /// one, else `fallbackMessage`.
    let message: String
    /// The label for the primary action. The provider's `remediationLabel`
    /// when it supplied one, else `fallbackActionLabel`.
    let actionLabel: String
    /// The remediation command, verbatim and opaque. `nil` when the provider
    /// supplied none — then the CTA is informational only, with no run
    /// button and nothing to copy.
    let command: String?

    /// Used when the provider gave no message. Says only what TBD actually
    /// knows from the contract: the provider can't authenticate, and (per §
    /// `attach`) the sessions themselves are unaffected.
    static let fallbackMessage = "This provider can't authenticate right now. Its sessions keep running."

    /// Used when the provider gave no remediation label. Neutral by
    /// construction — TBD has no idea what re-authenticating means for a
    /// given provider, so it doesn't pretend to.
    static let fallbackActionLabel = "Re-authenticate"

    /// Builds the CTA, or `nil` when there is nothing to show.
    ///
    /// Two INDEPENDENT signals light it, and either one is enough:
    ///
    /// - `status.health == .needsAuth` — the daemon's published provider
    ///   health, which is what the provider-level surfaces (the sidebar
    ///   header) have and all they should ever need.
    /// - `localAuthExit` — the caller's OWN knowledge that the attach it was
    ///   showing exited in the auth class. The app classifies that exit
    ///   itself and only *reports* it to the daemon fire-and-forget, so
    ///   gating purely on health would leave a gap between the exit and
    ///   health flipping — and an indefinite one whenever the report fails.
    ///   In that gap the session pane fell back to the calm
    ///   "Detached / Reattach" prompt whose Reattach button bypasses both
    ///   backoff and the health gate, i.e. exactly the "reattach just fails
    ///   again" experience this CTA exists to replace.
    ///
    /// Everything the CTA SAYS still comes from `status` alone, so the
    /// local signal changes only whether it shows, never what it claims.
    /// With no status at all the CTA is entirely generic — which is correct:
    /// the app knows the provider couldn't authenticate without yet knowing
    /// anything the provider had to say about it.
    ///
    /// `providerName` resolves registry name → `describe.name` →
    /// `fallbackProviderName` (the caller's own name for the provider, e.g.
    /// a selection's `provider`). `nil` when none of the three exists, since
    /// a CTA with nothing to name isn't worth showing. The registry key
    /// leads because it is what identifies the registration a user has to go
    /// and re-authenticate.
    static func make(
        from status: RemoteProviderStatus?,
        fallbackProviderName: String? = nil,
        localAuthExit: Bool = false
    ) -> RemoteProviderAuthPresentation? {
        guard status?.health == .needsAuth || localAuthExit else { return nil }
        // Registry key first: the remedy a user has to run is scoped to the
        // registered entry, and two entries of the same kind share a
        // `describe.name` that cannot say which one needs re-authenticating.
        guard let providerName = nonBlank(status?.config.name)
            ?? nonBlank(status?.describe?.name)
            ?? nonBlank(fallbackProviderName) else { return nil }
        return RemoteProviderAuthPresentation(
            providerName: providerName,
            message: nonBlank(status?.errorMessage) ?? fallbackMessage,
            actionLabel: nonBlank(status?.remediationLabel) ?? fallbackActionLabel,
            command: nonBlank(status?.remediationCommand)
        )
    }

    /// A present-but-blank string is treated exactly like an absent one — a
    /// provider that emits `"remediation": {"label": ""}` must not produce a
    /// button with no words on it.
    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Builds the argv for running a provider-supplied remediation command.
///
/// Interactive login flows need a real terminal AND a real login
/// environment, so the command runs through the user's login shell
/// (`$SHELL -lc <command>`) rather than being exec'd directly: without the
/// profile, a command installed by a version manager or in a
/// non-default prefix simply isn't on `PATH`.
///
/// The command itself is passed as ONE argv element and is never inspected.
/// TBD builds no shell string of its own beyond that single `-lc` argument —
/// no interpolation, no splitting, no quoting, no rewriting. The command is
/// the provider's, opaque by contract.
enum RemoteRemediationCommand {
    /// Shells tried in order when `$SHELL` is unset or not executable.
    static let fallbackShells = ["/bin/zsh", "/bin/sh"]

    static func loginShellArgv(
        command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [String] {
        let candidates = ([environment["SHELL"]].compactMap { $0 } + fallbackShells)
            .filter { !$0.isEmpty }
        // The final `?? "/bin/sh"` is unreachable on a working macOS install
        // (that path is in `fallbackShells`), but spawning something is a
        // better failure than silently doing nothing.
        let shell = candidates.first(where: isExecutable) ?? "/bin/sh"
        return [shell, "-lc", command]
    }
}
