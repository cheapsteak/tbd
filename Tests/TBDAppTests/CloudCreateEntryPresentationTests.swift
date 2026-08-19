import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

// Tier 1: pure over values.
@Suite("CloudCreateEntryPresentation")
struct CloudCreateEntryPresentationTests {
    private func status(_ name: String) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/x"),
            describe: ProviderDescribe(contractVersions: [2], name: name, capabilities: ["send"]),
            health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil)
    }

    private var both: [RemoteProviderStatus] {
        [status("acme"), status(ClaudeCloudProvider.name)]
    }

    /// OMITTED, not disabled — matching how capability-gated remote items are
    /// already omitted rather than grayed out.
    @Test func theCloudProviderIsOmittedWhenTheFlagIsOff() {
        let shown = CloudCreateEntryPresentation.createProviders(both, claudeCloudEnabled: false)
        #expect(shown.map { $0.config.name } == ["acme"])
        #expect(CloudCreateEntryPresentation.cloudProvider(both, claudeCloudEnabled: false) == nil)
    }

    /// The discriminating half: with the flag on it is shown, so the filter
    /// did not simply delete the entry.
    @Test func theCloudProviderIsShownWhenTheFlagIsOn() {
        let shown = CloudCreateEntryPresentation.createProviders(both, claudeCloudEnabled: true)
        #expect(shown.map { $0.config.name } == ["acme", ClaudeCloudProvider.name])
        #expect(CloudCreateEntryPresentation.cloudProvider(both, claudeCloudEnabled: true)?
            .config.name == ClaudeCloudProvider.name)
    }

    /// A registered provider is never touched by this gate, whichever way the
    /// cloud flag points.
    @Test func aRegisteredProviderIsUnaffectedByTheCloudFlag() {
        let only = [status("acme")]
        #expect(CloudCreateEntryPresentation.createProviders(only, claudeCloudEnabled: false)
            .map { $0.config.name } == ["acme"])
        #expect(CloudCreateEntryPresentation.createProviders(only, claudeCloudEnabled: true)
            .map { $0.config.name } == ["acme"])
        #expect(CloudCreateEntryPresentation.cloudProvider(only, claudeCloudEnabled: true) == nil)
    }

    /// The daemon registers the cloud provider only when it booted with the
    /// flag on, so "flag on but provider absent" is the flipped-after-boot
    /// state and must show nothing rather than a row that cannot work.
    @Test func aFlagOnWithNoRegisteredCloudProviderShowsNoCloudEntry() {
        let only = [status("acme")]
        #expect(CloudCreateEntryPresentation.cloudProvider(only, claudeCloudEnabled: true) == nil)
    }

    @Test func anEmptyProviderListStaysEmpty() {
        #expect(CloudCreateEntryPresentation.createProviders([], claudeCloudEnabled: true).isEmpty)
        #expect(CloudCreateEntryPresentation.cloudProvider([], claudeCloudEnabled: true) == nil)
    }

    // MARK: - The menu's own shape

    /// The single-provider fast path must be computed from the FILTERED list,
    /// not the raw one: with the flag off and cloud plus one registry
    /// provider on file, the menu must be the one-provider shape, not a
    /// two-entry submenu with a dead row.
    @Test func theSingleProviderFastPathIsDecidedAfterFiltering() {
        let filtered = CloudCreateEntryPresentation.createProviders(both, claudeCloudEnabled: false)
        #expect(filtered.count == 1)
        #expect(filtered.first?.config.name == "acme")

        let unfiltered = CloudCreateEntryPresentation.createProviders(both, claudeCloudEnabled: true)
        #expect(unfiltered.count == 2)
    }

    /// With cloud the only provider and the flag off, the menu item is
    /// omitted whole — an empty filtered list is what `newRemoteSessionMenuItem`
    /// already reads as "show nothing".
    @Test func cloudAloneWithTheFlagOffLeavesNothingToOffer() {
        let cloudOnly = [status(ClaudeCloudProvider.name)]
        #expect(CloudCreateEntryPresentation.createProviders(
            cloudOnly, claudeCloudEnabled: false).isEmpty)
        #expect(CloudCreateEntryPresentation.createProviders(
            cloudOnly, claudeCloudEnabled: true).count == 1)
    }

    // MARK: - The `+` button's row

    /// The `+` button's row is present exactly when there is a cloud provider
    /// to open the sheet for — omitted, never disabled.
    @Test func thePlusButtonRowFollowsTheSameGateAsTheMenu() {
        #expect(CloudCreateEntryPresentation.cloudProvider(both, claudeCloudEnabled: true) != nil)
        #expect(CloudCreateEntryPresentation.cloudProvider(both, claudeCloudEnabled: false) == nil)
        // And a daemon that never registered it shows nothing even with the
        // flag on — the flipped-on-without-restart state.
        #expect(CloudCreateEntryPresentation.cloudProvider(
            [status("acme")], claudeCloudEnabled: true) == nil)
    }

    // MARK: - The `+` button's row honors staleness (final review item 2)

    private func staleStatus(_ name: String) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/x"),
            describe: ProviderDescribe(contractVersions: [2], name: name, capabilities: ["send"]),
            health: .stale, errorMessage: nil, remediationLabel: nil, remediationCommand: nil,
            freshnessUnreadable: true)
    }

    /// The picker's cloud row has no disabled state of its own — unlike the
    /// context menu and the Remote section header, which both disable their
    /// own `+` on `hasStaleSnapshot` — so a stale cloud provider must be
    /// OMITTED the same way an absent or flag-off provider is, or the sheet
    /// opens onto a create call the daemon refuses as stale.
    @Test func cloudProviderIsOmittedWhenTheCloudProvidersInventoryIsStale() {
        let stale = [status("acme"), staleStatus(ClaudeCloudProvider.name)]
        #expect(CloudCreateEntryPresentation.cloudProvider(stale, claudeCloudEnabled: true) == nil)
    }

    /// The discriminating half: a non-stale cloud provider is unaffected —
    /// confirms the staleness check doesn't simply always return nil.
    @Test func cloudProviderIsShownWhenNotStale() {
        #expect(CloudCreateEntryPresentation.cloudProvider(both, claudeCloudEnabled: true) != nil)
    }

    /// Staleness on a DIFFERENT, unrelated provider must never suppress the
    /// cloud row — the check is scoped to the cloud provider's own status.
    @Test func aStaleUnrelatedProviderDoesNotSuppressTheCloudRow() {
        let mixed = [staleStatus("acme"), status(ClaudeCloudProvider.name)]
        #expect(CloudCreateEntryPresentation.cloudProvider(mixed, claudeCloudEnabled: true) != nil)
    }
}

