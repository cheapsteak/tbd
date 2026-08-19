import Foundation
import TBDShared

/// Which providers a repository's create surfaces offer.
///
/// The daemon registers the compiled cloud provider only when it BOOTED with
/// `claude_cloud_enabled` on, so a provider that is absent is already absent
/// from `remoteProviders` and needs no filtering. What this gate covers is the
/// other direction: a daemon that booted with the flag on and a user who has
/// since turned it off, where the provider is still registered but every one
/// of its verbs is refused by the daemon's inner gate. Offering an entry that
/// can only fail is exactly what the repository's omit-don't-disable
/// convention exists to prevent.
enum CloudCreateEntryPresentation {
    /// The providers the "New Remote Session…" enumeration should list.
    static func createProviders(
        _ providers: [RemoteProviderStatus], claudeCloudEnabled: Bool
    ) -> [RemoteProviderStatus] {
        guard !claudeCloudEnabled else { return providers }
        return providers.filter { $0.config.name != ClaudeCloudProvider.name }
    }

    /// The compiled cloud provider, when there is one to offer. Nil when the
    /// flag is off, when the daemon never registered it, or when its
    /// inventory is stale. The `+` picker's cloud row (this function's only
    /// caller) has no disabled state of its own — unlike the context menu
    /// and the Remote section header, which both disable their own `+` on
    /// `hasStaleSnapshot` — so a stale snapshot has to remove the row the
    /// same way an absent provider does, or the sheet would open onto a
    /// create call the daemon refuses with "inventory is stale".
    static func cloudProvider(
        _ providers: [RemoteProviderStatus], claudeCloudEnabled: Bool
    ) -> RemoteProviderStatus? {
        guard claudeCloudEnabled else { return nil }
        guard let provider = providers.first(where: { $0.config.name == ClaudeCloudProvider.name }) else {
            return nil
        }
        return provider.hasStaleSnapshot ? nil : provider
    }
}
