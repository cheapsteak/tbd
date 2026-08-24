import Testing
import Foundation
@testable import TBDApp
import TBDShared

/// Covers `WorktreeRowView.remoteSessionMenuProviders(providers:claudeCloudEnabled:isMain:)`
/// — the gate behind the worktree row's "New Remote Session…" context-menu
/// item, which is the always-opens-the-form twin of the nested `+`'s
/// remote-lane row. Every branch the item has (no provider / one / several,
/// the cloud filter, the main-row gate, staleness) is decided here, so it is
/// decided somewhere a test can reach without an `AppState` or a view
/// hierarchy — the same treatment `RepoSectionView.remoteSessionMenuProviders`
/// gets for the repo header's copy of the item.
@Suite("WorktreeRowView — New Remote Session menu item")
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
        _ providers: [RemoteProviderStatus], claudeCloudEnabled: Bool = true, isMain: Bool = false
    ) -> [String] {
        WorktreeRowView.remoteSessionMenuProviders(
            providers: providers, claudeCloudEnabled: claudeCloudEnabled, isMain: isMain)
            .map(\.config.name)
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

    /// The fast-path count must be read off the FILTERED list: with the flag
    /// off and cloud plus one registry provider on file, the item must be the
    /// one-provider shape, not a two-entry submenu with a dead row.
    @Test func theFastPathIsDecidedAfterTheCloudFilter() {
        #expect(names(both, claudeCloudEnabled: false) == ["acme"])
        #expect(names(both, claudeCloudEnabled: true).count == 2)
    }

    // MARK: - the cloud gate

    @Test func theCloudProviderIsOmittedWhenTheFlagIsOff() {
        #expect(!names(both, claudeCloudEnabled: false).contains(ClaudeCloudProvider.name))
    }

    /// The discriminating half: the filter does not simply always drop it.
    @Test func theCloudProviderIsListedWhenTheFlagIsOn() {
        #expect(names(both, claudeCloudEnabled: true).contains(ClaudeCloudProvider.name))
    }

    // MARK: - the main-row gate

    /// The main worktree is the repo's checkout, not a parent to nest under —
    /// the nested `+` is withheld from that row, and so is this item.
    @Test func theMainRowOffersNoRemoteSessionItem() {
        #expect(names(both, isMain: true).isEmpty)
        #expect(names([provider("acme")], isMain: true).isEmpty)
    }

    /// The discriminating half: the same providers on an ordinary row DO
    /// produce the item, so `isMain` gates rather than disables everything.
    @Test func anOrdinaryRowOffersTheItemForTheSameProviders() {
        #expect(names(both, isMain: false).count == 2)
    }

    // MARK: - staleness disables, it does not omit

    /// A stale provider keeps its row (the view disables it) rather than
    /// vanishing — the same divergence from the `+` picker that the repo
    /// header's item has.
    @Test func aStaleProviderIsStillListedSoTheRowCanExplainItself() {
        let stale = provider("acme", health: .stale, freshnessUnreadable: true)
        #expect(stale.hasStaleSnapshot)
        #expect(names([stale]) == ["acme"])
    }
}
