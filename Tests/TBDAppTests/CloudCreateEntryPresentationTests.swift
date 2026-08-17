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
}
