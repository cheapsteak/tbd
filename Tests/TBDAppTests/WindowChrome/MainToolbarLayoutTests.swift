import AppKit
import Foundation
import Testing
@testable import TBDApp
import TestSupport

@MainActor
@Suite("Main toolbar layout")
struct MainToolbarLayoutTests {
    private typealias ItemID = MainToolbarItemID

    private static func ids(_ state: MainToolbarLayoutState) -> [NSToolbarItem.Identifier] {
        MainToolbarLayout.identifiers(for: state)
    }

    private static func state(collapsed: Bool) -> MainToolbarLayoutState {
        MainToolbarLayoutState(
            sidebarCollapsed: collapsed, showsServers: false, showsTranscript: false,
            showsReconnect: false, showsStop: false)
    }

    @Test func chromeFollowsTheFlag() {
        let suite = TestDefaultsSuite("MainToolbarLayoutTests.chrome")
        defer { suite.tearDown() }
        let unsetExpected: MainWindowChrome = AppState.appKitSidebarDefault ? .appKit : .swiftUI
        #expect(MainWindowChrome.resolve(suite.defaults) == unsetExpected)
        suite.defaults.set(true, forKey: AppState.appKitSidebarKey)
        #expect(MainWindowChrome.resolve(suite.defaults) == .appKit)
        suite.defaults.set(false, forKey: AppState.appKitSidebarKey)
        #expect(MainWindowChrome.resolve(suite.defaults) == .swiftUI)
    }

    @Test func shownOrder() {
        let expected: [NSToolbarItem.Identifier] = [
            ItemID.toggleSidebar, ItemID.back, ItemID.forward, .flexibleSpace, ItemID.repoFilter,
            .sidebarTrackingSeparator, ItemID.title, .flexibleSpace,
        ]
        #expect(Self.ids(Self.state(collapsed: false)) == expected)
    }

    @Test func shownOrderWithEveryRightHandItem() {
        let state = MainToolbarLayoutState(
            sidebarCollapsed: false, showsServers: true, showsTranscript: true,
            showsReconnect: true, showsStop: true)
        let expected: [NSToolbarItem.Identifier] = [
            ItemID.toggleSidebar, ItemID.back, ItemID.forward, .flexibleSpace, ItemID.repoFilter,
            .sidebarTrackingSeparator, ItemID.title, .flexibleSpace,
            ItemID.servers, .space, ItemID.remoteTranscript, ItemID.remoteReconnect, ItemID.remoteStop,
        ]
        #expect(Self.ids(state) == expected)
    }

    @Test func collapsedOrderWithServersAndReconnect() {
        let state = MainToolbarLayoutState(
            sidebarCollapsed: true, showsServers: true, showsTranscript: false,
            showsReconnect: true, showsStop: false)
        let expected: [NSToolbarItem.Identifier] = [
            ItemID.toggleSidebar, ItemID.back, ItemID.forward,
            .sidebarTrackingSeparator, ItemID.title, .flexibleSpace,
            ItemID.servers, .space, ItemID.remoteReconnect,
        ]
        #expect(Self.ids(state) == expected)
    }

    @Test func everyEmittedIdentifierIsAllowed() {
        let allowed = Set(ItemID.allowed)
        for state in MainToolbarLayoutState.allCombinations {
            #expect(Self.ids(state).allSatisfy { allowed.contains($0) })
        }
    }

    @Test func collapsedOrder() {
        let expected: [NSToolbarItem.Identifier] = [
            ItemID.toggleSidebar, ItemID.back, ItemID.forward,
            .sidebarTrackingSeparator, ItemID.title, .flexibleSpace,
        ]
        #expect(Self.ids(Self.state(collapsed: true)) == expected)
    }

    @Test func filterOnlyWhileShown() {
        for state in MainToolbarLayoutState.allCombinations {
            let hasFilter = Self.ids(state).contains(ItemID.repoFilter)
            #expect(hasFilter == !state.sidebarCollapsed)
        }
    }

