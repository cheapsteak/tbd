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
    /// The provider's display name (its `describe.name` when it has one,
    /// otherwise the registry name).
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

    /// Builds the CTA for `status`, or `nil` when there is nothing to show:
    /// no provider, or a provider whose health is anything other than
    /// `.needsAuth`. Health is the ONLY gate — the presence or absence of a
    /// message/label/command never suppresses the CTA, it only changes how
    /// much of it is provider-supplied.
    static func make(from status: RemoteProviderStatus?) -> RemoteProviderAuthPresentation? {
        guard let status, status.health == .needsAuth else { return nil }
        return RemoteProviderAuthPresentation(
            providerName: status.describe?.name ?? status.config.name,
            message: nonBlank(status.errorMessage) ?? fallbackMessage,
            actionLabel: nonBlank(status.remediationLabel) ?? fallbackActionLabel,
            command: nonBlank(status.remediationCommand)
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