// MARK: - Cross-surface parity (final review item 4)
//
// The three owned create surfaces — `RepoSectionView`'s context menu
// (`remoteSessionMenuProviders`), its `+` picker (`cloudSessionProvider`),
// and `RemoteSectionView`'s header `+` (`RemoteProviderHeaderRow.canCreate`)
// — must reach the same "can this surface offer cloud?" verdict for a given
// (providers, claudeCloudEnabled) pair, with one documented exception: the
// picker additionally omits a STALE cloud provider, which the other two
// instead render and disable (see the staleness tests above).
//
// Each test below calls the actual `nonisolated static` functions the three
// view bodies call — not a re-implementation of their logic — so a future
// edit that re-derives the gate inline in one surface, drops a filter, or
// stops routing through `CloudCreateEntryPresentation` reddens this suite
// even without a rendered view. That is the gap the pure
// `CloudCreateEntryPresentation` tests above cannot close on their own: they
// only ever called the shared function directly, so a surface that silently
// stopped calling it left the whole suite green.
@Suite("CloudCreateEntryPresentation — cross-surface parity")
struct CloudCreateEntryPresentationParityTests {
    private func status(
        _ name: String, health: ProviderHealth = .ok, freshnessUnreadable: Bool = false
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/x"),
            describe: ProviderDescribe(contractVersions: [2], name: name, capabilities: ["send"]),
            health: health, errorMessage: nil, remediationLabel: nil, remediationCommand: nil,
            freshnessUnreadable: freshnessUnreadable)
    }

    private var both: [RemoteProviderStatus] {
        [status("acme"), status(ClaudeCloudProvider.name)]
    }

    private func cloudEntry(in providers: [RemoteProviderStatus]) -> RemoteProviderStatus {
        providers.first { $0.config.name == ClaudeCloudProvider.name }!
    }

    /// Flag off: all three surfaces must agree the cloud row is hidden.
    @Test func allThreeSurfacesAgreeTheCloudRowIsHiddenWhenTheFlagIsOff() {
        let menu = RepoSectionView.remoteSessionMenuProviders(providers: both, claudeCloudEnabled: false)
        let picker = RepoSectionView.cloudSessionProvider(providers: both, claudeCloudEnabled: false)
        let header = RemoteProviderHeaderRow.canCreate(provider: cloudEntry(in: both), claudeCloudEnabled: false)

        #expect(!menu.contains { $0.config.name == ClaudeCloudProvider.name })
        #expect(picker == nil)
        #expect(!header)
    }

    /// Flag on, healthy provider: all three surfaces must agree it is shown.
    @Test func allThreeSurfacesAgreeTheCloudRowIsShownWhenTheFlagIsOnAndHealthy() {
        let menu = RepoSectionView.remoteSessionMenuProviders(providers: both, claudeCloudEnabled: true)
        let picker = RepoSectionView.cloudSessionProvider(providers: both, claudeCloudEnabled: true)
        let header = RemoteProviderHeaderRow.canCreate(provider: cloudEntry(in: both), claudeCloudEnabled: true)

        #expect(menu.contains { $0.config.name == ClaudeCloudProvider.name })
        #expect(picker != nil)
        #expect(header)
    }

    /// Flipped-on-without-restart: the daemon never registered the provider,
    /// so it is simply absent from `providers` — both surfaces that can be
    /// checked against an empty registration must show nothing rather than
    /// inventing a row.
    @Test func menuAndPickerShowNothingWhenTheProviderWasNeverRegistered() {
        let onlyAcme = [status("acme")]
        let menu = RepoSectionView.remoteSessionMenuProviders(providers: onlyAcme, claudeCloudEnabled: true)
        let picker = RepoSectionView.cloudSessionProvider(providers: onlyAcme, claudeCloudEnabled: true)

        #expect(!menu.contains { $0.config.name == ClaudeCloudProvider.name })
        #expect(picker == nil)
        // No header assertion here: `RemoteSectionView` only ever renders a
        // header for a provider present in `appState.remoteProviders`
        // (`ForEach(appState.remoteProviders, ...)`), so there is no
        // `RemoteProviderStatus` to call `canCreate` with in this state.
    }

    /// The one documented divergence: a STALE cloud provider is disabled
    /// (not omitted) by the menu and the header's `+`, but OMITTED by the
    /// picker, whose row has no disabled state of its own. Pinning this as a
    /// deliberate divergence — rather than asserting the three must always
    /// agree — catches a future change that makes them agree the wrong way,
    /// e.g. the picker starting to show a stale row it cannot act on.
    @Test func staleInventoryDivergesByDesignBetweenThePickerAndTheOtherTwo() {
        let stale = [status("acme"), status(ClaudeCloudProvider.name, health: .stale, freshnessUnreadable: true)]
        let menu = RepoSectionView.remoteSessionMenuProviders(providers: stale, claudeCloudEnabled: true)
        let picker = RepoSectionView.cloudSessionProvider(providers: stale, claudeCloudEnabled: true)
        let header = RemoteProviderHeaderRow.canCreate(provider: cloudEntry(in: stale), claudeCloudEnabled: true)

        #expect(menu.contains { $0.config.name == ClaudeCloudProvider.name },
                "the menu still lists a stale provider — it disables the row instead of omitting it")
        #expect(header, "the header's + still renders for a stale provider — it disables the button instead")
        #expect(picker == nil, "the picker has no disabled state, so a stale cloud provider must be omitted")
    }
}
