import Foundation
import TBDShared

/// Which create entries a repository's surfaces offer, and on what terms.
///
/// TBD can start an agent session somewhere other than this machine, and the
/// two kinds of "somewhere" are not the same kind of thing. The **compiled
/// cloud provider** ships with TBD; a user who turned `claude_cloud_enabled`
/// on did so by name, and comes to the `+` menu looking for the thing they
/// enabled. A **registry provider** is one the user wrote into
/// `~/tbd/agent-providers.json` themselves, and TBD enumerating those is the
/// whole service the generic entry provides. So the cloud provider gets an
/// entry of its own on every surface that has a generic one, and is filtered
/// **out** of the generic enumeration rather than surfaced twice — a shortcut
/// that duplicates one member of a list teaches that the list is incomplete
/// somewhere else too.
///
/// Three functions, and no surface derives a gate inline. The flag check lives
/// in two of them and nowhere else, and its subject is narrow enough to state:
/// the daemon registers the compiled provider only when it BOOTED with
/// `claude_cloud_enabled` on, so a provider that was never registered is
/// already absent from `remoteProviders` and needs no filtering. What the flag
/// covers is the other direction — a daemon that booted with the flag on and a
/// user who has since turned it off, where the provider is still registered
/// but every one of its verbs is refused by the daemon's inner gate. Offering
/// an entry that can only fail is exactly what the repository's
/// omit-don't-disable convention exists to prevent.
///
/// Staleness is the opposite case and gets the opposite treatment: it is a
/// transient state of a capability this install *does* have, so a stale
/// provider keeps its entry everywhere and each surface renders it disabled,
/// naming its own reason. See `cloudEntry(_:claudeCloudEnabled:)`.
enum CloudCreateEntryPresentation {
    /// Every provider except the compiled cloud one — what the generic
    /// "New Remote Session" enumeration lists on every surface that has one.
    ///
    /// It takes no flag, because the flag has nothing to say here: cloud is
    /// never a member of this list at any flag value. Every registry provider
    /// passes through untouched, staleness included — a stale row renders
    /// disabled, which is a decision the row makes and not this filter's.
    static func registryProviders(_ providers: [RemoteProviderStatus]) -> [RemoteProviderStatus] {
        providers.filter { $0.config.name != ClaudeCloudProvider.name }
    }

    /// The compiled cloud provider's own entry, or nil when there is none to
    /// offer: the flag is off, or the daemon never registered it.
    ///
    /// A stale snapshot does **not** withdraw the entry. The row is not only a
    /// button — it is also the menu's statement about what exists, and to a
    /// user hunting for a provider they know is configured, absence reads as
    /// "TBD dropped support for this", an error that is both wrong and
    /// unrecoverable from inside the menu. Every surface renders the entry it
    /// gets back disabled and subtitled with its reason, exactly as it already
    /// does for a stale registry provider.
    static func cloudEntry(
        _ providers: [RemoteProviderStatus], claudeCloudEnabled: Bool
    ) -> RemoteProviderStatus? {
        guard claudeCloudEnabled else { return nil }
        return providers.first { $0.config.name == ClaudeCloudProvider.name }
    }

    /// Whether one already-registered provider may be created against — the
    /// per-provider verdict the Remote section's provider header row needs for
    /// its own `+`, where the surface is handed a single provider rather than
    /// a list to enumerate. True for every provider except the compiled cloud
    /// one with the flag off. Staleness stays a separate axis: the header
    /// still renders its `+` for a stale provider and disables the button.
    static func offersCreate(
        provider: RemoteProviderStatus, claudeCloudEnabled: Bool
    ) -> Bool {
        provider.config.name != ClaudeCloudProvider.name || claudeCloudEnabled
    }
}
