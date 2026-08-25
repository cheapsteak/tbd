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

    /// The providers the `+` picker's remote-lane row may offer.
    ///
    /// The picker enumerates every registered provider, so the cloud entry
    /// needs no row of its own — but it does keep its own gate, which is
    /// strictly narrower than `createProviders`: `cloudProvider` also
    /// withdraws it on a stale inventory, where the context menu and the
    /// Remote header instead render a disabled control. Expressing that as a
    /// filter over the full list keeps one gate for the cloud provider and
    /// leaves every other provider to the row's own staleness handling.
    static func pickerProviders(
        _ providers: [RemoteProviderStatus], claudeCloudEnabled: Bool
    ) -> [RemoteProviderStatus] {
        let cloud = cloudProvider(providers, claudeCloudEnabled: claudeCloudEnabled)
        return createProviders(providers, claudeCloudEnabled: claudeCloudEnabled)
            .filter { $0.config.name != ClaudeCloudProvider.name || cloud != nil }
    }

    /// The compiled cloud provider, when there is one to offer. Nil when the
    /// flag is off, when the daemon never registered it, or when its
    /// inventory is stale. `pickerProviders` — the `+` picker's gate, and
    /// this function's only caller — withdraws the cloud entry outright on a
    /// stale snapshot, unlike the context menu and the Remote section header,
    /// which both disable their own `+` on `hasStaleSnapshot`. A create the
    /// daemon would refuse with "inventory is stale" is worth no row at all.
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
