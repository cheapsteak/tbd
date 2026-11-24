import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Collects the actions a menu sends, on the main actor its target calls from.
@MainActor
private final class ActionRecorder {
    private(set) var actions: [TabContextMenu.Action] = []

    func record(_ action: TabContextMenu.Action) {
        actions.append(action)
    }
}

/// The tab's right-click menu, built with no menu shown. Titles, order,
/// submenus and enabled state must match the SwiftUI menu it replaces.
@MainActor
@Suite("TabContextMenu — the tab's right-click menu")
struct TabContextMenuTests {
    private let workID = UUID()
    private let personalID = UUID()

    // MARK: - Helpers

    private func build(_ model: TabContextMenu.Model, _ recorder: ActionRecorder) -> NSMenu {
        TabContextMenu.build(model: model) { recorder.record($0) }
    }

    /// Item titles in order, a separator as "—".
    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try #require(menu.item(withTitle: title), "no item titled \(title)")
    }

    private func submenu(_ title: String, in menu: NSMenu) throws -> NSMenu {
        let parent = try item(title, in: menu)
        return try #require(parent.submenu, "\(title) has no submenu")
    }

    /// Clicks `item` the way AppKit would: its action, sent to its target.
    private func fire(_ item: NSMenuItem) throws {
        let expectedAction = #selector(TabContextMenuTarget.fire(_:))
        #expect(item.action == expectedAction, "\(item.title) sends \(String(describing: item.action))")
        let target = try #require(item.target as? TabContextMenuTarget, "\(item.title) has no menu target")
        target.fire(item)
    }

    /// A live Claude tab on the pty holder, on the Work profile.
    private func liveClaudeModel() -> TabContextMenu.Model {
        TabContextMenu.Model(
            sessionID: "acme-session",
            pinTitle: "Pin",
            isClaude: true,
            profileHeader: "Profile: Work",
            offersInPlaceSwap: true,
            currentProfileID: workID,
            accounts: [
                TabContextMenu.Account(profileID: workID, name: "Work", usage: .none),
                TabContextMenu.Account(profileID: personalID, name: "Personal", usage: .none),
            ],
            showsContinueInCodex: true,
            parkAction: .hibernate,
            isRenameable: true
        )
    }

    /// The widths a title spaces its runs by: each attachment's width and each
    /// kern. Two titles that line their bars up at the same x agree on these.
    private func spacing(_ title: NSAttributedString?) -> [CGFloat] {
        guard let title else { return [] }
        var widths: [CGFloat] = []
        var index = 0
        while index < title.length {
            var range = NSRange()
            let attributes = title.attributes(at: index, effectiveRange: &range)
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                widths.append(attachment.bounds.width)
            }
            if let kern = attributes[.kern] as? NSNumber {
                widths.append(CGFloat(kern.doubleValue))
            }
            index = range.upperBound
        }
        return widths
    }

    // MARK: - Which items show

    @Test func shellTabShowsOnlyGenericItems() {
        let menu = build(TabContextMenu.Model(isRenameable: true), ActionRecorder())
        #expect(titles(menu) == ["Copy Link", "—", "Rename Tab", "—", "Close Tab"])
    }

    @Test func liveClaudeTabShowsSwapAndFork() {
        let menu = build(liveClaudeModel(), ActionRecorder())

        #expect(titles(menu) == [
            "Copy Link", "Copy Session ID", "—",
            "Pin", "—",
            "Profile: Work", "Swap profile", "—",
            "Fork Session", "Continue in Codex", "Hibernate", "—",
            "Rename Tab", "—",
            "Close Tab",
        ])
        let withIcon = Set(menu.items.filter { $0.image != nil }.map(\.title))
        #expect(withIcon == ["Pin", "Fork Session", "Continue in Codex", "Hibernate", "Close Tab"])
    }

    /// A running row still on tmux cannot switch in place, so only a fork is
    /// offered, and the separator before Fork Session stays.
    @Test func runningTmuxRowOffersForkOnly() {
        var model = liveClaudeModel()
        model.offersInPlaceSwap = false
        let menu = build(model, ActionRecorder())

        #expect(titles(menu) == [
            "Copy Link", "Copy Session ID", "—",
            "Pin", "—",
            "Profile: Work", "—",
            "Fork Session", "Continue in Codex", "Hibernate", "—",
            "Rename Tab", "—",
            "Close Tab",
        ])
    }

    @Test func parkedTabOffersWake() throws {
        var model = liveClaudeModel()
        model.parkAction = .wake
        let recorder = ActionRecorder()
        let menu = build(model, recorder)

        let names = titles(menu)
        #expect(names.contains("Hibernate") == false)
        let wake = try item("Wake", in: menu)
        #expect(wake.image != nil)
        try fire(wake)
        #expect(recorder.actions == [.wake])
    }

    @Test func noParkActionShowsNeitherHibernateNorWake() {
        var model = liveClaudeModel()
        model.parkAction = nil
        let names = titles(build(model, ActionRecorder()))
        #expect(names.contains("Hibernate") == false)
        #expect(names.contains("Wake") == false)
    }

    @Test func scheduledResumeOffersCancel() throws {
        var model = liveClaudeModel()
        model.hasScheduledResume = true
        let recorder = ActionRecorder()
        let menu = build(model, recorder)

        let names = titles(menu)
        let hibernate = try #require(names.firstIndex(of: "Hibernate"))
        #expect(names[hibernate + 1] == "Cancel Scheduled Resume")
        let cancel = try item("Cancel Scheduled Resume", in: menu)
        #expect(cancel.image != nil)
        try fire(cancel)
        #expect(recorder.actions == [.cancelScheduledResume])
    }

    @Test func pinnedTabOffersUnpin() throws {
        var model = liveClaudeModel()
        model.pinTitle = "Unpin"
        model.isPinned = true
        let recorder = ActionRecorder()
        let menu = build(model, recorder)

        #expect(titles(menu).contains("Pin") == false)
        try fire(item("Unpin", in: menu))
        #expect(recorder.actions == [.setPinned(false)])
    }

    /// A shell on tmux offers the move; it sits after the pin, before the
    /// Claude items, because shells move too.
    @Test func moveToHolderSitsAfterThePin() throws {
        let model = TabContextMenu.Model(pinTitle: "Pin", offersMoveToHolder: true, isRenameable: true)
        let recorder = ActionRecorder()
        let menu = build(model, recorder)

        #expect(titles(menu) == [
            "Copy Link", "—",
            "Pin", "—",
            TransportMigrationVocabulary.menuTitle, "—",
            "Rename Tab", "—",
            "Close Tab",
        ])
        let move = try item(TransportMigrationVocabulary.menuTitle, in: menu)
        #expect(move.image != nil)
        try fire(move)
        #expect(recorder.actions == [.moveToHolder])
    }

    @Test func fileTabLeadsWithFileItems() throws {
        let path = "/tmp/acme/notes.md"
        let editor = URL(fileURLWithPath: "/Applications/Acme Editor.app")
        let viewer = URL(fileURLWithPath: "/Applications/Acme Viewer.app")
        let model = TabContextMenu.Model(
            fileTarget: HeaderMenuTarget(path: path, copyLabel: "Copy Path"),
            openWithApps: [OpenWithApp(url: editor), OpenWithApp(url: viewer)]
        )
        let recorder = ActionRecorder()
        let menu = build(model, recorder)

        #expect(titles(menu) == ["Copy Path", "Reveal in Finder", "Open With", "Copy Link", "—", "Close Tab"])
        let openWith = try submenu("Open With", in: menu)
        #expect(titles(openWith) == ["Acme Editor", "Acme Viewer"])
        #expect(openWith.autoenablesItems == false)
        let viewerItem = try item("Acme Viewer", in: openWith)
        #expect(viewerItem.image?.size == NSSize(width: 16, height: 16))

        try fire(viewerItem)
        try fire(item("Copy Path", in: menu))
        try fire(item("Reveal in Finder", in: menu))
        #expect(recorder.actions == [
            .openWith(path: path, app: viewer),
            .copyPath(path),
            .revealInFinder(path),
        ])
    }

    @Test func fileTabWithNoAppsHasNoOpenWith() {
        let model = TabContextMenu.Model(
            fileTarget: HeaderMenuTarget(path: "/tmp/acme/session.jsonl", copyLabel: "Copy Conversation Path")
        )
        let menu = build(model, ActionRecorder())
        #expect(titles(menu) == ["Copy Conversation Path", "Reveal in Finder", "Copy Link", "—", "Close Tab"])
    }

    // MARK: - Actions

    @Test func eachItemSendsItsAction() throws {
        let recorder = ActionRecorder()
        let menu = build(liveClaudeModel(), recorder)

        for title in [
            "Copy Link", "Copy Session ID", "Pin", "Continue in Codex", "Hibernate", "Rename Tab", "Close Tab",
        ] {
            try fire(item(title, in: menu))
        }
        #expect(recorder.actions == [
            .copyLink,
            .copySessionID("acme-session"),
            .setPinned(true),
            .continueInCodex,
            .hibernate,
            .rename,
            .close,
        ])
    }

    // MARK: - Account submenus

    @Test func accountSubmenuChecksCurrentAndSendsIDs() throws {
        var model = liveClaudeModel()
        model.currentProfileID = personalID
        let recorder = ActionRecorder()
        let menu = build(model, recorder)
        let swap = try submenu("Swap profile", in: menu)
        let fork = try submenu("Fork Session", in: menu)

        for accounts in [swap, fork] {
            #expect(titles(accounts) == ["Default (logged in)", "—", "Work", "Personal"])
            #expect(accounts.autoenablesItems == false)
            let defaultState = try item("Default (logged in)", in: accounts).state
            let workState = try item("Work", in: accounts).state
            let personalState = try item("Personal", in: accounts).state
            #expect(defaultState == .off)
            #expect(workState == .off)
            #expect(personalState == .on)
        }

        try fire(item("Work", in: swap))
        try fire(item("Work", in: fork))
        try fire(item("Default (logged in)", in: swap))
        try fire(item("Default (logged in)", in: fork))
        #expect(recorder.actions == [
            .swapProfile(workID),
            .forkSession(workID),
            .swapProfile(nil),
            .forkSession(nil),
        ])
    }

    @Test func defaultLoginIsCheckedWhenTheTabHasNoProfile() throws {
        var model = liveClaudeModel()
        model.currentProfileID = nil
        let menu = build(model, ActionRecorder())
        let swap = try submenu("Swap profile", in: menu)

        let defaultState = try item("Default (logged in)", in: swap).state
        let workState = try item("Work", in: swap).state
        #expect(defaultState == .on)
        #expect(workState == .off)
    }

    @Test func busyCaptionEndsSwapProfileOnly() throws {
        var model = liveClaudeModel()
        model.busyCaption = SwapProfileMenu.interruptsRunCaption
        let menu = build(model, ActionRecorder())
        let swap = try submenu("Swap profile", in: menu)
        let fork = try submenu("Fork Session", in: menu)

        #expect(Array(titles(swap).suffix(2)) == ["—", SwapProfileMenu.interruptsRunCaption])
        let caption = try #require(swap.items.last)
        #expect(caption.isEnabled == false)
        #expect(caption.action == nil)
        #expect(titles(fork) == ["Default (logged in)", "—", "Work", "Personal"])
    }

    /// Each account row goes through `AccountMenuRow`: the plain title stays
    /// the name, and a row with usage gets the drawn title.
    @Test func accountRowsKeepTheNameAsTheirPlainTitle() throws {
        let note = "rate-limited · 3h old"
        var model = liveClaudeModel()
        model.accounts = [
            TabContextMenu.Account(profileID: workID, name: "Work", usage: .note(note)),
            TabContextMenu.Account(profileID: personalID, name: "Personal", usage: .none),
        ]
        let menu = build(model, ActionRecorder())
        let swap = try submenu("Swap profile", in: menu)

        let work = try item("Work", in: swap)
        let drawn = try #require(work.attributedTitle)
        #expect(drawn.string.hasPrefix("Work"))
        #expect(drawn.string.hasSuffix(note))
        let personal = try item("Personal", in: swap)
        #expect(personal.attributedTitle == nil)
    }

    /// Every row of a submenu shares one name column, so the bars start at the
    /// same x: each row is spaced as `AccountMenuRow` spaces it for the widest
    /// name among all the rows, not for its own name.
    @Test func accountRowsShareOneNameColumn() throws {
        let note = "rate-limited · 3h old"
        let shortName = "A"
        let longName = "A much longer account name"
        var model = liveClaudeModel()
        model.accounts = [
            TabContextMenu.Account(profileID: workID, name: shortName, usage: .note(note)),
            TabContextMenu.Account(profileID: personalID, name: longName, usage: .note(note)),
        ]
        let rows: [(name: String, usage: ProfileUsagePresentation.MenuUsage)] = [
            (name: shortName, usage: .note(note)),
            (name: longName, usage: .note(note)),
        ]
        let sharedWidth = AccountMenuRow.nameColumnWidth(rows)
        let menu = build(model, ActionRecorder())

        for submenuTitle in ["Swap profile", "Fork Session"] {
            let accounts = try submenu(submenuTitle, in: menu)
            for row in rows {
                let expected = NSMenuItem(title: row.name, action: nil, keyEquivalent: "")
                AccountMenuRow.apply(to: expected, name: row.name, usage: row.usage, nameColumnWidth: sharedWidth)
                let built = try item(row.name, in: accounts)
                #expect(spacing(built.attributedTitle) == spacing(expected.attributedTitle),
                        "\(submenuTitle): \(row.name)")
            }
        }

        // The check above can tell the two apart: the short name alone would
        // be spaced differently.
        let ownColumn = NSMenuItem(title: shortName, action: nil, keyEquivalent: "")
        AccountMenuRow.apply(
            to: ownColumn, name: shortName, usage: .note(note),
            nameColumnWidth: AccountMenuRow.nameColumnWidth([(name: shortName, usage: .note(note))]))
        let shared = NSMenuItem(title: shortName, action: nil, keyEquivalent: "")
        AccountMenuRow.apply(to: shared, name: shortName, usage: .note(note), nameColumnWidth: sharedWidth)
        #expect(spacing(ownColumn.attributedTitle) != spacing(shared.attributedTitle))
    }

    // MARK: - Enabled state and lifetime

    @Test func profileHeaderIsDisabled() throws {
        let menu = build(liveClaudeModel(), ActionRecorder())

        let header = try item("Profile: Work", in: menu)
        #expect(header.isEnabled == false)
        #expect(menu.autoenablesItems == false)
        let others = menu.items.filter { !$0.isSeparatorItem && $0 !== header }
        let disabled = others.filter { !$0.isEnabled }.map(\.title)
        #expect(disabled.isEmpty, "disabled: \(disabled)")
    }

    /// `NSMenuItem.target` is weak, so only the menu keeps the target alive
    /// once `build` returns.
    @Test func menuRetainsItsTarget() throws {
        let recorder = ActionRecorder()
        let menu = autoreleasepool { build(TabContextMenu.Model(), recorder) }

        let retained = objc_getAssociatedObject(menu, TabContextMenu.targetKey.utf8Start) as? TabContextMenuTarget
        #expect(retained != nil)
        let close = try item("Close Tab", in: menu)
        #expect(close.target === retained)
        try fire(close)
        #expect(recorder.actions == [.close])
    }
}
