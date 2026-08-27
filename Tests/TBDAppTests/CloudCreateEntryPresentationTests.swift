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

    private func staleStatus(_ name: String) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/x"),
            describe: ProviderDescribe(contractVersions: [2], name: name, capabilities: ["send"]),
            health: .stale, errorMessage: nil, remediationLabel: nil, remediationCommand: nil,
            freshnessUnreadable: true)
    }

    private var both: [RemoteProviderStatus] {
        [status("acme"), status(ClaudeCloudProvider.name)]
    }

    // MARK: - registryProviders: the generic enumeration

    /// The generic "New Remote Session" enumeration is the user's own
    /// `agent-providers.json`, and the compiled provider is never a member of
    /// it — it has an entry of its own on every surface that has a generic
    /// one. No flag can put it back.
    @Test func theCloudProviderIsNeverAMemberOfTheGenericEnumeration() {
        #expect(CloudCreateEntryPresentation.registryProviders(both)
            .map { $0.config.name } == ["acme"])
        #expect(CloudCreateEntryPresentation.registryProviders([status(ClaudeCloudProvider.name)])
            .isEmpty)
    }

    /// The discriminating half: registry providers pass through untouched, in
    /// order, so the filter did not simply empty the list.
    @Test func everyRegistryProviderPassesThroughInOrder() {
        let many = [status("acme"), status(ClaudeCloudProvider.name), status("widgets")]
        #expect(CloudCreateEntryPresentation.registryProviders(many)
            .map { $0.config.name } == ["acme", "widgets"])
    }

    /// A stale registry provider still reaches the enumeration — staleness is
    /// the row's business (it renders disabled), never this filter's.
    @Test func aStaleRegistryProviderStillReachesTheEnumeration() {
        let mixed = [staleStatus("acme"), status("widgets")]
        #expect(CloudCreateEntryPresentation.registryProviders(mixed)
            .map { $0.config.name } == ["acme", "widgets"])
    }

    @Test func anEmptyProviderListStaysEmpty() {
        #expect(CloudCreateEntryPresentation.registryProviders([]).isEmpty)
        #expect(CloudCreateEntryPresentation.cloudEntry([], claudeCloudEnabled: true) == nil)
    }

    // MARK: - cloudEntry: the compiled provider's own entry

    /// OMITTED, not disabled — the flag being off means this install does not
    /// have the capability, and a row for it would advertise something untrue.
    @Test func theCloudEntryIsOmittedWhenTheFlagIsOff() {
        #expect(CloudCreateEntryPresentation.cloudEntry(both, claudeCloudEnabled: false) == nil)
    }

    /// The discriminating half: with the flag on it is offered, so the gate
    /// did not simply delete the entry.
    @Test func theCloudEntryIsOfferedWhenTheFlagIsOn() {
        #expect(CloudCreateEntryPresentation.cloudEntry(both, claudeCloudEnabled: true)?
            .config.name == ClaudeCloudProvider.name)
    }

    /// The daemon registers the cloud provider only when it booted with the
    /// flag on, so "flag on but provider absent" is the flipped-after-boot
    /// state and must show nothing rather than a row that cannot work.
    @Test func aFlagOnWithNoRegisteredCloudProviderShowsNoCloudEntry() {
        #expect(CloudCreateEntryPresentation.cloudEntry(
            [status("acme")], claudeCloudEnabled: true) == nil)
    }

    /// Staleness DISABLES, it does not withdraw: a stale snapshot is a
    /// transient state of a capability this install does have, and the row is
    /// the menu's statement that the capability exists. Each surface renders
    /// the entry it gets back disabled, subtitled with its reason.
    @Test func aStaleCloudProviderStillYieldsAnEntry() {
        let stale = [status("acme"), staleStatus(ClaudeCloudProvider.name)]
        #expect(staleStatus(ClaudeCloudProvider.name).hasStaleSnapshot)
        #expect(CloudCreateEntryPresentation.cloudEntry(stale, claudeCloudEnabled: true)?
            .config.name == ClaudeCloudProvider.name)
    }

    /// Staleness on a DIFFERENT, unrelated provider says nothing about the
    /// cloud entry — the lookup is scoped to the cloud provider's own status.
    @Test func aStaleUnrelatedProviderDoesNotDisturbTheCloudEntry() {
        let mixed = [staleStatus("acme"), status(ClaudeCloudProvider.name)]
        #expect(CloudCreateEntryPresentation.cloudEntry(mixed, claudeCloudEnabled: true) != nil)
    }

    // MARK: - offersCreate: the per-provider verdict

    /// A registry provider's own `+` is never the cloud flag's business.
    @Test func aRegistryProviderOffersCreateWhicheverWayTheFlagPoints() {
        for flag in [true, false] {
            #expect(CloudCreateEntryPresentation.offersCreate(
                provider: status("acme"), claudeCloudEnabled: flag))
        }
    }

    @Test func theCloudProviderOffersCreateOnlyWhenTheFlagIsOn() {
        #expect(CloudCreateEntryPresentation.offersCreate(
            provider: status(ClaudeCloudProvider.name), claudeCloudEnabled: true))
        #expect(!CloudCreateEntryPresentation.offersCreate(
            provider: status(ClaudeCloudProvider.name), claudeCloudEnabled: false))
    }

    /// Staleness is a separate axis from this verdict: the header still
    /// renders its `+` for a stale provider and disables the button instead.
    @Test func aStaleProviderStillOffersCreate() {
        #expect(CloudCreateEntryPresentation.offersCreate(
            provider: staleStatus(ClaudeCloudProvider.name), claudeCloudEnabled: true))
        #expect(CloudCreateEntryPresentation.offersCreate(
            provider: staleStatus("acme"), claudeCloudEnabled: false))
    }
}

