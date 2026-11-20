import Foundation
import Testing
@testable import TBDApp
import TBDShared

// Tier 1: deterministic, in-process values only. No sleeps, no subprocesses,
// no AppState.

private enum RegistryFilterFixtures {
    static let acme = "acme"
    static let acmeTwo = "acme-two"
    static let cloud = ClaudeCloudProvider.name

    /// A row; `provider` makes it `.remote(provider:sessionID:)`, with the
    /// session ID defaulting to the row's name.
    static func row(_ name: String, id: UUID = UUID(), repo: UUID, provider: String? = nil,
                    session: String? = nil, parent: UUID? = nil, order: Int = 0,
                    status: WorktreeStatus = .active, origin: WorktreeOrigin? = nil) -> Worktree {
        let location = provider.map { WorktreeLocation.remote(provider: $0, sessionID: session ?? name) } ?? .local
        return Worktree(id: id, repoID: repo, name: name, displayName: name, branch: "feature",
                        path: location.storagePath ?? "/tmp/acme", status: status, tmuxServer: "acme",
                        sortOrder: order, parentWorktreeID: parent, location: location, origin: origin)
    }

    static func session(_ id: String, provider: String = acme, state: RemoteProcessState = .running,
                        repoID: UUID? = nil) -> RemoteSessionInfo {
        RemoteSessionInfo(provider: provider, payload: RemoteSessionPayload(id: id, state: state),
                          gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: repoID)
    }

    /// The filter over `rows`, whose roots default to the rows with no parent.
    static func filter(_ rows: [Worktree], roots: [Worktree]? = nil, sessions: [RemoteSessionInfo] = [],
                       isOn: Bool = true, selected: Set<UUID> = [],
                       selectedSession: UUID? = nil) -> SidebarRegistryRemoteFilter {
        SidebarRegistryRemoteFilter(
            roots: roots ?? rows.filter { $0.parentWorktreeID == nil },
            children: SidebarOrder.childrenIndex(rows),
            sessions: sessions, isOn: isOn,
            selectedWorktreeIDs: selected, selectedSessionID: selectedSession)
    }

    static func identity(_ sessionID: String, provider: String = acme) -> UUID {
        RemoteSessionIdentity.uuid(provider: provider, sessionID: sessionID)
    }
}

@Suite("Sidebar registry remote filter")
struct SidebarRegistryRemoteFilterTests {
    private typealias Fixture = RegistryFilterFixtures

    // MARK: What the filter hides

    @Test func registryRowAtTheTopLevelIsHidden() {
        let repo = UUID()
        let main = Fixture.row("main", repo: repo, status: .main)
        let registry = Fixture.row("worker", repo: repo, provider: Fixture.acme)
        let filter = Fixture.filter([main, registry])
        #expect(filter.hiddenWorktreeIDs == [registry.id])
        #expect(filter.hiddenSessionIDs.isEmpty)
        #expect(filter.count == 1)
        #expect(filter.isOn)
    }

    @Test func registryRowUnderALocalLaneIsHidden() {
        let repo = UUID()
        let lane = Fixture.row("lane", repo: repo)
        let registry = Fixture.row("worker", repo: repo, provider: Fixture.acme, parent: lane.id)
        let filter = Fixture.filter([lane, registry])
        #expect(filter.hiddenWorktreeIDs == [registry.id])
        #expect(!filter.hiddenWorktreeIDs.contains(lane.id))
        #expect(filter.count == 1)
    }

    @Test func registryRowUnderAnotherRegistryRowIsHidden() {
        let repo = UUID()
        let outer = Fixture.row("outer", repo: repo, provider: Fixture.acme)
        let inner = Fixture.row("inner", repo: repo, provider: Fixture.acme, parent: outer.id)
        let filter = Fixture.filter([outer, inner])
        #expect(filter.hiddenWorktreeIDs == [outer.id, inner.id])
        #expect(filter.count == 2)
        #expect(filter.hideableCount == 2)
    }

    @Test func looseRegistrySessionIsHidden() {
        let repo = UUID()
        let session = Fixture.session("loose", repoID: repo)
        let filter = Fixture.filter([Fixture.row("main", repo: repo, status: .main)], sessions: [session])
        #expect(filter.hiddenSessionIDs == [session.id])
        #expect(filter.hiddenWorktreeIDs.isEmpty)
        #expect(filter.count == 1)
    }

