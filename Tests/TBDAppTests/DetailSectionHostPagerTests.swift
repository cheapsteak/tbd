import Testing
@testable import TBDApp

/// `DetailSectionHostPager.targetTab` is the pure decision behind which of
/// the three always-mounted tabs (`.remote`/`.providerDesk`/`.other`) is in
/// front — see that type's doc comment for why each stays mounted (rather
/// than torn down) when not showing. Covers every input's branches.
@Suite("DetailSectionHostPager tab selection")
struct DetailSectionHostPagerTests {
    private let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")

    @Test("connected with a selected remote session shows the remote tab")
    func connectedWithSelectionShowsRemote() {
        #expect(DetailSectionHostPager.targetTab(
            isConnected: true, selectedRemoteSession: selection, selectedRemoteProvider: nil
        ) == .remote)
    }

    @Test("connected with no selection at all shows the other tab")
    func connectedWithoutSelectionShowsOther() {
        #expect(DetailSectionHostPager.targetTab(
            isConnected: true, selectedRemoteSession: nil, selectedRemoteProvider: nil
        ) == .other)
    }

    @Test("connected with a selected provider shows the provider desk tab")
    func connectedWithProviderShowsDesk() {
        #expect(DetailSectionHostPager.targetTab(
            isConnected: true, selectedRemoteSession: nil, selectedRemoteProvider: "acme-cloud"
        ) == .providerDesk)
    }

    @Test("disconnected with a selected remote session still shows the other tab")
    func disconnectedWithSelectionShowsOther() {
        #expect(DetailSectionHostPager.targetTab(
            isConnected: false, selectedRemoteSession: selection, selectedRemoteProvider: nil
        ) == .other)
    }

    @Test("disconnected with no selection shows the other tab")
    func disconnectedWithoutSelectionShowsOther() {
        #expect(DetailSectionHostPager.targetTab(
            isConnected: false, selectedRemoteSession: nil, selectedRemoteProvider: nil
        ) == .other)
    }

    @Test("disconnected with a selected provider still shows the other tab")
    func disconnectedWithProviderShowsOther() {
        #expect(DetailSectionHostPager.targetTab(
            isConnected: false, selectedRemoteSession: nil, selectedRemoteProvider: "acme-cloud"
        ) == .other)
    }

    /// The Provider Desk must never displace the `.remote` tab's content:
    /// that tab hosts `RemoteAttachPager`, and rendering the desk in its
    /// place would dismantle every live attach connection. A provider
    /// selection therefore resolves to its OWN tab, leaving `.remote`
    /// mounted-but-detached exactly as a worktree excursion does.
    @Test("a provider selection never resolves to the attach-hosting remote tab")
    func providerSelectionNeverTakesOverRemoteTab() {
        #expect(DetailSectionHostPager.targetTab(
            isConnected: true, selectedRemoteSession: nil, selectedRemoteProvider: "acme-cloud"
        ) != .remote)
    }

    /// The two selections are mutually exclusive in `AppState`; this pins
    /// the tie-break so an unreachable both-set state is still deterministic.
    @Test("a session selection outranks a provider selection")
    func sessionOutranksProvider() {
        #expect(DetailSectionHostPager.targetTab(
            isConnected: true, selectedRemoteSession: selection, selectedRemoteProvider: "acme-cloud"
        ) == .remote)
    }
}
