import Testing
import Foundation
@testable import TBDApp
import TBDShared

/// Covers the two gates behind the repo header menu's create items —
/// `CloudCreateEntryPresentation.registryProviders(_:)` for the generic
/// "New Remote Session…" item, and
/// `cloudEntry(_:claudeCloudEnabled:)` for the compiled provider's
/// "New Cloud Session…" item beside it. `SidebarMenus` calls both directly,
/// so every branch is decided somewhere a test can reach without an
/// `AppState` or a view hierarchy.
@Suite("Repo header — remote create menu items")
struct RepoHeaderRemoteCreateMenuTests {

    private func provider(
        _ name: String, health: ProviderHealth = .ok, freshnessUnreadable: Bool = false
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/usr/bin/true"),
            describe: ProviderDescribe(contractVersions: [2], name: name, capabilities: ["send"]),
            health: health, errorMessage: nil, remediationLabel: nil, remediationCommand: nil,
            freshnessUnreadable: freshnessUnreadable)
    }

    private var both: [RemoteProviderStatus] {
        [provider("acme"), provider(ClaudeCloudProvider.name)]
    }

    private func names(_ providers: [RemoteProviderStatus]) -> [String] {
        CloudCreateEntryPresentation.registryProviders(providers).map(\.config.name)
    }

    private func cloudName(
        _ providers: [RemoteProviderStatus], claudeCloudEnabled: Bool
    ) -> String? {
        CloudCreateEntryPresentation.cloudEntry(
            providers, claudeCloudEnabled: claudeCloudEnabled)?.config.name
    }

    // MARK: - the generic item enumerates registry providers only

    /// No provider registered → the item is omitted whole, not shown disabled.
    @Test func noRegisteredProviderLeavesNothingToOffer() {
        #expect(names([]).isEmpty)
    }

    @Test func registryProvidersFillTheItemInOrder() {
        #expect(names([provider("acme"), provider("widgets")]) == ["acme", "widgets"])
    }

    /// The compiled provider has an item of its own, so it is never a member
    /// of this enumeration — which is also what keeps the one-versus-many
    /// count (button versus submenu) a count of registry providers.
    @Test func theCloudProviderIsNeverListedInTheGenericItem() {
        #expect(names(both) == ["acme"])
        #expect(names([provider(ClaudeCloudProvider.name)]).isEmpty)
    }

    /// A stale registry provider keeps its row — the view disables it.
    @Test func aStaleRegistryProviderIsStillListed() {
        let stale = provider("acme", health: .stale, freshnessUnreadable: true)
        #expect(stale.hasStaleSnapshot)
        #expect(names([stale]) == ["acme"])
    }

    // MARK: - the cloud item's own gate

    @Test func theCloudItemIsOmittedWhenTheFlagIsOff() {
        #expect(cloudName(both, claudeCloudEnabled: false) == nil)
    }

    /// The discriminating half: with the flag on the item is offered, so the
    /// gate did not simply delete it.
    @Test func theCloudItemIsOfferedWhenTheFlagIsOn() {
        #expect(cloudName(both, claudeCloudEnabled: true) == ClaudeCloudProvider.name)
    }

    /// The flipped-on-without-restart state: the daemon never registered the
    /// provider, so there is nothing to offer whichever way the flag points.
    @Test func theCloudItemIsOmittedWhenTheProviderWasNeverRegistered() {
        for flag in [true, false] {
            #expect(cloudName([provider("acme")], claudeCloudEnabled: flag) == nil)
        }
    }

    /// Staleness disables rather than withdraws: the item stays so the menu
    /// can name its own reason, exactly as the generic item does for a stale
    /// registry provider.
    @Test func aStaleCloudProviderStillOffersItsItem() {
        let stale = provider(ClaudeCloudProvider.name, health: .stale, freshnessUnreadable: true)
        #expect(stale.hasStaleSnapshot)
        #expect(cloudName([provider("acme"), stale], claudeCloudEnabled: true)
            == ClaudeCloudProvider.name)
    }
}