    @Test func exitedRegistryRowsAndSessionsAreHidden() {
        let repo = UUID()
        let row = Fixture.row("done", repo: repo, provider: Fixture.acme, session: "bound")
        let bound = Fixture.session("bound", state: .exited, repoID: repo)
        let loose = Fixture.session("ended", state: .exited, repoID: repo)
        let filter = Fixture.filter([row], sessions: [bound, loose])
        #expect(filter.hiddenWorktreeIDs == [row.id])
        #expect(filter.hiddenSessionIDs == [bound.id, loose.id])
        #expect(filter.count == 2)
    }

    @Test func aPlaceholderRegistryRowIsHiddenWithNothingSelected() {
        // A creation placeholder has no session identity, so a nil selected
        // session must not read as selecting it.
        let repo = UUID()
        let placeholder = Fixture.row("creating", repo: repo, provider: Fixture.acme, session: "", status: .creating)
        let filter = Fixture.filter([placeholder])
        #expect(filter.hiddenWorktreeIDs == [placeholder.id])
        #expect(filter.count == 1)
    }

    // MARK: What the filter keeps

    @Test func mainLocalLandedCloudRowsAndCloudSessionsAreKept() {
        let repo = UUID()
        let main = Fixture.row("main", repo: repo, status: .main)
        let local = Fixture.row("local", repo: repo, order: 1)
        let landed = Fixture.row("landed", repo: repo, order: 2, origin: WorktreeOrigin(provider: Fixture.acme, sessionID: "x"))
        let cloudRow = Fixture.row("cloud", repo: repo, provider: Fixture.cloud, order: 3)
        let cloudSession = Fixture.session("cloud-loose", provider: Fixture.cloud, repoID: repo)
        let filter = Fixture.filter([main, local, landed, cloudRow], sessions: [cloudSession])
        #expect(filter.hiddenWorktreeIDs.isEmpty)
        #expect(filter.hiddenSessionIDs.isEmpty)
        #expect(filter.count == 0)
        #expect(filter.hideableCount == 0)
        #expect(filter.providerNames.isEmpty)
    }

    @Test func aKeptRowKeepsItsRegistryAncestors() {
        let repo = UUID()
        for provider in [nil, Fixture.cloud] {
            let outer = Fixture.row("outer", repo: repo, provider: Fixture.acme)
            let inner = Fixture.row("inner", repo: repo, provider: Fixture.acme, parent: outer.id)
            let leaf = Fixture.row("leaf", repo: repo, provider: provider, parent: inner.id)
            let filter = Fixture.filter([outer, inner, leaf])
            #expect(filter.hiddenWorktreeIDs.isEmpty)
            #expect(filter.count == 0)
            #expect(filter.hideableCount == 0)
            #expect(!filter.showsButton)
        }
    }

    @Test func theSelectedRowAndItsAncestorsAreKept() {
        let repo = UUID()
        let lane = Fixture.row("lane", repo: repo)
        let outer = Fixture.row("outer", repo: repo, provider: Fixture.acme, parent: lane.id)
        let inner = Fixture.row("inner", repo: repo, provider: Fixture.acme, session: "inner-session", parent: outer.id)
        let rows = [lane, outer, inner]

        let byRow = Fixture.filter(rows, selected: [inner.id])
        #expect(byRow.hiddenWorktreeIDs.isEmpty)
        #expect(byRow.count == 0)
        #expect(byRow.hideableCount == 2)
        #expect(byRow.showsButton)

        let bySession = Fixture.filter(rows, selectedSession: Fixture.identity("inner-session"))
        #expect(bySession.hiddenWorktreeIDs.isEmpty)
        #expect(bySession.count == 0)
        #expect(bySession.hideableCount == 2)
    }

    @Test func selectionKeepsAncestorsButNotDescendants() {
        let repo = UUID()
        let outer = Fixture.row("outer", repo: repo, provider: Fixture.acme)
        let inner = Fixture.row("inner", repo: repo, provider: Fixture.acme, parent: outer.id)
        let filter = Fixture.filter([outer, inner], selected: [outer.id])
        #expect(filter.hiddenWorktreeIDs == [inner.id])
        #expect(filter.count == 1)
        #expect(filter.hideableCount == 2)
    }