    @Test func toggleAndArrowsLeadInEveryState() {
        let lead: [NSToolbarItem.Identifier] = [ItemID.toggleSidebar, ItemID.back, ItemID.forward]
        for state in MainToolbarLayoutState.allCombinations {
            let list = Self.ids(state)
            #expect(Array(list.prefix(3)) == lead)
            let separator = list.firstIndex(of: .sidebarTrackingSeparator)
            #expect((separator ?? 0) > 2)
        }
    }

    @Test func eachRightHandItemFollowsItsFlag() {
        for state in MainToolbarLayoutState.allCombinations {
            let list = Self.ids(state)
            #expect(list.contains(ItemID.servers) == state.showsServers)
            #expect(list.contains(ItemID.remoteTranscript) == state.showsTranscript)
            #expect(list.contains(ItemID.remoteReconnect) == state.showsReconnect)
            #expect(list.contains(ItemID.remoteStop) == state.showsStop)
            let remote = list.filter {
                $0 == ItemID.remoteTranscript || $0 == ItemID.remoteReconnect || $0 == ItemID.remoteStop
            }
            let order: [NSToolbarItem.Identifier] = [
                ItemID.remoteTranscript, ItemID.remoteReconnect, ItemID.remoteStop,
            ]
            #expect(remote == order.filter { remote.contains($0) })
        }
    }

    @Test func spaceOnlyBetweenServersAndRemote() {
        for state in MainToolbarLayoutState.allCombinations {
            let list = Self.ids(state)
            let anyRemote = state.showsTranscript || state.showsReconnect || state.showsStop
            let wantsSpace = state.showsServers && anyRemote
            #expect(list.contains(.space) == wantsSpace)
            if wantsSpace, let serversIndex = list.firstIndex(of: ItemID.servers) {
                let after = list.dropFirst(serversIndex + 1).first
                #expect(after == .space)
            }
        }
    }

    @Test func noPRAndNoFilePanelItem() {
        #expect(ItemID.custom.count == 9)
        let distinct = Set(ItemID.custom)
        #expect(distinct.count == ItemID.custom.count)
        let allowed: [NSToolbarItem.Identifier] = ItemID.custom + ItemID.standard
        #expect(ItemID.allowed == allowed)
        for id in ItemID.custom {
            let raw = id.rawValue.lowercased()
            #expect(!raw.hasSuffix(".pr"))
            #expect(!raw.contains("filepanel"))
        }
    }

    @Test func editsReachTheTarget() {
        let all = MainToolbarLayoutState.allCombinations
        for a in all {
            for b in all {
                let from = Self.ids(a)
                let to = Self.ids(b)
                let edits = MainToolbarLayout.edits(from: from, to: to)
                #expect(MainToolbarLayout.applying(edits, to: from) == to)
            }
        }
    }

    /// Run through `MainToolbarLayout.perform`, the loop the toolbar runs.
    @Test func editsNeverTouchTheLeadingItems() {
        let protected: Set<NSToolbarItem.Identifier> = [
            ItemID.toggleSidebar, ItemID.back, ItemID.forward, .sidebarTrackingSeparator,
        ]
        let all = MainToolbarLayoutState.allCombinations
        for a in all {
            for b in all {
                var working = Self.ids(a)
                let edits = MainToolbarLayout.edits(from: working, to: Self.ids(b))
                var removed: [NSToolbarItem.Identifier] = []
                let stop = MainToolbarLayout.perform(
                    edits,
                    count: { working.count },
                    remove: { index in removed.append(working.remove(at: index)) },
                    insert: { identifier, index in working.insert(identifier, at: index) })
                #expect(stop == nil)
                let touched = removed.filter { protected.contains($0) }
                #expect(touched.isEmpty)
            }
        }
    }

    // MARK: - Edits that do not take

