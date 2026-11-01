import AppKit
import Foundation

/// Identifiers of the main window's `NSToolbar` items. The PR button and the
/// file-panel toggle are deliberately absent from the AppKit toolbar.
enum MainToolbarItemID {
    static let toggleSidebar = NSToolbarItem.Identifier("tbd.toolbar.toggleSidebar")
    static let back = NSToolbarItem.Identifier("tbd.toolbar.back")
    static let forward = NSToolbarItem.Identifier("tbd.toolbar.forward")
    static let repoFilter = NSToolbarItem.Identifier("tbd.toolbar.repoFilter")
    /// The tracking separator between the sidebar's part of the toolbar and
    /// the main area's, under an identifier of TBD's own. AppKit builds its
    /// own item for the standard `.sidebarTrackingSeparator`, bound to a
    /// divider it finds itself, and re-binding that item can raise a KVO
    /// exception. For this identifier the toolbar's delegate makes the item,
    /// bound to the split from the start.
    static let sidebarSeparator = NSToolbarItem.Identifier("tbd.toolbar.sidebarTrackingSeparator")
    static let title = NSToolbarItem.Identifier("tbd.toolbar.title")
    static let servers = NSToolbarItem.Identifier("tbd.toolbar.servers")
    static let remoteTranscript = NSToolbarItem.Identifier("tbd.toolbar.remoteTranscript")
    static let remoteReconnect = NSToolbarItem.Identifier("tbd.toolbar.remoteReconnect")
    static let remoteStop = NSToolbarItem.Identifier("tbd.toolbar.remoteStop")

    /// TBD's own identifiers, in toolbar order: the one list of them.
    static let custom: [NSToolbarItem.Identifier] = [
        toggleSidebar, back, forward, repoFilter, sidebarSeparator, title,
        servers, remoteTranscript, remoteReconnect, remoteStop,
    ]

    /// The standard identifiers the layout uses: the spaces only.
    static let standard: [NSToolbarItem.Identifier] = [.flexibleSpace, .space]

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
}

/// One step turning the toolbar's current item list into the next.
enum ToolbarEdit: Equatable {
    case remove(at: Int)
    case insert(NSToolbarItem.Identifier, at: Int)
}

/// The edit `MainToolbarLayout.perform` stopped at, and why.
enum ToolbarEditStop: Equatable {
    /// The index lay outside the list as it stood, so the edit was not
    /// carried out.
    case outOfRange(ToolbarEdit)
    /// The edit was carried out but did not grow or shrink the list by one:
    /// for an insert, the toolbar's delegate served no item.
    case noEffect(ToolbarEdit)
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
        ids.append(MainToolbarItemID.sidebarSeparator)
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
    /// loop the toolbar runs, through `ToolbarLayoutSync`, and the tests run
    /// over a plain list. `count` reads the list's length as it stands, and
    /// is how an edit reports that it took.
    ///
    /// Each index assumes every edit before it took, so the loop stops at the
    /// first edit whose index lies outside the list, without carrying it out,
    /// or that leaves the length as it was, such as an insert the toolbar's
    /// delegate could not serve. Carrying on would put later items in the
    /// wrong places, or past the end, where `NSToolbar` raises.
    ///
    /// - Returns: where it stopped, or `nil` when every edit took.
    @discardableResult
    static func perform(
        _ edits: [ToolbarEdit],
        count: () -> Int,
        remove: (Int) -> Void,
        insert: (NSToolbarItem.Identifier, Int) -> Void
    ) -> ToolbarEditStop? {
        for edit in edits {
            let before = count()
            switch edit {
            case .remove(let index):
                guard index >= 0, index < before else { return .outOfRange(edit) }
                remove(index)
                guard count() == before - 1 else { return .noEffect(edit) }
            case .insert(let identifier, let index):
                guard index >= 0, index <= before else { return .outOfRange(edit) }
                insert(identifier, index)
                guard count() == before + 1 else { return .noEffect(edit) }
            }
        }
        return nil
    }
}

/// Keeps the toolbar's items in step with a layout's target, one pass per
/// apply, through `MainToolbarLayout.perform`.
///
/// A pass that stops at an insert the toolbar's delegate could not serve,
/// such as the tracking separator once its split is gone, leaves that
/// identifier out of the passes after it, so the next one lands the rest of
/// the layout instead of stopping in the same place. The identifier is tried
/// again once the target changes, or after `reset()`, which the controller
/// calls on each install.
///
/// A stop asks for another pass only when that pass would get further,
/// because it leaves out one more identifier. The target holds only so many,
/// so an item the delegate never serves ends the passes rather than looping
/// them. Any other stop waits for the next apply.
struct ToolbarLayoutSync {
    enum Outcome: Equatable {
        /// The items match the target, less `refused`, after `edits` edits.
        case landed(edits: Int)
        /// The pass stopped at `stop`; `retry` when another pass would get
        /// further.
        case stopped(ToolbarEditStop, retry: Bool)
    }

    /// Identifiers left out of the target, each because an insert of it
    /// yielded no item.
    private(set) var refused: Set<NSToolbarItem.Identifier> = []
    /// The target `refused` was learned against.
    private var refusedTarget: [NSToolbarItem.Identifier] = []