    @Test func theSelectedSessionIsKept() {
        let repo = UUID()
        let session = Fixture.session("loose", repoID: repo)
        let filter = Fixture.filter([], sessions: [session], selectedSession: session.id)
        #expect(filter.hiddenSessionIDs.isEmpty)
        #expect(filter.count == 0)
        #expect(filter.hideableCount == 1)
        #expect(filter.showsButton)
    }

    // MARK: Counting

    @Test func aSessionAndItsRowCountOnce() {
        let repo = UUID()
        let row = Fixture.row("worker", repo: repo, provider: Fixture.acme, session: "s")
        let session = Fixture.session("s", repoID: repo)
        let filter = Fixture.filter([row], sessions: [session])
        #expect(filter.hiddenWorktreeIDs == [row.id])
        #expect(filter.hiddenSessionIDs == [session.id])
        #expect(filter.count == 1)
        #expect(filter.hideableCount == 1)
    }

    @Test func aSessionWhoseRowStaysInViewIsNeitherHiddenNorCounted() {
        let repo = UUID()
        // Kept as the ancestor of a local row.
        let ancestor = Fixture.row("ancestor", repo: repo, provider: Fixture.acme, session: "a")
        let local = Fixture.row("local", repo: repo, parent: ancestor.id)
        let ancestorSession = Fixture.session("a", repoID: repo)
        let kept = Fixture.filter([ancestor, local], sessions: [ancestorSession])
        #expect(kept.hiddenSessionIDs.isEmpty)
        #expect(kept.count == 0)
        #expect(kept.hideableCount == 0)

        // Kept because it is selected.
        let selectedRow = Fixture.row("selected", repo: repo, provider: Fixture.acme, session: "s")
        let selectedSession = Fixture.session("s", repoID: repo)
        let selected = Fixture.filter([selectedRow], sessions: [selectedSession], selected: [selectedRow.id])
        #expect(selected.hiddenWorktreeIDs.isEmpty)
        #expect(selected.hiddenSessionIDs.isEmpty)
        #expect(selected.count == 0)
        #expect(selected.hideableCount == 1)
    }

    @Test func offHidesNothingButStillReportsWhatItWouldHide() {
        let repo = UUID()
        let row = Fixture.row("worker", repo: repo, provider: Fixture.acme)
        let session = Fixture.session("loose", repoID: repo)
        let filter = Fixture.filter([row], sessions: [session], isOn: false, selected: [row.id])
        #expect(!filter.isOn)
        #expect(filter.hiddenWorktreeIDs.isEmpty)
        #expect(filter.hiddenSessionIDs.isEmpty)
        #expect(filter.count == 0)
        #expect(filter.hideableCount == 2)
        #expect(filter.providerNames == [Fixture.acme])
        #expect(filter.showsButton)
    }

    @Test func providerNamesAreSortedAndDistinct() {
        let repo = UUID()
        let rows = [Fixture.row("two", repo: repo, provider: Fixture.acmeTwo),
                    Fixture.row("one", repo: repo, provider: Fixture.acme, order: 1),
                    Fixture.row("cloud", repo: repo, provider: Fixture.cloud, order: 2)]
        let sessions = [Fixture.session("loose", repoID: repo), Fixture.session("cloud-loose", provider: Fixture.cloud, repoID: repo)]
        let filter = Fixture.filter(rows, sessions: sessions)
        #expect(filter.providerNames == [Fixture.acme, Fixture.acmeTwo])
    }

    @Test func dismissedAndArchivedSessionsAreIgnored() {
        let repo = UUID()
        let dismissed = RemoteSessionInfo(provider: Fixture.acme, payload: RemoteSessionPayload(id: "d", state: .running),
                                          gone: false, dismissed: true, lastSeen: Date(), resolvedRepoID: repo)
        let archived = RemoteSessionInfo(
            provider: Fixture.acme, payload: RemoteSessionPayload(id: "a", state: .running, archived: true),
            gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: repo)
        let filter = Fixture.filter([], sessions: [dismissed, archived])
        #expect(filter.hiddenSessionIDs.isEmpty)
        #expect(filter.hideableCount == 0)
    }

    // MARK: The button

