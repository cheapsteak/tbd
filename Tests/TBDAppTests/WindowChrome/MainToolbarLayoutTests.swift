import AppKit
import Foundation
import Testing
@testable import TBDApp
import TestSupport

@MainActor
@Suite("Main toolbar layout")
struct MainToolbarLayoutTests {
    private typealias ID = MainToolbarItemID

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
        #expect(MainWindowChrome.resolve(suite.defaults) == .swiftUI)
        suite.defaults.set(true, forKey: AppState.appKitSidebarKey)
        #expect(MainWindowChrome.resolve(suite.defaults) == .appKit)
        suite.defaults.set(false, forKey: AppState.appKitSidebarKey)
        #expect(MainWindowChrome.resolve(suite.defaults) == .swiftUI)
    }

    @Test func shownOrder() {
        let expected: [NSToolbarItem.Identifier] = [
            ID.toggleSidebar, ID.back, ID.forward, .flexibleSpace, ID.repoFilter,
            .sidebarTrackingSeparator, ID.title, .flexibleSpace,
        ]
        #expect(Self.ids(Self.state(collapsed: false)) == expected)
    }

    @Test func collapsedOrder() {
        let expected: [NSToolbarItem.Identifier] = [
            ID.toggleSidebar, ID.back, ID.forward,
            .sidebarTrackingSeparator, ID.title, .flexibleSpace,
        ]
        #expect(Self.ids(Self.state(collapsed: true)) == expected)
    }

    @Test func filterOnlyWhileShown() {
        for state in MainToolbarLayoutState.allCombinations {
            let hasFilter = Self.ids(state).contains(ID.repoFilter)
            #expect(hasFilter == !state.sidebarCollapsed)
        }
    }

    @Test func toggleAndArrowsLeadInEveryState() {
        let lead: [NSToolbarItem.Identifier] = [ID.toggleSidebar, ID.back, ID.forward]
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
            #expect(list.contains(ID.servers) == state.showsServers)
            #expect(list.contains(ID.remoteTranscript) == state.showsTranscript)
            #expect(list.contains(ID.remoteReconnect) == state.showsReconnect)
            #expect(list.contains(ID.remoteStop) == state.showsStop)
            let remote = list.filter {
                $0 == ID.remoteTranscript || $0 == ID.remoteReconnect || $0 == ID.remoteStop
            }
            let order: [NSToolbarItem.Identifier] = [
                ID.remoteTranscript, ID.remoteReconnect, ID.remoteStop,
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
            if wantsSpace, let serversIndex = list.firstIndex(of: ID.servers) {
                #expect(list[serversIndex + 1] == .space)
            }
        }
    }

    @Test func noPRAndNoFilePanelItem() {
        #expect(ID.custom.count == 9)
        for id in ID.custom {
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

    @Test func editsNeverTouchTheLeadingItems() {
        let protected: Set<NSToolbarItem.Identifier> = [
            ID.toggleSidebar, ID.back, ID.forward, .sidebarTrackingSeparator,
        ]
        let all = MainToolbarLayoutState.allCombinations
        for a in all {
            for b in all {
                var working = Self.ids(a)
                let edits = MainToolbarLayout.edits(from: working, to: Self.ids(b))
                for edit in edits {
                    switch edit {
                    case .remove(let index):
                        let removed = working.remove(at: index)
                        #expect(!protected.contains(removed))
                    case .insert(let id, let index):
                        working.insert(id, at: index)
                    }
                }
            }
        }
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
