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

    /// The compiled cloud provider, when there is one to offer. Nil both when
    /// the flag is off and when the daemon never registered it.
    static func cloudProvider(
        _ providers: [RemoteProviderStatus], claudeCloudEnabled: Bool
    ) -> RemoteProviderStatus? {
        guard claudeCloudEnabled else { return nil }
        return providers.first { $0.config.name == ClaudeCloudProvider.name }
    }
}
