import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Where the per-repo "hide registry remote sessions" filter is kept: the
/// daemon's repo row, mirrored from the repo list; a toggle's optimistic
/// write, its fence against stale fetches, its failure restore and alert;
/// overlapping repo fetches; the one-time copy of the old `UserDefaults` set,
/// the saved choice shown until it settles, and its ordering with clicks;
/// and cache invalidation.
/// Specs: docs/specs/2026-11-19-sidebar-remote-session-filter-design.md and
/// docs/specs/2026-11-22-phone-remote-session-filter-design.md.
@MainActor
@Suite("Sidebar registry filter storage")
struct SidebarRegistryFilterStorageTests {
    private static let key = AppState.sidebarRegistryRemoteHiddenRepoIDsKey

    private static func session(_ id: String, lastSeen: Date = Date(timeIntervalSince1970: 100)) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: "acme",
            payload: RemoteSessionPayload(id: id, state: .running),
            gone: false, dismissed: false, lastSeen: lastSeen)
    }

    private static func emptyGroups() -> SidebarRemoteGroups {
        SidebarRemoteGroups(roots: [], remainder: [], allWorktrees: [], inventory: [], providers: [])
    }

    private static func seedCaches(_ state: AppState, repoID: UUID) {
        state.sidebarRegistryFilterCache[repoID] = SidebarRegistryRemoteFilter.none
        state.sidebarParentRemoteGroupsCache[UUID()] = emptyGroups()
    }

    private static func seedCaches(_ state: AppState, repoIDs: [UUID], parentIDs: [UUID]) {
        for repoID in repoIDs { state.sidebarRegistryFilterCache[repoID] = SidebarRegistryRemoteFilter.none }
        for parentID in parentIDs { state.sidebarParentRemoteGroupsCache[parentID] = emptyGroups() }
    }

    private static func cachesAreEmpty(_ state: AppState) -> Bool {
        state.sidebarRegistryFilterCache.isEmpty && state.sidebarParentRemoteGroupsCache.isEmpty
    }

    private func makeState() -> (AppState, TestDefaultsSuite, FilterRPC) {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        let state = AppState(userDefaults: suite.defaults)
        let rpc = FilterRPC()
        state.registryRemoteHiddenSender = { id, hidden in try await rpc.send(id, hidden) }
        return (state, suite, rpc)
    }

    private static func repo(_ name: String, _ value: Bool?) -> Repo {
        Repo(path: "/tmp/acme-\(name)", displayName: name, registryRemoteHidden: value)
    }

    /// `repo` as the daemon would list it with `value` in its column.
    private static func with(_ repo: Repo, _ value: Bool?) -> Repo {
        var listed = repo
        listed.registryRemoteHidden = value
        return listed
    }

    /// The task sending the repo's latest toggle, to await its end.
    private static func send(
        _ state: AppState, _ repoID: UUID, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Task<Void, Never> {
        let pending = state.pendingRegistryFilterToggles[repoID]?.send
        return try #require(pending, "no toggle of the repo is pending", sourceLocation: sourceLocation)
    }

    private static func value(_ state: AppState, _ repoID: UUID) -> Bool? {
        state.repos.first { $0.id == repoID }?.registryRemoteHidden
    }

    private static let refused = DaemonClientError.rpcError("Unknown method: repo.setRegistryRemoteHidden", code: nil)

    /// Waits for the one-time copy's latest run, if one was started.
    private static func copied(_ state: AppState) async {
        await state.registryFilterLegacyCopyTask?.value
    }

    /// Starts a state subscription, as a connect does, answered by no daemon.
    private static func startSubscription(_ state: AppState) {
        state.programStatusListFetcher = { @MainActor in [] }
        state.deltaSubscriber = { _, _ in }
        state.startSubscription()
    }

    // MARK: - The mirror

    /// The filter reads from the repo list: on only where the column is 1,
    /// following each fetch, and kept through a failed one.
    @Test func theMirrorFollowsTheRepoList() async {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let on = Self.repo("on", true), off = Self.repo("off", false), unset = Self.repo("unset", nil)

        state.reposFetcher = { [on, off, unset] }
        await state.refreshRepos()
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [on.id])
        #expect(state.isSidebarRegistryRemoteFilterOn(repoID: on.id))
        #expect(!state.isSidebarRegistryRemoteFilterOn(repoID: unset.id))

        // The phone turned the first off and the third on.
        let turnedOff = Self.with(on, false), turnedOn = Self.with(unset, true)
        state.reposFetcher = { [turnedOff, off, turnedOn] }
        await state.refreshRepos()
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [unset.id])

        state.reposFetcher = { throw DaemonClientError.connectionFailed("boom") }
        await state.refreshRepos()
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [unset.id])
        #expect(rpc.calls.isEmpty, "reading the list sent a write")
    }

    /// Constructing the state neither reads the old key into the filter nor
    /// writes it.
    @Test func constructingAppStateWritesNothing() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        defer { suite.tearDown() }
        _ = AppState(userDefaults: suite.defaults)
        #expect(suite.defaults.object(forKey: Self.key) == nil)

        let saved = [UUID().uuidString]
        suite.defaults.set(saved, forKey: Self.key)
        let state = AppState(userDefaults: suite.defaults)
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs.isEmpty)
        #expect(suite.defaults.stringArray(forKey: Self.key) == saved)
    }

    // MARK: - A toggle

    /// A click flips the filter and the repo's value at once, before the call
    /// is even sent, then sends the new value.
    @Test func aToggleFlipsAtOnceAndCallsTheRPC() async throws {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let a = Self.repo("a", nil)
        state.repos = [a]

        state.toggleSidebarRegistryRemoteFilter(repoID: a.id)
        #expect(state.isSidebarRegistryRemoteFilterOn(repoID: a.id))
        #expect(Self.value(state, a.id) == true)
        #expect(rpc.calls.isEmpty)
        try await Self.send(state, a.id).value
        #expect(rpc.calls == [FilterRPC.Call(repoID: a.id, hidden: true)])

        state.toggleSidebarRegistryRemoteFilter(repoID: a.id)
        #expect(!state.isSidebarRegistryRemoteFilterOn(repoID: a.id))
        #expect(Self.value(state, a.id) == false)
        try await Self.send(state, a.id).value
        #expect(rpc.calls == [
            FilterRPC.Call(repoID: a.id, hidden: true), FilterRPC.Call(repoID: a.id, hidden: false),
        ])
    }

    /// A failed call puts the old value back, keeping its third state: a repo
    /// turned off stays off, and one nobody chose for stays unset. The person
    /// is told why the button flipped back.
    @Test func aFailedToggleRestoresTheOldValueAndSaysSo() async throws {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let off = Self.repo("off", false), unset = Self.repo("unset", nil)
        state.repos = [off, unset]
        rpc.failure = Self.refused

        state.toggleSidebarRegistryRemoteFilter(repoID: off.id)
        state.toggleSidebarRegistryRemoteFilter(repoID: unset.id)
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [off.id, unset.id])
        #expect(state.alertMessage == nil)
        let offSend = try Self.send(state, off.id), unsetSend = try Self.send(state, unset.id)
        await offSend.value
        await unsetSend.value

        #expect(state.sidebarRegistryRemoteHiddenRepoIDs.isEmpty)
        #expect(Self.value(state, off.id) == false)
        #expect(Self.value(state, unset.id) == nil)
        #expect(state.pendingRegistryFilterToggles.isEmpty)
        #expect(state.alertIsError)
        let message = try #require(state.alertMessage, "a failed toggle reverted silently")
        #expect(message.hasPrefix("Couldn't turn on the remote session filter for "))
        #expect(message.contains("Unknown method"))
    }

    /// A call lost because the daemon could not be reached still puts the old
    /// value back, but raises no alert: the connection state already shows it.
    @Test func aToggleLostToADisconnectRaisesNoAlert() async throws {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let on = Self.repo("on", true)
        state.repos = [on]
        state.syncSidebarRegistryRemoteHiddenRepoIDs()
        rpc.failure = DaemonClientError.connectionFailed("boom")

        state.toggleSidebarRegistryRemoteFilter(repoID: on.id)
        #expect(!state.isSidebarRegistryRemoteFilterOn(repoID: on.id))
        try await Self.send(state, on.id).value

        #expect(state.isSidebarRegistryRemoteFilterOn(repoID: on.id))
        #expect(Self.value(state, on.id) == true)
        #expect(state.alertMessage == nil, "a disconnect raised an alert")
    }

    /// A click overtaken by a later one raises nothing when its call fails:
    /// the later call decides what the button shows, and it succeeded.
    @Test func anOvertakenToggleFailingRaisesNoAlert() async throws {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let a = Self.repo("a", nil)
        state.repos = [a]
        rpc.holds = true

        state.toggleSidebarRegistryRemoteFilter(repoID: a.id)
        state.toggleSidebarRegistryRemoteFilter(repoID: a.id)
        let send = try Self.send(state, a.id)
        await rpc.answer(throwing: Self.refused)
        await rpc.answer()
        await send.value

        #expect(!state.isSidebarRegistryRemoteFilterOn(repoID: a.id))
        #expect(Self.value(state, a.id) == false)
        #expect(state.alertMessage == nil, "an overtaken click's failure raised an alert")
    }

    /// A repo refresh that lands while the toggle's call is in flight, or that
    /// was sent before the call committed and lands after it, reads the
    /// daemon's old value. The button keeps the new one.
    @Test func refreshDuringToggleKeepsTheNewValue() async throws {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let a = Self.repo("a", nil)
        state.repos = [a]
        state.reposFetcher = { [a] }
        rpc.holds = true

        state.toggleSidebarRegistryRemoteFilter(repoID: a.id)
        let send = try Self.send(state, a.id)
        await state.refreshRepos()
        #expect(state.isSidebarRegistryRemoteFilterOn(repoID: a.id), "a refresh in flight flipped the button back")
        #expect(Self.value(state, a.id) == true)

        let fetch = RepoFetchGate(answer: [a])
        state.reposFetcher = { await fetch.fetch() }
        let stale = Task { await state.refreshRepos() }
        await fetch.waitForCall()
        await rpc.answer()
        await send.value
        fetch.release()
        await stale.value

        #expect(state.isSidebarRegistryRemoteFilterOn(repoID: a.id), "a fetch sent before the commit flipped it back")
        #expect(Self.value(state, a.id) == true)
    }

    /// Once the call has succeeded, a fetch sent afterwards reads the daemon,
    /// and what it holds wins, such as the phone turning the filter off again.
    @Test func aFetchAfterTheCommitWins() async throws {
        let (state, suite, _) = makeState()
        defer { suite.tearDown() }
        let a = Self.repo("a", nil)
        state.repos = [a]

        state.toggleSidebarRegistryRemoteFilter(repoID: a.id)
        try await Self.send(state, a.id).value
        let turnedOff = Self.with(a, false)
        state.reposFetcher = { [turnedOff] }
        await state.refreshRepos()

        #expect(!state.isSidebarRegistryRemoteFilterOn(repoID: a.id))
        #expect(Self.value(state, a.id) == false)
        #expect(state.pendingRegistryFilterToggles.isEmpty)
    }

    /// Refreshes overlap. A fetch sent before the toggle committed that lands
    /// after a later fetch has been applied, and has retired the toggle, is
    /// dropped: it read the daemon earlier and would flip the button back.
    @Test func anOlderFetchLandingAfterANewerOneIsDropped() async throws {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let a = Self.repo("a", nil)
        state.repos = [a]
        rpc.holds = true

        state.toggleSidebarRegistryRemoteFilter(repoID: a.id)
        let send = try Self.send(state, a.id)
        // Read before the commit: the daemon still holds nothing for `a`.
        let older = RepoFetchGate(answer: [a])
        state.reposFetcher = { await older.fetch() }
        let olderRefresh = Task { await state.refreshRepos() }
        await older.waitForCall()
        await rpc.answer()
        await send.value

        state.reposFetcher = { rpc.listed([a]) }
        await state.refreshRepos()
        #expect(state.pendingRegistryFilterToggles.isEmpty, "the newer fetch did not retire the toggle")
        older.release()
        await olderRefresh.value

        #expect(state.isSidebarRegistryRemoteFilterOn(repoID: a.id), "an older fetch flipped the button back")
        #expect(Self.value(state, a.id) == true)
    }

    /// Two quick clicks send in click order, the second only once the first
    /// has returned. When the second fails, what goes back is what the daemon
    /// holds: the first click's value when its call succeeded, and the value
    /// from before both clicks, unset included, when it failed too.
    @Test func quickTogglesSendInOrderAndAFailurePutsBackWhatTheDaemonHolds() async throws {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let kept = Self.repo("kept", nil), lost = Self.repo("lost", nil)
        state.repos = [kept, lost]
        rpc.holds = true

        state.toggleSidebarRegistryRemoteFilter(repoID: kept.id)
        state.toggleSidebarRegistryRemoteFilter(repoID: kept.id)
        let keptSend = try Self.send(state, kept.id)
        await rpc.waitForHeld()
        #expect(rpc.calls == [FilterRPC.Call(repoID: kept.id, hidden: true)], "the second click was sent before the first returned")
        await rpc.answer()
        await rpc.answer(throwing: Self.refused)
        await keptSend.value
        #expect(rpc.calls == [
            FilterRPC.Call(repoID: kept.id, hidden: true), FilterRPC.Call(repoID: kept.id, hidden: false),
        ])
        #expect(state.isSidebarRegistryRemoteFilterOn(repoID: kept.id))
        #expect(Self.value(state, kept.id) == true)

        state.toggleSidebarRegistryRemoteFilter(repoID: lost.id)
        state.toggleSidebarRegistryRemoteFilter(repoID: lost.id)
        let lostSend = try Self.send(state, lost.id)
        await rpc.answer(throwing: Self.refused)
        await rpc.answer(throwing: Self.refused)
        await lostSend.value
        #expect(!state.isSidebarRegistryRemoteFilterOn(repoID: lost.id))
        #expect(Self.value(state, lost.id) == nil)
    }

    @Test func removingARepoForgetsItsFilter() async {
        let (state, suite, _) = makeState()
        defer { suite.tearDown() }
        let repoA = Self.repo("a", true)
        let repoB = Self.repo("b", true)
        state.repos = [repoA, repoB]
        state.syncSidebarRegistryRemoteHiddenRepoIDs()

        state.repoRemover = { _, _ in throw DaemonClientError.connectionFailed("boom") }
        await state.removeRepo(repoID: repoA.id)
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [repoA.id, repoB.id])

        state.repoRemover = { _, _ in }
        await state.removeRepo(repoID: repoA.id)
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [repoB.id])
    }

    // MARK: - The one-time copy

    /// The old saved set reaches the daemon after the first good refresh:
    /// only repos with no value of their own are set, a listed ID with no
    /// repo is dropped, the key goes once every call succeeded, and the copy
    /// never runs again.
    @Test func theCopySetsOnlyUnsetReposAndRunsOnce() async {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let unset = Self.repo("unset", nil), off = Self.repo("off", false), on = Self.repo("on", true)
        let unlisted = Self.repo("unlisted", nil)
        suite.defaults.set(
            [unset.id.uuidString, off.id.uuidString, on.id.uuidString, UUID().uuidString, "not-a-uuid"],
            forKey: Self.key)
        state.reposFetcher = { rpc.listed([unset, off, on, unlisted]) }

        await state.refreshRepos()
        await Self.copied(state)

        #expect(rpc.calls == [FilterRPC.Call(repoID: unset.id, hidden: true)])
        #expect(Self.value(state, unset.id) == true)
        #expect(Self.value(state, off.id) == false, "a repo turned off was overwritten")
        #expect(Self.value(state, on.id) == true)
        #expect(Self.value(state, unlisted.id) == nil)
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [unset.id, on.id])
        #expect(suite.defaults.object(forKey: Self.key) == nil)

        suite.defaults.set([unlisted.id.uuidString], forKey: Self.key)
        Self.startSubscription(state)
        await state.refreshRepos()
        await Self.copied(state)
        #expect(rpc.calls.count == 1, "the copy ran again after it succeeded")
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [unset.id, on.id], "the key was read again")
    }

    /// A daemon that refuses the call, such as one too old to know it, loses
    /// nothing: the key stays as it was, no repo with a value is touched, and
    /// the saved choice still shows. The poll's refreshes do not ask again;
    /// the copy runs again once a state subscription starts, as after a
    /// reconnect, and then the daemon takes it.
    @Test func aRefusedCopyKeepsTheKeyAndRunsAgainAtTheNextSubscription() async {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let unset = Self.repo("unset", nil), off = Self.repo("off", false)
        let saved = [unset.id.uuidString, off.id.uuidString]
        suite.defaults.set(saved, forKey: Self.key)
        state.reposFetcher = { rpc.listed([unset, off]) }
        rpc.failure = Self.refused

        await state.refreshRepos()
        await Self.copied(state)

        #expect(rpc.calls == [FilterRPC.Call(repoID: unset.id, hidden: true)])
        #expect(suite.defaults.stringArray(forKey: Self.key) == saved)
        #expect(Self.value(state, unset.id) == nil)
        #expect(Self.value(state, off.id) == false)
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [unset.id], "the saved choice is hidden while the copy fails")

        rpc.failure = nil
        await state.refreshRepos()
        await Self.copied(state)
        await state.refreshRepos()
        await Self.copied(state)
        #expect(rpc.calls.count == 1, "a poll's refresh ran the failed copy again")
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [unset.id])

        Self.startSubscription(state)
        await state.refreshRepos()
        await Self.copied(state)
        #expect(rpc.calls == [
            FilterRPC.Call(repoID: unset.id, hidden: true), FilterRPC.Call(repoID: unset.id, hidden: true),
        ])
        #expect(Self.value(state, unset.id) == true)
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [unset.id])
        #expect(suite.defaults.object(forKey: Self.key) == nil)

        Self.startSubscription(state)
        await state.refreshRepos()
        await Self.copied(state)
        #expect(rpc.calls.count == 2, "the copy ran again after it succeeded")
    }

    /// Without the old key there is nothing to copy, and nothing is sent.
    @Test func noKeyCopiesNothing() async {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let unset = Self.repo("unset", nil)
        state.reposFetcher = { [unset] }

        await state.refreshRepos()
        await Self.copied(state)

        #expect(rpc.calls.isEmpty)
        #expect(Self.value(state, unset.id) == nil)
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs.isEmpty)
    }

    /// The saved choice shows from the first refresh, before the copy's call
    /// has returned, and the refresh does not wait for that call. A list read
    /// before the call committed still shows it; once a fetch sent after the
    /// copy succeeded is applied, the daemon's values alone decide, so a
    /// listed ID whose repo was not there when the copy ran stays dropped.
    @Test func theSavedChoiceShowsUntilTheCopyHasSettled() async {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let a = Self.repo("a", nil), b = Self.repo("b", nil), late = Self.repo("late", nil)
        suite.defaults.set([a.id.uuidString, late.id.uuidString], forKey: Self.key)
        state.reposFetcher = { rpc.listed([a, b]) }
        rpc.holds = true

        let returned = Flag()
        let firstRefresh = Task {
            await state.refreshRepos()
            returned.isSet = true
        }
        await rpc.waitForHeld()
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { returned.isSet }
        }
        if outcome == .timedOut {
            Issue.record(BoundedWaitTimeout(
                what: "refreshRepos() returning while the copy's call is held",
                observed: "it had not returned",
                deadline: TestDeadlines.saturatedPass))
        }
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [a.id], "the saved choice waited for the copy")
        #expect(Self.value(state, a.id) == nil)

        // Sent before the copy's call commits, applied after it returned.
        let older = RepoFetchGate(answer: [a, b])
        state.reposFetcher = { await older.fetch() }
        let olderRefresh = Task { await state.refreshRepos() }
        await older.waitForCall()
        await rpc.answer()
        await Self.copied(state)
        await firstRefresh.value
        older.release()
        await olderRefresh.value
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [a.id], "a list read before the commit hid the saved choice")

        state.reposFetcher = { rpc.listed([a, b]) }
        await state.refreshRepos()
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [a.id])
        state.reposFetcher = { rpc.listed([a, b, late]) }
        await state.refreshRepos()
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [a.id], "a repo the copy dropped showed the saved choice")
        #expect(rpc.calls == [FilterRPC.Call(repoID: a.id, hidden: true)])
    }

    /// A click on a repo whose copy call is in flight is sent only once that
    /// call has returned, and the daemon's `true` from the copy is what the
    /// click's failure puts back.
    @Test func aClickDuringTheCopysCallIsSentAfterIt() async throws {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let a = Self.repo("a", nil)
        suite.defaults.set([a.id.uuidString], forKey: Self.key)
        state.reposFetcher = { rpc.listed([a]) }
        rpc.holds = true

        await state.refreshRepos()
        await rpc.waitForHeld()
        #expect(state.isSidebarRegistryRemoteFilterOn(repoID: a.id))
        state.toggleSidebarRegistryRemoteFilter(repoID: a.id)
        #expect(!state.isSidebarRegistryRemoteFilterOn(repoID: a.id))
        let click = try Self.send(state, a.id)
        await rpc.answer()
        await rpc.answer(throwing: Self.refused)
        await click.value
        await Self.copied(state)

        #expect(rpc.calls == [FilterRPC.Call(repoID: a.id, hidden: true), FilterRPC.Call(repoID: a.id, hidden: false)])
        #expect(rpc.mostHeldAtOnce == 1, "the click was sent while the copy's call was in flight")
        #expect(state.isSidebarRegistryRemoteFilterOn(repoID: a.id))
        #expect(Self.value(state, a.id) == true, "the failed click put back a value the daemon no longer holds")
    }

    /// A repo clicked while the copy is busy with another is decided just
    /// before its own call: once the click's call has returned, a click that
    /// succeeded stands, and the repo of a click that failed is copied.
    @Test func theCopyLeavesARepoClickedDuringItToTheClick() async throws {
        let (state, suite, rpc) = makeState()
        defer { suite.tearDown() }
        let a = Self.repo("a", nil), clicked = Self.repo("clicked", nil), lost = Self.repo("lost", nil)
        suite.defaults.set([a.id.uuidString, clicked.id.uuidString, lost.id.uuidString], forKey: Self.key)
        state.reposFetcher = { rpc.listed([a, clicked, lost]) }
        rpc.holds = true

        await state.refreshRepos()
        await rpc.waitForHeld()
        state.toggleSidebarRegistryRemoteFilter(repoID: clicked.id)
        let clickedSend = try Self.send(state, clicked.id)
        await rpc.waitForHeld(count: 2)
        state.toggleSidebarRegistryRemoteFilter(repoID: lost.id)
        let lostSend = try Self.send(state, lost.id)
        await rpc.waitForHeld(count: 3)

        await rpc.answer()
        await rpc.answer()
        await clickedSend.value
        await rpc.answer(throwing: Self.refused)
        await lostSend.value
        await rpc.answer()
        await Self.copied(state)

        #expect(rpc.calls == [
            FilterRPC.Call(repoID: a.id, hidden: true),
            FilterRPC.Call(repoID: clicked.id, hidden: false),
            FilterRPC.Call(repoID: lost.id, hidden: false),
            FilterRPC.Call(repoID: lost.id, hidden: true),
        ])
        #expect(Self.value(state, clicked.id) == false, "the copy overwrote a click")
        #expect(Self.value(state, lost.id) == true)
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [a.id, lost.id])
        #expect(suite.defaults.object(forKey: Self.key) == nil)
    }

    @Test func absentEmptyAndUnreadableEntriesMeanNoFilter() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        defer { suite.tearDown() }
        let a = UUID()
        #expect(AppState.restoredSidebarRegistryRemoteHiddenRepoIDs(defaults: suite.defaults).isEmpty)
        suite.defaults.set([String](), forKey: Self.key)
        #expect(AppState.restoredSidebarRegistryRemoteHiddenRepoIDs(defaults: suite.defaults).isEmpty)
        suite.defaults.set(["not-a-uuid", a.uuidString], forKey: Self.key)
        #expect(AppState.restoredSidebarRegistryRemoteHiddenRepoIDs(defaults: suite.defaults) == [a])
    }

    // MARK: - Caches

    @Test func aToggleClearsBothCaches() {
        let (state, suite, _) = makeState()
        defer { suite.tearDown() }
        let repoID = UUID()
        Self.seedCaches(state, repoID: repoID)
        state.toggleSidebarRegistryRemoteFilter(repoID: repoID)
        #expect(Self.cachesAreEmpty(state))
    }

    /// A selection change clears nothing while no repo is filtered, and then
    /// only what a filtered repo's section shows: that repo's filter, and the
    /// partition of each parent whose top-level ancestor is in that repo,
    /// whatever the parent's own repo. An unfiltered repo's filter and the
    /// partitions in its section survive.
    @Test func selectionClearsOnlyTheFilteredReposCaches() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        defer { suite.tearDown() }
        let filtered = UUID(), unfiltered = UUID()
        let director = SidebarGroupFixtures.row("director", repoID: filtered)
        // Another repo's row nested under the filtered repo's row renders in
        // the filtered repo's section.
        let guest = SidebarGroupFixtures.row("guest", repoID: unfiltered, parent: director.id)
        let lead = SidebarGroupFixtures.row("lead", repoID: unfiltered)
        let state = AppState(userDefaults: suite.defaults)
        state.worktrees = [filtered: [director], unfiltered: [guest, lead]]
        let parents = [director.id, guest.id, lead.id]

        _ = state.sidebarRemoteSnapshot
        Self.seedCaches(state, repoIDs: [filtered, unfiltered], parentIDs: parents)
        state.selectedWorktreeIDs = [UUID()]
        state.selectedRemoteSession = RemoteSessionSelection(provider: "acme", sessionID: "s1")
        #expect(state.sidebarRegistryFilterCache.count == 2, "Unfiltered, a selection change cleared a filter")
        #expect(state.sidebarParentRemoteGroupsCache.count == 3, "Unfiltered, a selection change cleared a partition")

        state.sidebarRegistryRemoteHiddenRepoIDs = [filtered]
        _ = state.sidebarRemoteSnapshot
        Self.seedCaches(state, repoIDs: [filtered, unfiltered], parentIDs: parents)
        state.selectedWorktreeIDs = [UUID()]
        #expect(state.sidebarRegistryFilterCache[filtered] == nil)
        #expect(state.sidebarRegistryFilterCache[unfiltered] != nil, "The unfiltered repo's filter was cleared")
        #expect(state.sidebarParentRemoteGroupsCache[director.id] == nil)
        #expect(state.sidebarParentRemoteGroupsCache[guest.id] == nil, "A parent in the filtered section survived")
        #expect(state.sidebarParentRemoteGroupsCache[lead.id] != nil, "A parent in the unfiltered section was cleared")

        Self.seedCaches(state, repoIDs: [filtered, unfiltered], parentIDs: parents)
        state.selectedRemoteSession = RemoteSessionSelection(provider: "acme", sessionID: "s2")
        #expect(state.sidebarRegistryFilterCache[filtered] == nil)
        #expect(state.sidebarRegistryFilterCache[unfiltered] != nil, "The unfiltered repo's filter was cleared")
        #expect(state.sidebarParentRemoteGroupsCache[director.id] == nil)
        #expect(state.sidebarParentRemoteGroupsCache[guest.id] == nil, "A parent in the filtered section survived")
        #expect(state.sidebarParentRemoteGroupsCache[lead.id] != nil, "A parent in the unfiltered section was cleared")

        // With no snapshot to name a parent's section, every partition clears.
        Self.seedCaches(state, repoIDs: [unfiltered], parentIDs: [lead.id])
        state.sidebarRemoteSnapshotCache = nil
        state.selectedWorktreeIDs = [UUID()]
        #expect(state.sidebarParentRemoteGroupsCache.isEmpty)
        #expect(state.sidebarRegistryFilterCache[unfiltered] != nil, "The unfiltered repo's filter was cleared")
    }

    @Test func onlyMatchInputChangesClearTheFilterCache() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        defer { suite.tearDown() }
        let repoID = UUID()
        let state = AppState(userDefaults: suite.defaults)
        state.remoteSessions = [Self.session("s1")]

        state.sidebarRegistryFilterCache[repoID] = SidebarRegistryRemoteFilter.none
        state.remoteSessions = [Self.session("s1", lastSeen: Date(timeIntervalSince1970: 999))]
        #expect(!state.sidebarRegistryFilterCache.isEmpty)

        state.remoteSessions = [Self.session("s1"), Self.session("s2")]
        #expect(state.sidebarRegistryFilterCache.isEmpty)

        state.sidebarRegistryFilterCache[repoID] = SidebarRegistryRemoteFilter.none
        state.worktrees = [:]
        #expect(state.sidebarRegistryFilterCache.isEmpty)
    }
}

