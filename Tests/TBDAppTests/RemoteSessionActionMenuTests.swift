import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Task 10: pure composition of a remote-session row's context menu
/// (`RemoteSessionActionMenu.items(capabilities:gone:isPinned:)`). One test per
/// capability gate branch, per repo policy for behavior-gating conditionals.
@Suite("Remote session action menu — pure composition")
struct RemoteSessionActionMenuTests {
    private typealias Item = RemoteSessionActionMenu.Item
    private typealias Kind = RemoteSessionActionMenu.Kind

    private func kinds(_ items: [Item]) -> [Kind?] {
        items.map { item in
            if case let .action(action) = item { return action.kind }
            return nil
        }
    }

    // MARK: - gone rows collapse, regardless of capabilities

    @Test func goneRowCollapsesToCopySessionIDAndDismiss() {
        let items = RemoteSessionActionMenu.items(capabilities: ["attach", "log", "send"], gone: true, isPinned: false)
        #expect(kinds(items) == [.copySessionID, .pin, .dismiss])
    }

    @Test func goneRowCollapsesEvenWithNoCapabilities() {
        let items = RemoteSessionActionMenu.items(capabilities: [], gone: true, isPinned: false)
        #expect(kinds(items) == [.copySessionID, .pin, .dismiss])
    }

    @Test func goneRowNeverIncludesRenameOrStop() {
        let items = RemoteSessionActionMenu.items(capabilities: ["attach", "log", "send"], gone: true, isPinned: false)
        let allKinds = Set(kinds(items).compactMap { $0 })
        #expect(!allKinds.contains(.rename))
        #expect(!allKinds.contains(.stop))
        #expect(!allKinds.contains(.attach))
        #expect(!allKinds.contains(.viewLog))
        #expect(!allKinds.contains(.sendText))
    }

    // MARK: - live rows: base shape with no optional capabilities