// MARK: - Cross-surface parity
//
// Five owned create entries carry the compiled cloud provider — the repo
// header `+` picker's cloud row and the nested `+` picker's cloud row
// (`WorktreeProfilePickerView.cloudLaneEntry`), `RepoSectionView`'s
// context-menu item (`cloudSessionMenuEntry`), `WorktreeRowView`'s
// context-menu item (its own `cloudSessionMenuEntry`), and
// `RemoteSectionView`'s provider header `+` (`RemoteProviderHeaderRow
// .canCreate`) — and all five must reach the same "is the cloud entry shown?"
// verdict for a given (providers, claudeCloudEnabled, staleness) input. There
// is no documented divergence: staleness shows the entry disabled everywhere.
//
// `WorktreeRowView`'s item carries one extra gate of its own — the main row
// offers nothing, because the main worktree is not a parent to nest under —
// which is orthogonal to the cloud question and so is pinned in
// `WorktreeRowRemoteSessionMenuTests` rather than here. Every call below
// passes `isMain: false` so this suite reads only the cloud verdict.
//
// Each test below calls the actual `nonisolated static` functions the view
// bodies call — not a re-implementation of their logic — so a future edit
// that re-derives the gate inline in one surface, drops a filter, or stops
// routing through `CloudCreateEntryPresentation` reddens this suite even
// without a rendered view. That is the gap the pure
// `CloudCreateEntryPresentation` tests above cannot close on their own: they
// only ever call the shared function directly, so a surface that silently
// stopped calling it would leave the whole suite green.
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

    private func cloudStatus(in providers: [RemoteProviderStatus]) -> RemoteProviderStatus {
        providers.first { $0.config.name == ClaudeCloudProvider.name }!
    }

    /// Whether each of the four entry-yielding surfaces offers a cloud entry,
    /// in a fixed order so a failing `#expect` names which one diverged.
    private func entriesShown(
        _ providers: [RemoteProviderStatus], claudeCloudEnabled: Bool
    ) -> [String: Bool] {
        [
            "repo + picker": WorktreeProfilePickerView.cloudLaneEntry(
                providers: providers, claudeCloudEnabled: claudeCloudEnabled,
                parentWorktreeID: nil) != nil,
            "nested + picker": WorktreeProfilePickerView.cloudLaneEntry(
                providers: providers, claudeCloudEnabled: claudeCloudEnabled,
                parentWorktreeID: UUID()) != nil,
            "repo context menu": RepoSectionView.cloudSessionMenuEntry(
                providers: providers, claudeCloudEnabled: claudeCloudEnabled) != nil,
            "worktree row context menu": WorktreeRowView.cloudSessionMenuEntry(
                providers: providers, claudeCloudEnabled: claudeCloudEnabled,
                isMain: false) != nil,
        ]
    }

    /// Flag off: all five entries must agree the cloud entry is hidden.
    @Test func allFiveEntriesAgreeTheCloudRowIsHiddenWhenTheFlagIsOff() {
        for (surface, shown) in entriesShown(both, claudeCloudEnabled: false) {
            #expect(!shown, "\(surface) still offers the cloud entry with the flag off")
        }
        #expect(!RemoteProviderHeaderRow.canCreate(
            provider: cloudStatus(in: both), claudeCloudEnabled: false))
    }

    /// Flag on, healthy provider: all five entries must agree it is shown.
    @Test func allFiveEntriesAgreeTheCloudRowIsShownWhenTheFlagIsOnAndHealthy() {
        for (surface, shown) in entriesShown(both, claudeCloudEnabled: true) {
            #expect(shown, "\(surface) hides the cloud entry with the flag on and healthy")
        }
        #expect(RemoteProviderHeaderRow.canCreate(
            provider: cloudStatus(in: both), claudeCloudEnabled: true))
    }

    /// Flipped-on-without-restart: the daemon never registered the provider,
    /// so it is simply absent from `providers` — every surface that can be
    /// checked against an empty registration must show nothing rather than
    /// inventing a row, with no flag dependence.
    @Test func everyEntryShowsNothingWhenTheProviderWasNeverRegistered() {
        let onlyAcme = [status("acme")]
        for flag in [true, false] {
            for (surface, shown) in entriesShown(onlyAcme, claudeCloudEnabled: flag) {
                #expect(!shown, "\(surface) invented a cloud entry for an unregistered provider")
            }
        }
        // No header assertion here: `RemoteSectionView` only ever renders a
        // header for a provider present in `appState.remoteProviders`
        // (`ForEach(appState.remoteProviders, ...)`), so there is no
        // `RemoteProviderStatus` to call `canCreate` with in this state.
    }

    /// Staleness converges: every surface SHOWS the entry and renders it
    /// disabled, because the row is not only a button — it is also the menu's
    /// statement about what exists, and a transient outage is no reason to
    /// retract a true statement.
    @Test func everyEntryShowsAStaleCloudProviderSoEachSurfaceCanDisableIt() {
        let stale = [status("acme"),
                     status(ClaudeCloudProvider.name, health: .stale, freshnessUnreadable: true)]
        #expect(cloudStatus(in: stale).hasStaleSnapshot)
        for (surface, shown) in entriesShown(stale, claudeCloudEnabled: true) {
            let why = "\(surface) withdrew the cloud entry on a stale snapshot, "
                + "instead of showing it disabled"
            #expect(shown, "\(why)")
        }
        #expect(RemoteProviderHeaderRow.canCreate(
            provider: cloudStatus(in: stale), claudeCloudEnabled: true),
                "the header's + still renders for a stale provider — it disables the button instead")
    }

    /// A registry provider is unaffected by the flag in every state.
    @Test func aRegistryProviderIsUnaffectedByTheCloudFlag() {
        for flag in [true, false] {
            #expect(RepoSectionView.remoteSessionMenuProviders(providers: both)
                .map(\.config.name) == ["acme"])
            #expect(WorktreeRowView.remoteSessionMenuProviders(providers: both, isMain: false)
                .map(\.config.name) == ["acme"])
            #expect(RemoteProviderHeaderRow.canCreate(
                provider: status("acme"), claudeCloudEnabled: flag))
        }
    }

    /// The cloud provider never appears in any surface's generic enumeration,
    /// at either flag value — a shortcut that duplicated one entry of a list
    /// would teach that the list is incomplete somewhere else too.
    @Test func theCloudProviderNeverAppearsInAGenericEnumeration() {
        #expect(!WorktreeProfilePickerView.registryLaneProviders(both)
            .contains { $0.config.name == ClaudeCloudProvider.name })
        #expect(!RepoSectionView.remoteSessionMenuProviders(providers: both)
            .contains { $0.config.name == ClaudeCloudProvider.name })
        #expect(!WorktreeRowView.remoteSessionMenuProviders(providers: both, isMain: false)
            .contains { $0.config.name == ClaudeCloudProvider.name })
        #expect(!CloudCreateEntryPresentation.registryProviders(both)
            .contains { $0.config.name == ClaudeCloudProvider.name })
    }
}