    /// An insert that adds nothing, as one the toolbar's delegate cannot
    /// serve, stops the run there: nothing after it is attempted, so no later
    /// index, each of which assumed it took, reaches the list.
    @Test func performStopsAtAnInsertThatAddsNothing() {
        let leading: [NSToolbarItem.Identifier] = [ItemID.toggleSidebar, ItemID.back, ItemID.forward]
        let items = FakeToolbarItems(leading, refusing: [.sidebarTrackingSeparator])
        let edits = MainToolbarLayout.edits(from: leading, to: Self.ids(Self.state(collapsed: true)))

        let stop = items.perform(edits)

        let refusedInsert = ToolbarEdit.insert(.sidebarTrackingSeparator, at: 3)
        let expectedStop = ToolbarEditStop.noEffect(refusedInsert)
        #expect(stop == expectedStop)
        let expectedAttempts: [ToolbarEdit] = [refusedInsert]
        #expect(items.attempts == expectedAttempts)
        #expect(items.list == leading)
    }

    /// An index outside the list as it stands is never carried out, for an
    /// insert past the end or a remove at it, where `NSToolbar` would raise.
    @Test func performCarriesOutNothingOutsideTheList() {
        let leading: [NSToolbarItem.Identifier] = [ItemID.toggleSidebar, ItemID.back, ItemID.forward]
        let pastTheEnd = ToolbarEdit.insert(ItemID.title, at: 4)
        let atTheEnd = ToolbarEdit.remove(at: 3)
        let cases: [ToolbarEdit] = [pastTheEnd, atTheEnd]
        for edit in cases {
            let items = FakeToolbarItems(leading)
            let stop = items.perform([edit])
            let expectedStop = ToolbarEditStop.outOfRange(edit)
            #expect(stop == expectedStop)
            #expect(items.attempts.isEmpty)
            #expect(items.list == leading)
        }
    }

    /// A refused item is left out of the passes after the one it stopped, so
    /// the next pass lands the rest of the layout and the one after that does
    /// not try it again. A changed target tries it again, and so does a
    /// reset, which lands it once the toolbar serves it.
    @Test func aRefusedItemIsLeftOutUntilTheTargetChangesOrAReset() {
        let separator: Set<NSToolbarItem.Identifier> = [.sidebarTrackingSeparator]
        let collapsed = Self.ids(Self.state(collapsed: true))
        let expanded = Self.ids(Self.state(collapsed: false))
        let leading: [NSToolbarItem.Identifier] = [ItemID.toggleSidebar, ItemID.back, ItemID.forward]
        let items = FakeToolbarItems(leading, refusing: separator)
        var sync = ToolbarLayoutSync()

        let first = items.pass(&sync, to: collapsed)
        let firstExpected = ToolbarLayoutSync.Outcome.stopped(
            .noEffect(.insert(.sidebarTrackingSeparator, at: 3)), retry: true)
        #expect(first == firstExpected)
        #expect(sync.refused == separator)

        let second = items.pass(&sync, to: collapsed)
        let secondExpected = ToolbarLayoutSync.Outcome.landed(edits: 2)
        #expect(second == secondExpected)
        let collapsedWithoutSeparator = collapsed.filter { !separator.contains($0) }
        #expect(items.list == collapsedWithoutSeparator)

        let third = items.pass(&sync, to: collapsed)
        let nothingToDo = ToolbarLayoutSync.Outcome.landed(edits: 0)
        #expect(third == nothingToDo)
        #expect(items.attempts.isEmpty)

        let changed = items.pass(&sync, to: expanded)
        let changedExpected = ToolbarLayoutSync.Outcome.stopped(
            .noEffect(.insert(.sidebarTrackingSeparator, at: 5)), retry: true)
        #expect(changed == changedExpected)
        let expandedWithoutSeparator = expanded.filter { !separator.contains($0) }
        #expect(items.list == expandedWithoutSeparator)

        items.refusing = []
        sync.reset()
        let served = items.pass(&sync, to: expanded)
        let servedExpected = ToolbarLayoutSync.Outcome.landed(edits: 1)
        #expect(served == servedExpected)
        #expect(items.list == expanded)
        #expect(sync.refused.isEmpty)
    }