// MARK: - Gates

/// Stands in for `repo.setRegistryRemoteHidden`: records each call, and
/// answers it at once (throwing `failure` when set) or, while `holds`, holds
/// it until the test answers. Keeps what the daemon would hold, so a fetch
/// can list it (`listed`).
@MainActor
private final class FilterRPC {
    struct Call: Equatable {
        let repoID: UUID
        let hidden: Bool
    }

    private(set) var calls: [Call] = []
    /// Each repo's value from its last call that succeeded.
    private(set) var stored: [UUID: Bool] = [:]
    /// The most calls held at the same time.
    private(set) var mostHeldAtOnce = 0
    var holds = false
    var failure: (any Error)?
    private var held: [CheckedContinuation<Void, any Error>] = []

    func send(_ repoID: UUID, _ hidden: Bool) async throws {
        calls.append(Call(repoID: repoID, hidden: hidden))
        if holds {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                held.append(continuation)
                mostHeldAtOnce = max(mostHeldAtOnce, held.count)
            }
        } else if let failure {
            throw failure
        }
        stored[repoID] = hidden
    }

    /// `repos` as the daemon would list them, with each stored value in its
    /// column.
    func listed(_ repos: [Repo]) -> [Repo] {
        repos.map { repo in
            guard let value = stored[repo.id] else { return repo }
            var listed = repo
            listed.registryRemoteHidden = value
            return listed
        }
    }

    /// Returns once `count` calls are held, recording a timeout instead of
    /// hanging.
    func waitForHeld(count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async {
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { self.held.count >= count }
        }
        if outcome == .timedOut {
            Issue.record(
                BoundedWaitTimeout(
                    what: "\(count) held repo.setRegistryRemoteHidden call(s)",
                    observed: "\(calls.count) call(s) made, \(held.count) held",
                    deadline: TestDeadlines.saturatedPass),
                sourceLocation: sourceLocation)
        }
    }

    /// Answers the oldest held call once it is made, throwing `error` if given.
    func answer(throwing error: (any Error)? = nil, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitForHeld(sourceLocation: sourceLocation)
        guard !held.isEmpty else { return }
        let continuation = held.removeFirst()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

/// Stands in for `repo.list`: holds each fetch until `release`, then answers
/// `answer`.
@MainActor
private final class RepoFetchGate {
    private let answer: [Repo]
    private var held: CheckedContinuation<[Repo], Never>?

    init(answer: [Repo]) {
        self.answer = answer
    }

    func fetch() async -> [Repo] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Repo], Never>) in
            held = continuation
        }
    }

    /// Returns once a fetch is held, recording a timeout instead of hanging.
    func waitForCall(sourceLocation: SourceLocation = #_sourceLocation) async {
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { self.held != nil }
        }
        if outcome == .timedOut {
            Issue.record(
                BoundedWaitTimeout(what: "a held repo fetch", observed: nil, deadline: TestDeadlines.saturatedPass),
                sourceLocation: sourceLocation)
        }
    }

    func release() {
        guard let held else {
            Issue.record("no repo fetch is held")
            return
        }
        self.held = nil
        held.resume(returning: answer)
    }
}

/// Set once a task the test started has got past the call it wraps.
@MainActor
private final class Flag {
    var isSet = false
}
