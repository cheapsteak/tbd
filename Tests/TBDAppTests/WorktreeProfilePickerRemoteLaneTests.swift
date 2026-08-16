import Testing
import Foundation
@testable import TBDApp
import TBDShared

/// Covers the `+` menu's remote-lane entry point —
/// `WorktreeProfilePickerView.remoteLaneOffer(providers:parentWorktreeID:)`
/// and the copy helpers that hang off its result. Every gating branch the row
/// has (no provider / one / several, stale provider) is decided here, so it is
/// decided in a place a test can reach without an `AppState` or a view
/// hierarchy — including the fact that the nested `+` is no longer a gate.
@Suite("WorktreeProfilePickerView — remote lane row")
struct WorktreeProfilePickerRemoteLaneTests {

    private func provider(
        name: String,
        describeName: String? = nil,
        health: ProviderHealth = .ok,
        lastSuccessfulSnapshotAt: Date? = Date(),
        freshnessUnreadable: Bool = false
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/usr/bin/true"),
            describe: describeName.map { ProviderDescribe(name: $0) },
            health: health,
            errorMessage: nil,
            remediationLabel: nil,
            remediationCommand: nil,
            lastSuccessfulSnapshotAt: lastSuccessfulSnapshotAt,
            freshnessUnreadable: freshnessUnreadable)
    }

    /// Test-side flattening of the offer so assertions read as data. The enum
    /// itself stays non-`Equatable` because `RemoteProviderStatus` is not.
    private func describeOffer(_ offer: RemoteLaneOffer) -> (kind: String, providers: [String]) {
        switch offer {
        case .hidden: return ("hidden", [])
        case .single(let only): return ("single", [only.config.name])
        case .chooseProvider(let all): return ("chooseProvider", all.map(\.config.name))
        }
    }

    // MARK: - the provider-registered gate

    /// No provider registered → the row is omitted, not disabled — mirroring
    /// `RepoSectionView.newRemoteSessionMenuItem`.
    @Test func noRegisteredProviderOffersNothing() {
        let offer = WorktreeProfilePickerView.remoteLaneOffer(providers: [], parentWorktreeID: nil)
        #expect(describeOffer(offer).kind == "hidden")
    }

    // MARK: - one vs. many providers

    @Test func oneProviderGoesStraightToThatProvider() {
        let offer = WorktreeProfilePickerView.remoteLaneOffer(
            providers: [provider(name: "acme")], parentWorktreeID: nil)
        #expect(describeOffer(offer) == ("single", ["acme"]))
    }

    @Test func severalProvidersDrillIntoTheProviderList() {
        let offer = WorktreeProfilePickerView.remoteLaneOffer(
            providers: [provider(name: "acme"), provider(name: "acme-prod")],
            parentWorktreeID: nil)
        #expect(describeOffer(offer) == ("chooseProvider", ["acme", "acme-prod"]))
    }

    // MARK: - the nested `+` offers the same row

    /// The nested `+` promises the new lane nests under that worktree, and the
    /// create path now keeps that promise (`RemoteCreateParams.parentWorktreeID`
    /// carries the click through to adoption), so nesting is no longer a gate:
    /// the row is offered on exactly the same terms as on the repo header.
    @Test func nestedPlusOffersTheRowForOneProvider() {
        let offer = WorktreeProfilePickerView.remoteLaneOffer(
            providers: [provider(name: "acme")], parentWorktreeID: UUID())
        #expect(describeOffer(offer) == ("single", ["acme"]))
    }

    @Test func nestedPlusDrillsIntoTheProviderListForSeveralProviders() {
        let offer = WorktreeProfilePickerView.remoteLaneOffer(
            providers: [provider(name: "acme"), provider(name: "acme-prod")],
            parentWorktreeID: UUID())
        #expect(describeOffer(offer) == ("chooseProvider", ["acme", "acme-prod"]))
    }

    /// The provider gate is untouched by the change: with nothing registered
    /// the nested `+` shows no row either.
    @Test func nestedPlusWithNoRegisteredProviderOffersNothing() {
        let offer = WorktreeProfilePickerView.remoteLaneOffer(
            providers: [], parentWorktreeID: UUID())
        #expect(describeOffer(offer).kind == "hidden")
    }

    /// A stale provider is disabled rather than omitted on the nested `+` too.
    @Test func nestedPlusStillOffersAStaleProvider() {
        let stale = provider(name: "acme", health: .error, lastSuccessfulSnapshotAt: Date())
        #expect(describeOffer(
            WorktreeProfilePickerView.remoteLaneOffer(
                providers: [stale], parentWorktreeID: UUID())
        ) == ("single", ["acme"]))
    }

    // MARK: - staleness disables, it does not omit

    /// Stale is the one state that grays a row out instead of removing it:
    /// the user has a provider, and the menu should say why it can't be used.
    @Test func staleProviderIsStillOffered() {
        let stale = provider(name: "acme", health: .error, lastSuccessfulSnapshotAt: Date())
        #expect(stale.hasStaleSnapshot)
        #expect(describeOffer(
            WorktreeProfilePickerView.remoteLaneOffer(providers: [stale], parentWorktreeID: nil)
        ) == ("single", ["acme"]))
    }

    @Test func staleProviderRowExplainsWhyItIsUnselectable() {
        let stale = provider(name: "acme", health: .needsAuth, lastSuccessfulSnapshotAt: Date())
        #expect(WorktreeProfilePickerView.providerRowSubtitle(stale) == "Unavailable — inventory is stale")
    }

    @Test func healthyProviderRowCarriesNoUnavailableNote() {
        #expect(WorktreeProfilePickerView.providerRowSubtitle(provider(name: "acme")) == nil)
    }

    // MARK: - provider display name

    @Test func providerLabelPrefersTheNegotiatedDescribeName() {
        #expect(WorktreeProfilePickerView.providerLabel(
            provider(name: "acme", describeName: "Acme Cloud")) == "Acme Cloud")
    }

    @Test func providerLabelFallsBackToTheConfiguredName() {
        #expect(WorktreeProfilePickerView.providerLabel(provider(name: "acme")) == "acme")
    }

    // MARK: - header copy follows the row

    /// "New worktree with…" stops being true once the page can also start a
    /// provider session, so the title widens exactly when the row is offered —
    /// and stays narrow (the nested `+`, or no provider) when it is not.
    @Test func headerNamesOnlyWorktreesWhenNoRemoteRowIsOffered() {
        #expect(WorktreeProfilePickerView.profilesPageTitle(offer: .hidden) == "New worktree with…")
    }

    @Test func headerNamesRemoteSessionsForASingleProvider() {
        #expect(WorktreeProfilePickerView.profilesPageTitle(offer: .single(provider(name: "acme")))
            == "New worktree or remote session…")
    }

    @Test func headerNamesRemoteSessionsForSeveralProviders() {
        #expect(WorktreeProfilePickerView.profilesPageTitle(
            offer: .chooseProvider([provider(name: "acme"), provider(name: "acme-prod")]))
            == "New worktree or remote session…")
    }
}