    /// Forgets every refusal, so the next pass tries each identifier again.
    mutating func reset() {
        refused.removeAll()
        refusedTarget.removeAll()
    }

    /// Brings the list toward `target`, less `refused`, from `current`, the
    /// items as they stand. `count`, `remove` and `insert` act on the same
    /// list, as `MainToolbarLayout.perform` takes them.
    mutating func pass(
        to target: [NSToolbarItem.Identifier],
        from current: [NSToolbarItem.Identifier],
        count: () -> Int,
        remove: (Int) -> Void,
        insert: (NSToolbarItem.Identifier, Int) -> Void
    ) -> Outcome {
        if target != refusedTarget {
            refused.removeAll()
            refusedTarget = target
        }
        let wanted = target.filter { !refused.contains($0) }
        let edits = MainToolbarLayout.edits(from: current, to: wanted)
        guard let stop = MainToolbarLayout.perform(edits, count: count, remove: remove, insert: insert) else {
            return .landed(edits: edits.count)
        }
        guard case .noEffect(.insert(let identifier, _)) = stop else {
            return .stopped(stop, retry: false)
        }
        return .stopped(stop, retry: refused.insert(identifier).inserted)
    }
}

/// The sizes the toolbar's layout rests on: the compact leading buttons, the
/// sidebar's minimum thickness derived from them, and the title item's
/// flexible width.
///
/// AppKit moves a toolbar item that does not fit its section into the
/// toolbar's overflow menu, out of its place, so the sidebar can never be
/// narrower than the items over it. AppKit publishes
/// neither its spacing between items nor where it places the first item after
/// the window buttons, so `interItemSpacing` and `firstItemLeadingInset` are
/// estimates, taken from a reference macOS 27 toolbar whose window buttons,
/// sidebar toggle, back and forward sit 28 pt apart. The running app confirms
/// or tightens them.
enum MainToolbarMetrics {
    /// The distance from one leading button's centre to the next: the
    /// reference toolbar's 28 pt, split into `iconButtonWidth` and
    /// `interItemSpacing`.
    static let iconButtonPitch: CGFloat = 28
    /// AppKit's spacing between adjacent toolbar items. It is not public, so
    /// this is an estimate the running app confirms: when the buttons it
    /// shows are not `iconButtonPitch` apart, this is the constant to tune.
    static let interItemSpacing: CGFloat = 8
    /// A leading button's width: the pitch less AppKit's spacing, so adjacent
    /// buttons sit `iconButtonPitch` apart.
    static let iconButtonWidth: CGFloat = iconButtonPitch - interItemSpacing
    /// A leading button's height. AppKit centres items vertically in the
    /// toolbar, which puts the glyphs on the window buttons' line.
    static let iconButtonHeight: CGFloat = 28
    /// The point size of a leading button's symbol, drawn at regular weight.
    static let iconGlyphPointSize: CGFloat = 13
    /// From the window's leading edge to the first item's leading edge: where
    /// AppKit places the first item after the window buttons. Estimated from
    /// the reference toolbar, whose toggle is centred 97.8 pt from the edge,
    /// less half a button.
    static let firstItemLeadingInset: CGFloat = 88
    /// The repo filter's widest, past which a long repo name truncates.
    static let filterMaxWidth: CGFloat = 110
    /// The margin the sidebar's section keeps before the tracking separator.
    static let sectionPadding: CGFloat = 20
    /// The sidebar's section at its narrowest, left to right: the leading
    /// inset; toggle, back and forward, each followed by one spacing; the
    /// flexible space, empty at this width but still spaced on both sides,
    /// so one more spacing before the filter; the filter at its widest; and
    /// the margin before the separator. 310 pt with the estimates above.
    /// Three buttons and four spacings are three pitches and one more
    /// spacing, so the thickness grows with the spacing estimate.
    static let sidebarMinimumThickness: CGFloat =
        firstItemLeadingInset + 3 * iconButtonWidth + 4 * interItemSpacing + filterMaxWidth + sectionPadding
    static let sidebarMaximumThickness: CGFloat = 400

    /// The title item's narrowest, which the title view holds as a required
    /// minimum: when AppKit measures the item's range through its
    /// constraints, the item can shrink this far before the right-hand items
    /// overflow. A title wider than the space it gets is cut at the trailing
    /// edge. A choice, not a measurement.
    static let titleMinimumWidth: CGFloat = 80
    /// The width a fitting measurement gives the title item: the title
    /// cluster's hosting view reports it as its intrinsic width, and its
    /// compression resistance outweighs a fitting measurement's pull, so the
    /// measurement lands here whatever the text says. When AppKit measures
    /// the item's range through its constraints, the item can still shrink
    /// toward the minimum or grow toward the maximum. A choice, not a
    /// measurement.
    static let titleIdealWidth: CGFloat = 240
    /// The title item's widest. The title view prefers it at a low priority,
    /// so the item fills the space up to the right-hand items on any window
    /// a person uses; a wider window leaves the rest to the flexible space
    /// after it. A choice, not a measurement.
    static let titleMaximumWidth: CGFloat = 2000
}
