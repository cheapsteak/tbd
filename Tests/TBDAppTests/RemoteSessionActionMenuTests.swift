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

    /// The log view is a fallback the detail pane shows on its own when
    /// attach is unavailable, never a menu destination: raw log text is not a
    /// place anyone navigates to on purpose.
    @Test func logCapabilityAddsNoMenuItem() {
        let items = RemoteSessionActionMenu.items(capabilities: ["log"], gone: false, isPinned: false)
        #expect(kinds(items) == [.rename, .copySessionID, .pin, nil, .stop])
    }

    @Test func sendCapabilityAddsSendTextItem() {
        let items = RemoteSessionActionMenu.items(capabilities: ["send"], gone: false, isPinned: false)
        #expect(kinds(items) == [.rename, .sendText, .copySessionID, .pin, nil, .stop])
    }

    /// Send Text… lives only where the pane has a send footer. With a live
    /// attached terminal, typing goes straight into it, so the item would
    /// only duplicate it.
    @Test func sendTextOmittedWhenAttachIsDeclared() {
        let items = RemoteSessionActionMenu.items(capabilities: ["attach", "send"], gone: false, isPinned: false)
        #expect(!kinds(items).contains(.sendText))
        #expect(kinds(items) == [.rename, .attach, .copySessionID, .pin, nil, .stop])
    }

    /// When selecting the session would not attach — detached, exited, or
    /// its provider needs authentication — the pane shows a send footer, so
    /// the item comes back even though `attach` is declared.
    @Test func sendTextOfferedWhenLiveAttachIsUnavailable() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["attach", "send"], gone: false, isPinned: false, liveAttachUnavailable: true)
        #expect(kinds(items) == [.rename, .attach, .sendText, .copySessionID, .pin, nil, .stop])
        // Still withheld on a stale snapshot.
        #expect(!kinds(RemoteSessionActionMenu.items(
            capabilities: ["attach", "send"], gone: false, snapshotFresh: false,
            isPinned: false, liveAttachUnavailable: true)).contains(.sendText))
    }

    @Test func sendTextOfferedAlongsideTheLogFallback() {
        let items = RemoteSessionActionMenu.items(capabilities: ["log", "send"], gone: false, isPinned: false)
        #expect(kinds(items) == [.rename, .sendText, .copySessionID, .pin, nil, .stop])
    }

    @Test func sendCapabilityAbsentOmitsSendTextItem() {
        let items = RemoteSessionActionMenu.items(capabilities: [], gone: false, isPinned: false)
        #expect(!kinds(items).contains(.sendText))
    }

    // MARK: - Reconnect: offered only while this app holds an attach pane

    @Test func reconnectFollowsAttachWhenAttached() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["attach"], gone: false, isPinned: false, isAttached: true)
        #expect(kinds(items) == [.rename, .attach, .reconnect, .copySessionID, .pin, nil, .stop])
    }

    @Test func reconnectOmittedWhenNotAttached() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["attach"], gone: false, isPinned: false, isAttached: false)
        #expect(!kinds(items).contains(.reconnect))
        #expect(!kinds(RemoteSessionActionMenu.items(
            capabilities: ["attach"], gone: false, isPinned: false)).contains(.reconnect))
    }

    /// Reconnect re-runs the provider's `attach` verb, so without the
    /// capability there is nothing to restart even if the flag claims a pane.
    @Test func reconnectOmittedWithoutAttachCapability() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["log"], gone: false, isPinned: false, isAttached: true)
        #expect(!kinds(items).contains(.reconnect))
    }

    /// Local like Attach — a stale inventory does not withhold it.
    @Test func reconnectSurvivesAStaleSnapshot() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["attach"], gone: false, snapshotFresh: false,
            isPinned: false, isAttached: true)
        #expect(kinds(items) == [.attach, .reconnect, .copySessionID, .pin])
    }

    @Test func reconnectNeverOfferedOnAGoneRow() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["attach"], gone: true, isPinned: false, isAttached: true)
        #expect(!kinds(items).contains(.reconnect))
    }

    // MARK: - full capability set: exact order

    @Test func allCapabilitiesProduceTheFullOrderedMenu() {
        let items = RemoteSessionActionMenu.items(capabilities: ["attach", "log", "send"], gone: false, isPinned: false)
        #expect(kinds(items) == [.rename, .attach, .copySessionID, .pin, nil, .stop])
    }

    @Test func staleSnapshotKeepsInspectionAndDropsStateChangingActions() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["attach", "log", "send"], gone: false,
            snapshotFresh: false, isPinned: false)
        #expect(kinds(items) == [.attach, .copySessionID, .pin])
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
        #expect(RemoteSessionActionMenu.items(capabilities: ["attach", "log", "send"], gone: false, isPinned: false).count == 6)
    }

    // MARK: - Dismiss: offered for gone OR exited, never for a live running row

    /// The gate this parameter opens. A provider may keep an exited session
    /// listed indefinitely, so the row is not `gone`; on a provider that
    /// never implements `delete`, Dismiss is the only thing that removes it.
    @Test func dismissOfferedForExitedSession() {
        let items = RemoteSessionActionMenu.items(
            capabilities: [], gone: false, isPinned: false, exited: true)
        #expect(kinds(items).contains(.dismiss))
        // Immediately after the pin toggle and before the divider, so Stop
        // stays the last destructive item.
        #expect(kinds(items) == [.rename, .copySessionID, .pin, .dismiss, nil, .stop])
    }

    /// The pre-existing branch is untouched: a `gone` row still collapses to
    /// Copy + pin + Dismiss, whatever `exited` says.
    @Test func dismissOfferedForGoneSession() {
        for exited in [true, false] {
            let items = RemoteSessionActionMenu.items(
                capabilities: [], gone: true, isPinned: false, exited: exited)
            #expect(kinds(items) == [.copySessionID, .pin, .dismiss])
        }
    }

    /// The discriminating arm: a live, running row must NOT offer Dismiss —
    /// tombstoning a session the agent is still working in would hide live
    /// work behind a local-only gesture with no undo in the menu.
    @Test func dismissNotOfferedForLiveRunningSession() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["attach", "log", "send"], gone: false, isPinned: false, exited: false)
        #expect(!kinds(items).contains(.dismiss))
        // And the default keeps every existing call site on that branch.
        #expect(!kinds(RemoteSessionActionMenu.items(
            capabilities: [], gone: false, isPinned: false)).contains(.dismiss))
    }

    /// An exited row takes the LIVE branch, not the collapsed `gone` one: it
    /// keeps every inspection action plus Stop, and merely gains Dismiss.
    @Test func exitedSessionKeepsInspectionActions() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["attach", "log", "send"], gone: false, isPinned: false, exited: true)
        #expect(kinds(items) == [
            .rename, .attach, .copySessionID, .pin, .dismiss, nil, .stop,
        ])
        #expect(items.last == .action(RemoteSessionActionMenu.Action(
            kind: .stop, title: RemoteSessionActionMenu.stopLabel, role: .destructive)))
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

    // MARK: - Delete, behind the default-off flag

    private func deleteAction(_ items: [Item]) -> RemoteSessionActionMenu.Action? {
        items.compactMap { item -> RemoteSessionActionMenu.Action? in
            if case let .action(action) = item, action.kind == .delete { return action }
            return nil
        }.first
    }

    /// The flag's off branch — the shipped default, and the default of the
    /// parameter, so every pre-existing call site in this suite composes no
    /// Delete at all.
    @Test func deleteOmittedWhenFlagOff() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["delete"], gone: false, isPinned: false, deleteEnabled: false)
        #expect(!kinds(items).contains(.delete))
    }

    /// The flag's on branch, with the capability: present, enabled, destructive.
    @Test func deletePresentAndEnabledWithTheCapability() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["delete"], gone: false, isPinned: false, deleteEnabled: true)
        let delete = deleteAction(items)
        #expect(delete?.title == RemoteSessionActionMenu.deleteLabel)
        #expect(delete?.isEnabled == true)
        #expect(delete?.role == .destructive)
        #expect(delete?.disabledHelp == nil)
    }

    /// **Present but disabled**, not omitted — the one deliberate departure
    /// from this menu's omit-when-absent convention. Attach and Send Text
    /// vanish when undeclared; Delete stays and says why, because a user
    /// looking for the way to reclaim a session needs to be told the way exists
    /// and this provider has not built it yet.
    @Test func deletePresentButDisabledWithoutTheCapability() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["attach", "log"], gone: false, isPinned: false, deleteEnabled: true)
        let delete = deleteAction(items)
        #expect(delete?.title == RemoteSessionActionMenu.deleteProviderCannotDeleteLabel)
        #expect(delete?.title == "Delete (provider can't delete)")
        #expect(delete?.isEnabled == false)
        #expect(delete?.role == .destructive)
        #expect(delete?.disabledHelp == RemoteSessionActionMenu.deleteNeedsProviderCapabilityHelp)
    }

    /// The discriminating pair for the departure: an absent `attach` is
    /// omitted while an absent `delete` is present-and-disabled, in the very
    /// same menu. If someone "fixed" Delete into consistency, this goes red.
    @Test func anAbsentDeleteIsShownWhileAnAbsentAttachIsNot() {
        let items = RemoteSessionActionMenu.items(
            capabilities: [], gone: false, isPinned: false, deleteEnabled: true)
        #expect(!kinds(items).contains(.attach))
        #expect(kinds(items).contains(.delete))
    }

    /// Delete is last: it strictly outranks Stop, which ends compute without
    /// removing the record.
    @Test func deleteIsTheLastItemAfterStop() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["delete"], gone: false, isPinned: false, deleteEnabled: true)
        #expect(kinds(items) == [.rename, .copySessionID, .pin, nil, .stop, .delete])
    }

    /// A `gone` row keeps its collapsed shape: the provider has stopped
    /// enumerating that session, so there is nothing left there to destroy and
    /// Dismiss is the row's removal gesture.
    @Test func deleteNotOfferedForAGoneRow() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["delete"], gone: true, isPinned: false, deleteEnabled: true)
        #expect(kinds(items) == [.copySessionID, .pin, .dismiss])
    }

    /// A stale inventory omits Delete with Stop, for the same reason: provider
    /// mutations wait for an inventory worth trusting.
    @Test func deleteOmittedWhileTheSnapshotIsStale() {
        let items = RemoteSessionActionMenu.items(
            capabilities: ["delete"], gone: false, snapshotFresh: false,
            isPinned: false, deleteEnabled: true)
        #expect(!kinds(items).contains(.delete))
        #expect(!kinds(items).contains(.stop))
    }
}