    @Test func liveRowWithNoCapabilitiesShowsRenameCopyDividerStop() {
        let items = RemoteSessionActionMenu.items(capabilities: [], gone: false, isPinned: false)
        #expect(kinds(items) == [.rename, .copySessionID, .pin, nil, .stop])
        #expect(items.last == .action(RemoteSessionActionMenu.Action(
            kind: .stop, title: RemoteSessionActionMenu.stopLabel, role: .destructive)))
    }

    // MARK: - live rows: one capability gate at a time

    @Test func attachCapabilityAddsAttachItem() {
        let items = RemoteSessionActionMenu.items(capabilities: ["attach"], gone: false, isPinned: false)
        #expect(kinds(items) == [.rename, .attach, .copySessionID, .pin, nil, .stop])
    }

    @Test func attachCapabilityAbsentOmitsAttachItem() {
        let items = RemoteSessionActionMenu.items(capabilities: [], gone: false, isPinned: false)
        #expect(!kinds(items).contains(.attach))
    }

    @Test func logCapabilityAddsViewLogItem() {
        let items = RemoteSessionActionMenu.items(capabilities: ["log"], gone: false, isPinned: false)
        #expect(kinds(items) == [.rename, .viewLog, .copySessionID, .pin, nil, .stop])
    }

    @Test func logCapabilityAbsentOmitsViewLogItem() {
        let items = RemoteSessionActionMenu.items(capabilities: [], gone: false, isPinned: false)
        #expect(!kinds(items).contains(.viewLog))
    }

    @Test func sendCapabilityAddsSendTextItem() {
        let items = RemoteSessionActionMenu.items(capabilities: ["send"], gone: false, isPinned: false)
        #expect(kinds(items) == [.rename, .sendText, .copySessionID, .pin, nil, .stop])
    }

    @Test func sendCapabilityAbsentOmitsSendTextItem() {
        let items = RemoteSessionActionMenu.items(capabilities: [], gone: false, isPinned: false)
        #expect(!kinds(items).contains(.sendText))
    }

    // MARK: - full capability set: exact order

    @Test func allCapabilitiesProduceTheFullOrderedMenu() {
        let items = RemoteSessionActionMenu.items(capabilities: ["attach", "log", "send"], gone: false, isPinned: false)
        #expect(kinds(items) == [.rename, .attach, .viewLog, .sendText, .copySessionID, .pin, nil, .stop])
    }

    @Test func staleSnapshotKeepsInspectionAndDropsStateChangingActions() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["attach", "log", "send"], gone: false,
            snapshotFresh: false, isPinned: false)
        #expect(kinds(items) == [.attach, .viewLog, .copySessionID, .pin])
        #expect(!kinds(items).contains(.rename))
        #expect(!kinds(items).contains(.sendText))
        #expect(!kinds(items).contains(.stop))
    }

    /// Items are omitted, never disabled — `RemoteSessionActionMenu` carries
    /// no `isEnabled`/disabled-help concept the way `RowActionMenu.Action`
    /// does, so an absent capability simply never produces an `Action` at
    /// all (already exercised above); this pins the composed list length as
    /// an extra guard against a future accidental "always append, gate
    /// visibility in the view" regression.
    @Test func itemCountMatchesExactlyTheDeclaredCapabilities() {
        #expect(RemoteSessionActionMenu.items(capabilities: [], gone: false, isPinned: false).count == 5) // rename, copy, pin, divider, stop
        #expect(RemoteSessionActionMenu.items(capabilities: ["attach", "log", "send"], gone: false, isPinned: false).count == 8)
    }

    // MARK: - unrecognized capability strings are ignored, not erroring

    @Test func unrecognizedCapabilityStringsAreIgnored() {
        let items = RemoteSessionActionMenu.items(capabilities: ["events", "rename", "future-verb"], gone: false, isPinned: false)
        // `rename` (the capability) doesn't map to any menu item here — the
        // rename PUSH is handled entirely by `AppState.supportsRenamePush`,
        // not this menu; "Rename…" is always present regardless.
        #expect(kinds(items) == [.rename, .copySessionID, .pin, nil, .stop])
    }

    // MARK: - pin toggle: both branches, both row states

    @Test func unpinnedLiveRowOffersPin() {
        let items = RemoteSessionActionMenu.items(capabilities: [], gone: false, isPinned: false)
        #expect(kinds(items) == [.rename, .copySessionID, .pin, nil, .stop])
        #expect(items.contains(.action(RemoteSessionActionMenu.Action(
            kind: .pin, title: RemoteSessionActionMenu.pinLabel))))
    }

    @Test func pinnedLiveRowOffersUnpinInstead() {
        let items = RemoteSessionActionMenu.items(capabilities: [], gone: false, isPinned: true)
        #expect(kinds(items) == [.rename, .copySessionID, .unpin, nil, .stop])
        #expect(items.contains(.action(RemoteSessionActionMenu.Action(
            kind: .unpin, title: RemoteSessionActionMenu.unpinLabel))))
    }

    /// The whole point of carrying the toggle into the collapsed branch: a
    /// pinned session that stops being reported must still be unpinnable
    /// without dismissing it.
    @Test func pinnedGoneRowStillOffersUnpin() {
        let items = RemoteSessionActionMenu.items(capabilities: [], gone: true, isPinned: true)
        #expect(kinds(items) == [.copySessionID, .unpin, .dismiss])
    }

    @Test func unpinnedGoneRowOffersPin() {
        let items = RemoteSessionActionMenu.items(capabilities: [], gone: true, isPinned: false)
        #expect(kinds(items) == [.copySessionID, .pin, .dismiss])
    }

    /// Pin is local-only — it needs no provider capability, so it appears
    /// with an empty capability list and with a full one alike.
    @Test func pinToggleIsNeverCapabilityGated() {
        for capabilities in [[], ["attach", "log", "send"]] {
            for gone in [true, false] {
                let items = RemoteSessionActionMenu.items(
                    capabilities: capabilities, gone: gone, isPinned: false)
                #expect(kinds(items).contains(.pin))
            }
        }
    }

    /// A remote row and a worktree row must name the same dock the same way.
    @Test func pinWordingMatchesTheWorktreeRowMenu() {
        #expect(RemoteSessionActionMenu.pinLabel == RowActionMenu.pinLabel)
        #expect(RemoteSessionActionMenu.unpinLabel == RowActionMenu.unpinLabel)
    }
}