    @Test func buttonExistence() {
        let repo = UUID()
        let local = Fixture.row("local", repo: repo)
        let nothing = Fixture.filter([Fixture.row("main", repo: repo, status: .main), local])
        #expect(!nothing.showsButton)

        let cloudOnly = Fixture.filter([Fixture.row("cloud", repo: repo, provider: Fixture.cloud)],
                                       sessions: [Fixture.session("cloud-loose", provider: Fixture.cloud, repoID: repo)])
        #expect(!cloudOnly.showsButton)

        let oneRow = Fixture.filter([Fixture.row("worker", repo: repo, provider: Fixture.acme)])
        #expect(oneRow.showsButton)

        let oneSession = Fixture.filter([], sessions: [Fixture.session("loose", repoID: repo)])
        #expect(oneSession.showsButton)

        let ancestor = Fixture.row("ancestor", repo: repo, provider: Fixture.acme)
        let keptChild = Fixture.row("child", repo: repo, parent: ancestor.id)
        let onlyAnAncestor = Fixture.filter([ancestor, keptChild])
        #expect(!onlyAnAncestor.showsButton)

        #expect(!SidebarRegistryRemoteFilter.none.showsButton)
        #expect(!SidebarRegistryRemoteFilter.none.isOn)
        #expect(SidebarRegistryRemoteFilter.none.hiddenWorktreeIDs.isEmpty)
    }

    @Test func isRegistryProviderIsEveryNameButCloud() {
        #expect(!SidebarRegistryRemoteFilter.isRegistryProvider(ClaudeCloudProvider.name))
        #expect(SidebarRegistryRemoteFilter.isRegistryProvider("acme"))
        #expect(SidebarRegistryRemoteFilter.isRegistryProvider("acme-two"))
    }

    @Test func wordingNamesOneProviderAndFallsBackForTwo() {
        let one = ["acme"], two = ["acme", "acme-two"]
        #expect(SidebarRegistryRemoteFilter.offTooltip(providerNames: one) == "Hide acme sessions")
        #expect(SidebarRegistryRemoteFilter.onTooltip(count: 3, providerNames: one)
                == "3 acme sessions hidden. Click to show them.")
        #expect(SidebarRegistryRemoteFilter.menuTitle(providerNames: one) == "Hide acme Sessions")
        #expect(SidebarRegistryRemoteFilter.offTooltip(providerNames: two) == "Hide remote sessions except cloud")
        #expect(SidebarRegistryRemoteFilter.onTooltip(count: 3, providerNames: two)
                == "3 remote sessions hidden. Click to show them.")
        #expect(SidebarRegistryRemoteFilter.menuTitle(providerNames: two) == "Hide Remote Sessions Except Cloud")

        #expect(SidebarRegistryRemoteFilter.onTooltip(count: 1, providerNames: one)
                == "1 acme session hidden. Click to show it.")
        #expect(SidebarRegistryRemoteFilter.onTooltip(count: 1, providerNames: two)
                == "1 remote session hidden. Click to show it.")
        #expect(SidebarRegistryRemoteFilter.onTooltip(count: 0, providerNames: one)
                == "0 acme sessions hidden. Click to show them.")
    }

    @Test func buttonTooltipAndMenuTitleFollowItsState() {
        let off = SidebarRegistryFilterButton(isOn: false, count: 0, hideableCount: 4, providerNames: ["acme"])
        #expect(off.tooltip == "Hide acme sessions")
        #expect(off.menuTitle == "Hide acme Sessions")

        let on = SidebarRegistryFilterButton(isOn: true, count: 4, hideableCount: 4, providerNames: ["acme"])
        #expect(on.tooltip == "4 acme sessions hidden. Click to show them.")
        #expect(on.menuTitle == "Hide acme Sessions")
    }

    // MARK: Corrupt input

    @Test func aCyclicParentChainHidesNothingAndTerminates() {
        let repo = UUID()
        let firstID = UUID(), secondID = UUID()
        let first = Fixture.row("first", id: firstID, repo: repo, provider: Fixture.acme, parent: secondID)
        let second = Fixture.row("second", id: secondID, repo: repo, provider: Fixture.acme, parent: firstID)
        let filter = Fixture.filter([first, second], roots: [first])
        #expect(filter.hiddenWorktreeIDs.isEmpty)
        #expect(filter.count == 0)
        #expect(filter.hideableCount == 0)
    }
}