    /// Each stop leaves out one more identifier, so passes over items the
    /// toolbar never serves end once every one of them is left out, where
    /// passes that kept trying them would never land.
    @Test func passesOverItemsNeverServedEnd() {
        let refusing: Set<NSToolbarItem.Identifier> = [.sidebarTrackingSeparator, ItemID.title]
        let target = Self.ids(Self.state(collapsed: false))
        let items = FakeToolbarItems([], refusing: refusing)
        var sync = ToolbarLayoutSync()

        var retries = 0
        var outcome = items.pass(&sync, to: target)
        while case .stopped(_, retry: true) = outcome, retries < target.count {
            retries += 1
            outcome = items.pass(&sync, to: target)
        }

        #expect(retries == refusing.count)
        let landedOnce = ToolbarLayoutSync.Outcome.landed(edits: 1)
        #expect(outcome == landedOnce)
        #expect(sync.refused == refusing)
        let served = target.filter { !refusing.contains($0) }
        #expect(items.list == served)
    }

    @Test func minimumThicknessFitsTheSidebarSection() {
        let needed: CGFloat = MainToolbarMetrics.windowButtonsWidth
            + 3 * MainToolbarMetrics.iconItemWidth + MainToolbarMetrics.filterMaxWidth
        let minimum: CGFloat = MainToolbarMetrics.sidebarMinimumThickness
        let maximum: CGFloat = MainToolbarMetrics.sidebarMaximumThickness
        #expect(minimum >= needed)
        #expect(minimum <= maximum)
    }
}

private extension MainToolbarLayoutState {
    /// All 32 combinations of the five flags.
    static var allCombinations: [MainToolbarLayoutState] {
        (0..<32).map { bits in
            MainToolbarLayoutState(
                sidebarCollapsed: bits & 1 != 0,
                showsServers: bits & 2 != 0,
                showsTranscript: bits & 4 != 0,
                showsReconnect: bits & 8 != 0,
                showsStop: bits & 16 != 0)
        }
    }
}

private extension MainToolbarLayout {
    /// `items` after `edits`, through `perform`, the loop the toolbar runs.
    static func applying(
        _ edits: [ToolbarEdit], to items: [NSToolbarItem.Identifier]
    ) -> [NSToolbarItem.Identifier] {
        var working = items
        perform(
            edits,
            count: { working.count },
            remove: { index in _ = working.remove(at: index) },
            insert: { identifier, index in working.insert(identifier, at: index) })
        return working
    }
}

/// A toolbar's item list as a plain array. An insert of an identifier in
/// `refusing` adds nothing, as one the toolbar's delegate cannot serve. An
/// edit outside the list adds or removes nothing either, where the array
/// would trap and `NSToolbar` would raise, so a run that reaches one fails
/// its test rather than ending the process. Every edit the run hands over
/// is recorded in `attempts`.
private final class FakeToolbarItems {
    private(set) var list: [NSToolbarItem.Identifier]
    var refusing: Set<NSToolbarItem.Identifier>
    /// The edits handed over by the latest `perform` or `pass`.
    private(set) var attempts: [ToolbarEdit] = []

    init(_ list: [NSToolbarItem.Identifier], refusing: Set<NSToolbarItem.Identifier> = []) {
        self.list = list
        self.refusing = refusing
    }

    func perform(_ edits: [ToolbarEdit]) -> ToolbarEditStop? {
        attempts.removeAll()
        return MainToolbarLayout.perform(
            edits, count: { self.list.count }, remove: { self.remove(at: $0) }, insert: { self.insert($0, at: $1) })
    }

    func pass(_ sync: inout ToolbarLayoutSync, to target: [NSToolbarItem.Identifier]) -> ToolbarLayoutSync.Outcome {
        attempts.removeAll()
        return sync.pass(
            to: target, from: list,
            count: { self.list.count }, remove: { self.remove(at: $0) }, insert: { self.insert($0, at: $1) })
    }

    private func remove(at index: Int) {
        attempts.append(.remove(at: index))
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
    }

    private func insert(_ identifier: NSToolbarItem.Identifier, at index: Int) {
        attempts.append(.insert(identifier, at: index))
        guard !refusing.contains(identifier), index >= 0, index <= list.count else { return }
        list.insert(identifier, at: index)
    }
}
