import Testing
import Foundation
@testable import TBDApp
import TBDShared

/// Covers the two gates behind the worktree row's create context-menu items —
/// `WorktreeRowView.remoteSessionMenuProviders(providers:isMain:)` for the
/// generic "New Remote Session…" item and
/// `cloudSessionMenuEntry(providers:claudeCloudEnabled:isMain:)` for the
/// compiled provider's "New Cloud Session…" item beside it. The two are the
/// always-opens-the-form twins of the nested `+`'s two lane rows. Every branch
/// they have (no provider / one / several, the cloud flag, the main-row gate,
/// staleness) is decided here, so it is decided somewhere a test can reach
/// without an `AppState` or a view hierarchy — the same treatment
/// `RepoSectionView`'s copies of the two items get.
@Suite("WorktreeRowView — remote create menu items")
struct WorktreeRowRemoteSessionMenuTests {

    private func provider(
        _ name: String,
        describeName: String? = nil,
        health: ProviderHealth = .ok,
        freshnessUnreadable: Bool = false
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/usr/bin/true"),
            describe: ProviderDescribe(contractVersions: [2], name: describeName ?? name,
                                       capabilities: ["send"]),
            health: health, errorMessage: nil, remediationLabel: nil, remediationCommand: nil,
            freshnessUnreadable: freshnessUnreadable)
    }

    private var both: [RemoteProviderStatus] {
        [provider("acme"), provider(ClaudeCloudProvider.name)]
    }

    private func names(
        _ providers: [RemoteProviderStatus], isMain: Bool = false
    ) -> [String] {
        WorktreeRowView.remoteSessionMenuProviders(providers: providers, isMain: isMain)
            .map(\.config.name)
    }

    private func cloudName(
        _ providers: [RemoteProviderStatus], claudeCloudEnabled: Bool = true, isMain: Bool = false
    ) -> String? {
        WorktreeRowView.cloudSessionMenuEntry(
            providers: providers, claudeCloudEnabled: claudeCloudEnabled, isMain: isMain)?
            .config.name
    }

    // MARK: - the provider-registered gate

    /// No provider registered → the item is omitted whole, not shown disabled,
    /// matching `RepoSectionView.newRemoteSessionMenuItem`.
    @Test func noRegisteredProviderLeavesNothingToOffer() {
        #expect(names([]).isEmpty)
    }

    // MARK: - one vs. many providers

    /// One provider is the plain-`Button` shape; the count is what the view
    /// branches on.
    @Test func oneProviderTakesTheSingleButtonFastPath() {
        #expect(names([provider("acme")]) == ["acme"])
    }

    @Test func severalProvidersFillTheSubmenu() {
        #expect(names([provider("acme"), provider("widgets")]) == ["acme", "widgets"])
    }

    /// The one-versus-many count is a count of REGISTRY providers: with cloud
    /// plus one configured provider on file, the generic item must be the
    /// one-provider shape, because cloud is not one of its members.
    @Test func theFastPathCountsRegistryProvidersOnly() {
        #expect(names(both) == ["acme"])
        #expect(names([provider("acme"), provider("widgets"),
                       provider(ClaudeCloudProvider.name)]).count == 2)
    }

    // MARK: - the cloud item is a sibling, never a member

    /// The compiled provider has an item of its own, so it never appears in
    /// the generic enumeration — surfacing it in both would make the count
    /// above ambiguous at exactly the moment it decides button versus submenu.
    @Test func theCloudProviderIsNeverListedInTheGenericItem() {
        #expect(!names(both).contains(ClaudeCloudProvider.name))
    }

    @Test func theCloudItemIsOmittedWhenTheFlagIsOff() {
        #expect(cloudName(both, claudeCloudEnabled: false) == nil)
    }

    /// The discriminating half: the gate does not simply always drop it.
    @Test func theCloudItemIsOfferedWhenTheFlagIsOn() {
        #expect(cloudName(both, claudeCloudEnabled: true) == ClaudeCloudProvider.name)
    }

    @Test func theCloudItemIsOmittedWhenTheProviderWasNeverRegistered() {
        #expect(cloudName([provider("acme")], claudeCloudEnabled: true) == nil)
    }

    /// The cloud flag is not the generic item's business in either direction.
    @Test func theGenericItemIsUnaffectedByTheCloudFlag() {
        #expect(names(both) == ["acme"])
        #expect(names([provider("acme")]) == ["acme"])
    }

    // MARK: - the main-row gate

    /// The main worktree is the repo's checkout, not a parent to nest under —
    /// the nested `+` is withheld from that row, and so are BOTH items.
    @Test func theMainRowOffersNeitherCreateItem() {
        #expect(names(both, isMain: true).isEmpty)
        #expect(names([provider("acme")], isMain: true).isEmpty)
        #expect(cloudName(both, isMain: true) == nil)
    }

    /// The discriminating half: the same providers on an ordinary row DO
    /// produce both items, so `isMain` gates rather than disables everything.
    @Test func anOrdinaryRowOffersBothItemsForTheSameProviders() {
        #expect(names(both, isMain: false) == ["acme"])
        #expect(cloudName(both, isMain: false) == ClaudeCloudProvider.name)
    }

    // MARK: - staleness disables, it does not omit

    /// A stale provider keeps its item (the view disables it) rather than
    /// vanishing — the menu's statement that the provider exists is worth
    /// keeping through a transient outage.
    @Test func aStaleProviderIsStillListedSoTheRowCanExplainItself() {
        let stale = provider("acme", health: .stale, freshnessUnreadable: true)
        #expect(stale.hasStaleSnapshot)
        #expect(names([stale]) == ["acme"])
    }

    /// And the cloud item converges on that: staleness disables it, exactly
    /// as it disables a stale registry provider's row, rather than
    /// withdrawing the entry.
    @Test func aStaleCloudProviderStillOffersItsItem() {
        let stale = provider(ClaudeCloudProvider.name, health: .stale, freshnessUnreadable: true)
        #expect(stale.hasStaleSnapshot)
        #expect(cloudName([provider("acme"), stale]) == ClaudeCloudProvider.name)
    }
}
