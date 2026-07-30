import Testing
@testable import TBDApp

/// `DetailSectionHostPager.showsRemoteTab` is the pure decision behind which
/// of the two always-mounted tabs (`.remote`/`.other`) is in front — see
/// that type's doc comment for why the `.remote` tab stays mounted (rather
/// than torn down) when not showing. Covers both inputs' branches.
@Suite("DetailSectionHostPager tab selection")
struct DetailSectionHostPagerTests {
    private let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")

    @Test("connected with a selected remote session shows the remote tab")
    func connectedWithSelectionShowsRemote() {
        #expect(DetailSectionHostPager.showsRemoteTab(isConnected: true, selectedRemoteSession: selection))
    }

    @Test("connected with no selected remote session shows the other tab")
    func connectedWithoutSelectionShowsOther() {
        #expect(!DetailSectionHostPager.showsRemoteTab(isConnected: true, selectedRemoteSession: nil))
    }

    @Test("disconnected with a selected remote session still shows the other tab")
    func disconnectedWithSelectionShowsOther() {
        #expect(!DetailSectionHostPager.showsRemoteTab(isConnected: false, selectedRemoteSession: selection))
    }

    @Test("disconnected with no selected remote session shows the other tab")
    func disconnectedWithoutSelectionShowsOther() {
        #expect(!DetailSectionHostPager.showsRemoteTab(isConnected: false, selectedRemoteSession: nil))
    }
}
