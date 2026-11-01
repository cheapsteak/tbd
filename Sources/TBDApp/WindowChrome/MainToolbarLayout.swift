import AppKit
import Foundation

/// Identifiers of the main window's `NSToolbar` items. The PR button and the
/// file-panel toggle are deliberately absent from the AppKit toolbar.
enum MainToolbarItemID {
    static let toggleSidebar = NSToolbarItem.Identifier("tbd.toolbar.toggleSidebar")
    static let back = NSToolbarItem.Identifier("tbd.toolbar.back")
    static let forward = NSToolbarItem.Identifier("tbd.toolbar.forward")
    static let repoFilter = NSToolbarItem.Identifier("tbd.toolbar.repoFilter")
    static let title = NSToolbarItem.Identifier("tbd.toolbar.title")
    static let servers = NSToolbarItem.Identifier("tbd.toolbar.servers")
    static let remoteTranscript = NSToolbarItem.Identifier("tbd.toolbar.remoteTranscript")
    static let remoteReconnect = NSToolbarItem.Identifier("tbd.toolbar.remoteReconnect")
    static let remoteStop = NSToolbarItem.Identifier("tbd.toolbar.remoteStop")

    /// TBD's own items, in toolbar order: the one list of them.
    static let custom: [NSToolbarItem.Identifier] = [
        toggleSidebar, back, forward, repoFilter, title,
        servers, remoteTranscript, remoteReconnect, remoteStop,
    ]

    /// The standard identifiers the layout uses.
    static let standard: [NSToolbarItem.Identifier] = [.flexibleSpace, .space, .sidebarTrackingSeparator]

    /// Every identifier the toolbar delegate may be asked for.
    static let allowed: [NSToolbarItem.Identifier] = custom + standard
}

/// The inputs that decide which items the toolbar shows.
struct MainToolbarLayoutState: Equatable {
    var sidebarCollapsed: Bool
    var showsServers: Bool
    var showsTranscript: Bool
    var showsReconnect: Bool
    var showsStop: Bool

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

/// One step turning the toolbar's current item list into the next.
enum ToolbarEdit: Equatable {
    case remove(at: Int)
    case insert(NSToolbarItem.Identifier, at: Int)
}

enum MainToolbarLayout {
    /// The item list, left to right, for `state`.
    static func identifiers(for state: MainToolbarLayoutState) -> [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] = [
            MainToolbarItemID.toggleSidebar, MainToolbarItemID.back, MainToolbarItemID.forward,
        ]
        // The leading flexible space only pushes the filter to the sidebar's
        // edge, so it leaves with the filter.
        if !state.sidebarCollapsed {
            ids.append(.flexibleSpace)
            ids.append(MainToolbarItemID.repoFilter)
        }
        ids.append(.sidebarTrackingSeparator)
        ids.append(MainToolbarItemID.title)
        ids.append(.flexibleSpace)

        let remote: [(Bool, NSToolbarItem.Identifier)] = [
            (state.showsTranscript, MainToolbarItemID.remoteTranscript),
            (state.showsReconnect, MainToolbarItemID.remoteReconnect),
            (state.showsStop, MainToolbarItemID.remoteStop),
        ]
        let shownRemote = remote.filter { $0.0 }.map { $0.1 }
        if state.showsServers {
            ids.append(MainToolbarItemID.servers)
            if !shownRemote.isEmpty { ids.append(.space) }
        }
        ids.append(contentsOf: shownRemote)
        return ids
    }

    /// Minimal-ish edits turning `from` into `to`, using only inserts and
    /// removes so items shared by both lists (notably the leading ones and the
    /// tracking separator) are never torn down.
    static func edits(
        from: [NSToolbarItem.Identifier], to: [NSToolbarItem.Identifier]
    ) -> [ToolbarEdit] {
        var working = from
        var result: [ToolbarEdit] = []
        var i = 0
        while i < to.count {
            if i < working.count, working[i] == to[i] {
                i += 1
                continue
            }
            if i < working.count {
                // Count-aware: `.flexibleSpace` repeats, so the item at `i` is
                // only surplus when the rest of `working` holds more of it
                // than the rest of `to` needs.
                let current = working[i]
                let have = working[i...].filter { $0 == current }.count
                let need = to[i...].filter { $0 == current }.count
                if have > need {
                    result.append(.remove(at: i))
                    working.remove(at: i)
                    continue
                }
            }
            result.append(.insert(to[i], at: i))
            working.insert(to[i], at: i)
            i += 1
        }
        while working.count > to.count {
            let last = working.count - 1
            result.append(.remove(at: last))
            working.removeLast()
        }
        return result
    }

    /// Carries out `edits` in order through `remove` and `insert`: the one
    /// loop both the toolbar and `applying(_:to:)` run.
    static func perform(
        _ edits: [ToolbarEdit],
        remove: (Int) -> Void,
        insert: (NSToolbarItem.Identifier, Int) -> Void
    ) {
        for edit in edits {
            switch edit {
            case .remove(let index):
                remove(index)
            case .insert(let identifier, let index):
                insert(identifier, index)
            }
        }
    }

    /// `items` after `edits`, through `perform`.
    static func applying(
        _ edits: [ToolbarEdit], to items: [NSToolbarItem.Identifier]
    ) -> [NSToolbarItem.Identifier] {
        var working = items
        perform(
            edits,
            remove: { index in _ = working.remove(at: index) },
            insert: { identifier, index in working.insert(identifier, at: index) })
        return working
    }
}

/// Section widths the sidebar's minimum thickness is derived from. AppKit
/// drops a toolbar item that does not fit its section, silently, so the
/// sidebar can never be narrower than the window buttons, three icon items and
/// the filter. The running app confirms these numbers.
enum MainToolbarMetrics {
    static let windowButtonsWidth: CGFloat = 80
    static let iconItemWidth: CGFloat = 30
    static let filterMaxWidth: CGFloat = 110
    static let sectionPadding: CGFloat = 20
    static let sidebarMinimumThickness: CGFloat =
        windowButtonsWidth + 3 * iconItemWidth + filterMaxWidth + sectionPadding
    static let sidebarMaximumThickness: CGFloat = 400
}
